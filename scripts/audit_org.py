#!/usr/bin/env python3
"""Read-only governance and hygiene drift auditor for Heretek-AI.

Checks organization security settings, Actions policy and allowlisting, OIDC
subject claims, runner and secret scoping, code security configurations,
third-party app permissions, fleet-manifest.json coverage, custom properties,
Tier 1 rulesets, immutable releases, unpinned workflow actions, missing
licenses or descriptions, and stale chore/sync-org-standards pull requests.

Every check is read-only (GET). A failed critical read is reported under
`unavailable` instead of being treated as healthy.

Usage:
  python3 scripts/audit_org.py [--format markdown|json] [--strict]
"""

from __future__ import annotations

import argparse
import base64
import binascii
import concurrent.futures
import json
import pathlib
import re
import subprocess
import sys
import urllib.parse
from datetime import datetime, timezone
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFEST_PATH = ROOT / "fleet-manifest.json"
ALLOWLIST_PATH = ROOT / "org-actions-allowlist.json"

FLEET_CODE_SECURITY_CONFIG = "Heretek-AI fleet baseline"
HYGIENE_CONTEXT = "hygiene / No machine-local paths"
HYGIENE_WORKFLOW_REF = "Heretek-AI/.github/.github/workflows/hygiene.yml"
# Report static names, never API-supplied identifiers. The audit reads secret
# names/visibility/repository scope only; it never fetches or logs values.
KNOWN_ORG_SECRETS = (
    "ORG_SYNC_TOKEN",
    "LLM_API_KEY",
    "OCR_LLM_TOKEN",
    "OPENROUTER_API_KEY",
    "OPENCODE_GO_API_KEY",
    "RUNNER_PROBE_TOKEN",
    "OPENCODE_API_KEY",
)

CATEGORY_ORDER = (
    "p0_security",
    "manifest_drift",
    "ruleset_drift",
    "supply_chain",
    "repo_security",
    "third_party_apps",
    "secret_hygiene",
    "custom_properties",
    "unavailable",
    "stalled_sync_prs",
    "hygiene_gaps",
)

CATEGORY_LABELS = {
    "p0_security": "P0 Security",
    "manifest_drift": "Manifest Drift",
    "ruleset_drift": "Ruleset Drift",
    "supply_chain": "Supply Chain",
    "repo_security": "Repository Security",
    "third_party_apps": "Third-Party Apps",
    "secret_hygiene": "Secret Hygiene",
    "custom_properties": "Custom Properties",
    "unavailable": "Unavailable Surfaces",
    "stalled_sync_prs": "Stalled Sync PRs",
    "hygiene_gaps": "Hygiene Gaps",
}

SECTION_TITLES = {
    "p0_security": "P0 Security Findings",
    "manifest_drift": "Manifest Drift",
    "ruleset_drift": "Tier 1 Ruleset Drift",
    "supply_chain": "Supply Chain (Unpinned Actions)",
    "repo_security": "Repository Security",
    "third_party_apps": "Third-Party Apps",
    "secret_hygiene": "Secret Hygiene",
    "custom_properties": "Custom Properties",
    "unavailable": "Unavailable Surfaces",
    "stalled_sync_prs": "Stalled Sync PRs",
    "hygiene_gaps": "Hygiene Gaps & Advisory Notes",
}

STRICT_CATEGORIES = (
    "p0_security",
    "manifest_drift",
    "ruleset_drift",
    "supply_chain",
    "repo_security",
    "third_party_apps",
    "secret_hygiene",
    "custom_properties",
    "unavailable",
)

USES_RE = re.compile(r"^\s*(?:-\s*)?uses:\s*[\"']?([^\s\"'#]+)", re.MULTILINE)
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
HTTP_STATUS_RE = re.compile(r"HTTP (\d{3})")
# API paths are built from manifest/API-supplied identifiers. Validate them
# before they reach a subprocess argument, and keep the report limited to
# names/visibility/counts (secret values are never fetched or logged).
SAFE_API_PATH_RE = re.compile(r"^/[A-Za-z0-9._~%/?&=+:#-]*$")
SAFE_ORG_RE = re.compile(r"^[A-Za-z0-9-]+$")


def empty_findings() -> dict[str, list[str]]:
    return {key: [] for key in CATEGORY_ORDER}


def gh_api(path: str) -> Any:
    """Legacy helper: returns parsed JSON or None on failure."""
    if SAFE_API_PATH_RE.fullmatch(path) is None:
        return None
    proc = subprocess.run(  # NOSONAR: fixed argv, no shell; path validated above
        ["gh", "api", path], capture_output=True, text=True, check=False
    )
    if proc.returncode != 0:
        return None
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None
    if (
        isinstance(data, dict)
        and "message" in data
        and ("status" in data or "documentation_url" in data)
    ):
        return None
    return data


def coerce_status(value: Any, fallback: int = 0) -> int:
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value.isdigit():
        return int(value)
    return fallback


def gh_api_status(path: str) -> tuple[Any, int]:
    """Return (parsed JSON or None, HTTP status or 0).

    `gh api` exits non-zero for 4xx/5xx and may print the error body to stdout
    or the status only to stderr. Both shapes are normalized here.
    """
    if SAFE_API_PATH_RE.fullmatch(path) is None:
        return None, 0
    proc = subprocess.run(  # NOSONAR: fixed argv, no shell; path validated above
        ["gh", "api", path], capture_output=True, text=True, check=False
    )
    status = 0
    match = HTTP_STATUS_RE.search(proc.stderr or "")
    if match:
        status = int(match.group(1))

    if proc.returncode != 0:
        try:
            body = json.loads(proc.stdout)
        except json.JSONDecodeError:
            body = None
        if isinstance(body, dict):
            status = coerce_status(body.get("status"), status)
        return None, status

    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None, status

    if (
        isinstance(data, dict)
        and "message" in data
        and ("status" in data or "documentation_url" in data)
    ):
        return None, coerce_status(data.get("status"), status)
    return data, 200


def unavailable_message(label: str, status: int) -> str:
    detail = f"HTTP {status}" if status else "request failed"
    return f"{label} could not be read ({detail}); posture unknown"


def gh_api_checked(path: str, label: str, findings: dict[str, list[str]]) -> Any:
    """GET a critical surface, recording `unavailable` instead of failing open."""
    data, status = gh_api_status(path)
    if data is None:
        findings["unavailable"].append(unavailable_message(label, status))
    return data


class WorkflowCache:
    """Per-run cache of workflow listings, contents, and hygiene detection."""

    def __init__(self, org: str, findings: dict[str, list[str]]) -> None:
        self.org = org
        self.findings = findings
        self._listings: dict[str, list[dict[str, Any]] | None] = {}
        self._contents: dict[tuple[str, str], str | None] = {}
        self._hygiene: dict[str, bool | None] = {}

    def listing(self, repo: str) -> list[dict[str, Any]] | None:
        if repo in self._listings:
            return self._listings[repo]

        path = f"/repos/{self.org}/{repo}/contents/.github/workflows"
        data, status = gh_api_status(path)
        entries: list[dict[str, Any]] | None

        if data is None:
            if status == 404:
                entries = []
            else:
                self.findings["unavailable"].append(
                    unavailable_message(f"workflow listing for `{repo}`", status)
                )
                entries = None
        elif isinstance(data, list):
            entries = [
                entry
                for entry in data
                if isinstance(entry, dict)
                and entry.get("type") == "file"
                and str(entry.get("name", "")).lower().endswith((".yml", ".yaml"))
            ]
        else:
            self.findings["unavailable"].append(
                f"workflow listing for `{repo}` returned an unexpected payload; posture unknown"
            )
            entries = None

        self._listings[repo] = entries
        return entries

    def content(self, repo: str, filename: str) -> str | None:
        key = (repo, filename)
        if key in self._contents:
            return self._contents[key]

        quoted = urllib.parse.quote(filename)
        path = f"/repos/{self.org}/{repo}/contents/.github/workflows/{quoted}"
        data, status = gh_api_status(path)
        text: str | None = None
        reported = False

        if data is None:
            # A listed workflow file that cannot be fetched is an unknown
            # supply-chain surface, so fail closed even on 404.
            self.findings["unavailable"].append(
                unavailable_message(
                    f"workflow `{repo}/.github/workflows/{filename}`", status
                )
            )
            reported = True
        elif isinstance(data, dict):
            encoded = data.get("content")
            if data.get("encoding") == "base64" and isinstance(encoded, str):
                try:
                    text = base64.b64decode(encoded).decode("utf-8", errors="replace")
                except (ValueError, binascii.Error):
                    text = None
            elif data.get("encoding") in (None, "utf-8") and isinstance(encoded, str):
                # Some API gateways return already-decoded content.
                text = encoded
            elif isinstance(data.get("download_url"), str):
                self.findings["unavailable"].append(
                    f"workflow `{repo}/.github/workflows/{filename}` had no inline content; posture unknown"
                )
                reported = True
        else:
            self.findings["unavailable"].append(
                f"workflow `{repo}/.github/workflows/{filename}` returned an unexpected payload; posture unknown"
            )
            reported = True

        if data is not None and text is None and not reported:
            self.findings["unavailable"].append(
                f"workflow `{repo}/.github/workflows/{filename}` had no decodable content; posture unknown"
            )

        self._contents[key] = text
        return text

    def has_hygiene(self, repo: str) -> bool | None:
        """Whether the repo calls the shared hygiene reusable workflow.

        `.github` owns and defines the reusable workflow, so it inherently has
        the hygiene job even though its own workflow file never references the
        `Heretek-AI/.github/...` caller string.
        """
        if repo in self._hygiene:
            return self._hygiene[repo]
        if repo == ".github":
            self._hygiene[repo] = True
            return True

        entries = self.listing(repo)
        if entries is None:
            self._hygiene[repo] = None
            return None

        result: bool | None = False
        unknown = False
        for entry in entries:
            text = self.content(repo, entry["name"])
            if text is None:
                unknown = True
                continue
            if HYGIENE_WORKFLOW_REF in text:
                result = True
                break
        if result is False and unknown:
            result = None

        self._hygiene[repo] = result
        return result


def check_supply_chain(
    org: str,
    name: str,
    cache: WorkflowCache,
) -> list[str]:
    findings: list[str] = []
    entries = cache.listing(name)
    if entries is None:
        return findings

    seen: set[str] = set()
    for entry in entries:
        filename = entry["name"]
        text = cache.content(name, filename)
        if text is None:
            continue
        for match in USES_RE.finditer(text):
            action = match.group(1).strip()
            if not action or action.startswith(("./", "$/", "docker://")):
                continue

            if "@" in action:
                _, ref = action.rsplit("@", 1)
            else:
                ref = ""
            if ref and SHA_RE.fullmatch(ref):
                continue

            dedupe_key = f"{filename}:{action}"
            if dedupe_key in seen:
                continue
            seen.add(dedupe_key)

            ref_display = ref if ref else "no ref"
            findings.append(
                f"`{org}/{name}/.github/workflows/{filename}`: `{action}` is not "
                f"SHA-pinned (ref `{ref_display}`)"
            )
    return findings


def expected_custom_properties(
    name: str,
    entry: dict[str, Any] | None,
    forks: dict[str, dict[str, Any]],
) -> dict[str, str]:
    if name == ".github":
        return {
            "tier": "control-plane",
            "stack_profile": "universal",
            "security_critical": "true",
            "managed_by": "manual",
        }
    if entry is not None:
        tier = entry.get("tier")
        security_critical = (
            "true"
            if entry.get("protected_ruleset") is True or str(tier) == "1"
            else "false"
        )
        return {
            "tier": f"tier-{tier}",
            "stack_profile": str(entry.get("profile") or "universal"),
            "security_critical": security_critical,
            "managed_by": "fleet-sync",
        }
    if name in forks:
        return {
            "tier": "fork",
            "stack_profile": "none",
            "security_critical": "false",
            "managed_by": "manual",
        }
    return {}


def normalize_property_value(value: Any) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return ""
    return str(value)


def check_custom_properties(
    org: str,
    name: str,
    expected: dict[str, str],
    findings: dict[str, list[str]],
) -> list[str]:
    drift: list[str] = []
    data = gh_api_checked(
        f"/repos/{org}/{name}/properties/values",
        f"custom property values for `{name}`",
        findings,
    )
    if data is None:
        return drift

    entries = data.get("properties") if isinstance(data, dict) else data
    if not isinstance(entries, list):
        findings["unavailable"].append(
            f"custom property values for `{name}` returned an unexpected payload; posture unknown"
        )
        return drift

    actual: dict[str, Any] = {}
    for item in entries:
        if isinstance(item, dict) and item.get("property_name"):
            actual[str(item["property_name"])] = item.get("value")

    for prop, want in expected.items():
        if prop not in actual:
            drift.append(
                f"`{name}` is missing custom property `{prop}` (expected `{want}`)"
            )
            continue
        got = normalize_property_value(actual[prop])
        if got != want:
            drift.append(
                f"`{name}` custom property `{prop}` is `{got}` (expected `{want}`)"
            )
    return drift


def check_rulesets(
    org: str,
    name: str,
    tier_label: str,
    require_tag_ruleset: bool,
    findings: dict[str, list[str]],
    cache: WorkflowCache,
) -> list[str]:
    drift: list[str] = []
    rulesets = gh_api_checked(
        f"/repos/{org}/{name}/rulesets?per_page=100",
        f"rulesets for `{name}`",
        findings,
    )
    if rulesets is None:
        return drift
    if isinstance(rulesets, dict):
        rulesets = rulesets.get("rulesets")
    if not isinstance(rulesets, list):
        findings["unavailable"].append(
            f"rulesets for `{name}` returned an unexpected payload; posture unknown"
        )
        return drift

    active_branches = [
        ruleset
        for ruleset in rulesets
        if isinstance(ruleset, dict)
        and ruleset.get("enforcement") == "active"
        and ruleset.get("target") == "branch"
    ]
    branch = next(
        (
            ruleset
            for ruleset in active_branches
            if ruleset.get("name") == "keep summer safe"
        ),
        None,
    )
    if branch is None and active_branches:
        branch = active_branches[0]

    if branch is None:
        drift.append(
            f"`{name}` ({tier_label}) is missing an active default-branch ruleset"
        )
    else:
        detail, status = gh_api_status(
            f"/repos/{org}/{name}/rulesets/{branch.get('id')}"
        )
        if detail is None:
            findings["unavailable"].append(
                unavailable_message(
                    f"details for `{name}` branch ruleset `{branch.get('name')}`",
                    status,
                )
            )
        else:
            bypass = detail.get("bypass_actors") or []
            if bypass:
                drift.append(
                    f"`{name}` branch ruleset `{branch.get('name')}` has "
                    f"{len(bypass)} bypass actor(s) (expected zero-bypass)"
                )

            rules = detail.get("rules") or []
            pr_rule = next(
                (
                    rule
                    for rule in rules
                    if isinstance(rule, dict) and rule.get("type") == "pull_request"
                ),
                None,
            )
            if pr_rule is None:
                drift.append(
                    f"`{name}` branch ruleset `{branch.get('name')}` is missing "
                    "the `pull_request` rule"
                )
            else:
                parameters = pr_rule.get("parameters") or {}
                if parameters.get("required_review_thread_resolution") is not True:
                    drift.append(
                        f"`{name}` branch ruleset `{branch.get('name')}` does not "
                        "require review thread resolution"
                    )
                if parameters.get("dismiss_stale_reviews_on_push") is not True:
                    drift.append(
                        f"`{name}` branch ruleset `{branch.get('name')}` does not "
                        "dismiss stale reviews on push"
                    )

            contexts: set[str] = set()
            for rule in rules:
                if (
                    not isinstance(rule, dict)
                    or rule.get("type") != "required_status_checks"
                ):
                    continue
                parameters = rule.get("parameters") or {}
                for check in parameters.get("required_status_checks") or []:
                    if isinstance(check, dict) and check.get("context"):
                        contexts.add(str(check["context"]))

            has_hygiene = cache.has_hygiene(name)
            if has_hygiene is True and HYGIENE_CONTEXT not in contexts:
                drift.append(
                    f"`{name}` runs `{HYGIENE_WORKFLOW_REF}` but branch ruleset "
                    f"`{branch.get('name')}` does not require `{HYGIENE_CONTEXT}`"
                )
            elif has_hygiene is False and HYGIENE_CONTEXT in contexts:
                drift.append(
                    f"`{name}` requires `{HYGIENE_CONTEXT}` but does not run "
                    f"`{HYGIENE_WORKFLOW_REF}` (required check will never report)"
                )

    if require_tag_ruleset:
        active_tags = [
            ruleset
            for ruleset in rulesets
            if isinstance(ruleset, dict)
            and ruleset.get("enforcement") == "active"
            and ruleset.get("target") == "tag"
        ]
        if not active_tags:
            drift.append(
                f"`{name}` ({tier_label}) is missing an active release-tag ruleset"
            )
        else:
            tag = active_tags[0]
            tag_detail, status = gh_api_status(
                f"/repos/{org}/{name}/rulesets/{tag.get('id')}"
            )
            if tag_detail is None:
                findings["unavailable"].append(
                    unavailable_message(
                        f"details for `{name}` tag ruleset `{tag.get('name')}`",
                        status,
                    )
                )
            else:
                bypass = tag_detail.get("bypass_actors") or []
                if bypass:
                    drift.append(
                        f"`{name}` release-tag ruleset `{tag.get('name')}` has "
                        f"{len(bypass)} bypass actor(s) (expected zero-bypass)"
                    )

    return drift


def check_repo(
    repo: dict[str, Any],
    org: str,
    managed: dict[str, dict[str, Any]],
    forks: dict[str, dict[str, Any]],
    archive_cands: dict[str, dict[str, Any]],
    findings: dict[str, list[str]],
    cache: WorkflowCache,
    now: datetime,
    custom_schema_defined: bool,
    sync_branch: str,
) -> dict[str, list[str]]:
    name = repo["name"]

    # Tracked forks are not processed by sync-fleet.sh or sync-repo-settings.sh.
    # Their repo-security and supply-chain posture is therefore advisory/out of
    # scope for --strict; manifest, secret/variable, license/description, PR, and
    # custom-property checks stay as before.
    is_tracked_fork = name in forks

    info: dict[str, list[str]] = {
        "p0": [],
        "manifest": [],
        "ruleset": [],
        "hygiene": [],
        "stalled_pr": [],
        "supply_chain": [],
        "repo_security": [],
        "custom_properties": [],
    }

    if (
        name != ".github"
        and name not in managed
        and name not in forks
        and name not in archive_cands
    ):
        info["manifest"].append(
            f"`{name}` is active on GitHub but untracked in `fleet-manifest.json`"
        )

    entry = managed.get(name)
    allowed_exceptions = set(entry.get("secret_exceptions", [])) if entry else set()

    repo_meta = gh_api_checked(
        f"/repos/{org}/{name}/actions/secrets",
        f"repository secrets for `{name}`",
        findings,
    )
    repo_var_meta = gh_api_checked(
        f"/repos/{org}/{name}/actions/variables",
        f"repository variables for `{name}`",
        findings,
    )
    repo_entries = (
        (repo_meta or {}).get("secrets", []) if isinstance(repo_meta, dict) else []
    )
    var_entries = (
        (repo_var_meta or {}).get("variables", [])
        if isinstance(repo_var_meta, dict)
        else []
    )
    unexpected_entries = [
        item["name"] for item in repo_entries if item["name"] not in allowed_exceptions
    ]
    unexpected_vars = [
        var_item["name"]
        for var_item in var_entries
        if var_item["name"] not in allowed_exceptions
    ]
    if unexpected_entries:
        info["p0"].append(
            f"`{name}` has unapproved per-repo secret(s) (inspect repository settings)"
        )
    if unexpected_vars:
        info["p0"].append(
            f"`{name}` has unapproved per-repo variable(s) "
            "(inspect repository settings)"
        )

    # Repository details feed only the strict repo-security checks below.
    # Tracked forks are outside fleet-sync scope, so do not fetch them there.
    details = None
    if not is_tracked_fork:
        details = gh_api_checked(
            f"/repos/{org}/{name}",
            f"repository `{name}`",
            findings,
        )

    # Advisory visibility for managed repos and tracked forks; neither check
    # is strict, and forks are not fleet-synced.
    if entry or is_tracked_fork:
        if not repo.get("licenseInfo") and not repo["isPrivate"]:
            info["hygiene"].append(f"`{name}` is public and missing a `LICENSE` file")
        if not repo.get("description"):
            info["hygiene"].append(f"`{name}` is missing a repository description")

        prs = (
            gh_api(f"/repos/{org}/{name}/pulls?state=open&head={org}:{sync_branch}")
            or []
        )
        for pr in prs:
            created = datetime.fromisoformat(pr["created_at"].replace("Z", "+00:00"))
            age_days = (now - created).days
            if age_days >= 7:
                info["stalled_pr"].append(
                    f"`{name}` PR #{pr['number']} (`{sync_branch}`) "
                    f"open for {age_days} days"
                )

    if not is_tracked_fork and not repo["isPrivate"]:
        pvr = gh_api_checked(
            f"/repos/{org}/{name}/private-vulnerability-reporting",
            f"private vulnerability reporting for `{name}`",
            findings,
        )
        if pvr is not None and pvr.get("enabled") is not True:
            info["repo_security"].append(
                f"`{name}` private vulnerability reporting is not enabled"
            )

        if details is not None:
            security = details.get("security_and_analysis")
            if not isinstance(security, dict):
                findings["unavailable"].append(
                    f"repository `{name}` has no `security_and_analysis` metadata; "
                    "secret-scanning posture unknown"
                )
            else:
                for key in (
                    "secret_scanning_non_provider_patterns",
                    "secret_scanning_validity_checks",
                    "secret_scanning_push_protection",
                ):
                    item = security.get(key)
                    status_value = (
                        item.get("status") if isinstance(item, dict) else None
                    )
                    if status_value != "enabled":
                        info["repo_security"].append(
                            f"`{name}` `{key}` is `{status_value or 'unset'}` "
                            "(expected `enabled`)"
                        )

    entry_is_tier1 = bool(entry and entry.get("protected_ruleset"))
    if not is_tracked_fork and (name == ".github" or entry_is_tier1):
        immutable, status = gh_api_status(f"/repos/{org}/{name}/immutable-releases")
        if immutable is None:
            if status == 404:
                info["repo_security"].append(
                    f"`{name}` immutable releases are not enabled (endpoint returned 404)"
                )
            else:
                findings["unavailable"].append(
                    unavailable_message(f"immutable releases for `{name}`", status)
                )
        elif immutable.get("enabled") is not True:
            info["repo_security"].append(f"`{name}` immutable releases are not enabled")

    if not is_tracked_fork and entry is not None and details is not None:
        if details.get("delete_branch_on_merge") is not True:
            info["repo_security"].append(
                f"`{name}` `delete_branch_on_merge` is not `true`"
            )
        if details.get("allow_update_branch") is not True:
            info["repo_security"].append(
                f"`{name}` `allow_update_branch` is not `true`"
            )

    if name == ".github":
        info["ruleset"].extend(
            check_rulesets(org, name, "control-plane", False, findings, cache)
        )
    elif entry is not None and entry.get("protected_ruleset"):
        info["ruleset"].extend(
            check_rulesets(
                org, name, f"Tier {entry.get('tier')}", True, findings, cache
            )
        )

    if not is_tracked_fork:
        info["supply_chain"].extend(check_supply_chain(org, name, cache))

    if custom_schema_defined:
        expected = expected_custom_properties(name, entry, forks)
        if expected:
            info["custom_properties"].extend(
                check_custom_properties(org, name, expected, findings)
            )

    return info


def check_org_secrets(
    org: str,
    findings: dict[str, list[str]],
    managed: dict[str, dict[str, Any]],
    forks: dict[str, dict[str, Any]],
    archived_names: set[str],
) -> None:
    payload = gh_api_checked(
        f"/orgs/{org}/actions/secrets?per_page=100",
        "organization Actions secrets",
        findings,
    )
    if payload is None:
        return

    entries = payload.get("secrets") if isinstance(payload, dict) else payload
    if not isinstance(entries, list):
        findings["unavailable"].append(
            "organization Actions secrets returned an unexpected payload; posture unknown"
        )
        return

    tracked = set(managed) | set(forks) | {".github"}

    # Compare the API list only to detect unknown secrets; report a static
    # message without echoing API-supplied identifiers.
    listed = {
        entry.get("name")
        for entry in entries
        if isinstance(entry, dict) and isinstance(entry.get("name"), str)
    }
    if any(name not in KNOWN_ORG_SECRETS for name in listed):
        findings["secret_hygiene"].append(
            "organization has untracked Actions secret(s); names withheld from this report"
        )

    for name in KNOWN_ORG_SECRETS:
        meta, status = gh_api_status(f"/orgs/{org}/actions/secrets/{name}")
        if meta is None:
            if status == 404:
                continue
            findings["unavailable"].append(
                unavailable_message(f"org secret `{name}`", status)
            )
            continue

        visibility = meta.get("visibility")
        vis = (
            "all"
            if visibility == "all"
            else "selected"
            if visibility == "selected"
            else "other"
        )

        if name == "OPENCODE_API_KEY":
            findings["secret_hygiene"].append(
                "org secret `OPENCODE_API_KEY` still exists (stale; remove it)"
            )

        if vis == "all":
            findings["secret_hygiene"].append(
                f"org secret `{name}` has visibility `all` "
                "(expected selected repositories)"
            )
        elif vis == "selected":
            repo_payload = gh_api_checked(
                f"/orgs/{org}/actions/secrets/{name}/repositories?per_page=100",
                f"repositories for org secret `{name}`",
                findings,
            )
            if repo_payload is None:
                continue
            repo_entries = (
                repo_payload.get("repositories")
                if isinstance(repo_payload, dict)
                else repo_payload
            )
            if not isinstance(repo_entries, list):
                findings["unavailable"].append(
                    f"repositories for org secret `{name}` returned an unexpected "
                    "payload; posture unknown"
                )
                continue

            out_of_scope = False
            for repo in repo_entries:
                if not isinstance(repo, dict):
                    continue
                repo_name = repo.get("name")
                if not repo_name and isinstance(repo.get("full_name"), str):
                    repo_name = repo["full_name"].rsplit("/", 1)[-1]
                if not repo_name:
                    continue
                if repo_name in archived_names or repo_name not in tracked:
                    out_of_scope = True
                    break

            if out_of_scope:
                findings["secret_hygiene"].append(
                    f"org secret `{name}` is scoped to archived or untracked "
                    "repositories (inspect in Org Settings)"
                )


def check_installations(org: str, findings: dict[str, list[str]]) -> None:
    data = gh_api_checked(
        f"/orgs/{org}/installations?per_page=100",
        "GitHub App installations",
        findings,
    )
    if data is None:
        return

    installations = data.get("installations") if isinstance(data, dict) else data
    if not isinstance(installations, list):
        findings["unavailable"].append(
            "GitHub App installations returned an unexpected payload; posture unknown"
        )
        return

    for installation in installations:
        if not isinstance(installation, dict):
            continue
        slug = installation.get("app_slug") or f"app-{installation.get('app_id')}"
        selection = installation.get("repository_selection")
        permissions = installation.get("permissions") or {}

        offending: list[str] = []
        if permissions.get("administration") == "write":
            offending.append("administration: write")
        if selection == "all":
            for key in ("workflows", "repository_hooks"):
                if permissions.get(key) == "write":
                    offending.append(f"{key}: write")

        if offending:
            findings["third_party_apps"].append(
                f"GitHub App `{slug}` has `{', '.join(offending)}` with "
                f"repository selection `{selection}`"
            )


def check_code_security_config(
    org: str,
    findings: dict[str, list[str]],
    expected_public_repos: set[str],
) -> None:
    configs = gh_api_checked(
        f"/orgs/{org}/code-security/configurations?per_page=100",
        "organization code security configurations",
        findings,
    )
    if configs is None:
        return

    if isinstance(configs, dict):
        configs = configs.get("configurations")
    if not isinstance(configs, list):
        findings["unavailable"].append(
            "organization code security configurations returned an unexpected "
            "payload; posture unknown"
        )
        return

    fleet_config = next(
        (
            config
            for config in configs
            if isinstance(config, dict)
            and config.get("target_type") == "organization"
            and config.get("name") == FLEET_CODE_SECURITY_CONFIG
        ),
        None,
    )
    if fleet_config is None:
        findings["repo_security"].append(
            f"organization code security configuration `{FLEET_CODE_SECURITY_CONFIG}` "
            "is missing"
        )
        return

    required = (
        ("private_vulnerability_reporting", "enabled"),
        ("secret_scanning_non_provider_patterns", "enabled"),
        ("secret_scanning_validity_checks", "enabled"),
        ("secret_scanning", "enabled"),
        ("secret_scanning_push_protection", "enabled"),
        ("code_scanning_default_setup", "not_set"),
    )
    for key, want in required:
        got = fleet_config.get(key)
        if got != want:
            findings["repo_security"].append(
                f"code security configuration `{FLEET_CODE_SECURITY_CONFIG}` "
                f"`{key}` is `{got}` (expected `{want}`)"
            )

    attached_data = gh_api_checked(
        f"/orgs/{org}/code-security/configurations/{fleet_config.get('id')}"
        "/repositories?per_page=100",
        f"repositories attached to code security configuration "
        f"`{FLEET_CODE_SECURITY_CONFIG}`",
        findings,
    )
    if attached_data is None:
        return

    entries = (
        attached_data.get("repositories")
        if isinstance(attached_data, dict)
        else attached_data
    )
    if not isinstance(entries, list):
        findings["unavailable"].append(
            f"repositories attached to code security configuration "
            f"`{FLEET_CODE_SECURITY_CONFIG}` returned an unexpected payload; "
            "posture unknown"
        )
        return

    attached: set[str] = set()
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        state = entry.get("status")
        if state and state not in ("attached", "attaching"):
            continue
        repo_obj = entry.get("repository")
        if not isinstance(repo_obj, dict):
            repo_obj = entry
        repo_name = repo_obj.get("name")
        if not repo_name and isinstance(repo_obj.get("full_name"), str):
            repo_name = repo_obj["full_name"].rsplit("/", 1)[-1]
        if repo_name:
            attached.add(str(repo_name))

    for name in sorted(expected_public_repos):
        if name not in attached:
            findings["repo_security"].append(
                f"`{name}` is not attached to code security configuration "
                f"`{FLEET_CODE_SECURITY_CONFIG}`"
            )


def audit_org(manifest: dict[str, Any]) -> dict[str, Any]:
    org = manifest["organization"]
    findings = empty_findings()

    managed = {r["name"]: r for r in manifest["repositories"]}
    forks = {r["name"]: r for r in manifest.get("forks", [])}
    archive_cands = {r["name"]: r for r in manifest.get("archive_candidates", [])}
    tier1_count = sum(
        1 for entry in managed.values() if entry.get("protected_ruleset") is True
    )

    # Advisory visibility for the intentional strict-mode boundary: fork
    # repo-security/supply-chain posture is not synced by the fleet scripts.
    if forks:
        fork_names = ", ".join(f"`{name}`" for name in sorted(forks))
        findings["hygiene_gaps"].append(
            f"tracked forks {fork_names} are excluded from strict repo-security "
            "and supply-chain checks (not fleet-sync managed)"
        )

    now = datetime.now(timezone.utc)

    # 1. Organization general security baseline
    org_info = gh_api_checked(f"/orgs/{org}", f"organization `{org}`", findings)
    if org_info is not None:
        if org_info.get("two_factor_requirement_enabled") is not True:
            findings["p0_security"].append(
                "`two_factor_requirement_enabled` is not `true`"
            )
        if org_info.get("default_repository_permission") != "read":
            findings["p0_security"].append(
                f"`default_repository_permission` is "
                f"`{org_info.get('default_repository_permission')}` (expected `read`)"
            )
        if org_info.get("members_can_create_repositories") is not False:
            findings["p0_security"].append(
                "`members_can_create_repositories` is not `false`"
            )
        if org_info.get("deploy_keys_enabled_for_repositories") is not False:
            findings["p0_security"].append(
                "`deploy_keys_enabled_for_repositories` is not `false`"
            )
        if org_info.get("web_commit_signoff_required") is not True:
            findings["p0_security"].append(
                "`web_commit_signoff_required` is not `true`"
            )

    # 2. Actions workflow permissions (existing baseline)
    wf_perm = gh_api_checked(
        f"/orgs/{org}/actions/permissions/workflow",
        "Actions workflow permissions",
        findings,
    )
    if wf_perm is not None:
        if wf_perm.get("default_workflow_permissions") != "read":
            findings["p0_security"].append(
                f"`default_workflow_permissions` is "
                f"`{wf_perm.get('default_workflow_permissions')}` (expected `read`)"
            )
        if wf_perm.get("can_approve_pull_request_reviews") is not False:
            findings["p0_security"].append(
                "`can_approve_pull_request_reviews` is enabled (expected `false`)"
            )

    # 3. Actions permissions and selected-actions allowlist
    actions_perm = gh_api_checked(
        f"/orgs/{org}/actions/permissions",
        "Actions permissions",
        findings,
    )
    if actions_perm is not None:
        if actions_perm.get("allowed_actions") != "selected":
            findings["p0_security"].append(
                f"`allowed_actions` is `{actions_perm.get('allowed_actions')}` "
                "(expected `selected`)"
            )
        if actions_perm.get("sha_pinning_required") is not True:
            findings["p0_security"].append(
                "`sha_pinning_required` is `false` (expected `true`)"
            )

    selected_actions = gh_api_checked(
        f"/orgs/{org}/actions/permissions/selected-actions",
        "Actions selected-actions allowlist",
        findings,
    )
    try:
        expected_allowlist = json.loads(ALLOWLIST_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        findings["unavailable"].append(
            f"`org-actions-allowlist.json` could not be read ({exc}); "
            "allowlist comparison skipped"
        )
        expected_allowlist = None

    if selected_actions is not None and expected_allowlist is not None:
        for key in ("github_owned_allowed", "verified_allowed"):
            want = expected_allowlist.get(key)
            got = selected_actions.get(key)
            if got != want:
                findings["p0_security"].append(
                    f"Actions allowlist `{key}` is `{got}` (expected `{want}`)"
                )

        expected_patterns = set(expected_allowlist.get("patterns_allowed") or [])
        actual_patterns = set(selected_actions.get("patterns_allowed") or [])
        missing_patterns = sorted(expected_patterns - actual_patterns)
        extra_patterns = sorted(actual_patterns - expected_patterns)
        if missing_patterns:
            findings["p0_security"].append(
                f"Actions allowlist is missing {len(missing_patterns)} pattern(s): "
                f"`{', '.join(missing_patterns)}`"
            )
        if extra_patterns:
            findings["p0_security"].append(
                f"Actions allowlist has {len(extra_patterns)} unexpected pattern(s): "
                f"`{', '.join(extra_patterns)}`"
            )

    # 4. Fork-PR contributor approval
    fork_approval = gh_api_checked(
        f"/orgs/{org}/actions/permissions/fork-pr-contributor-approval",
        "fork-PR contributor approval policy",
        findings,
    )
    if (
        fork_approval is not None
        and fork_approval.get("approval_policy") != "all_external_contributors"
    ):
        findings["p0_security"].append(
            f"`approval_policy` is `{fork_approval.get('approval_policy')}` "
            "(expected `all_external_contributors`)"
        )

    # 5. OIDC custom subject claim (404 is a known "not configured" state)
    oidc, oidc_status = gh_api_status(f"/orgs/{org}/actions/oidc/customization/sub")
    if oidc is None:
        if oidc_status == 404:
            findings["p0_security"].append(
                "Actions OIDC custom subject claim template is not configured "
                "(expected claims `repo`, `context`, `job_workflow_ref`)"
            )
        else:
            findings["unavailable"].append(
                unavailable_message("Actions OIDC custom subject claim", oidc_status)
            )
    else:
        claim_keys = set(oidc.get("include_claim_keys") or [])
        missing_claims = [
            key
            for key in ("repo", "context", "job_workflow_ref")
            if key not in claim_keys
        ]
        if missing_claims:
            findings["p0_security"].append(
                "Actions OIDC custom subject claim is missing claim key(s): "
                f"`{', '.join(missing_claims)}`"
            )

    # 6. Runner group visibility
    runner_groups = gh_api_checked(
        f"/orgs/{org}/actions/runner-groups",
        "runner groups",
        findings,
    )
    if runner_groups is not None:
        groups = (
            runner_groups.get("runner_groups")
            if isinstance(runner_groups, dict)
            else runner_groups
        )
        if not isinstance(groups, list):
            findings["unavailable"].append(
                "runner groups returned an unexpected payload; posture unknown"
            )
        else:
            for group in groups:
                if not isinstance(group, dict):
                    continue
                if group.get("visibility") == "all":
                    findings["p0_security"].append(
                        f"runner group `{group.get('name')}` is visible to `all` "
                        "repositories (expected `selected`)"
                    )

    # 7. Self-hosted runner repository scope
    self_hosted = gh_api_checked(
        f"/orgs/{org}/actions/permissions/self-hosted-runners",
        "self-hosted runner permissions",
        findings,
    )
    if (
        self_hosted is not None
        and self_hosted.get("enabled_repositories") != "selected"
    ):
        findings["p0_security"].append(
            "self-hosted runners `enabled_repositories` is "
            f"`{self_hosted.get('enabled_repositories')}` (expected `selected`)"
        )

    # 8. Fork-PR workflows for private repositories
    fork_private = gh_api_checked(
        f"/orgs/{org}/actions/permissions/fork-pr-workflows-private-repos",
        "fork-PR workflows for private repositories",
        findings,
    )
    if fork_private is not None:
        if fork_private.get("require_approval_for_fork_pr_workflows") is not True:
            findings["p0_security"].append(
                "`require_approval_for_fork_pr_workflows` is not `true`"
            )
        if fork_private.get("send_secrets_and_variables") is not False:
            findings["p0_security"].append(
                "`send_secrets_and_variables` is not `false`"
            )
        if fork_private.get("send_write_tokens_to_workflows") is not False:
            findings["p0_security"].append(
                "`send_write_tokens_to_workflows` is not `false`"
            )

    # 9. ORG_SYNC_TOKEN scoping (existing baseline)
    sync_meta = gh_api(f"/orgs/{org}/actions/secrets/ORG_SYNC_TOKEN")
    sync_vis = (
        "selected"
        if sync_meta and sync_meta.get("visibility") == "selected"
        else "other"
    )
    if sync_meta and sync_vis != "selected":
        findings["p0_security"].append(
            f"`ORG_SYNC_TOKEN` visibility is `{sync_vis}` "
            f"(expected `selected` -> `{org}/.github` only)"
        )

    # 10. Repository inventory
    if SAFE_ORG_RE.fullmatch(org) is None:
        findings["unavailable"].append(
            f"organization `{org}` failed validation; repository inventory unknown"
        )
        return {
            "organization": org,
            "generated_at": now.isoformat(),
            "active_repo_count": 0,
            "managed_repo_count": len(managed),
            "tracked_fork_count": len(forks),
            "tier1_repo_count": tier1_count,
            "findings": findings,
        }
    proc = subprocess.run(  # NOSONAR: fixed argv, no shell; org validated above
        [
            "gh",
            "repo",
            "list",
            org,
            "--limit",
            "250",
            "--json",
            "name,isArchived,isFork,isPrivate,licenseInfo,description,defaultBranchRef",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        findings["unavailable"].append(
            f"`gh repo list {org}` failed; repository inventory unknown "
            f"({(proc.stderr or '').strip() or 'no stderr'})"
        )
        return {
            "organization": org,
            "generated_at": now.isoformat(),
            "active_repo_count": 0,
            "managed_repo_count": len(managed),
            "tracked_fork_count": len(forks),
            "tier1_repo_count": tier1_count,
            "findings": findings,
        }

    try:
        all_repos = json.loads(proc.stdout)
    except json.JSONDecodeError:
        findings["unavailable"].append(
            "`gh repo list` returned invalid JSON; repository inventory unknown"
        )
        return {
            "organization": org,
            "generated_at": now.isoformat(),
            "active_repo_count": 0,
            "managed_repo_count": len(managed),
            "tracked_fork_count": len(forks),
            "tier1_repo_count": tier1_count,
            "findings": findings,
        }

    active_repos = [r for r in all_repos if not r.get("isArchived")]
    archived_names = {r["name"] for r in all_repos if r.get("isArchived")}
    active_public = {r["name"] for r in active_repos if not r.get("isPrivate")}

    # 11. Code security configuration and public-repo attachment coverage
    expected_public_repos = {".github"} | {
        name for name in managed if name in active_public
    }
    check_code_security_config(org, findings, expected_public_repos)

    # 12. Organization secret scoping
    check_org_secrets(org, findings, managed, forks, archived_names)

    # 13. Third-party GitHub App installations
    check_installations(org, findings)

    # 14. Custom property schema gate
    schema = gh_api_checked(
        f"/orgs/{org}/properties/schema",
        "custom property schema",
        findings,
    )
    custom_schema_defined = False
    if schema is not None:
        properties = schema.get("properties") if isinstance(schema, dict) else schema
        if isinstance(properties, list):
            custom_schema_defined = bool(properties)
            if not custom_schema_defined:
                findings["custom_properties"].append(
                    "custom property schema is not defined"
                )
        else:
            findings["unavailable"].append(
                "custom property schema returned an unexpected payload; "
                "per-repository comparison skipped"
            )

    # 15. Per-repository checks
    cache = WorkflowCache(org, findings)

    def work(repo: dict[str, Any]) -> dict[str, list[str]]:
        return check_repo(
            repo,
            org,
            managed,
            forks,
            archive_cands,
            findings,
            cache,
            now,
            custom_schema_defined,
            manifest["sync_branch"],
        )

    with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
        for res in pool.map(work, active_repos):
            findings["p0_security"].extend(res["p0"])
            findings["manifest_drift"].extend(res["manifest"])
            findings["ruleset_drift"].extend(res["ruleset"])
            findings["hygiene_gaps"].extend(res["hygiene"])
            findings["stalled_sync_prs"].extend(res["stalled_pr"])
            findings["supply_chain"].extend(res["supply_chain"])
            findings["repo_security"].extend(res["repo_security"])
            findings["custom_properties"].extend(res["custom_properties"])

    for key in findings:
        findings[key] = list(dict.fromkeys(findings[key]))

    return {
        "organization": org,
        "generated_at": now.isoformat(),
        "active_repo_count": len(active_repos),
        "managed_repo_count": len(managed),
        "tracked_fork_count": len(forks),
        "tier1_repo_count": tier1_count,
        "findings": findings,
    }


def render_markdown(report: dict[str, Any]) -> str:
    findings = report["findings"]
    strict_failed = any(findings.get(key) for key in STRICT_CATEGORIES)
    org = report["organization"]

    lines = [
        f"# {org} Governance Drift Audit",
        "",
        f"- **Generated:** `{report['generated_at']}`",
        (
            f"- **Active repositories:** `{report['active_repo_count']}` "
            f"(`{report['managed_repo_count']}` managed + `.github` + "
            f"`{report.get('tracked_fork_count', 0)}` tracked forks)"
        ),
        (
            f"- **Tier 1 repositories:** `{report.get('tier1_repo_count', 0)}` managed "
            "+ `.github` control-plane"
        ),
        (
            f"- **Control-plane hygiene:** `{org}/.github` hosts "
            "`.github/workflows/hygiene.yml` and requires the "
            f"`{HYGIENE_CONTEXT}` check."
        ),
        f"- **Strict gate:** `{'FAIL' if strict_failed else 'PASS'}`",
        "",
        "| Category | Findings | Strict gate |",
        "| --- | ---: | --- |",
    ]
    for key in CATEGORY_ORDER:
        label = CATEGORY_LABELS[key]
        strict = "fail" if key in STRICT_CATEGORIES else "advisory"
        lines.append(f"| {label} | {len(findings.get(key, []))} | {strict} |")
    lines.append("")

    for key in CATEGORY_ORDER:
        title = SECTION_TITLES[key]
        items = findings.get(key, [])
        lines.append(f"## {title}")
        if not items:
            lines.append("- None")
        else:
            for item in sorted(items):
                lines.append(f"- {item}")
        lines.append("")

    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Audit Heretek-AI org governance drift."
    )
    parser.add_argument("--format", choices=["markdown", "json"], default="markdown")
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Exit non-zero on security, supply-chain, ruleset, or availability drift",
    )
    args = parser.parse_args()

    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    report = audit_org(manifest)

    if args.format == "json":
        print(json.dumps(report, indent=2))
    else:
        print(render_markdown(report))

    if args.strict:
        findings = report["findings"]
        if any(findings.get(key) for key in STRICT_CATEGORIES):
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Read-only governance and hygiene drift auditor for Heretek-AI.

Checks organization security settings, secret scoping, fleet-manifest.json
coverage, per-repo secret/var exceptions, Tier 1 rulesets, missing licenses
or descriptions, and stale chore/sync-org-standards pull requests.

Usage:
  python3 scripts/audit_org.py [--format markdown|json] [--strict]
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import pathlib
import subprocess
import sys
from datetime import datetime, timezone
from typing import Any


ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFEST_PATH = ROOT / "fleet-manifest.json"


def gh_api(path: str) -> Any:
    proc = subprocess.run(["gh", "api", path], capture_output=True, text=True)
    if proc.returncode != 0:
        return None
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None


def audit_org(manifest: dict[str, Any]) -> dict[str, Any]:
    org = manifest["organization"]
    findings: dict[str, list[str]] = {
        "p0_security": [],
        "manifest_drift": [],
        "ruleset_drift": [],
        "hygiene_gaps": [],
        "stalled_sync_prs": [],
    }

    # 1. Org-level security checks
    actions_perm = gh_api(f"/orgs/{org}/actions/permissions") or {}
    wf_perm = gh_api(f"/orgs/{org}/actions/permissions/workflow") or {}
    org_info = gh_api(f"/orgs/{org}") or {}
    sync_secret = gh_api(f"/orgs/{org}/actions/secrets/ORG_SYNC_TOKEN")

    if wf_perm.get("default_workflow_permissions") != "read":
        findings["p0_security"].append(
            f"`default_workflow_permissions` is `{wf_perm.get('default_workflow_permissions')}` (expected `read`)"
        )
    if wf_perm.get("can_approve_pull_request_reviews") is not False:
        findings["p0_security"].append(
            "`can_approve_pull_request_reviews` is enabled (expected `false`)"
        )
    if actions_perm.get("sha_pinning_required") is not True:
        findings["p0_security"].append(
            "`sha_pinning_required` is `false` (expected `true`)"
        )
    if sync_secret and sync_secret.get("visibility") != "selected":
        findings["p0_security"].append(
            f"`ORG_SYNC_TOKEN` visibility is `{sync_secret.get('visibility')}` (expected `selected` -> `{org}/.github` only)"
        )
    if org_info.get("web_commit_signoff_required") is not True:
        findings["p0_security"].append("`web_commit_signoff_required` is not `true`")

    # 2. Inventory active repos via gh CLI
    raw = subprocess.check_output(
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
        text=True,
    )
    all_repos = json.loads(raw)
    active_repos = [r for r in all_repos if not r["isArchived"]]

    managed = {r["name"]: r for r in manifest["repositories"]}
    forks = {r["name"]: r for r in manifest.get("forks", [])}
    archive_cands = {r["name"]: r for r in manifest.get("archive_candidates", [])}

    now = datetime.now(timezone.utc)

    def check_repo(repo: dict[str, Any]) -> dict[str, Any]:
        name = repo["name"]
        info: dict[str, Any] = {
            "name": name,
            "is_fork": repo["isFork"],
            "is_private": repo["isPrivate"],
            "has_license": bool(repo.get("licenseInfo")),
            "has_description": bool(repo.get("description")),
            "p0": [],
            "manifest": [],
            "ruleset": [],
            "hygiene": [],
            "stalled_pr": [],
        }

        if name != ".github" and name not in managed and name not in forks and name not in archive_cands:
            info["manifest"].append(f"`{name}` is active on GitHub but untracked in `fleet-manifest.json`")

        entry = managed.get(name)
        allowed_secrets = set(entry.get("secret_exceptions", [])) if entry else set()

        secs = (gh_api(f"/repos/{org}/{name}/actions/secrets") or {}).get("secrets", [])
        vrs = (gh_api(f"/repos/{org}/{name}/actions/variables") or {}).get("variables", [])
        extra_secs = [s["name"] for s in secs if s["name"] not in allowed_secrets]
        extra_vars = [v["name"] for v in vrs if v["name"] not in allowed_secrets]
        if extra_secs:
            info["p0"].append(f"`{name}` has unapproved per-repo secrets: `{', '.join(extra_secs)}`")
        if extra_vars:
            info["p0"].append(f"`{name}` has unapproved per-repo variables: `{', '.join(extra_vars)}`")

        if entry:
            if entry.get("protected_ruleset"):
                rulesets = gh_api(f"/repos/{org}/{name}/rulesets") or []
                active_branch_rules = [
                    r for r in rulesets if r.get("enforcement") == "active" and r.get("target") == "branch"
                ]
                if not active_branch_rules:
                    info["ruleset"].append(f"`{name}` (Tier {entry['tier']}) is missing an active default-branch ruleset")

            if not info["has_license"] and not info["is_private"]:
                info["hygiene"].append(f"`{name}` is public and missing a `LICENSE` file")
            if not info["has_description"]:
                info["hygiene"].append(f"`{name}` is missing a repository description")

            prs = gh_api(f"/repos/{org}/{name}/pulls?state=open&head={org}:{manifest['sync_branch']}") or []
            for pr in prs:
                created = datetime.fromisoformat(pr["created_at"].replace("Z", "+00:00"))
                age_days = (now - created).days
                if age_days >= 7:
                    info["stalled_pr"].append(
                        f"`{name}` PR #{pr['number']} (`{manifest['sync_branch']}`) open for {age_days} days"
                    )

        return info

    with concurrent.futures.ThreadPoolExecutor(max_workers=10) as pool:
        for res in pool.map(check_repo, active_repos):
            findings["p0_security"].extend(res["p0"])
            findings["manifest_drift"].extend(res["manifest"])
            findings["ruleset_drift"].extend(res["ruleset"])
            findings["hygiene_gaps"].extend(res["hygiene"])
            findings["stalled_sync_prs"].extend(res["stalled_pr"])

    return {
        "organization": org,
        "generated_at": now.isoformat(),
        "active_repo_count": len(active_repos),
        "managed_repo_count": len(managed),
        "findings": findings,
    }


def render_markdown(report: dict[str, Any]) -> str:
    f = report["findings"]
    lines = [
        f"# {report['organization']} Governance Drift Audit",
        "",
        f"- **Generated:** `{report['generated_at']}`",
        f"- **Active repositories:** `{report['active_repo_count']}` (`{report['managed_repo_count']}` managed in `fleet-manifest.json` + `.github`)",
        f"- **P0 Security Findings:** `{len(f['p0_security'])}`",
        f"- **Manifest Drift:** `{len(f['manifest_drift'])}`",
        f"- **Ruleset Drift:** `{len(f['ruleset_drift'])}`",
        f"- **Stalled Sync PRs (>=7d):** `{len(f['stalled_sync_prs'])}`",
        f"- **Hygiene Gaps (License/Description):** `{len(f['hygiene_gaps'])}`",
        "",
    ]

    sections = [
        ("P0 Security Findings", f["p0_security"]),
        ("Manifest Drift", f["manifest_drift"]),
        ("Tier 1 Ruleset Drift", f["ruleset_drift"]),
        ("Stalled Sync PRs", f["stalled_sync_prs"]),
        ("Hygiene Gaps", f["hygiene_gaps"]),
    ]
    for title, items in sections:
        lines.append(f"## {title}")
        if not items:
            lines.append("- None")
        else:
            for item in sorted(items):
                lines.append(f"- {item}")
        lines.append("")

    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Audit Heretek-AI org governance drift.")
    parser.add_argument("--format", choices=["markdown", "json"], default="markdown")
    parser.add_argument("--strict", action="store_true", help="Exit non-zero on P0 security or manifest/ruleset drift")
    args = parser.parse_args()

    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    report = audit_org(manifest)

    if args.format == "json":
        print(json.dumps(report, indent=2))
    else:
        print(render_markdown(report))

    if args.strict:
        f = report["findings"]
        if f["p0_security"] or f["manifest_drift"] or f["ruleset_drift"]:
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

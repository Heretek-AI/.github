#!/usr/bin/env bash
# Define and synchronize GitHub Organization Custom Properties from fleet-manifest.json.
#
# Usage: scripts/sync-custom-properties.sh [--dry-run]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$root/fleet-manifest.json"
org="$(jq -r '.organization' "$manifest")"
dry_run=false

if [ "${1:-}" = "--dry-run" ]; then
  dry_run=true
fi

echo "=== $org Custom Properties Sync (dry_run=$dry_run) ==="

schema_payload="$(cat <<'EOF'
{
  "properties": [
    {
      "property_name": "tier",
      "value_type": "single_select",
      "required": false,
      "default_value": "tier-2",
      "description": "Governance tier from Heretek-AI/.github fleet-manifest.json",
      "allowed_values": ["control-plane", "tier-1", "tier-2", "fork", "archive-candidate"],
      "values_editable_by": "org_actors"
    },
    {
      "property_name": "stack_profile",
      "value_type": "single_select",
      "required": false,
      "default_value": "universal",
      "description": "Standardized Lefthook/CI stack profile from fleet-manifest.json",
      "allowed_values": ["bun-biome", "python-uv", "node-zerodep", "rust-cargo", "cpp-cmake", "godot-gdscript", "universal", "none"],
      "values_editable_by": "org_actors"
    },
    {
      "property_name": "security_critical",
      "value_type": "true_false",
      "required": false,
      "default_value": "false",
      "description": "True for control-plane and Tier 1 zero-bypass repositories",
      "values_editable_by": "org_actors"
    },
    {
      "property_name": "managed_by",
      "value_type": "single_select",
      "required": false,
      "default_value": "fleet-sync",
      "description": "How repository standards are maintained",
      "allowed_values": ["fleet-sync", "manual"],
      "values_editable_by": "org_actors"
    }
  ]
}
EOF
)"

if [ "$dry_run" = true ]; then
  echo "[dry-run] Would PATCH /orgs/$org/properties/schema (tier, stack_profile, security_critical, managed_by)"
else
  gh api -X PATCH "/orgs/$org/properties/schema" \
    -H "Accept: application/vnd.github+json" \
    --input - <<<"$schema_payload" >/dev/null
  echo "Synced custom property schema (tier, stack_profile, security_critical, managed_by)."
fi

apply_props() {
  local repo_name="$1"
  local tier_val="$2"
  local profile_val="$3"
  local critical_val="$4"
  local managed_val="$5"

  local payload
  payload="$(jq -nc \
    --arg r "$repo_name" \
    --arg t "$tier_val" \
    --arg p "$profile_val" \
    --arg c "$critical_val" \
    --arg m "$managed_val" \
    '{
      repository_names: [$r],
      properties: [
        {property_name: "tier", value: $t},
        {property_name: "stack_profile", value: $p},
        {property_name: "security_critical", value: $c},
        {property_name: "managed_by", value: $m}
      ]
    }')"

  if [ "$dry_run" = true ]; then
    echo "[dry-run] $org/$repo_name -> tier=$tier_val stack_profile=$profile_val security_critical=$critical_val managed_by=$managed_val"
  else
    gh api -X PATCH "/orgs/$org/properties/values" \
      -H "Accept: application/vnd.github+json" \
      --input - <<<"$payload" >/dev/null
    echo "$org/$repo_name: synced custom properties ($tier_val / $profile_val)"
  fi
}

# Control plane
apply_props ".github" "control-plane" "universal" "true" "manual"

# Managed repositories
while IFS=$'\t' read -r name tier profile protected; do
  critical="false"
  if [ "$protected" = "true" ] || [ "$tier" = "1" ]; then
    critical="true"
  fi
  apply_props "$name" "tier-$tier" "$profile" "$critical" "fleet-sync"
done < <(jq -r '.repositories[] | [.name, (.tier | tostring), .profile, (.protected_ruleset | tostring)] | @tsv' "$manifest")

# Tracked forks
while IFS= read -r name; do
  apply_props "$name" "fork" "none" "false" "manual"
done < <(jq -r '.forks[].name' "$manifest")

#!/usr/bin/env bash
# Atomically switch the active Heretek-AI organization LLM profile across all
# repositories by updating canonical LLM_* org variables and mirroring legacy
# OCR_LLM_* and OPENCODE_MODEL variables.
#
# Usage:
#   scripts/set-llm-profile.sh --list
#   scripts/set-llm-profile.sh [--dry-run] [--set-key-stdin] <profile-name>
#   scripts/set-llm-profile.sh [--dry-run] --provider <p> --base-url <u> --model <m> [--opencode-model <om>] [--protocol openai|anthropic]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profiles_file="$root/llm-profiles.json"
org="Heretek-AI"

dry_run=false
set_key_stdin=false
profile_name=""
provider=""
base_url=""
model=""
opencode_model=""
protocol="openai"
key_secret=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --list)
      jq -r '.profiles | to_entries[] | "\(.key)\t\(.value.provider)\t\(.value.model)\t\(.value.base_url)"' "$profiles_file"
      exit 0
      ;;
    --dry-run)
      dry_run=true
      shift
      ;;
    --set-key-stdin)
      set_key_stdin=true
      shift
      ;;
    --provider)
      provider="${2:-}"
      shift 2
      ;;
    --base-url)
      base_url="${2:-}"
      shift 2
      ;;
    --model)
      model="${2:-}"
      shift 2
      ;;
    --opencode-model)
      opencode_model="${2:-}"
      shift 2
      ;;
    --protocol)
      protocol="${2:-}"
      shift 2
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
    *)
      profile_name="$1"
      shift
      ;;
  esac
done

if [ -n "$profile_name" ]; then
  if ! jq -e --arg p "$profile_name" '.profiles[$p] != null' "$profiles_file" >/dev/null; then
    echo "ERROR: Profile '$profile_name' not found in $profiles_file" >&2
    exit 1
  fi
  provider="${provider:-$(jq -r --arg p "$profile_name" '.profiles[$p].provider' "$profiles_file")}"
  base_url="${base_url:-$(jq -r --arg p "$profile_name" '.profiles[$p].base_url' "$profiles_file")}"
  model="${model:-$(jq -r --arg p "$profile_name" '.profiles[$p].model' "$profiles_file")}"
  opencode_model="${opencode_model:-$(jq -r --arg p "$profile_name" '.profiles[$p].opencode_model' "$profiles_file")}"
  protocol="$(jq -r --arg p "$profile_name" '.profiles[$p].protocol' "$profiles_file")"
  key_secret="$(jq -r --arg p "$profile_name" '.profiles[$p].key_secret // empty' "$profiles_file")"
fi

if [ -z "$provider" ] || [ -z "$base_url" ] || [ -z "$model" ]; then
  echo "usage: $0 [--dry-run] [--set-key-stdin] <profile-name>" >&2
  echo "   or: $0 [--dry-run] --provider <p> --base-url <u> --model <m> [--opencode-model <om>] [--protocol openai|anthropic]" >&2
  exit 2
fi

if [ -z "$opencode_model" ]; then
  opencode_model="${provider}/${model}"
fi

use_anthropic="false"
if [ "$protocol" = "anthropic" ]; then
  use_anthropic="true"
fi

echo "=== Heretek-AI LLM Profile Cutover (dry_run=$dry_run) ==="
echo "  profile:            ${profile_name:-custom}"
echo "  LLM_PROVIDER:       $provider"
echo "  LLM_BASE_URL:       $base_url"
echo "  LLM_MODEL:          $model"
echo "  LLM_OPENCODE_MODEL: $opencode_model"
echo "  LLM_PROTOCOL:       $protocol (OCR_LLM_USE_ANTHROPIC=$use_anthropic)"

set_org_var() {
  local name="$1"
  local value="$2"
  if [ "$dry_run" = true ]; then
    echo "[dry-run] Would set org variable $name=$value (visibility=all)"
  else
    gh variable set "$name" --org "$org" --visibility all --body "$value"
    echo "Set org variable $name=$value"
  fi
}

# Canonical LLM_* org variables
set_org_var "LLM_PROVIDER" "$provider"
set_org_var "LLM_BASE_URL" "$base_url"
set_org_var "LLM_MODEL" "$model"
set_org_var "LLM_OPENCODE_MODEL" "$opencode_model"
set_org_var "LLM_PROTOCOL" "$protocol"

# Backwards-compatible legacy mirrors
set_org_var "OCR_LLM_URL" "$base_url"
set_org_var "OCR_LLM_MODEL" "$model"
set_org_var "OCR_LLM_USE_ANTHROPIC" "$use_anthropic"
set_org_var "OPENCODE_MODEL" "$opencode_model"

if [ "$set_key_stdin" = true ]; then
  IFS= read -r api_key
  if [ -z "$api_key" ]; then
    echo "ERROR: Empty API key read from stdin." >&2
    exit 1
  fi
  if [ "$dry_run" = true ]; then
    echo "[dry-run] Would update org secrets: LLM_API_KEY, OCR_LLM_TOKEN${key_secret:+, $key_secret}"
  else
    printf '%s' "$api_key" | gh secret set LLM_API_KEY --org "$org" --visibility all
    printf '%s' "$api_key" | gh secret set OCR_LLM_TOKEN --org "$org" --visibility all
    if [ -n "$key_secret" ] && [ "$key_secret" != "LLM_API_KEY" ] && [ "$key_secret" != "OCR_LLM_TOKEN" ]; then
      printf '%s' "$api_key" | gh secret set "$key_secret" --org "$org" --visibility all
    fi
    echo "Updated org secrets: LLM_API_KEY, OCR_LLM_TOKEN${key_secret:+, $key_secret}"
  fi
fi

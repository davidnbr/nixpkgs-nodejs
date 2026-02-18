#!/usr/bin/env bash
#
# Fetches Node.js versions from nixpkgs and updates versions.json
# Uses GitHub API to find commits that updated Node.js packages
#
# Usage:
#   ./fetch-node-versions.sh          # Auto-discover and add new versions
#   ./fetch-node-versions.sh list     # List current versions
#   ./fetch-node-versions.sh add 22.12 # Add specific version
#   ./fetch-node-versions.sh --dry-run # Show what would be added
#

set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# Configuration
# =============================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly VERSIONS_FILE="${SCRIPT_DIR}/../versions.json"
readonly NIXPKGS_REPO="NixOS/nixpkgs"
readonly GITHUB_API_URL="https://api.github.com"

# Supported Node.js major versions
readonly MIN_MAJOR=14
readonly MAX_MAJOR=26

# API rate limiting
readonly MAX_PAGES=3
readonly API_DELAY=0.5

if [[ -t 1 ]]; then
  readonly RED='\033[0;31m'
  readonly GREEN='\033[0;32m'
  readonly YELLOW='\033[1;33m'
  readonly BLUE='\033[0;34m'
  readonly NC='\033[0m'
else
  readonly RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

log() {
  local -r level="$1"
  local -r msg="$2"
  local color

  case "$level" in
  error) color="$RED" ;;
  warn) color="$YELLOW" ;;
  info) color="$GREEN" ;;
  step) color="$BLUE" ;;
  esac

  echo -e "${color}[${level^^}]${NC} $msg" >&2
}

die() {
  log error "$1"
  exit 1
}

check_dependencies() {
  local -ra deps=(jq curl nix-prefetch-git)
  local dep

  for dep in "${deps[@]}"; do
    command -v "$dep" &>/dev/null || die "Missing required command: $dep"
  done
}

github_api() {
  local -r endpoint="$1"
  local -r url="${GITHUB_API_URL}${endpoint}"

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl -s -H "Authorization: token ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github.v3+json" "$url"
  else
    curl -s -H "Accept: application/vnd.github.v3+json" "$url"
  fi
}

fetch_commits() {
  local -r query="$1"
  local -a results=()
  local page=1

  while ((page <= MAX_PAGES)); do
    local response
    response=$(github_api "/search/commits?q=${query// /+}&sort=author-date&order=desc&per_page=100&page=$page")

    local count
    count=$(echo "$response" | jq -r '.total_count // 0')

    if [[ "$count" -eq 0 ]] || [[ -z "$count" ]]; then
      break
    fi

    local items
    items=$(echo "$response" | jq -r '.items[] | "\(.sha)|\(.commit.message)"' 2>/dev/null)

    [[ -z "$items" ]] && break

    while IFS='|' read -r sha msg; do
      results+=("$sha|$msg")
    done <<<"$items"

    ((page++))
    sleep "$API_DELAY"
  done

  printf '%s\n' "${results[@]}"
}

get_attr_name() {
  local -r major="$1"
  local attr

  case "$major" in
  14) attr="nodejs_14" ;;
  16) attr="nodejs-16_x" ;;
  18) attr="nodejs_18" ;;
  20) attr="nodejs_20" ;;
  22) attr="nodejs_22" ;;
  23) attr="nodejs_23" ;;
  24) attr="nodejs_24" ;;
  25) attr="nodejs_25" ;;
  26) attr="nodejs_26" ;;
  *) attr="nodejs" ;;
  esac

  echo "$attr"
}

extract_version() {
  local -r msg="$1"
  echo "$msg" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true
}

is_valid_version() {
  local -r version="$1"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

is_supported_major() {
  local -r major="$1"
  ((major >= MIN_MAJOR && major <= MAX_MAJOR))
}

get_existing_versions() {
  [[ -f "$VERSIONS_FILE" ]] && jq -r '.versions | keys[]' "$VERSIONS_FILE" 2>/dev/null || true
}

version_exists() {
  local -r version="$1"
  [[ -f "$VERSIONS_FILE" ]] && jq -e ".versions[\"$version\"]" "$VERSIONS_FILE" &>/dev/null
}

fetch_sha256() {
  local -r rev="$1"
  local sha256

  sha256=$(nix-prefetch-git "https://github.com/${NIXPKGS_REPO}.git" "$rev" --quiet 2>/dev/null |
    jq -r '.sha256 // empty')

  echo "$sha256"
}

add_version() {
  local -r version="$1"
  local -r rev="$2"
  local -r dry_run="${3:-false}"

  is_valid_version "$version" || {
    log warn "Invalid version format: $version"
    return 1
  }

  local -r major="${version%%.*}"
  is_supported_major "$major" || {
    log warn "Unsupported major version: $major"
    return 1
  }

  if version_exists "$version"; then
    log info "Version $version already exists, skipping"
    return 0
  fi

  log info "Adding Node.js $version..."

  local sha256
  sha256=$(fetch_sha256 "$rev")

  if [[ -z "$sha256" ]] || [[ "$sha256" == "null" ]]; then
    log error "Failed to fetch sha256 for $version"
    return 1
  fi

  if [[ "$dry_run" == "true" ]]; then
    log info "[DRY-RUN] Would add $version (rev: ${rev:0:7}, sha256: ${sha256:0:20}...)"
    return 0
  fi

  local -r attr
  attr=$(get_attr_name "$major")

  local tmp
  tmp=$(mktemp)
  jq ".versions[\"$version\"] = {
    \"version\": \"$version\",
    \"rev\": \"$rev\",
    \"sha256\": \"$sha256\",
    \"attr\": \"$attr\"
  }" "$VERSIONS_FILE" >"$tmp" && mv "$tmp" "$VERSIONS_FILE"

  log info "Added $version (sha256: ${sha256:0:30}...)"
}

cmd_discover() {
  local -r dry_run="${1:-false}"

  check_dependencies
  [[ -f "$VERSIONS_FILE" ]] || die "versions.json not found at $VERSIONS_FILE"

  log info "Starting Node.js version discovery from nixpkgs..."
  log info "Target: https://github.com/${NIXPKGS_REPO}"

  local existing
  existing=$(get_existing_versions)
  log info "Existing versions: ${existing:-none}"

  log step "Searching GitHub for Node.js commits..."

  local -a commits
  mapfile -t commits < <(fetch_commits "nodejs update repo:${NIXPKGS_REPO} is:merged")

  if ((${#commits[@]} == 0)); then
    die "No commits found"
  fi

  log step "Processing ${#commits[@]} commits..."

  local -A seen_versions
  local -a version_data=()

  for entry in "${commits[@]}"; do
    [[ -z "$entry" ]] && continue

    local commit_sha="${entry%%|*}"
    local msg="${entry#*|}"

    local version
    version=$(extract_version "$msg")

    [[ -z "$version" ]] && continue
    [[ -n "${seen_versions[$version]:-}" ]] && continue

    seen_versions[$version]=1
    version_data+=("$version|$commit_sha")
  done

  local sorted_versions
  sorted_versions=$(printf '%s\n' "${version_data[@]}" | sort -t'|' -k1 -V)

  local added=0

  while IFS='|' read -r version rev; do
    [[ -z "$version" ]] && continue

    local major="${version%%.*}"

    if is_supported_major "$major"; then
      if [[ "$dry_run" == "true" ]] && version_exists "$version"; then
        log info "Version $version already exists, would skip"
        continue
      fi

      if add_version "$version" "$rev" "$dry_run"; then
        ((added++)) || true
      fi
    fi
  done <<<"$sorted_versions"

  log info "Discovery complete! Added $added new versions."

  # Summary
  log info "Current versions:"
  jq -r '.versions | to_entries[0:3] | .[] | "\(.key): \(.value.rev | .[0:7])"' "$VERSIONS_FILE"
  echo "..."
  jq -r '.versions | length' "$VERSIONS_FILE" | xargs echo "Total versions:"
}

cmd_list() {
  [[ -f "$VERSIONS_FILE" ]] || die "versions.json not found"

  echo "Current Node.js versions:"
  echo ""
  jq -r '.versions | to_entries[] | "\(.key): rev=\(.value.rev[0:7]), attr=\(.value.attr)"' "$VERSIONS_FILE" |
    sort -t: -k1 -V
}

cmd_add() {
  local -r version="${1:-}"

  [[ -n "$version" ]] || die "Usage: $0 add <version>"

  check_dependencies
  [[ -f "$VERSIONS_FILE" ]] || die "versions.json not found"

  log info "Looking for Node.js $version in nixpkgs..."

  local -a commits
  mapfile -t commits < <(fetch_commits "nodejs ${version} repo:${NIXPKGS_REPO} is:merged")

  for entry in "${commits[@]}"; do
    [[ -z "$entry" ]] && continue

    local -r sha="${entry%%|*}"
    local -r msg="${entry#*|}"

    if echo "$msg" | grep -q "$version"; then
      log info "Found commit: $sha"
      add_version "$version" "$sha"
      exit 0
    fi
  done

  die "Could not find Node.js $version in nixpkgs"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [command] [options]

Commands:
  (none)          Discover and add new Node.js versions
  list            List current versions
  add <version>   Add specific version (e.g., 22.12)
  --dry-run       Show what would be added without making changes

Options:
  -h, --help      Show this help message

Environment:
  GITHUB_TOKEN    GitHub API token for higher rate limits

EOF
}

main() {
  local dry_run="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --dry-run)
      dry_run="true"
      shift
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage
      exit 1
      ;;
    *)
      break
      ;;
    esac
  done

  case "${1:-}" in
  list)
    cmd_list
    ;;
  add)
    cmd_add "${2:-}"
    ;;
  "")
    cmd_discover "$dry_run"
    ;;
  *)
    usage
    exit 1
    ;;
  esac
}

main "$@"

#!/usr/bin/env bash
#
# Fetches Node.js versions from nixpkgs and updates versions.json
# Uses GitHub API to find commits that updated Node.js packages
#
# Usage:
#   ./fetch-node-versions.sh              # Auto-discover and add new versions
#   ./fetch-node-versions.sh list         # List current versions
#   ./fetch-node-versions.sh add 22.12    # Add specific major.minor version
#   ./fetch-node-versions.sh --dry-run    # Show what would be added

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly VERSIONS_FILE="${SCRIPT_DIR}/../versions.json"
readonly NIXPKGS_REPO="NixOS/nixpkgs"
readonly GITHUB_API_URL="https://api.github.com"

readonly MIN_MAJOR=14
readonly MAX_MAJOR=26
readonly MAX_PAGES=3
readonly API_DELAY=0.5

[[ -t 1 ]] && readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' BLUE='\033[0;34m' NC='\033[0m' ||
  readonly RED='' GREEN='' YELLOW='' BLUE='' NC=''

# Temp files tracked for cleanup
declare -a _TEMP_FILES=()

cleanup() {
  for f in "${_TEMP_FILES[@]}"; do
    [[ -f "$f" ]] && rm -f "$f"
  done
}
trap cleanup EXIT

make_temp() {
  local tmp
  tmp=$(mktemp)
  _TEMP_FILES+=("$tmp")
  echo "$tmp"
}

log() {
  local -r level="$1" msg="$2"
  local c
  case "$level" in
  error) c="$RED" ;;
  warn) c="$YELLOW" ;;
  info) c="$GREEN" ;;
  step) c="$BLUE" ;;
  esac
  echo -e "${c}[${level^^}]${NC} $msg" >&2
}
die() {
  log error "$1"
  exit 1
}

check_dependencies() {
  local -ra deps=(jq curl nix-prefetch-git)
  for dep in "${deps[@]}"; do command -v "$dep" &>/dev/null || die "Missing: $dep"; done
}

github_api() {
  local -r endpoint="$1"
  local -r url="${GITHUB_API_URL}${endpoint}"
  local -a curl_args=(
    -s -f --retry 2 --retry-delay 1
    -H "Accept: application/vnd.github.v3+json"
  )
  [[ -n "${GITHUB_TOKEN:-}" ]] && curl_args+=(-H "Authorization: token ${GITHUB_TOKEN}")

  local response http_code
  response=$(curl "${curl_args[@]}" -w '\n%{http_code}' "$url" 2>/dev/null) || {
    log warn "API request failed for: $endpoint"
    return 1
  }

  http_code=$(tail -1 <<<"$response")
  response=$(sed '$d' <<<"$response")

  case "$http_code" in
  200 | 2*) echo "$response" ;;
  403)
    log warn "GitHub API rate limit hit (403). Set GITHUB_TOKEN for higher limits."
    return 1
    ;;
  *)
    log warn "GitHub API returned HTTP $http_code for: $endpoint"
    return 1
    ;;
  esac
}

fetch_commits() {
  local -r query="$1"
  local -a results=()
  local page=1

  while ((page <= MAX_PAGES)); do
    local response
    response=$(github_api "/search/commits?q=${query// /+}&sort=author-date&order=desc&per_page=100&page=$page") || break

    local count
    count=$(echo "$response" | jq -r '.total_count // 0')
    [[ -n "$count" ]] && [[ "$count" -gt 0 ]] 2>/dev/null || break

    local items
    items=$(echo "$response" | jq -r '.items[] | "\(.sha)|\(.commit.message | split("\n")[0])"' 2>/dev/null)
    [[ -z "$items" ]] && break

    while IFS='|' read -r sha msg; do
      [[ -n "$sha" ]] && results+=("$sha|$msg")
    done <<<"$items"

    ((page++))
    sleep "$API_DELAY"
  done

  ((${#results[@]} > 0)) && printf '%s\n' "${results[@]}"
}

# Resolve the correct nixpkgs attribute name for a Node.js major version.
# Nixpkgs had two naming conventions:
#   Old (pre-2023): nodejs-16_x, nodejs-18_x  (hyphen + _x suffix)
#   Current:        nodejs_16, nodejs_20       (underscore, no suffix)
# We check the target rev to determine which convention applies.
resolve_attr_name() {
  local -r major="$1" rev="$2"
  local -r modern="nodejs_${major}"
  local -r legacy="nodejs-${major}_x"
  local all_packages

  all_packages=$(curl -sf "https://raw.githubusercontent.com/NixOS/nixpkgs/${rev}/pkgs/top-level/all-packages.nix" 2>/dev/null) || {
    log warn "Could not fetch all-packages.nix for rev ${rev:0:7}, defaulting to ${modern}"
    echo "$modern"
    return
  }

  if grep -qE "^[[:space:]]+${modern}[[:space:]]*=" <<<"$all_packages"; then
    echo "$modern"
  elif grep -qE "^[[:space:]]+${legacy}[[:space:]]*=" <<<"$all_packages"; then
    echo "$legacy"
  else
    log warn "Neither ${modern} nor ${legacy} found in rev ${rev:0:7}, defaulting to ${modern}"
    echo "$modern"
  fi
}

# Extract Node.js major.minor from commit messages like:
#   "nodejs_22: 22.14.0 -> 22.15.0"
#   "nodejs: 20.8.0 -> 20.9.0"
#   "update nodejs to 22.12.0"
extract_version() {
  local -r msg="$1"
  # Match patterns like "22.14.0" or "22.14" preceded by a word boundary context
  echo "$msg" | grep -oP '(?:^|[\s:>])(\d+\.\d+)(?:\.\d+)?' | grep -oE '[0-9]+\.[0-9]+' | head -1 || true
}

is_valid_version() {
  local -r version="$1"
  [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]]
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
  [[ -f "$VERSIONS_FILE" ]] && jq -e --arg v "$version" '.versions[$v]' "$VERSIONS_FILE" &>/dev/null
}

fetch_sha256() {
  local -r rev="$1"
  nix-prefetch-git "https://github.com/${NIXPKGS_REPO}.git" "$rev" --quiet 2>/dev/null | jq -r '.sha256 // empty'
}

add_version() {
  local -r version="$1" rev="$2" dry_run="${3:-false}"

  is_valid_version "$version" || {
    log warn "Invalid version: $version"
    return 1
  }

  local -r major="${version%%.*}"
  is_supported_major "$major" || {
    log warn "Unsupported major: $major"
    return 1
  }

  if version_exists "$version"; then
    log info "Version $version already exists, skipping"
    return 0
  fi

  if [[ "$dry_run" == "true" ]]; then
    log info "[DRY-RUN] Would add $version (rev: ${rev:0:7})"
    return 0
  fi

  log info "Adding Node.js $version..."

  local sha256
  sha256=$(fetch_sha256 "$rev")
  [[ -n "$sha256" ]] && [[ "$sha256" != "null" ]] || {
    log error "Failed to fetch sha256 for $version (rev: ${rev:0:7})"
    return 1
  }

  local attr
  attr=$(resolve_attr_name "$major" "$rev")
  readonly attr

  local tmp
  tmp=$(make_temp)
  jq --arg v "$version" --arg r "$rev" --arg s "$sha256" --arg a "$attr" \
    '.versions[$v] = { version: $v, rev: $r, sha256: $s, attr: $a }' \
    "$VERSIONS_FILE" >"$tmp" && mv "$tmp" "$VERSIONS_FILE"

  log info "Added $version"
}

cmd_discover() {
  local -r dry_run="${1:-false}"

  check_dependencies
  [[ -f "$VERSIONS_FILE" ]] || die "versions.json not found at $VERSIONS_FILE"

  log info "Starting Node.js version discovery from nixpkgs..."
  log info "Target: https://github.com/${NIXPKGS_REPO}"

  local existing
  existing=$(get_existing_versions)
  log info "Existing: ${existing:-none}"

  log step "Searching GitHub..."

  local -a commits
  mapfile -t commits < <(fetch_commits "nodejs update repo:${NIXPKGS_REPO}")

  ((${#commits[@]} == 0)) && die "No commits found"

  log step "Processing ${#commits[@]} commits..."

  # Track the first (most recent) commit seen per major.minor version.
  # Results are already sorted by date desc, so first occurrence wins.
  local -A version_commit

  for entry in "${commits[@]}"; do
    [[ -z "$entry" ]] && continue

    local commit_sha="${entry%%|*}"
    local msg="${entry#*|}"
    local version
    version=$(extract_version "$msg")

    [[ -z "$version" ]] && continue

    local major="${version%%.*}"

    is_supported_major "$major" || continue

    # Keep only the first (latest) commit per version
    [[ -n "${version_commit[$version]:-}" ]] && continue
    version_commit[$version]=$commit_sha
  done

  local added=0
  for version in "${!version_commit[@]}"; do
    add_version "$version" "${version_commit[$version]}" "$dry_run" && ((added++)) || true
  done

  log info "Discovery complete! Added $added new versions."
  log info "Current versions:"
  jq -r '.versions | to_entries | sort_by(.key | split(".") | map(tonumber)) | .[-3:][] | "\(.key): \(.value.rev | .[0:7])"' "$VERSIONS_FILE"
  echo "..."
  jq -r '.versions | length' "$VERSIONS_FILE" | xargs echo "Total:"
}

cmd_list() {
  [[ -f "$VERSIONS_FILE" ]] || die "versions.json not found"
  echo "Current Node.js versions:"
  echo ""
  jq -r '.versions | to_entries | sort_by(.key | split(".") | map(tonumber))[] | "\(.key): rev=\(.value.rev[0:7]), attr=\(.value.attr)"' "$VERSIONS_FILE"
}

cmd_add() {
  local -r version="${1:-}"
  [[ -n "$version" ]] || die "Usage: $0 add <major.minor>"
  is_valid_version "$version" || die "Invalid version format: $version (expected major.minor, e.g. 22.12)"

  check_dependencies
  [[ -f "$VERSIONS_FILE" ]] || die "versions.json not found"

  if version_exists "$version"; then
    log info "Version $version already exists"
    return 0
  fi

  log info "Looking for Node.js $version in nixpkgs..."

  local -a commits
  mapfile -t commits < <(fetch_commits "nodejs ${version} repo:${NIXPKGS_REPO}")

  for entry in "${commits[@]}"; do
    [[ -z "$entry" ]] && continue
    local sha="${entry%%|*}" msg="${entry#*|}"
    if echo "$msg" | grep -q "$version"; then
      log info "Found commit: ${sha:0:7}"
      add_version "$version" "$sha"
      return 0
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
    *) break ;;
    esac
  done

  case "${1:-}" in
  list) cmd_list ;;
  add) cmd_add "${2:-}" ;;
  "") cmd_discover "$dry_run" ;;
  *)
    usage
    exit 1
    ;;
  esac
}

main "$@"

#!/usr/bin/env bash
#
# Fetches the latest Node.js versions from nixpkgs and generates versions.json
# Uses GitHub API to find commits that updated each Node.js version
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSIONS_FILE="${SCRIPT_DIR}/../versions.json"
NIXPKGS_REPO="NixOS/nixpkgs"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*" | tee /dev/tty >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*" | tee /dev/tty >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" | tee /dev/tty >&2; }
log_step() { echo -e "${BLUE}[STEP]${NC} $*" | tee /dev/tty >&2; }

# Check dependencies
check_dependencies() {
  for dep in jq curl nix-prefetch-git; do
    if ! command -v "$dep" &> /dev/null; then
      log_error "Missing required command: $dep"
      exit 1
    fi
  done
}

# Get attribute name for major version
get_attr_name() {
  local major="$1"
  case "$major" in
    14) echo "nodejs_14" ;;
    16) echo "nodejs-16_x" ;;
    18) echo "nodejs_18" ;;
    20) echo "nodejs_20" ;;
    22) echo "nodejs_22" ;;
    23) echo "nodejs_23" ;;
    24) echo "nodejs_24" ;;
    25) echo "nodejs_25" ;;
    26) echo "nodejs_26" ;;
    *) echo "nodejs" ;;
  esac
}

# Extract version from commit message
extract_version_from_msg() {
  local msg="$1"
  # Match patterns like "18.20.0", "20.14.1", etc.
  echo "$msg" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# Fetch sha256 for a revision
fetch_sha256() {
  local rev="$1"
  nix-prefetch-git "https://github.com/${NIXPKGS_REPO}.git" "$rev" --quiet 2>/dev/null | \
    jq -r '.sha256 // empty'
}

# Check if version exists
version_exists() {
  local version="$1"
  [ -f "$VERSIONS_FILE" ] && jq -e ".versions[\"$version\"]" "$VERSIONS_FILE" &>/dev/null
}

# Get versions already in versions.json
get_existing_versions() {
  if [ -f "$VERSIONS_FILE" ]; then
    jq -r '.versions | keys[]' "$VERSIONS_FILE" 2>/dev/null || true
  fi
}

# Fetch commits from GitHub API with rate limit handling
fetch_commits() {
  local query="$1"
  local page=1
  local results=()

  while [ $page -le 3 ]; do
    log_step "Fetching commits page $page..."

    local response
    response=$(curl -s -H "Accept: application/vnd.github.v3+json" \
      "https://api.github.com/search/commits?q=${query// /+}&sort=author-date&order=desc&per_page=100&page=$page" 2>/dev/null)

    local count
    count=$(echo "$response" | jq -r '.total_count // 0')

    if [ "$count" = "0" ] || [ -z "$count" ]; then
      break
    fi

    local items
    items=$(echo "$response" | jq -r '.items[] | "\(.sha)|\(.commit.message)"' 2>/dev/null)

    if [ -z "$items" ]; then
      break
    fi

    while IFS='|' read -r sha msg; do
      results+=("$sha|$msg")
    done <<< "$items"

    ((page++))
    sleep 0.5  # Rate limit handling
  done

  printf '%s\n' "${results[@]}"
}

# Process commits and find versions
process_commits() {
  local commits=("$@")

  # Declare associative array - must use declare, not local -A with set -u
  declare -A found_versions
  found_versions=()

  log_step "Processing ${#commits[@]} commits to extract versions..."

  # Use a temp file instead of associative array for portability
  local temp_map
  temp_map=$(mktemp)

  for entry in "${commits[@]}"; do
    [ -z "$entry" ] && continue

    local sha="${entry%%|*}"
    local msg="${entry#*|}"

    local version
    version=$(extract_version_from_msg "$msg")

    if [ -z "$version" ]; then
      continue
    fi

    # Only keep the first (most recent) commit for each version
    if ! grep -q "^${version}|" "$temp_map" 2>/dev/null; then
      echo "${version}|${sha}" >> "$temp_map"
      log_info "Found: Node.js $version -> $sha"
    fi
  done

  # Sort and output
  sort -t'|' -k1 -V "$temp_map"
  rm -f "$temp_map"
}

# Add a version to versions.json
add_version() {
  local version="$1"
  local rev="$2"

  if version_exists "$version"; then
    log_info "Version $version already exists, skipping"
    return 0
  fi

  local version_major
  version_major=$(echo "$version" | cut -d. -f1)

  log_info "Adding Node.js $version..."

  local sha256
  sha256=$(fetch_sha256 "$rev")

  if [ -z "$sha256" ] || [ "$sha256" = "null" ]; then
    log_error "Failed to fetch sha256 for $version"
    return 1
  fi

  local attr
  attr=$(get_attr_name "$version_major")

  # Add using jq
  local tmp
  tmp=$(mktemp)
  jq ".versions[\"$version\"] = {
    \"version\": \"$version\",
    \"rev\": \"$rev\",
    \"sha256\": \"$sha256\",
    \"attr\": \"$attr\"
  }" "$VERSIONS_FILE" > "$tmp" && mv "$tmp" "$VERSIONS_FILE"

  log_info "Added $version (sha256: ${sha256:0:30}...)"
}

# Main discovery
main() {
  check_dependencies

  if [ ! -f "$VERSIONS_FILE" ]; then
    log_error "versions.json not found"
    exit 1
  fi

  log_info "Starting Node.js version discovery from nixpkgs..."
  log_info "Target: https://github.com/${NIXPKGS_REPO}"

  # Get existing versions
  local existing
  existing=$(get_existing_versions)
  log_info "Existing versions: $(echo $existing | tr '\n' ' ')"

  # Search for nodejs update commits
  log_step "Searching GitHub for Node.js commits..."

  local commits
  mapfile -t commits < <(fetch_commits "nodejs update repo:NixOS/nixpkgs is:merged")

  if [ ${#commits[@]} -eq 0 ]; then
    log_error "No commits found"
    exit 1
  fi

  # Process and extract versions
  local version_data
  version_data=$(process_commits "${commits[@]}")

  # Filter to versions we want (14-26) and add new ones
  local added=0

  while IFS='|' read -r version rev; do
    [ -z "$version" ] && continue

    local major
    major=$(echo "$version" | cut -d. -f1)

    # Only process versions 14-26
    if [ "$major" -ge 14 ] && [ "$major" -le 26 ]; then
      if add_version "$version" "$rev"; then
        ((added++)) || true
      fi
    fi
  done <<< "$version_data"

  log_info "Discovery complete! Added $added new versions."

  # Show summary
  log_info "Current versions:"
  jq -r '.versions | to_entries[0:3] | .[] | "\(.key): \(.value.rev | .[0:7])"' "$VERSIONS_FILE"
  echo "..."
  jq -r '.versions | length' "$VERSIONS_FILE" | xargs echo "Total versions:"
}

# List command
cmd_list() {
  if [ ! -f "$VERSIONS_FILE" ]; then
    log_error "versions.json not found"
    exit 1
  fi

  echo "Current Node.js versions:"
  echo ""
  jq -r '.versions | to_entries[] | "\(.key): rev=\(.value.rev[0:7]), attr=\(.value.attr)"' "$VERSIONS_FILE" | \
    sort -t: -k1 -V
}

# Add specific version
cmd_add() {
  local version="${1:-}"

  if [ -z "$version" ]; then
    log_error "Usage: fetch-node-versions.sh add <version>"
    exit 1
  fi

  if [ ! -f "$VERSIONS_FILE" ]; then
    log_error "versions.json not found"
    exit 1
  fi

  check_dependencies

  log_info "Looking for Node.js $version in nixpkgs..."

  # Search for commits with this specific version
  local commits
  mapfile -t commits < <(fetch_commits "nodejs ${version} repo:NixOS/nixpkgs is:merged")

  local found=
  for entry in "${commits[@]}"; do
    [ -z "$entry" ] && continue

    local sha="${entry%%|*}"
    local msg="${entry#*|}"

    if echo "$msg" | grep -q "$version"; then
      log_info "Found commit: $sha"
      add_version "$version" "$sha"
      found=1
      break
    fi
  done

  if [ -z "$found" ]; then
    log_error "Could not find Node.js $version in nixpkgs"
    exit 1
  fi
}

# Handle commands
case "${1:-}" in
  list)
    cmd_list
    ;;
  add)
    cmd_add "${2:-}"
    ;;
  --help|-h)
    echo "Usage: fetch-node-versions.sh [command]"
    echo ""
    echo "Commands:"
    echo "  (none)      Discover and add new Node.js versions"
    echo "  add <ver>   Add specific version (e.g., 22.12)"
    echo "  list        List current versions"
    ;;
  *)
    main
    ;;
esac

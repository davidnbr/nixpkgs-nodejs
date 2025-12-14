#!/usr/bin/env bash
set -euo pipefail

# --- User-Defined Node.js Versions ---
# List of desired major.minor versions
TARGET_VERSIONS=("18.16" "18.18" "18.20" "20.14" "20.16" "20.18" "22.6" "22.8" "22.10")
# -------------------------------------

# This function shows how you would generate the sha256.
# It is commented out because it requires running 'nix-prefetch-git'
# or similar tools and is time-consuming.
#
# NOTE: To use this in a real environment, you'd uncomment this function and
# replace the placeholder call below with the actual function call.
#
# function prefetch_sha256() {
#   local REV=$1
#   # Replace with your specific nixpkgs repository URL if different
#   local REPO="https://github.com/NixOS/nixpkgs.git"
#
#   # This command will fetch the source and calculate the hash
#   # It outputs a JSON string containing "sha256"
#   nix-prefetch-git "$REPO" "$REV" | jq -r '.sha256'
# }

# Initialize versions output
echo "{" >versions.json
echo '  "versions": {' >>versions.json

FIRST=true

# For each target version, find the nixpkgs rev and add a placeholder for sha256
for VERSION_KEY in "${TARGET_VERSIONS[@]}"; do

  echo "Finding latest patch version for Node.js ${VERSION_KEY}..."

  # 1. Find the latest patch version for the major.minor branch
  FULL_VERSION_OBJ=$(curl -s https://nodejs.org/dist/index.json | jq -r '
    [.[] | select(.version | test("^v'${VERSION_KEY}'\\."))] |
    max_by(.version)
  ')

  if [ -z "$FULL_VERSION_OBJ" ] || [ "$FULL_VERSION_OBJ" == "null" ]; then
    echo "⚠️ Could not find a version matching v${VERSION_KEY}.* on nodejs.org. Skipping."
    continue
  fi

  # Get the full version string (e.g., "18.16.1")
  FULL_VERSION=$(echo "$FULL_VERSION_OBJ" | jq -r '.version' | sed 's/^v//')

  echo "Latest full version found: $FULL_VERSION"

  # 2. Search lazamar.co.uk for the nixpkgs revision (rev)
  echo "Finding nixpkgs revision (rev) for Node.js $FULL_VERSION..."

  # Query nixpkgs, find the link containing the specific version, extract the revision from the URL.
  NIXPKGS_REV=$(curl -s "https://lazamar.co.uk/nix-versions/?channel=nixpkgs-unstable&package=nodejs" |
    grep "version=${FULL_VERSION}" |
    grep -o "revision=[a-f0-9]*" |
    cut -d'=' -f2 |
    head -1 || echo "")

  # 3. Handle data output
  if [ -n "$NIXPKGS_REV" ]; then

    # Placeholder for the actual SHA256 calculation
    # SHA256_HASH=$(prefetch_sha256 "$NIXPKGS_REV")
    SHA256_HASH="<NIX_SHA256_REQUIRED_FOR_REV_$NIXPKGS_REV>"

    if [ "$FIRST" = true ]; then
      FIRST=false
    else
      echo "," >>versions.json
    fi

    cat >>versions.json <<EOF
    "$VERSION_KEY": {
      "version": "$VERSION_KEY",
      "rev": "$NIXPKGS_REV",
      "sha256": "$SHA256_HASH"
    }
EOF
  else
    echo "⚠️ Could not find nixpkgs revision for Node.js $FULL_VERSION. Skipping."
  fi
done

{
  echo ""
  echo "  }"
  echo "}"
} >>versions.json

echo "✓ Updated versions.json"
echo "---"
echo "⚠️ ACTION REQUIRED: You must manually run 'nix-prefetch-git' or similar for each 'rev' to replace the '<NIX_SHA256_REQUIRED...>' placeholders with the correct sha256 hashes."

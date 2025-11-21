#!/usr/bin/env bash
set -euo pipefail

# --- User-Defined Node.js Versions ---
# List of desired major.minor versions based on your versions.json input.
TARGET_VERSIONS=("18.16" "18.18" "18.20" "20.14" "20.16" "20.18" "22.6" "22.8" "22.10")
# -------------------------------------

# Initialize versions output
echo "{" >versions.json
echo '  "versions": {' >>versions.json

FIRST=true

# For each target version, find the nixpkgs commit
for VERSION_KEY in "${TARGET_VERSIONS[@]}"; do
  # VERSION_KEY is the major.minor (e.g., "18.16")

  echo "Finding latest patch version for Node.js ${VERSION_KEY}..."

  # Fetch all versions, then filter for the specific major.minor branch and get the latest patch's full version string (vX.Y.Z)
  # Uses the regex pattern for the major.minor version, e.g., "^v18.16\."
  FULL_VERSION_OBJ=$(curl -s https://nodejs.org/dist/index.json | jq -r '
    [.[] | select(.version | test("^v'${VERSION_KEY}'\\."))] |
    max_by(.version)
  ')

  # Check if a version was found
  if [ -z "$FULL_VERSION_OBJ" ] || [ "$FULL_VERSION_OBJ" == "null" ]; then
    echo "⚠️ Could not find a version matching v${VERSION_KEY}.* on nodejs.org. Skipping."
    continue
  fi

  # Get the full version string (e.g., "18.16.1")
  FULL_VERSION=$(echo "$FULL_VERSION_OBJ" | jq -r '.version' | sed 's/^v//')

  echo "Latest full version found: $FULL_VERSION"

  # Search lazamar.co.uk for the nixpkgs commit using the FULL_VERSION
  echo "Finding nixpkgs commit for Node.js $FULL_VERSION..."

  # Query nixpkgs for this full version. We attempt to extract the full commit hash from the URL.
  NIXPKGS_COMMIT=$(curl -s "https://lazamar.co.uk/nix-versions/?channel=nixpkgs-unstable&package=nodejs" |
    grep "nodejs-${FULL_VERSION}" | head -1 | sed 's/.*<a href="\/nix-versions\/\([^"]*\)">[^<]*<\/a>.*$/\1/' || echo "")

  # Note: The original script used a method that wouldn't extract the commit hash.
  # This updated sed command attempts to extract the hash/rev from the link provided by lazamar.co.uk.
  # If that fails, it will be empty.

  if [ -n "$NIXPKGS_COMMIT" ]; then
    if [ "$FIRST" = true ]; then
      FIRST=false
    else
      echo "," >>versions.json
    fi

    # The key and version in the output JSON is the major.minor part
    cat >>versions.json <<EOF
    "$VERSION_KEY": {
      "version": "$VERSION_KEY",
      "full_version": "$FULL_VERSION",
      "nixpkgs_commit": "$NIXPKGS_COMMIT"
    }
EOF
  else
    echo "⚠️ Could not find nixpkgs commit for Node.js $FULL_VERSION. Skipping."
  fi
done

{
  echo ""
  echo "  }"
  echo "}"
} >>versions.json

echo "✓ Updated versions.json"

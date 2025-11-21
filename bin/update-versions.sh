#!/usr/bin/env bash
set -euo pipefail

# Fetch all Node.js versions from official source
echo "Fetching Node.js versions from nodejs.org..."
NODEJS_VERSIONS=$(curl -s https://nodejs.org/dist/index.json)

# Filter for versions >= 16.0.0 (adjust as needed)
# Only keep latest patch version per minor release
FILTERED_VERSIONS=$(echo "$NODEJS_VERSIONS" | jq -r '
  [.[] | select(.version | test("^v(1[6-9]|2[0-9])"))] |
  group_by(.version | split(".")[0:2] | join(".")) |
  map(max_by(.version)) |
  .[]
')

# Initialize versions output
echo "{" >versions.json
echo '  "versions": {' >>versions.json

FIRST=true

# For each version, find the nixpkgs commit that has it
echo "$FILTERED_VERSIONS" | jq -c '.' | while IFS= read -r version_obj; do
  VERSION=$(echo "$version_obj" | jq -r '.version' | sed 's/^v//')

  # Search lazamar.co.uk for the nixpkgs commit
  echo "Finding nixpkgs commit for Node.js $VERSION..."

  # Query nixpkgs for this version
  NIXPKGS_COMMIT=$(curl -s "https://lazamar.co.uk/nix-versions/?channel=nixpkgs-unstable&package=nodejs" |
    grep -o "nodejs-${VERSION}" | head -1 || echo "")

  if [ -n "$NIXPKGS_COMMIT" ]; then
    if [ "$FIRST" = true ]; then
      FIRST=false
    else
      echo "," >>versions.json
    fi

    cat >>versions.json <<EOF
    "$VERSION": {
      "version": "$VERSION",
      "nixpkgs_commit": "$NIXPKGS_COMMIT"
    }
EOF
  fi
done

{
  echo ""
  echo "  }"
  echo "}"
} >>versions.json

echo "✓ Updated versions.json"

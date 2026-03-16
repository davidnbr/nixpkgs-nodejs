#!/usr/bin/env bash
. "$HOME/.nix-profile/etc/profile.d/nix.sh"

set -euo pipefail

command -v nix-prefetch-git >/dev/null 2>&1 || {
  echo "Error: nix-prefetch-git (Nix) is not found. Ensure Nix is set up."
  exit 1
}

UPDATED_JSON=$(cat versions.json)

mapfile -t REVS < <(jq -r '.versions | to_entries[] | "\(.key) \(.value.rev)"' versions.json)

for entry in "${REVS[@]}"; do
  VERSION_KEY=$(echo "$entry" | cut -d' ' -f1)
  REV_HASH=$(echo "$entry" | cut -d' ' -f2)

  echo "Processing ${VERSION_KEY} (rev: ${REV_HASH})..."

  NEW_SHA256=$(
    nix-prefetch-git \
      "https://github.com/NixOS/nixpkgs.git" \
      "${REV_HASH}" \
      --quiet --fetch-submodules |
      jq -r '.sha256'
  )

  if [ -z "$NEW_SHA256" ] || [ "$NEW_SHA256" == "null" ]; then
    echo "❌ Failed to retrieve sha256. Skipping."
    continue
  fi

  UPDATED_JSON=$(
    echo "$UPDATED_JSON" | jq \
      --arg version "$VERSION_KEY" \
      --arg sha "$NEW_SHA256" \
      '.versions[$version] += {sha256: $sha}'
  )
  echo "   ✓ Hash calculated."
done

echo "$UPDATED_JSON" >versions.json
echo "✓ versions.json updated successfully."

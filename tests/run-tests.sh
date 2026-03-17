#!/usr/bin/env bash
# Integration tests for nixpkgs-nodejs.
# Runs outside the Nix sandbox so package managers can reach the network.
#
# Usage:
#   ./tests/run-tests.sh              # run all tests
#   ./tests/run-tests.sh 22.22        # run only tests for a specific Node version
#   SKIP_BUILD=1 ./tests/run-tests.sh # skip nix build, assume packages are cached

set -euo pipefail

FLAKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="$(dirname "${BASH_SOURCE[0]}")"

GREEN='\033[0;32m' RED='\033[0;31m' YELLOW='\033[1;33m' CYAN='\033[0;36m' NC='\033[0m'
pass() { echo -e "${GREEN}  PASS${NC}  $*"; }
fail() { echo -e "${RED}  FAIL${NC}  $*"; FAILURES=$((FAILURES + 1)); }
info() { echo -e "${CYAN}  ----${NC}  $*"; }

FAILURES=0
FILTER="${1:-}"

# Each entry: "flake_package  package_manager  install_flags"
declare -a TESTS=(
  # npm (built into Node, no bundled package needed)
  "22.22       npm    "
  "20.18       npm    "
  "18.20       npm    "
  "16.20       npm    "

  # yarn — pinned nixpkgs (era-compatible)
  "yarn_16_20  yarn   --no-frozen-lockfile"
  "yarn_18_16  yarn   --no-frozen-lockfile"
  "yarn_22_22  yarn   --no-frozen-lockfile"

  # pnpm — nodePackages.pnpm as-is
  "pnpm_16_14  pnpm   --no-frozen-lockfile"
  "pnpm_18_16  pnpm   --no-frozen-lockfile"
  "pnpm_20_12  pnpm   --no-frozen-lockfile"

  # pnpm — pkgs.pnpm with override (pnpm 10+)
  "pnpm_18_20  pnpm   --no-frozen-lockfile"
  "pnpm_20_18  pnpm   --no-frozen-lockfile"
  "pnpm_22_22  pnpm   --no-frozen-lockfile"
)

run_test() {
  local pkg="$1" pm="$2" flags="$3"

  # Apply filter if set
  if [[ -n "$FILTER" ]] && [[ "$pkg" != *"$FILTER"* ]]; then
    return 0
  fi

  local tmpdir
  tmpdir=$(mktemp -d)
  trap "rm -rf '$tmpdir'" RETURN

  cp "$FIXTURE_DIR/package.json" "$tmpdir/"
  cp "$FIXTURE_DIR/index.js"     "$tmpdir/"

  info "Testing $pkg ($pm install $flags)"

  local output
  # npm packages use the bare version key (e.g. "22.22"), others use the alias
  local flake_ref
  if [[ "$pm" == "npm" ]]; then
    flake_ref="${FLAKE_DIR}#packages.x86_64-linux.\"${pkg}\""
  else
    flake_ref="${FLAKE_DIR}#${pkg}"
  fi

  if output=$(nix shell "$flake_ref" --command sh -c "
    set -e
    cd '$tmpdir'
    echo \"  node: \$(node --version)\"
    echo \"  $pm:  \$($pm --version)\"
    $pm install $flags --silent 2>/dev/null || $pm install $flags
    node index.js
  " 2>&1); then
    pass "$pkg — node+$pm install+require(ms) all OK"
    echo "$output" | grep -E '^\s+(node|ms|'"$pm"')' | sed 's/^/    /'
  else
    fail "$pkg — $pm install failed"
    echo "$output" | tail -20 | sed 's/^/    /'
  fi
}

echo ""
echo "nixpkgs-nodejs integration tests"
echo "Flake: $FLAKE_DIR"
echo "──────────────────────────────────────────────"

for entry in "${TESTS[@]}"; do
  read -r pkg pm flags <<<"$entry"
  run_test "$pkg" "$pm" "$flags"
done

echo "──────────────────────────────────────────────"
if [[ $FAILURES -eq 0 ]]; then
  echo -e "${GREEN}All tests passed${NC}"
else
  echo -e "${RED}${FAILURES} test(s) failed${NC}"
  exit 1
fi

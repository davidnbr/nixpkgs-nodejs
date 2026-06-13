#!/usr/bin/env bash
# Unit tests for scripts/fetch-node-versions.sh's helper functions.
# Pure-logic tests only - no network access.
#
# Usage: ./tests/test-fetch-node-versions.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GREEN='\033[0;32m' RED='\033[0;31m' NC='\033[0m'
FAILURES=0

# shellcheck source=../scripts/fetch-node-versions.sh
source "$SCRIPT_DIR/scripts/fetch-node-versions.sh"

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo -e "${GREEN}  PASS${NC}  $desc"
  else
    echo -e "${RED}  FAIL${NC}  $desc — expected '$expected', got '$actual'"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_true() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo -e "${GREEN}  PASS${NC}  $desc"
  else
    echo -e "${RED}  FAIL${NC}  $desc"
    FAILURES=$((FAILURES + 1))
  fi
}

assert_false() {
  local desc="$1"
  shift
  if ! "$@" >/dev/null 2>&1; then
    echo -e "${GREEN}  PASS${NC}  $desc"
  else
    echo -e "${RED}  FAIL${NC}  $desc"
    FAILURES=$((FAILURES + 1))
  fi
}

echo ""
echo "fetch-node-versions.sh unit tests"
echo "──────────────────────────────────────────────"

echo "extract_version"
assert_eq "FROM -> TO bump uses TO"     "25.9"  "$(extract_version 'nodejs_25: 25.8.2 -> 25.9.0')"
assert_eq "legacy nodejs-NN_x attr"     "16.20" "$(extract_version 'nodejs-16_x: 16.20.1 -> 16.20.2')"
assert_eq "bare nodejs attr"            "20.9"  "$(extract_version 'nodejs: 20.8.0 -> 20.9.0')"
assert_eq "init at"                     "25.2"  "$(extract_version 'nodejs_25: init at 25.2.1 (#452389)')"
assert_eq "rc -> rc"                    "26.0"  "$(extract_version 'nodejs_26: 26.0.0-rc.1 -> 26.0.0-rc.2')"
assert_eq "rc -> final"                 "26.0"  "$(extract_version 'nodejs_26: 26.0.0-rc.2 -> 26.0.0')"
assert_eq "minor bump with PR suffix"   "22.22" "$(extract_version 'nodejs_22: 22.22.2 -> 22.22.3 (#519938)')"
assert_eq "loose 'bump to' fallback"    "24.15" "$(extract_version 'nodejs_24: bump to 24.15.0')"
assert_eq "ignores nodejs_latest bump"  ""      "$(extract_version 'nodejs_latest: 25.9.0 -> 26.0.0-rc.1')"
assert_eq "ignores nodejs_slim bump"    ""      "$(extract_version 'nodejs_slim: 25.0.0 -> 26.0.0')"
assert_eq "ignores brace-expansion msg" ""      "$(extract_version 'nodejs_{20,22}: disable broken openssl tests')"
assert_eq "ignores non-version commit"  ""      "$(extract_version 'nodejs_24: skip tests failing on Darwin')"
assert_eq "ignores merge PR title"      ""      "$(extract_version 'Merge pull request #263285 from marsam/update-nodejs')"
assert_eq "ignores unrelated mention"   ""      "$(extract_version 'mainsail: update nodejs to version 22')"

echo ""
echo "is_valid_version"
assert_true  "22.22 is valid"        is_valid_version "22.22"
assert_true  "16.20 is valid"        is_valid_version "16.20"
assert_false "22 (no minor) invalid" is_valid_version "22"
assert_false "22.22.0 invalid"       is_valid_version "22.22.0"
assert_false "empty string invalid"  is_valid_version ""

echo ""
echo "is_supported_major"
assert_true  "14 supported (MIN_MAJOR)" is_supported_major 14
assert_true  "26 supported (MAX_MAJOR)" is_supported_major 26
assert_true  "22 supported"             is_supported_major 22
assert_false "13 unsupported (< MIN)"   is_supported_major 13
assert_false "27 unsupported (> MAX)"   is_supported_major 27

echo ""
echo "version_exists / get_existing_versions (against real versions.json)"
assert_true  "14.21 exists"     version_exists "14.21"
assert_true  "26.2 exists"      version_exists "26.2"
assert_false "99.99 missing"    version_exists "99.99"
existing="$(get_existing_versions)"
assert_eq "get_existing_versions includes 14.21" "14.21" "$(grep -Fx '14.21' <<<"$existing")"

echo "──────────────────────────────────────────────"
if [[ $FAILURES -eq 0 ]]; then
  echo -e "${GREEN}All tests passed${NC}"
else
  echo -e "${RED}${FAILURES} test(s) failed${NC}"
  exit 1
fi

#!/usr/bin/env bash

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_FILE="$BASE_DIR/$1"
TMP_FILE="$BASE_DIR/$1.tmp"

jq '.versions |= (to_entries | sort_by(.key | split(".") | map(tonumber)) | from_entries)' "$BASE_FILE" >"$TMP_FILE"
mv $TMP_FILE $BASE_FILE

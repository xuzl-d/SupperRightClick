#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

NUMBER_FILE="build-number.txt"
CURRENT="$(<"$NUMBER_FILE")"
if [[ ! "$CURRENT" =~ ^[0-9]+$ ]]; then
    echo "错误：$NUMBER_FILE 必须只包含一个非负整数，当前值为：$CURRENT" >&2
    exit 1
fi

NEXT="$((10#$CURRENT + 1))"
TEMP_FILE="$(mktemp "${NUMBER_FILE}.XXXXXX")"
trap 'rm -f "$TEMP_FILE"' EXIT
printf '%s\n' "$NEXT" > "$TEMP_FILE"
mv "$TEMP_FILE" "$NUMBER_FILE"
trap - EXIT
printf '%s\n' "$NEXT"

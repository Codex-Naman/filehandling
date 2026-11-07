#!/bin/sh
set -eu

MYCP=${MYCP:-build/mycp}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

expect_failure() {
	if "$@" >/dev/null 2>/dev/null; then
		echo "expected failure did not occur: $*" >&2
		exit 1
	fi
}

mkdir -p "$tmp/tree/nested" "$tmp/parent"
printf 'coverage root\n' > "$tmp/tree/root.txt"
printf 'coverage nested\n' > "$tmp/tree/nested/file.txt"

# Help and argument validation paths.
"$MYCP" --help >/dev/null
expect_failure "$MYCP" --buffer invalid "$tmp/tree/root.txt" "$tmp/bad"
expect_failure "$MYCP" --unknown "$tmp/tree/root.txt" "$tmp/bad"
expect_failure "$MYCP" "$tmp/tree/root.txt"

# Info, benchmark, logging, and verbose paths.
"$MYCP" --info "$tmp/tree/root.txt" "$tmp/info-copy"
"$MYCP" -r --info --benchmark --verbose --log "$tmp/operations.log" \
	"$tmp/tree" "$tmp/info-tree"
test -s "$tmp/operations.log"

# Existing destination directory and basename handling.
"$MYCP" "$tmp/tree/root.txt" "$tmp/parent"
test -f "$tmp/parent/root.txt"

# Resume mismatch restart path.
printf 'wrong prefix' > "$tmp/mismatch"
"$MYCP" --resume "$tmp/tree/root.txt" "$tmp/mismatch"
cmp "$tmp/tree/root.txt" "$tmp/mismatch"

# Sync skip path: make destination metadata match the source.
mkdir -p "$tmp/sync-dest/tree"
cp "$tmp/tree/root.txt" "$tmp/sync-dest/tree/root.txt"
touch -r "$tmp/tree/root.txt" "$tmp/sync-dest/tree/root.txt"
"$MYCP" -r --sync --benchmark "$tmp/tree" "$tmp/sync-dest"

# Operation-failed path.
expect_failure "$MYCP" "$tmp/tree/root.txt" "$tmp/missing-parent/dest"

echo 'coverage extra scenarios: ok'

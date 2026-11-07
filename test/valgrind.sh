#!/bin/sh
set -eu

MYCP=${MYCP:-build/mycp}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

run_checked() {
	valgrind --quiet --leak-check=full --show-leak-kinds=all \
		--track-origins=yes --error-exitcode=1 "$MYCP" "$@"
}

mkdir -p "$tmp/source/nested/deeper"
printf 'valgrind root\n' > "$tmp/source/root.txt"
printf 'valgrind nested\n' > "$tmp/source/nested/deeper/file.txt"
chmod 640 "$tmp/source/root.txt"

# Regular copy, verification, and permission preservation.
run_checked --buffer 512 --preserve --verify \
	"$tmp/source/root.txt" "$tmp/single.txt"
cmp "$tmp/source/root.txt" "$tmp/single.txt"
test "$(stat -c %a "$tmp/source/root.txt")" = "$(stat -c %a "$tmp/single.txt")"

# Recursive copy and verification.
run_checked -r --buffer 512 --preserve --verify \
	"$tmp/source" "$tmp/tree-copy"
diff -r "$tmp/source" "$tmp/tree-copy"

# Resume a valid partial file.
head -c 8 "$tmp/source/root.txt" > "$tmp/partial.txt"
run_checked --buffer 512 --resume --verify \
	"$tmp/source/root.txt" "$tmp/partial.txt"
cmp "$tmp/source/root.txt" "$tmp/partial.txt"

# Logging and verbose operation records.
run_checked --buffer 512 --verbose --log "$tmp/mycp.log" \
	"$tmp/source/root.txt" "$tmp/logged.txt"
test -s "$tmp/mycp.log"

echo 'valgrind: all scenarios passed with no memory errors'

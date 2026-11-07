#!/bin/sh
set -eu

MYCP=${MYCP:-./mycp}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/source/nested/deeper"
printf 'integration root\n' > "$tmp/source/root.txt"
printf 'integration nested\n' > "$tmp/source/nested/deeper/file.txt"
chmod 640 "$tmp/source/root.txt"

"$MYCP" --buffer 512 --preserve --verify \
	"$tmp/source/root.txt" "$tmp/single.txt"
cmp "$tmp/source/root.txt" "$tmp/single.txt"
test "$(stat -c %a "$tmp/source/root.txt")" = "$(stat -c %a "$tmp/single.txt")"

"$MYCP" -r --buffer 512 --preserve --verify \
	"$tmp/source" "$tmp/tree-copy"
diff -r "$tmp/source" "$tmp/tree-copy"

head -c 8 "$tmp/source/root.txt" > "$tmp/partial.txt"
"$MYCP" --buffer 512 --resume --verify \
	"$tmp/source/root.txt" "$tmp/partial.txt"
cmp "$tmp/source/root.txt" "$tmp/partial.txt"

echo 'integration: ok'

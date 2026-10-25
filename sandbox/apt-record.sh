#!/bin/sh
# Keeps the shared list of hand-installed apt packages in step with this sandbox. apt runs it after
# every dpkg invocation (99shared-installs.conf). A package this sandbox newly installs joins the
# list, and one it removes leaves it; launch.sh installs the list's names in every sandbox at start.
export LC_ALL=C
d=/data/cache/apt-shared
me=$(hostname)
mkdir -p "$d/state" 2>/dev/null || exit 0
exec 9>"$d/.lock"
flock 9 || exit 0
tmp=$(mktemp -d "$d/.record.XXXXXX") || exit 0

apt-mark showmanual | sort -u > "$tmp/now"
sort -u "$d/state/$me" 2>/dev/null > "$tmp/last"
comm -13 "$tmp/last" "$tmp/now" > "$tmp/added"
comm -23 "$tmp/last" "$tmp/now" > "$tmp/removed"
{ sort -u "$d/manual.list" 2>/dev/null; cat "$tmp/added"; } | sort -u \
    | comm -23 - "$tmp/removed" > "$tmp/list"

mv "$tmp/list" "$d/manual.list"
cp "$tmp/now" "$d/state/$me"
chown 1000:1000 "$d/state" "$d/state/$me" "$d/manual.list" "$d/.lock" 2>/dev/null
rm -rf "$tmp"
exit 0

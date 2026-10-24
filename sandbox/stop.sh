#!/usr/bin/env bash
# Stops one dev sandbox (dev1..dev4) and keeps everything it installed.
#  - Its home on btrfs is kept.
#  - Its container is committed to dev-desktop:<name> too, so the installs survive the container
#    being removed: launch.sh starts the next container from that image.
#  - --pristine skips the commit, so the next start is the bare base image again.
set -euo pipefail
NAME="${1:-}"
MODE="${2:-}"
case "$NAME" in
    dev1|dev2|dev3|dev4) ;;
    *) echo "usage: $0 dev1|dev2|dev3|dev4 [--pristine]" >&2; exit 2 ;;
esac
case "$MODE" in
    ""|--pristine) ;;
    *) echo "usage: $0 dev1|dev2|dev3|dev4 [--pristine]" >&2; exit 2 ;;
esac

DOCKER=(sudo -n docker)
if [ -z "$("${DOCKER[@]}" ps -aq -f "name=^${NAME}$")" ]; then
    echo "$NAME has no container."
    exit 0
fi

"${DOCKER[@]}" stop "$NAME" >/dev/null 2>&1 && echo "$NAME stopped." || echo "$NAME was not running."

if [ "$MODE" = "--pristine" ]; then
    echo "$NAME: --pristine, its installs are not committed."
    exit 0
fi

PREV=""
if "${DOCKER[@]}" image inspect "dev-desktop:${NAME}" >/dev/null 2>&1; then
    "${DOCKER[@]}" tag "dev-desktop:${NAME}" "dev-desktop:${NAME}-prev" >/dev/null 2>&1 && PREV=", previous kept as dev-desktop:${NAME}-prev"
fi
"${DOCKER[@]}" commit "$NAME" "dev-desktop:${NAME}" >/dev/null
echo "$NAME installs committed to dev-desktop:${NAME}${PREV}."

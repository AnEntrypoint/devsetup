#!/usr/bin/env bash
# Stops one dev sandbox (dev1..dev4). Its home on btrfs is kept.
set -euo pipefail
NAME="${1:-}"
case "$NAME" in
    dev1|dev2|dev3|dev4) ;;
    *) echo "usage: $0 dev1|dev2|dev3|dev4" >&2; exit 2 ;;
esac
sudo -n docker stop "$NAME" >/dev/null 2>&1 && echo "$NAME stopped." || echo "$NAME was not running."

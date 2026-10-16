#!/usr/bin/env bash
# Starts one dev sandbox (dev1..dev4) and opens it in the host browser.
#  - Image: dev-desktop (webtop XFCE + apt build tools, gh, gcloud)
#  - Tools: host toolchains mounted read-only (Go, Node, Rust, uv, caches)
#  - Config: a per-sandbox home on btrfs, cloned from /data/sandboxes/shared-home on first start
#  - Isolation: no host home, browser profiles, credentials, X/D-Bus sockets or Docker socket mounted
set -euo pipefail

NAME="${1:-}"
mkdir -p /data/sandboxes/logs && exec >>"/data/sandboxes/logs/${NAME:-launch}.log" 2>&1
echo "--- $(date) launch ${NAME}"
case "$NAME" in
    dev1|dev2|dev3|dev4) ;;
    *) echo "usage: $0 dev1|dev2|dev3|dev4" >&2; exit 2 ;;
esac

IMAGE=dev-desktop:latest
N="${NAME#dev}"
PORT=$((3000 + N))            # 3001..3004, bound to 127.0.0.1 only
BASE=/data/sandboxes
TEMPLATE=$BASE/shared-home
HOME_DIR=$BASE/$NAME/home
DOCKER=(sudo -n docker)

if [ -n "$("${DOCKER[@]}" ps -q -f "name=^${NAME}$")" ]; then
    echo "Already running: http://127.0.0.1:${PORT}"
    xdg-open "http://127.0.0.1:${PORT}" >/dev/null 2>&1 || true
    exit 0
fi

# Fresh home on every start: drop the previous session's home, clone the template again
# (btrfs snapshot: instant, copy-on-write). Only the shared workspace persists.
"${DOCKER[@]}" rm -f "$NAME" >/dev/null 2>&1 || true
if [ -d "$HOME_DIR" ]; then
    sudo -n btrfs subvolume delete "$HOME_DIR" >/dev/null
fi
sudo -n mkdir -p "$BASE/$NAME"
sudo -n btrfs subvolume snapshot "$TEMPLATE" "$HOME_DIR" >/dev/null
sudo -n chown 1000:1000 "$HOME_DIR"
echo "$NAME home reset from shared template."


# Seed the sandbox's gh login from the template when its own folder has none yet
if [ ! -f "$BASE/$NAME/creds/gh/hosts.yml" ] && [ -f "$TEMPLATE/.config/gh/hosts.yml" ]; then
    sudo -n mkdir -p "$BASE/$NAME/creds/gh"
    sudo -n cp -a "$TEMPLATE/.config/gh/." "$BASE/$NAME/creds/gh/"
    sudo -n chown -R 1000:1000 "$BASE/$NAME/creds/gh"
fi

# Web desktop password = sandbox name
PASS="$NAME"   # fixed per sandbox; reachable only on 127.0.0.1

"${DOCKER[@]}" run -d --name "$NAME" \
  --hostname "$NAME" \
  -e PUID=1000 -e PGID=1000 -e TZ="$(cat /etc/timezone 2>/dev/null || echo UTC)" \
  -e CUSTOM_USER=dev -e PASSWORD="$PASS" \
  -e PATH="/lsiopy/bin:/data/cache/google-cloud-sdk/bin:/data/cache/npm-global/bin:/usr/local/go/bin:/data/cache/bin:/data/cache/cargo/bin:/data/cache/node/current/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  -e RUSTUP_HOME=/data/cache/rustup \
  -e CARGO_HOME=/data/cache/cargo \
  -e GOPATH=/data/projects/go \
  -e GOCACHE=/data/cache/go-build \
  -e GOMODCACHE=/data/cache/go-mod \
  -e UV_CACHE_DIR=/data/cache/uv \
  -e UV_PYTHON_INSTALL_DIR=/data/cache/uv/python \
  -e NPM_CONFIG_CACHE=/data/cache/npm \
  -p "127.0.0.1:${PORT}:3000" \
  --cap-drop ALL \
  --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
  --cap-add SETUID --cap-add SETGID --cap-add KILL \
  --security-opt no-new-privileges:true \
  --pids-limit 4096 --memory 12g --cpus 12 --shm-size 1g \
  -v "$HOME_DIR:/config" \
  -v "$BASE/$NAME/creds/gh:/config/.config/gh" \
  -v "$BASE/$NAME/creds/gcloud:/config/.config/gcloud" \
  -v /data/projects:/data/projects \
  -v /data/workspace:/workspace \
  -v /data/cache/gm:/data/cache/gm \
  -v /data/cache/claude-auth:/config/.claude-auth \
  -v /data/cache/claude-state:/config/.claude-state \
  -v /data/cache/npm-global:/data/cache/npm-global \
  -v /data/cache/google-cloud-sdk:/data/cache/google-cloud-sdk:ro \
  -v /usr/local/go:/usr/local/go:ro \
  -v /data/cache/bin:/data/cache/bin:ro \
  -v /data/cache/node:/data/cache/node:ro \
  -v /data/cache/rustup:/data/cache/rustup:ro \
  -v /data/cache/cargo:/data/cache/cargo:ro \
  -v /data/cache/cargo/registry:/data/cache/cargo/registry \
  -v /data/cache/uv:/data/cache/uv \
  -v /data/cache/npm:/data/cache/npm \
  -v /data/cache/go-build:/data/cache/go-build \
  -v /data/cache/go-mod:/data/cache/go-mod \
  "$IMAGE" >/dev/null

echo "$NAME starting at http://127.0.0.1:${PORT}"
echo "Login: dev"
echo "Password: ${PASS}"
echo "(stop with: sudo docker stop ${NAME})"
for _ in $(seq 1 60); do
    code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}" || true)
    [ "$code" != "000" ] && [ -n "$code" ] && break
    sleep 2
done
echo "web desktop answered: ${code:-none}"
xdg-open "http://127.0.0.1:${PORT}" >/dev/null 2>&1 || true

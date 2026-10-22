#!/usr/bin/env bash
# Starts one dev sandbox (dev1..dev4) and opens it in the host browser.
#  - Image: dev-desktop (webtop XFCE + apt build tools, gh, gcloud)
#  - Tools: host toolchains mounted read-only (Go, Node, Rust, uv, caches)
#  - Config: a per-sandbox home on btrfs, cloned from /data/sandboxes/shared-home on first start
#  - Persistence: the home and the container survive restarts. Installs made in a sandbox stay.
#    Pass --recreate to rebuild from the template and a fresh container (drops both).
#  - Isolation: no host home, browser profiles, credentials, X/D-Bus sockets or Docker socket mounted
set -euo pipefail

NAME="${1:-}"
RECREATE="${2:-}"
mkdir -p /data/sandboxes/logs && exec >>"/data/sandboxes/logs/${NAME:-launch}.log" 2>&1
echo "--- $(date) launch ${NAME} ${RECREATE}"
case "$NAME" in
    dev1|dev2|dev3|dev4) ;;
    *) echo "usage: $0 dev1|dev2|dev3|dev4 [--recreate]" >&2; exit 2 ;;
esac

IMAGE="${SANDBOX_IMAGE:-dev-desktop:latest}"
N="${NAME#dev}"
PORT=$((3000 + N))            # 3001..3004, bound to 127.0.0.1 only
BASE=/data/sandboxes
TEMPLATE=$BASE/shared-home
HOME_DIR=$BASE/$NAME/home
DOCKER=(sudo -n docker)

open_desktop() {
    local code
    for _ in $(seq 1 60); do
        code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${PORT}" || true)
        [ "$code" != "000" ] && [ -n "$code" ] && break
        sleep 2
    done
    echo "web desktop answered: ${code:-none}"
    xdg-open "http://127.0.0.1:${PORT}" >/dev/null 2>&1 || true
}

if [ -n "$("${DOCKER[@]}" ps -q -f "name=^${NAME}$")" ] && [ "$RECREATE" != "--recreate" ]; then
    echo "Already running: http://127.0.0.1:${PORT}"
    xdg-open "http://127.0.0.1:${PORT}" >/dev/null 2>&1 || true
    exit 0
fi

# Existing container (stopped): start it again. Its writable layer keeps apt installs.
if [ -n "$("${DOCKER[@]}" ps -aq -f "name=^${NAME}$")" ] && [ "$RECREATE" != "--recreate" ]; then
    echo "$NAME resuming existing container (home, installed packages and mounts kept)."
    "${DOCKER[@]}" start "$NAME" >/dev/null
    echo "$NAME starting at http://127.0.0.1:${PORT}"
    open_desktop
    exit 0
fi

# First start, or --recreate: build the home from the template and a new container.
if [ "$RECREATE" = "--recreate" ] || [ ! -d "$HOME_DIR" ]; then
    "${DOCKER[@]}" rm -f "$NAME" >/dev/null 2>&1 || true
    if [ -d "$HOME_DIR" ]; then
        sudo -n btrfs subvolume delete "$HOME_DIR" >/dev/null
    fi
    sudo -n mkdir -p "$BASE/$NAME"
    sudo -n btrfs subvolume snapshot "$TEMPLATE" "$HOME_DIR" >/dev/null
    sudo -n chown 1000:1000 "$HOME_DIR"
    echo "$NAME home created from shared template."

    # Claude login and chat history live in persistent mounts, not in the home.
    STATE=/data/cache/claude-state
    AUTH=/data/cache/claude-auth
    sudo -n mkdir -p "$STATE" "$AUTH"
    sudo -n chown 1000:1000 "$STATE" "$AUTH"
    if [ -f "$HOME_DIR/.claude.json" ] && [ ! -f "$STATE/claude.json" ]; then
        sudo -n cp -a "$HOME_DIR/.claude.json" "$STATE/claude.json"
    fi
    sudo -n rm -f "$HOME_DIR/.claude.json"
    sudo -n ln -s /config/.claude-state/claude.json "$HOME_DIR/.claude.json"
    sudo -n mkdir -p "$HOME_DIR/.claude"

    # Plain colour desktop per sandbox, written into its fresh home before start
    case "$NAME" in
        dev1) BG="#1f3d6e" ;;   # blue
        dev2) BG="#2e6b3a" ;;   # green
        dev3) BG="#7a2e2e" ;;   # red
        dev4) BG="#5b3a7a" ;;   # purple
    esac
    XFCONF="$HOME_DIR/.config/xfce4/xfconf/xfce-perchannel-xml"
    sudo -n mkdir -p "$XFCONF"
    sudo -n python3 /data/projects/dev-sandbox/bgcolor.py "$BG" "$XFCONF/xfce4-desktop.xml"
# Window manager: compositing off (the GPU compositor hides the top panel)
sudo -n install -m 0644 "$(dirname "$(readlink -f "$0")")/xfce/xfwm4.xml" "$XFCONF/xfwm4.xml"
    sudo -n chown -R 1000:1000 "$HOME_DIR/.config"
    echo "$NAME desktop colour $BG"

    # Seed the sandbox's gh login from the template when its own folder has none yet
    if [ ! -f "$BASE/$NAME/creds/gh/hosts.yml" ] && [ -f "$TEMPLATE/.config/gh/hosts.yml" ]; then
        sudo -n mkdir -p "$BASE/$NAME/creds/gh"
        sudo -n cp -a "$TEMPLATE/.config/gh/." "$BASE/$NAME/creds/gh/"
        sudo -n chown -R 1000:1000 "$BASE/$NAME/creds/gh"
    fi
else
    echo "$NAME home kept (persistent)."
fi

# Web desktop password = sandbox name
PASS="$NAME"   # fixed per sandbox; reachable only on 127.0.0.1

# Playwright browsers are shared; apply the GPU shim to any already downloaded (idempotent)
/data/cache/bin/playwright-gpu-shim /data/cache/ms-playwright >/dev/null 2>&1 || true

"${DOCKER[@]}" rm -f "$NAME" >/dev/null 2>&1 || true
"${DOCKER[@]}" run -d --name "$NAME" \
  --hostname "$NAME" \
  -e PUID=1000 -e PGID=1000 -e TZ="$(cat /etc/timezone 2>/dev/null || echo UTC)" \
  -e CUSTOM_USER=dev -e PASSWORD="$PASS" \
  -e PATH="/data/cache/platform-tools:/data/cache/venvs/ml/bin:/lsiopy/bin:/data/cache/bin:/data/cache/google-cloud-sdk/bin:/data/cache/npm-global/bin:/usr/local/go/bin:/data/cache/bin:/data/cache/cargo/bin:/data/cache/node/current/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  -e RUSTUP_HOME=/data/cache/rustup \
  -e CARGO_HOME=/data/cache/cargo \
  -e GOPATH=/data/projects/go \
  -e GOCACHE=/data/cache/go-build \
  -e GOMODCACHE=/data/cache/go-mod \
  -e UV_CACHE_DIR=/data/cache/uv \
  -e UV_PYTHON_INSTALL_DIR=/data/cache/uv/python \
  -e NPM_CONFIG_CACHE=/data/cache/npm \
  -e NPM_CONFIG_PREFIX=/data/cache/npm-global \
  -e NPM_CONFIG_GLOBALCONFIG=/data/cache/npm-global/etc/npmrc \
  -e PLAYWRIGHT_BROWSERS_PATH=/data/cache/ms-playwright \
  -e VIRTUAL_ENV=/data/cache/venvs/ml \
  -e PYTHONUSERBASE=/data/cache/pyuser \
  -e DISABLE_AUTOUPDATER=1 \
  -p "127.0.0.1:${PORT}:3000" \
  --cap-drop ALL \
  --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
  --cap-add SETUID --cap-add SETGID --cap-add KILL \
  --security-opt no-new-privileges:true \
  --pids-limit 4096 --memory 12g --cpus 12 --shm-size 1g \
  --gpus all -e NVIDIA_DRIVER_CAPABILITIES=compute,utility,video,graphics \
  --group-add "$(getent group plugdev | cut -d: -f3)" \
  --device-cgroup-rule "c 189:* rwm" \
  -v /dev/bus/usb:/dev/bus/usb \
  -v /data/cache/platform-tools:/data/cache/platform-tools:ro \
  -v /data/cache/android-keys:/config/.android \
  -v "$HOME_DIR:/config" \
  -v "$BASE/$NAME/creds/gh:/config/.config/gh" \
  -v "$BASE/$NAME/creds/gcloud:/config/.config/gcloud" \
  -v "$BASE/$NAME/creds/kaggle:/config/.kaggle" \
  -v /data/projects:/data/projects \
  -v /data/workspace:/workspace \
  -v /data/cache/gm:/data/cache/gm \
  -v /data/cache/claude-auth:/config/.claude-auth \
  -v "$HOME/.claude:/config/.claude" \
  -v /data/cache/claude-state:/config/.claude-state \
  -v /data/cache/npm-global:/data/cache/npm-global \
  -v /data/cache/google-cloud-sdk:/data/cache/google-cloud-sdk \
  -v /usr/local/go:/usr/local/go \
  -v /data/cache/bin:/data/cache/bin \
  -v /data/cache/node:/data/cache/node \
  -v /data/cache/rustup:/data/cache/rustup \
  -v /data/cache/cargo:/data/cache/cargo \
  -v /data/cache/uv:/data/cache/uv \
  -v /data/cache/npm:/data/cache/npm \
  -v /data/cache/go-build:/data/cache/go-build \
  -v /data/cache/go-mod:/data/cache/go-mod \
  -v /data/cache/huggingface:/data/cache/huggingface \
  -v /data/cache/ms-playwright:/data/cache/ms-playwright \
  -v /data/cache/venvs:/data/cache/venvs \
  -v /data/cache/pyuser:/data/cache/pyuser \
  "$IMAGE" >/dev/null

echo "$NAME starting at http://127.0.0.1:${PORT}"
echo "Login: dev"
echo "Password: ${PASS}"
echo "(stop with: sudo docker stop ${NAME})"
open_desktop

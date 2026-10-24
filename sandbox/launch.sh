#!/usr/bin/env bash
# Starts one dev sandbox (dev1..dev4) and opens it in the host browser.
#  - Image: dev-desktop (webtop XFCE + apt build tools, gh, gcloud)
#  - Tools: host toolchains mounted from /data/cache (Go, Node, Rust, uv, caches)
#  - Config: a per-sandbox home on btrfs, cloned from /data/sandboxes/shared-home on first start
#  - Retention: the home, the container and everything installed in it survive restarts. Before a
#    container is removed, its installs are committed to dev-desktop:<name>, and the next container
#    starts from that image, so apt packages and anything under /usr/local or /opt come back.
#  - Sharing: every sandbox mounts /data/cache/usrlocal first on PATH, plus the same build caches,
#    so a tool installed there is in all four sandboxes at once and outlives all of their containers.
#  - --recreate: a fresh container and a fresh home from the template; the installs are kept
#  - --pristine: as --recreate, and the kept installs are dropped too (back to dev-desktop:latest)
#  - Isolation: no host home, browser profiles, credentials, X/D-Bus sockets or Docker socket mounted
set -euo pipefail

NAME="${1:-}"
MODE="${2:-}"
mkdir -p /data/sandboxes/logs && exec >>"/data/sandboxes/logs/${NAME:-launch}.log" 2>&1
echo "--- $(date) launch ${NAME} ${MODE}"
case "$NAME" in
    dev1|dev2|dev3|dev4) ;;
    *) echo "usage: $0 dev1|dev2|dev3|dev4 [--recreate|--pristine]" >&2; exit 2 ;;
esac
case "$MODE" in
    ""|--recreate|--pristine) ;;
    *) echo "usage: $0 dev1|dev2|dev3|dev4 [--recreate|--pristine]" >&2; exit 2 ;;
esac

BASE_IMAGE="${SANDBOX_IMAGE:-dev-desktop:latest}"
KEEP_IMAGE="dev-desktop:${NAME}"      # this sandbox's installs, committed out of its container
SHARED=/data/cache/usrlocal           # installs every sandbox shares; first on PATH
N="${NAME#dev}"
PORT=$((3000 + N))            # 3001..3004, bound to 127.0.0.1 only
BASE=/data/sandboxes
TEMPLATE=$BASE/shared-home
HOME_DIR=$BASE/$NAME/home
DOCKER=(sudo -n docker)

RESET=""
case "$MODE" in --recreate|--pristine) RESET=1 ;; esac

# Build caches and the shared install prefix live on the host, so they outlive every container and
# are read by all four sandboxes. Inductor, Triton and the Hugging Face hub keep their locks.
mkdir -p "$SHARED/bin" /data/cache/torchinductor /data/cache/triton /data/cache/torch

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

container_exists() { [ -n "$("${DOCKER[@]}" ps -aq -f "name=^${NAME}$")" ]; }

# The image a new container starts from: this sandbox's own kept installs when they exist,
# the bare base image when they do not (first start, or --pristine).
start_image() {
    if [ "$MODE" != "--pristine" ] && "${DOCKER[@]}" image inspect "$KEEP_IMAGE" >/dev/null 2>&1; then
        echo "$KEEP_IMAGE"
    else
        echo "$BASE_IMAGE"
    fi
}

# Commit what the container has installed, so removing it does not throw the installs away.
# The previous kept image stays as dev-desktop:<name>-prev, one step of rollback.
commit_installs() {
    "${DOCKER[@]}" image inspect "$KEEP_IMAGE" >/dev/null 2>&1 \
        && "${DOCKER[@]}" tag "$KEEP_IMAGE" "${KEEP_IMAGE}-prev" >/dev/null 2>&1 || true
    "${DOCKER[@]}" commit "$NAME" "$KEEP_IMAGE" >/dev/null
    echo "$NAME: installs committed to $KEEP_IMAGE ($1)"
}

# What the container holds that its image does not. The bulk is scratch under /tmp.
report_layer() {
    echo "$NAME: container layer below is what a removal would have dropped"
    "${DOCKER[@]}" diff "$NAME" 2>/dev/null | awk '{print $2}' | cut -d/ -f1-3 \
        | sort | uniq -c | sort -rn | head -6
}

# Every entry of the shared prefix becomes a symlink in /usr/local, so tools installed there are
# found by their normal paths (a CUDA toolkit at /data/cache/usrlocal/cuda is /usr/local/cuda).
# A directory with content (bin, lib, share, ... the image's own) is never shadowed, a real file
# is never shadowed, and an empty leftover directory (a former mount point in a kept image) is
# taken over, so /usr/local/go becomes the link on the containers that had it mounted.
link_shared_usrlocal() {
    local _ try
    for try in 1 2 3; do
        if "${DOCKER[@]}" exec "$NAME" sh -c '
            for e in /data/cache/usrlocal/*; do
                [ -e "$e" ] || continue
                n=${e##*/}
                t=/usr/local/$n
                if [ -L "$t" ]; then
                    ln -sfn "$e" "$t"
                elif [ -d "$t" ]; then
                    [ -n "$(ls -A "$t" 2>/dev/null)" ] && continue
                    rmdir "$t" 2>/dev/null || continue
                    ln -sfn "$e" "$t"
                elif [ -e "$t" ]; then
                    continue
                else
                    ln -sfn "$e" "$t"
                fi
            done' >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    echo "$NAME: shared-prefix link step did not run"
}

if [ -z "$RESET" ] && [ -n "$("${DOCKER[@]}" ps -q -f "name=^${NAME}$")" ]; then
    echo "Already running: http://127.0.0.1:${PORT}"
    link_shared_usrlocal
    xdg-open "http://127.0.0.1:${PORT}" >/dev/null 2>&1 || true
    exit 0
fi

# Existing container (stopped): start it again. Its writable layer keeps apt installs.
if [ -z "$RESET" ] && container_exists; then
    echo "$NAME resuming existing container (home, installed packages and mounts kept)."
    if ! "${DOCKER[@]}" image inspect "$KEEP_IMAGE" >/dev/null 2>&1; then
        echo "$NAME note: no $KEEP_IMAGE yet; run ./stop.sh $NAME to keep this layer past a removal"
    fi
    "${DOCKER[@]}" start "$NAME" >/dev/null
    link_shared_usrlocal
    echo "$NAME starting at http://127.0.0.1:${PORT}"
    open_desktop
    exit 0
fi

# From here the container is replaced: --recreate/--pristine, or it is gone and the home is not.
if container_exists; then
    report_layer
    if [ "$MODE" = "--pristine" ]; then
        if "${DOCKER[@]}" image inspect "$KEEP_IMAGE" >/dev/null 2>&1; then
            "${DOCKER[@]}" tag "$KEEP_IMAGE" "${KEEP_IMAGE}-prev" >/dev/null 2>&1 || true
            "${DOCKER[@]}" image rm "$KEEP_IMAGE" >/dev/null 2>&1 || true
            echo "$NAME: --pristine, kept installs dropped (still recoverable at ${KEEP_IMAGE}-prev)"
        else
            echo "$NAME: --pristine, no kept installs to drop"
        fi
    else
        commit_installs "before the container is replaced"
    fi
    "${DOCKER[@]}" rm -f "$NAME" >/dev/null
elif [ -d "$HOME_DIR" ]; then
    if "${DOCKER[@]}" image inspect "$KEEP_IMAGE" >/dev/null 2>&1; then
        echo "$NAME: container was gone, installs resumed from $KEEP_IMAGE"
    else
        echo "$NAME: container was gone and $KEEP_IMAGE does not exist: starting from $BASE_IMAGE"
        echo "$NAME: anything installed in that container is lost; stop.sh keeps it next time"
    fi
fi

# Fresh home from the template (first start, or a reset). Installs are not part of the home.
if [ -n "$RESET" ] || [ ! -d "$HOME_DIR" ]; then
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
    sudo -n python3 "$(dirname "$(readlink -f "$0")")/bgcolor.py" "$BG" "$XFCONF/xfce4-desktop.xml"
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

# A published UDP range belongs to the sandbox that runs a peer (the Hyperswarm relay), not to all
# of them: two sandboxes cannot publish the same host ports. Put the range the NAS dials in
# /data/sandboxes/devN/swarm-udp (for example 25000-25004); a sandbox without that file publishes none.
UDP_ARGS=()
if [ -s "$BASE/$NAME/swarm-udp" ]; then
    UDP_RANGE=$(tr -d ' \n' <"$BASE/$NAME/swarm-udp")
    UDP_ARGS=(-p "${UDP_RANGE}:${UDP_RANGE}/udp")
    echo "$NAME publishing UDP ${UDP_RANGE} for its peer"
fi

# Playwright browsers are shared; apply the GPU shim to any already downloaded (idempotent)
/data/cache/bin/playwright-gpu-shim /data/cache/ms-playwright >/dev/null 2>&1 || true

IMAGE_TO_START=$(start_image)

# A CUDA toolkit installed in the shared prefix is /usr/local/cuda (linked after start), so builds
# that insist on a toolkit find it. Absent toolkit: the variables are not set at all.
CUDA_ENV=()
[ -d "$SHARED/cuda" ] && CUDA_ENV=(-e CUDA_HOME=/usr/local/cuda -e CUDA_PATH=/usr/local/cuda)

"${DOCKER[@]}" rm -f "$NAME" >/dev/null 2>&1 || true
# Go is mounted inside the shared prefix ($SHARED/go): the link step is what puts it at /usr/local/go,
# the same way the host links it, and the same way a toolkit installed into the prefix is found.
"${DOCKER[@]}" run -d --name "$NAME" \
  --hostname "$NAME" \
  -e PUID=1000 -e PGID=1000 -e TZ="$(cat /etc/timezone 2>/dev/null || echo UTC)" \
  -e CUSTOM_USER=dev -e PASSWORD="$PASS" \
  -e PATH="/data/cache/usrlocal/bin:/data/cache/usrlocal/usr/bin:/usr/local/cuda/bin:/data/cache/platform-tools:/data/cache/venvs/ml/bin:/lsiopy/bin:/data/cache/bin:/data/cache/google-cloud-sdk/bin:/data/cache/npm-global/bin:/usr/local/go/bin:/data/cache/bin:/data/cache/cargo/bin:/data/cache/node/current/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  "${CUDA_ENV[@]}" \
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
  -e TORCHINDUCTOR_CACHE_DIR=/data/cache/torchinductor \
  -e TRITON_CACHE_DIR=/data/cache/triton \
  -e TORCH_HOME=/data/cache/torch \
  -e HF_HOME=/data/cache/huggingface \
  -e DISABLE_AUTOUPDATER=1 \
  -p "127.0.0.1:${PORT}:3000" \
  "${UDP_ARGS[@]}" \
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
  -v /data/cache/bin:/data/cache/bin \
  -v "$SHARED:$SHARED" \
  -v /data/cache/go:"$SHARED/go" \
  -v /data/cache/node:/data/cache/node \
  -v /data/cache/rustup:/data/cache/rustup \
  -v /data/cache/cargo:/data/cache/cargo \
  -v /data/cache/uv:/data/cache/uv \
  -v /data/cache/npm:/data/cache/npm \
  -v /data/cache/go-build:/data/cache/go-build \
  -v /data/cache/go-mod:/data/cache/go-mod \
  -v /data/cache/huggingface:/data/cache/huggingface \
  -v /data/cache/torchinductor:/data/cache/torchinductor \
  -v /data/cache/triton:/data/cache/triton \
  -v /data/cache/torch:/data/cache/torch \
  -v /data/cache/ms-playwright:/data/cache/ms-playwright \
  -v /data/cache/venvs:/data/cache/venvs \
  -v /data/cache/pyuser:/data/cache/pyuser \
  "$IMAGE_TO_START" >/dev/null

link_shared_usrlocal

echo "$NAME starting at http://127.0.0.1:${PORT}"
echo "$NAME started from image $IMAGE_TO_START"
echo "Login: dev"
echo "Password: ${PASS}"
echo "(stop with: sudo docker stop ${NAME}, or ./stop.sh ${NAME} to keep its installs)"
open_desktop

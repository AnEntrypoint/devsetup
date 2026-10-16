#!/usr/bin/env bash
# devsetup: menu-driven setup for an Ubuntu dev machine.
#
#   - btrfs data drive with subvolumes, shared toolchains on /data/cache, flatpak and Docker on /data
#   - sandboxes (webtop XFCE) that share tools and, where you choose, logins and history
#
# Usage:
#   ./setup/devsetup.sh                     interactive menus (whiptail when available)
#   ./setup/devsetup.sh --dry-run           print every action, change nothing
#   ./setup/devsetup.sh --answers FILE      run from a saved answers file, without prompts
#   ./setup/devsetup.sh --install-launcher  add a desktop icon for the menus
#   ./setup/devsetup.sh --help
#
# Answers are saved to ~/.config/devsetup/answers.env, so a run can be repeated.
# Passwords and tokens are never asked for or stored. Each action is idempotent where possible.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_DIR="$HOME/.config/devsetup"
ANSWERS="$STATE_DIR/answers.env"
LOG_DIR="$HOME/.local/state/devsetup"
LOG="$LOG_DIR/run-$(date +%Y%m%d-%H%M%S).log"
DRY=0
ANSWERS_IN=""
UI=none
if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v zenity >/dev/null 2>&1; then UI=zenity
elif [ -t 0 ] && command -v whiptail >/dev/null 2>&1; then UI=whiptail; fi
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

MODULES_ALL="storage boot sudo env apt rust go node uv npm git docker flatpak dedup gcloud kaggle sandboxes gm skills"
MODULE_LABELS=(
  "storage|Data drive: btrfs subvolumes, mounts, /tmp on btrfs|on"
  "boot|Boot: root mounts read-write (GRUB rw)|on"
  "sudo|Passwordless sudo for this user (single-user workstation)|off"
  "env|System-wide tool paths and apt cache on /data|on"
  "apt|Build tools and common packages (apt)|on"
  "rust|Rust stable (rustup) on /data|on"
  "go|Go, latest stable on /data|on"
  "node|Node, latest LTS on /data|on"
  "uv|uv (Python tooling) on /data|on"
  "npm|npm prefix and cache on /data|on"
  "git|Git identity (GitHub no-reply address)|on"
  "docker|Docker with data root on /data|on"
  "flatpak|Flatpak desktop apps on /data|on"
  "dedup|Weekly non-destructive btrfs dedup|on"
  "gcloud|Google Cloud SDK, shared copy on /data|off"
  "kaggle|Kaggle CLI, shared|off"
  "sandboxes|Sandboxes: template, image, launcher, desktop icons|on"
  "gm|gm, shared bundle (touches host Zed config)|off"
  "skills|grill-me skill in the sandbox template|off"
)

# ---------- helpers ----------

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

log() { printf '%s\n' "$*" | tee -a "$LOG" >&2; }
die() { log "ERROR: $*"; exit 1; }

# Run a command, or print it in dry-run mode.
run() {
    if [ "$DRY" = 1 ]; then printf '  + %s\n' "$*" | tee -a "$LOG" >&2; return 0; fi
    printf '  $ %s\n' "$*" >>"$LOG"
    "$@" 2>&1 | tee -a "$LOG" >&2
    return "${PIPESTATUS[0]}"
}

# Write stdin to a file. Use "sudo" as the second argument for root-owned files.
put() {
    local path="$1" who="${2:-}"
    if [ "$DRY" = 1 ]; then
        printf '  + write %s\n' "$path" | tee -a "$LOG" >&2
        cat >/dev/null
        return 0
    fi
    if [ "$who" = sudo ] && [ -n "$SUDO" ]; then
        $SUDO tee "$path" >/dev/null
    else
        tee "$path" >/dev/null
    fi
    printf '  wrote %s\n' "$path" >>"$LOG"
}

# Replace or append a block delimited by markers in a file. Content comes on stdin.
managed_block() {
    local file="$1" id="$2" who="${3:-}" tmp new
    tmp="$(mktemp)"; new="$(mktemp)"
    cat >"$new"
    if [ -f "$file" ]; then cp "$file" "$tmp"; else : >"$tmp"; fi
    python3 - "$tmp" "$new" "$id" <<'PY'
import sys
path, new_path, bid = sys.argv[1], sys.argv[2], sys.argv[3]
start, end = f"# >>> devsetup:{bid}", f"# <<< devsetup:{bid}"
text = open(path).read()
block = start + "\n" + open(new_path).read().rstrip("\n") + "\n" + end + "\n"
if start in text and end in text:
    pre, rest = text.split(start, 1)
    post = rest.split(end, 1)[1].lstrip("\n")
    text = pre + block + post
else:
    text = text.rstrip("\n") + ("\n\n" if text.strip() else "") + block
open(path, "w").write(text)
PY
    if [ "$DRY" = 1 ]; then
        printf '  + managed block %s in %s\n' "$id" "$file" | tee -a "$LOG" >&2
    else
        if [ "$who" = sudo ] && [ -n "$SUDO" ]; then $SUDO cp "$tmp" "$file"; else cp "$tmp" "$file"; fi
        printf '  updated block %s in %s\n' "$id" "$file" >>"$LOG"
    fi
    rm -f "$tmp" "$new"
}

# ---------- answers ----------

load_answers() {
    local src="$1"
    [ -f "$src" ] || die "answers file not found: $src"
    set -a; # shellcheck disable=SC1090
    . "$src"
    set +a
}

get() { eval "printf '%s' \"\${$1:-}\""; }

set_answer() {
    local key="$1" value="$2"
    mkdir -p "$STATE_DIR"
    touch "$ANSWERS"
    if grep -q "^${key}=" "$ANSWERS"; then
        grep -v "^${key}=" "$ANSWERS" >"$ANSWERS.tmp" || true
        mv "$ANSWERS.tmp" "$ANSWERS"
    fi
    printf '%s=%q\n' "$key" "$value" >>"$ANSWERS"
    printf -v "$key" '%s' "$value"
    export "$key"
}

# Dialog backends. Each returns the answer on stdout (or 0/1 for yes/no).
ui_yesno() { # text default(on|off)
    case "$UI" in
        zenity) zenity --question --title="devsetup" --text="$1" --width=460 ;;
        whiptail) local f=""; [ "$2" = on ] || f="--defaultno"
                  whiptail --title "devsetup" $f --yesno "$1" 14 76 ;;
    esac
}
ui_input() { # text default
    case "$UI" in
        zenity) zenity --entry --title="devsetup" --text="$1" --entry-text="$2" --width=460 ;;
        whiptail) whiptail --title "devsetup" --inputbox "$1" 12 76 "$2" 3>&1 1>&2 2>&3 ;;
    esac
}
ui_radio() { # text default-tag "tag|label" ...
    local text="$1" def="$2"; shift 2
    case "$UI" in
        zenity)
            local args=() item
            for item in "$@"; do
                local tag="${item%%|*}" label="${item#*|}"
                if [ "$tag" = "$def" ]; then args+=(TRUE "$tag" "$label"); else args+=(FALSE "$tag" "$label"); fi
            done
            zenity --list --radiolist --title="devsetup" --text="$text" --width=520 --height=420 \
                --column=Pick --column=Key --column=Item --hide-column=2 --print-column=2 "${args[@]}" ;;
        whiptail)
            local items=() item
            for item in "$@"; do items+=("${item%%|*}" "${item#*|}"); done
            whiptail --title "devsetup" --menu "$text" 20 78 10 "${items[@]}" 3>&1 1>&2 2>&3 ;;
    esac
}
ui_checklist() { # text "tag|label|on|off" ...  -> prints selected tags, space-separated
    local text="$1"; shift
    case "$UI" in
        zenity)
            local args=() item tag label st
            for item in "$@"; do
                IFS='|' read -r tag label st <<<"$item"
                if [ "$st" = on ]; then args+=(TRUE "$tag" "$label"); else args+=(FALSE "$tag" "$label"); fi
            done
            zenity --list --checklist --title="devsetup" --text="$text" --width=640 --height=560 \
                --column=Pick --column=Key --column=Item --hide-column=2 --print-column=2 \
                --separator=' ' "${args[@]}" ;;
        whiptail)
            local items=() item
            for item in "$@"; do
                IFS='|' read -r tag label st <<<"$item"
                items+=("$tag" "$label" "$st")
            done
            whiptail --title "devsetup" --checklist "$text" 24 84 16 "${items[@]}" 3>&1 1>&2 2>&3 | tr -d '"' ;;
    esac
}

# Ask yes/no. Answers file first, then the dialog, then the default.
ask_yes() { # KEY "text" default(on|off)
    local key="$1" text="$2" def="$3" v
    if [ -n "$(get "$key")" ]; then [ "$(get "$key")" = yes ]; return; fi
    if [ -n "$ANSWERS_IN" ] || [ "$UI" = none ]; then
        v="$([ "$def" = on ] && echo yes || echo no)"
    else
        if ui_yesno "$text" "$def"; then v=yes; else v=no; fi
    fi
    set_answer "$key" "$v"
    [ "$v" = yes ]
}

ask_input() { # KEY "text" default
    local key="$1" text="$2" def="$3" v
    if [ -n "$(get "$key")" ]; then printf '%s' "$(get "$key")"; return; fi
    if [ -n "$ANSWERS_IN" ] || [ "$UI" = none ]; then
        v="$def"
    else
        v="$(ui_input "$text" "$def")" || die "cancelled"
    fi
    set_answer "$key" "$v"
    printf '%s' "$v"
}

ask_menu() { # KEY "text" default "tag|label" ...
    local key="$1" text="$2" def="$3"; shift 3
    local v
    if [ -n "$(get "$key")" ]; then printf '%s' "$(get "$key")"; return; fi
    if [ -n "$ANSWERS_IN" ] || [ "$UI" = none ]; then
        v="$def"
    else
        [ "$#" -gt 0 ] || die "nothing to choose from for: $text"
        v="$(ui_radio "$text" "$def" "$@")" || die "cancelled"
    fi
    set_answer "$key" "$v"
    printf '%s' "$v"
}

# ---------- main menu ----------

select_modules() {
    local v entry tag label def items=()
    if [ -n "$(get MODULES)" ]; then return; fi
    if [ -n "$ANSWERS_IN" ] || [ "$UI" = none ]; then
        v=""
        for entry in "${MODULE_LABELS[@]}"; do
            IFS='|' read -r tag label def <<<"$entry"
            [ "$def" = on ] && v="$v $tag"
        done
    else
        for entry in "${MODULE_LABELS[@]}"; do
            IFS='|' read -r tag label def <<<"$entry"
            items+=("$tag|$label|$def")
        done
        v="$(ui_checklist "Select what to set up. Destructive steps still ask again." "${items[@]}")" || die "cancelled"
    fi
    set_answer MODULES "$(echo "$v" | xargs)"
}

wants() { case " $MODULES " in *" $1 "*) return 0;; *) return 1;; esac; }

# ---------- preflight ----------

preflight() {
    log "== preflight"
    [ -r /etc/os-release ] && . /etc/os-release || true
    case "${ID:-}" in ubuntu|debian) ;; *) log "warning: tested on Ubuntu; continuing on ${ID:-unknown}" ;; esac
    if [ -n "$SUDO" ]; then
        if [ "$DRY" = 1 ]; then log "dry-run: skipping sudo check"; else $SUDO -v || die "sudo is needed"; fi
    fi
    command -v python3 >/dev/null || die "python3 is needed"
    command -v curl >/dev/null || die "curl is needed (sudo apt-get install curl)"
    mkdir -p "$LOG_DIR"
    log "log: $LOG"
}

# ---------- modules ----------

mod_storage() {
    log "== storage: data drive"
    local uuid="" dev=""
    if ask_yes FORMAT_DATA "Format a partition as the data drive? This ERASES it. Choose 'no' to use an existing btrfs drive." off; then
        local options=() name fs size mnt
        # Partitions that are not the system (/, /boot) and not already btrfs data.
        while read -r name fs size mnt; do
            case "$mnt" in /|/boot*|/boot/efi) continue ;; esac
            [ -n "$name" ] && options+=("$name|$fs $size ${mnt:+mounted at $mnt}")
        done < <(lsblk -pn -l -o NAME,FSTYPE,SIZE,MOUNTPOINT | awk 'NF>=3 {m=($4==""?"":$4); print $1, $2, $3, m}' || true)
        dev="$(ask_menu DATA_DEVICE "Partition to ERASE and format as btrfs (look twice):" "" "${options[@]}")"
        local confirm; confirm="$(ask_input FORMAT_CONFIRM "Type exactly: ERASE $dev" "")"
        [ "$confirm" = "ERASE $dev" ] || die "confirmation did not match; nothing was erased"
        run $SUDO mkfs.btrfs -f -L data "$dev"
    else
        local options=() line name fs size id
        while read -r name fs size id; do
            [ -n "$name" ] && [ "$fs" = btrfs ] && options+=("$id|$name $size")
        done < <(lsblk -pn -l -o NAME,FSTYPE,SIZE,UUID || true)
        [ "${#options[@]}" -gt 0 ] || die "no btrfs partition found; choose the format option or create one first"
        uuid="$(ask_menu DATA_UUID "btrfs partition to use as the data drive:" "" "${options[@]}")"
    fi
    if [ -z "$uuid" ]; then
        uuid="$($SUDO blkid -s UUID -o value "$dev")"
    fi
    set_answer DATA_UUID "$uuid"

    # Subvolumes, created from the top level.
    local top=/mnt/devsetup-top subs="@projects @cache @models @docker @tmp @sandboxes @workspace"
    run $SUDO mkdir -p "$top"
    run $SUDO mount -o subvolid=5 "UUID=$uuid" "$top"
    local sv
    for sv in $subs; do
        if [ "$DRY" = 1 ] || [ ! -d "$top/$sv" ]; then run $SUDO btrfs subvolume create "$top/$sv"; else log "  exists: $sv"; fi
    done
    run $SUDO umount "$top"

    # fstab entries, one per subvolume. Existing lines for a mount point are left alone.
    local entries=(
        "/data/projects|@projects|zstd:3"
        "/data/cache|@cache|zstd:3"
        "/data/models|@models|"
        "/data/docker|@docker|zstd:3"
        "/data/tmp|@tmp|zstd:3"
        "/tmp|@tmp|zstd:3"
        "/data/sandboxes|@sandboxes|zstd:3"
        "/data/workspace|@workspace|zstd:3"
    )
    local e mp sub comp opts line
    for e in "${entries[@]}"; do
        IFS='|' read -r mp sub comp <<<"$e"
        opts="subvol=$sub,noatime"; [ -n "$comp" ] && opts="subvol=$sub,compress=$comp,noatime"
        line="UUID=$uuid  $mp  btrfs  $opts  0 0"
        if grep -q -E "[[:space:]]$mp[[:space:]]" /etc/fstab; then
            log "  fstab already has $mp"
        else
            if [ "$DRY" = 1 ]; then log "  + fstab: $line"; else
                printf '\n%s\n' "$line" | $SUDO tee -a /etc/fstab >/dev/null; log "  fstab + $line"; fi
        fi
    done
    run $SUDO systemctl daemon-reload
    run $SUDO mkdir -p /data/projects /data/cache /data/models /data/docker /data/tmp /data/sandboxes /data/workspace
    run $SUDO mount -a
    run $SUDO chown -R "$(id -u):$(id -g)" /data/projects /data/cache /data/models /data/sandboxes /data/workspace
    run $SUDO chmod 1777 /data/tmp
    if [ "$DRY" != 1 ] && [ -d /data/models ]; then run $SUDO btrfs property set /data/models compression no || true; fi
    log "  note: /tmp is mounted from @tmp at the next boot. Do not mask tmp.mount."
}

mod_boot() {
    log "== boot: root read-write"
    local f=/etc/default/grub
    if [ "$DRY" != 1 ] && grep -q 'GRUB_CMDLINE_LINUX_DEFAULT=.*\brw\b' "$f"; then log "  already set"; return; fi
    run $SUDO cp "$f" "$f.bak-$(date +%Y%m%d-%H%M%S)"
    if [ "$DRY" = 1 ]; then log "  + set GRUB_CMDLINE_LINUX_DEFAULT to include rw (drop autoinstall)"; return; fi
    $SUDO python3 - "$f" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()
def fix(m):
    args = [a for a in m.group(1).split() if a not in ("autoinstall", "rw")]
    return 'GRUB_CMDLINE_LINUX_DEFAULT="' + " ".join(args + ["rw"]) + '"'
text = re.sub(r'GRUB_CMDLINE_LINUX_DEFAULT="([^"]*)"', fix, text, count=1)
open(path, "w").write(text)
PY
    run $SUDO update-grub
}

mod_sudo() {
    log "== sudo: passwordless for $(id -un)"
    log "  warning: anything running as this user can become root without a password."
    put /tmp/devsetup-sudoers <<<"$(id -un) ALL=(ALL) NOPASSWD: ALL"
    run $SUDO install -m 0440 -o root -g root /tmp/devsetup-sudoers "/etc/sudoers.d/90-$(id -un)-nopasswd"
    run $SUDO visudo -cf "/etc/sudoers.d/90-$(id -un)-nopasswd"
    rm -f /tmp/devsetup-sudoers
}

mod_env() {
    log "== env: system-wide tool paths and apt cache"
    managed_block /etc/environment env sudo <<'EOF'
TMPDIR=/data/tmp
RUSTUP_HOME=/data/cache/rustup
CARGO_HOME=/data/cache/cargo
GOPATH=/data/projects/go
GOCACHE=/data/cache/go-build
GOMODCACHE=/data/cache/go-mod
UV_CACHE_DIR=/data/cache/uv
UV_PYTHON_INSTALL_DIR=/data/cache/uv/python
NPM_CONFIG_CACHE=/data/cache/npm
EOF
    run mkdir -p /data/cache/apt/archives/partial
    if [ ! -L /var/cache/apt/archives ]; then
        run $SUDO rm -rf /var/cache/apt/archives
        run $SUDO ln -s /data/cache/apt/archives /var/cache/apt/archives
    fi
}

mod_apt() {
    log "== apt: build tools"
    run $SUDO apt-get update
    run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential cmake ninja-build pkg-config \
        libssl-dev libffi-dev zlib1g-dev libsqlite3-dev unzip jq git curl ca-certificates gnupg
}

mod_rust() {
    log "== rust: stable"
    local base=https://static.rust-lang.org/rustup/dist/x86_64-unknown-linux-gnu
    export RUSTUP_HOME=/data/cache/rustup CARGO_HOME=/data/cache/cargo
    if [ -x /data/cache/cargo/bin/rustup ]; then
        run /data/cache/cargo/bin/rustup update stable
    else
        if [ "$DRY" = 1 ]; then log "  + download rustup-init and verify its .sha256, then install stable"; return; fi
        local tmp; tmp="$(mktemp -d)"
        curl -fsSL -o "$tmp/rustup-init" "$base/rustup-init"
        curl -fsSL -o "$tmp/rustup-init.sha256" "$base/rustup-init.sha256"
        (cd "$tmp" && sha256sum -c rustup-init.sha256 >/dev/null)
        chmod +x "$tmp/rustup-init"
        "$tmp/rustup-init" -y --no-modify-path --default-toolchain stable 2>&1 | tee -a "$LOG" >/dev/null
        rm -rf "$tmp"
    fi
}

latest_go() { curl -fsSL 'https://go.dev/dl/?mode=json' | python3 -c '
import json, sys
for r in json.load(sys.stdin):
    if not r.get("stable"): continue
    for f in r["files"]:
        if f["os"] == "linux" and f["arch"] == "amd64" and f["kind"] == "archive":
            print(r["version"], f["filename"], f["sha256"]); raise SystemExit
'; }

mod_go() {
    log "== go: latest stable"
    read -r ver file sha < <(latest_go)
    log "  latest: $ver"
    if [ -d "/data/cache/$ver" ]; then log "  already installed"; else
        if [ "$DRY" = 1 ]; then log "  + download $file, verify, install to /data/cache/$ver"; else
            local tmp; tmp="$(mktemp -d)"
            curl -fsSL -o "$tmp/$file" "https://go.dev/dl/$file"
            echo "$sha  $tmp/$file" | sha256sum -c - >/dev/null
            tar -C "$tmp" -xzf "$tmp/$file"
            mv "$tmp/go" "/data/cache/$ver"
            rm -rf "$tmp"
        fi
    fi
    if [ -d /data/cache/go ] && [ ! -L /data/cache/go ]; then
        # An older unlinked install sits in the way; move it aside so the symlink lands correctly.
        run mv /data/cache/go "/data/cache/go-prev-$(date +%Y%m%d%H%M%S)"
    fi
    run ln -sfn "/data/cache/$ver" /data/cache/go
    run $SUDO ln -sfn /data/cache/go /usr/local/go
}

latest_lts() { curl -fsSL https://nodejs.org/dist/index.json | python3 -c '
import json, sys
print([x["version"] for x in json.load(sys.stdin) if x["lts"]][0])'; }

mod_node() {
    log "== node: latest LTS"
    local v; v="$(latest_lts)"
    log "  latest LTS: $v"
    local dir="/data/cache/node/node-$v-linux-x64"
    if [ -d "$dir" ]; then log "  already installed"; else
        if [ "$DRY" = 1 ]; then log "  + download $v, verify against SHASUMS256, install to $dir"; else
            local tmp; tmp="$(mktemp -d)"
            curl -fsSL -o "$tmp/node.tar.xz" "https://nodejs.org/dist/$v/node-$v-linux-x64.tar.xz"
            curl -fsSL -o "$tmp/SHASUMS256.txt" "https://nodejs.org/dist/$v/SHASUMS256.txt"
            (cd "$tmp" && grep " node-$v-linux-x64.tar.xz\$" SHASUMS256.txt | sha256sum -c - >/dev/null)
            mkdir -p /data/cache/node && tar -C /data/cache/node -xJf "$tmp/node.tar.xz"
            rm -rf "$tmp"
        fi
    fi
    run ln -sfn "$dir" /data/cache/node/current
    run mkdir -p "$HOME/.local/bin"
    local b; for b in node npm npx; do run ln -sfn "/data/cache/node/current/bin/$b" "$HOME/.local/bin/$b"; done
}

mod_uv() {
    log "== uv: standalone release"
    local tag
    tag="$(curl -fsSL https://api.github.com/repos/astral-sh/uv/releases/latest | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')"
    log "  latest: $tag"
    if [ "$DRY" = 1 ]; then log "  + download uv $tag, verify .sha256, install to /data/cache/bin"; return; fi
    local tmp; tmp="$(mktemp -d)"
    local base="https://github.com/astral-sh/uv/releases/download/$tag/uv-x86_64-unknown-linux-gnu.tar.gz"
    curl -fsSL -o "$tmp/uv.tar.gz" "$base"
    curl -fsSL -o "$tmp/uv.tar.gz.sha256" "$base.sha256"
    (cd "$tmp" && sha256sum -c uv.tar.gz.sha256 >/dev/null)
    tar -C "$tmp" -xzf "$tmp/uv.tar.gz"
    mkdir -p /data/cache/bin
    install -m 0755 "$tmp/uv-x86_64-unknown-linux-gnu/uv" "$tmp/uv-x86_64-unknown-linux-gnu/uvx" /data/cache/bin/
    rm -rf "$tmp"
    mkdir -p "$HOME/.local/bin"
    ln -sfn /data/cache/bin/uv "$HOME/.local/bin/uv"
    ln -sfn /data/cache/bin/uvx "$HOME/.local/bin/uvx"
}

mod_npm() {
    log "== npm: prefix, cache, global tools"
    run npm config set prefix /data/cache/npm-global
    run npm config set cache /data/cache/npm
    run mkdir -p /data/cache/npm-global
    local pkgs=""
    ask_yes NPM_PNPM "Install pnpm and bun (global, scripts allowed)?" on && pkgs="$pkgs pnpm bun"
    ask_yes NPM_CLAUDE "Install Claude Code (global, native binary allowed)?" on && pkgs="$pkgs @anthropic-ai/claude-code"
    ask_yes NPM_OPENCODE "Install opencode-ai (global, script allowed)?" off && pkgs="$pkgs opencode-ai"
    local p
    for p in $pkgs; do
        case "$p" in
            pnpm|bun) run npm install -g --allow-scripts="$p" "$p@latest" ;;
            @anthropic-ai/claude-code) run npm install -g --allow-scripts="$p" "$p@latest" ;;
            opencode-ai) run npm install -g --allow-scripts="$p" "$p@latest" ;;
        esac
    done
    ask_yes NPM_GIT "Allow git-hosted npm packages in the sandboxes? (they run their install scripts)" off || true
    managed_block "$HOME/.bashrc" shared-bin <<'EOF'
export PATH="/data/cache/npm-global/bin:/data/cache/bin:$PATH"
EOF
}

mod_git() {
    log "== git: identity"
    local login id
    login="$(ask_input GIT_LOGIN "Your GitHub login (for the no-reply address):" "")"
    id="$(ask_input GIT_ID "Your GitHub numeric user ID (gh api user --jq .id):" "")"
    [ -n "$login" ] && [ -n "$id" ] || { log "  skipped: login and numeric ID are needed"; return; }
    case "$id" in *[!0-9]*) die "the user ID must be numeric";; esac
    local email="$id+$login@users.noreply.github.com"
    run git config --global user.name "$login"
    run git config --global user.email "$email"
    log "  identity: $login <$email>"
    log "  do not use a work email as the author: GitHub credits commits to whichever account owns it."
}

mod_docker() {
    log "== docker: data root on /data"
    run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io docker-compose-v2
    if [ "$DRY" = 1 ]; then log "  + merge data-root=/data/docker into /etc/docker/daemon.json"; else
        local cur="{}"; [ -f /etc/docker/daemon.json ] && cur="$(cat /etc/docker/daemon.json)"
        printf '%s' "$cur" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}")
d["data-root"] = "/data/docker"
print(json.dumps(d, indent=2))' | $SUDO tee /etc/docker/daemon.json >/dev/null
    fi
    run $SUDO systemctl restart docker
    run $SUDO usermod -aG docker "$(id -un)"
    log "  note: restarting Docker stops running containers. Log out and back in for group access."
}

mod_flatpak() {
    log "== flatpak: system installation on /data"
    run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y flatpak
    run $SUDO mkdir -p /data/flatpak
    if [ "$DRY" != 1 ] && [ -d /var/lib/flatpak ] && [ ! -L /var/lib/flatpak ]; then
        $SUDO cp -a /var/lib/flatpak/. /data/flatpak/ && $SUDO rm -rf /var/lib/flatpak
    fi
    run $SUDO ln -sfn /data/flatpak /var/lib/flatpak
    run $SUDO flatpak remote-add --system --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
    local app
    if ask_yes FP_OBS "Install OBS Studio (flatpak)?" on; then app="com.obsproject.Studio"; run $SUDO flatpak install -y --system flathub "$app"; fi
    if ask_yes FP_DISCORD "Install Discord (flatpak build)?" off; then run $SUDO flatpak install -y --system flathub com.discordapp.Discord; fi
    run mkdir -p "$HOME/.local/share/applications"
    if [ "$DRY" != 1 ]; then
        for f in /data/flatpak/exports/share/applications/*.desktop; do [ -e "$f" ] && ln -sfn "$f" "$HOME/.local/share/applications/"; done
        update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
    fi
}

mod_dedup() {
    log "== dedup: weekly non-destructive dedup of /data"
    run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y duperemove
    if [ "$DRY" != 1 ]; then
        cat >/tmp/devsetup-dedup.service <<'EOF'
[Unit]
Description=Non-destructive btrfs dedup (shared extents) for /data
[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
ExecStart=/usr/bin/duperemove -r -d --hashfile=/data/cache/duperemove.db --io-threads=4 --cpu-threads=8 /data/projects /data/models /data/cache
EOF
        cat >/tmp/devsetup-dedup.timer <<'EOF'
[Unit]
Description=Weekly dedup of /data
[Timer]
OnCalendar=Sun *-*-* 03:00:00
Persistent=true
[Install]
WantedBy=timers.target
EOF
        $SUDO install -m 0644 /tmp/devsetup-dedup.service /etc/systemd/system/dedup-data.service
        $SUDO install -m 0644 /tmp/devsetup-dedup.timer /etc/systemd/system/dedup-data.timer
        rm -f /tmp/devsetup-dedup.service /tmp/devsetup-dedup.timer
    else
        log "  + install dedup-data.service and dedup-data.timer (weekly, Sunday 03:00)"
    fi
    run $SUDO systemctl daemon-reload
    run $SUDO systemctl enable --now dedup-data.timer
}

mod_gcloud() {
    log "== gcloud: shared SDK copy on /data"
    if ! command -v gcloud >/dev/null 2>&1 || [ ! -d /usr/lib/google-cloud-sdk ]; then
        run $SUDO install -d -m 0755 /etc/apt/keyrings
        if [ "$DRY" != 1 ]; then
            curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/cloud.google.gpg
            echo "deb [signed-by=/etc/apt/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | $SUDO tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null
        fi
        run $SUDO apt-get update
        run $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y google-cloud-cli
    fi
    run $SUDO rm -rf /data/cache/google-cloud-sdk
    run $SUDO cp -a /usr/lib/google-cloud-sdk /data/cache/google-cloud-sdk
    run $SUDO chown -R root:root /data/cache/google-cloud-sdk
    log "  refresh after apt upgrades of gcloud: rerun this module."
}

mod_kaggle() {
    log "== kaggle: shared CLI"
    run env UV_TOOL_BIN_DIR=/data/cache/bin UV_TOOL_DIR=/data/cache/uv/tools uv tool install kaggle
    log "  each sandbox keeps its own ~/.kaggle token. Nothing is copied from here."
}

mod_gm() {
    log "== gm: shared bundle"
    run mkdir -p /data/cache/gm/.gm-tools /data/cache/npm-global
    run env HOME=/data/cache/gm npm install -g --prefix /data/cache/npm-global --allow-git=all github:AnEntrypoint/gm
    run env HOME=/data/cache/gm /data/cache/npm-global/bin/gm -g
    if ask_yes GM_CLEAN "Remove the gm Zed entry and stop the agentplug daemon the installer started on this host?" on; then
        if [ "$DRY" != 1 ]; then
            if [ -f "$HOME/.config/zed/settings.json" ] && grep -q '"gm"' "$HOME/.config/zed/settings.json"; then
                rm -f "$HOME/.config/zed/settings.json"; log "  removed Zed entry"
            fi
            pkill -f 'agentplug-runner daemon' 2>/dev/null || true
        else
            log "  + remove Zed gm entry; stop agentplug-runner daemon"
        fi
    fi
}

mod_skills() {
    log "== skills: grill-me in the sandbox template"
    local tpl=/data/sandboxes/shared-home
    if [ "$DRY" = 1 ]; then log "  + npx skills add mattpocock/skills --skill=grill-me into $tpl (then remove the rest)"; return; fi
    [ -d "$tpl" ] || { log "  skipped: template not created yet (run the sandboxes module first)"; return; }
    local before; before="$(ls "$tpl/.claude/skills" 2>/dev/null | sort || true)"
    (cd /tmp && HOME="$tpl" npx -y skills@latest add mattpocock/skills --skill=grill-me -g -a claude-code -y --copy) 2>&1 | tee -a "$LOG" >/dev/null || true
    local d
    for d in $(ls "$tpl/.claude/skills" 2>/dev/null); do
        if ! grep -qx "$d" <<<"$before" && [ "$d" != grill-me ]; then rm -rf "$tpl/.claude/skills/$d"; fi
    done
    rm -rf "$tpl/.agents"
    log "  kept: grill-me"
}

mod_sandboxes() {
    log "== sandboxes: template, launcher, desktop icons"
    local tpl=/data/sandboxes/shared-home dsb="$(ask_input DEVSB_DIR "Where to keep the sandbox launcher files:" /data/projects/dev-sandbox)"
    run $SUDO mkdir -p /data/sandboxes /data/cache/claude-auth /data/cache/claude-state/projects /data/cache/gm
    run $SUDO chown -R "$(id -u):$(id -g)" /data/sandboxes /data/cache/claude-auth /data/cache/claude-state /data/cache/gm
    run mkdir -p "$dsb"
    run cp "$REPO_DIR/sandbox/Dockerfile" "$REPO_DIR/sandbox/launch.sh" "$REPO_DIR/sandbox/stop.sh" "$dsb/"
    run chmod +x "$dsb/launch.sh" "$dsb/stop.sh"

    if [ ! -d "$tpl" ]; then run $SUDO btrfs subvolume create "$tpl"; fi
    run $SUDO chown "$(id -u):$(id -g)" "$tpl"
    run chmod 750 "$tpl"

    local gname gemail
    gname="$(git config --global user.name 2>/dev/null || true)"
    gemail="$(git config --global user.email 2>/dev/null || true)"
    if [ "$DRY" != 1 ]; then
        cat >"$tpl/.profile" <<'EOF'
# Shared sandbox profile. Per-sandbox changes stay in each sandbox home.
export RUSTUP_HOME=/data/cache/rustup
export CARGO_HOME=/data/cache/cargo
export GOPATH=/data/projects/go
export GOCACHE=/data/cache/go-build
export GOMODCACHE=/data/cache/go-mod
export UV_CACHE_DIR=/data/cache/uv
export UV_PYTHON_INSTALL_DIR=/data/cache/uv/python
export NPM_CONFIG_CACHE=/data/cache/npm
export TMPDIR=/tmp
export PATH="/data/cache/npm-global/bin:/data/cache/bin:/data/cache/node/current/bin:$PATH"
EOF
        cp "$tpl/.profile" "$tpl/.bashrc"
        printf '\n# Git packs and caches are read-only by design; rm should not prompt on them\nalias rm="rm -f"\n' >>"$tpl/.bashrc"
        {
            [ -n "$gname" ] && printf '[user]\n\tname = %s\n\temail = %s\n' "$gname" "$gemail"
            printf '[credential "https://github.com"]\n\thelper =\n\thelper = !/usr/bin/gh auth git-credential\n'
            printf '[credential "https://gist.github.com"]\n\thelper =\n\thelper = !/usr/bin/gh auth git-credential\n'
        } >"$tpl/.gitconfig"
        if [ "${NPM_GIT:-no}" = yes ]; then printf 'allow-git=all\nprefix=/data/cache/npm-global\n' >"$tpl/.npmrc"
        else printf 'prefix=/data/cache/npm-global\n' >"$tpl/.npmrc"; fi
        mkdir -p "$tpl/.claude"
        ln -sfn /data/cache/gm/.gm-tools "$tpl/.gm-tools"
        ln -sfn /config/.claude-state/projects "$tpl/.claude/projects"
        ln -sfn /config/.claude-state/history.jsonl "$tpl/.claude/history.jsonl"
        touch /data/cache/claude-state/history.jsonl
        chmod 750 "$tpl" 2>/dev/null || true
    else
        log "  + write template .profile, .bashrc (with rm alias), .gitconfig, .npmrc, links"
    fi

    if ask_yes SB_COPY_CLAUDE "Copy this machine's Claude settings, skills and plugins into the template (no login, no history)?" on; then
        if [ "$DRY" != 1 ]; then
            mkdir -p "$tpl/.claude"
            [ -f "$HOME/.claude/settings.json" ] && cp "$HOME/.claude/settings.json" "$tpl/.claude/"
            [ -d "$HOME/.claude/skills" ] && cp -an "$HOME/.claude/skills" "$tpl/.claude/"
            [ -d "$HOME/.claude/plugins" ] && cp -an "$HOME/.claude/plugins" "$tpl/.claude/"
        else log "  + copy settings.json, skills, plugins"; fi
    fi

    if ask_yes SB_SHARE_LOGIN "Share this machine's Claude login with every sandbox? (one account, shared refreshes)" off; then
        if [ "$DRY" != 1 ] && [ -f "$HOME/.claude/.credentials.json" ] && [ ! -L "$HOME/.claude/.credentials.json" ]; then
            cp -p "$HOME/.claude/.credentials.json" /data/cache/claude-auth/.credentials.json
            chmod 600 /data/cache/claude-auth/.credentials.json
            mv "$HOME/.claude/.credentials.json" "$HOME/.claude/.credentials.json.pre-symlink"
            ln -s /data/cache/claude-auth/.credentials.json "$HOME/.claude/.credentials.json"
        fi
        run ln -sfn /config/.claude-auth/.credentials.json "$tpl/.claude/.credentials.json"
    fi

    local count="$(ask_menu SB_COUNT "How many sandboxes (dev1..devN)?" 4 "1|1" "2|2" "3|3" "4|4")"
    local n
    for n in $(seq 1 "$count"); do
        run $SUDO mkdir -p "/data/sandboxes/dev$n/creds/gh" "/data/sandboxes/dev$n/creds/gcloud" "/data/sandboxes/dev$n/creds/kaggle"
        run $SUDO chown -R 1000:1000 "/data/sandboxes/dev$n/creds"
        if ask_yes "SB_ICON_$n" "Create Start and Stop desktop icons for dev$n?" on; then
            local desk="$HOME/Desktop"; [ -d "$desk" ] || desk="$HOME/Desktop"
            if [ "$DRY" != 1 ]; then
                mkdir -p "$desk"
                cat >"$desk/dev$n.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Start Dev $n
Comment=Start sandbox dev$n and open it in the default browser (http://127.0.0.1:300$n)
Exec=$dsb/launch.sh dev$n
Icon=media-playback-start
Terminal=false
Categories=Development;
EOF
                cat >"$desk/stop-dev$n.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Stop Dev $n
Comment=Stop sandbox dev$n (its home is kept)
Exec=$dsb/stop.sh dev$n
Icon=media-playback-stop
Terminal=false
Categories=Development;
EOF
                chmod +x "$desk/dev$n.desktop" "$desk/stop-dev$n.desktop"
                gio set "$desk/dev$n.desktop" metadata::trusted true 2>/dev/null || true
                gio set "$desk/stop-dev$n.desktop" metadata::trusted true 2>/dev/null || true
            else log "  + desktop icons dev$n"; fi
        fi
    done

    if ask_yes SB_BUILD "Build the dev-desktop sandbox image now? (downloads several GB)" off; then
        run $SUDO docker build -t dev-desktop:latest "$dsb"
    else
        log "  build later: sudo docker build -t dev-desktop:latest $dsb"
    fi
    log "  sign in per sandbox: gh auth login (and gcloud / kaggle when needed). The gh login is not copied."
}

# ---------- summary ----------

summary() {
    log ""
    log "== done"
    log "modules: $MODULES"
    log "log: $LOG"
    if wants storage || wants boot; then log "reboot is recommended so fstab and the rw boot argument take effect."; fi
    if wants docker; then log "log out and back in for the docker group."; fi
    log "re-run any time: $0   (answers in $ANSWERS)"
}

install_launcher() {
    local desk="$HOME/Desktop"
    mkdir -p "$desk"
    cat >"$desk/devsetup.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Dev machine setup
Comment=Menu-driven setup for the data drive, toolchains, Docker, apps and sandboxes
Exec=$SCRIPT_DIR/devsetup.sh
Icon=system-software-install
Terminal=false
Categories=Development;
EOF
    chmod +x "$desk/devsetup.desktop"
    gio set "$desk/devsetup.desktop" metadata::trusted true 2>/dev/null || true
    echo "launcher: $desk/devsetup.desktop"
}

# ---------- main ----------

main() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) DRY=1 ;;
            --answers) ANSWERS_IN="$2"; shift ;;
            --install-launcher) install_launcher; exit 0 ;;
            --help|-h) usage ;;
            *) die "unknown option: $1" ;;
        esac
        shift
    done
    mkdir -p "$STATE_DIR" "$LOG_DIR"
    touch "$LOG" "$ANSWERS"
    preflight
    if [ -n "$ANSWERS_IN" ]; then load_answers "$ANSWERS_IN"; fi
    if [ -z "$ANSWERS_IN" ] && [ "$UI" != none ]; then
        local welcome="This sets up the data drive, shared toolchains, Docker, flatpak and the sandboxes.

Destructive steps (formatting a drive, boot changes, sudo) ask again before they run."
        case "$UI" in
            zenity) zenity --info --title="devsetup" --text="$welcome" --width=460 ;;
            whiptail) whiptail --title "devsetup" --msgbox "$welcome" 12 76 ;;
        esac
    fi
    select_modules
    log "selected: $MODULES"
    if [ "$DRY" = 1 ]; then log "DRY RUN: nothing will change"; fi
    local m
    for m in $MODULES; do
        case "$m" in
            storage|boot|sudo|env|apt|rust|go|node|uv|npm|git|docker|flatpak|dedup|gcloud|kaggle|sandboxes|gm|skills)
                "mod_$m" ;;
            *) log "unknown module: $m" ;;
        esac
    done
    summary
}

main "$@"

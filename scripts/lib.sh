# shellcheck shell=bash disable=SC2034 # variables set here are used by the sourcing scripts
# Shared helpers for the scripts in this directory (source it, don't run it).

APP=com.usebottles.bottles
DATA=$HOME/.var/app/$APP/data/bottles
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# The "prefix" backend: a plain Wine prefix, run with the host's libraries instead of the
# Bottles Flatpak. scripts/setup-prefix.sh creates it; everything lives under PREFIX_HOME.
PREFIX_HOME=${ALTIUM_PREFIX_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/altium-on-linux}

say() { printf '\033[1m==> %s\033[0m\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Windows path (Z:\...) of a host path, for programs running inside the bottle.
winpath() { printf 'Z:%s' "${1//\//\\}"; }

# load_bottle_dir NAME
# Sets BACKEND, BOTTLE_DIR, RUNNER, RUNNER_DIR and STAGE (a folder inside the bottle that
# the Bottles sandbox can read and write; the sandbox has no access to this repository).
#
# BACKEND is "bottles" (the Bottles Flatpak bottle NAME) or "prefix" (the Wine prefix in
# PREFIX_HOME/prefix; NAME is not used). ALTIUM_BACKEND chooses; without it the bottle is
# used if it exists, else the prefix if scripts/setup-prefix.sh created one.
load_bottle_dir() {
    BACKEND=${ALTIUM_BACKEND:-}
    if [ -z "$BACKEND" ]; then
        if [ ! -f "$DATA/bottles/$1/bottle.yml" ] && [ -f "$PREFIX_HOME/prefix/prefix.conf" ]; then
            BACKEND=prefix
        else
            BACKEND=bottles
        fi
    fi
    case $BACKEND in
        bottles)
            BOTTLE_DIR=$DATA/bottles/$1
            [ -f "$BOTTLE_DIR/bottle.yml" ] || die "no Bottles bottle named '$1' in $DATA/bottles (use --bottle, or scripts/setup-prefix.sh for a prefix without Bottles)"
            RUNNER=$(sed -n 's/^Runner: //p' "$BOTTLE_DIR/bottle.yml")
            RUNNER_DIR=$DATA/runners/$RUNNER
            [ -x "$RUNNER_DIR/bin/wine" ] || die "runner '$RUNNER' not found in $DATA/runners"
            ;;
        prefix)
            BOTTLE_DIR=$PREFIX_HOME/prefix
            [ -f "$BOTTLE_DIR/prefix.conf" ] || die "no prefix in $BOTTLE_DIR (run scripts/setup-prefix.sh)"
            RUNNER=$(sed -n 's/^RUNNER=//p' "$BOTTLE_DIR/prefix.conf")
            RUNNER_DIR=$PREFIX_HOME/runners/$RUNNER
            [ -x "$RUNNER_DIR/bin/wine" ] || die "runner '$RUNNER' not found in $PREFIX_HOME/runners (run scripts/setup-prefix.sh)"
            ENV_FILE=$BOTTLE_DIR/altium.env
            ;;
        *) die "unknown ALTIUM_BACKEND '$BACKEND' (bottles or prefix)" ;;
    esac
    STAGE=$BOTTLE_DIR/altium-on-linux
}

# bottle_set_env NAME VALUE: an environment variable for every program started in the
# bottle (bottle.yml for Bottles, altium.env for the prefix; VALUE is taken literally).
bottle_set_env() {
    if [ "$BACKEND" = bottles ]; then
        flatpak run --command=bottles-cli "$APP" edit -b "$(basename "$BOTTLE_DIR")" --env-var "$1=$2"
    else
        local tmp
        tmp=$(mktemp "$ENV_FILE.XXXXXX")
        { grep -v "^$1=" "$ENV_FILE" 2>/dev/null || true; printf '%s=%s\n' "$1" "$2"; } > "$tmp"
        mv "$tmp" "$ENV_FILE"
    fi
}

# bottle_has_env NAME VALUE: whether bottle_set_env NAME VALUE is in effect.
bottle_has_env() {
    if [ "$BACKEND" = bottles ]; then
        grep -qF "$1: $2" "$BOTTLE_DIR/bottle.yml"
    else
        grep -qxF "$1=$2" "$ENV_FILE" 2>/dev/null
    fi
}

# The bottle's own environment variables, one NAME=VALUE per line.
bottle_env_vars() {
    if [ "$BACKEND" = bottles ]; then
        awk '/^Environment_Variables:/{on=1; next} on && /^    [A-Za-z_][A-Za-z0-9_]*: /{sub(/^    /,""); k=$1; sub(/:$/,"",k);
             $1=""; v=substr($0,2); gsub(/^'"'"'|'"'"'$/,"",v); print k"="v; next} on{exit}' "$BOTTLE_DIR/bottle.yml"
    else
        cat "$ENV_FILE" 2>/dev/null || true
    fi
}

# Where the zero-size filter goes for each architecture, as "arch:dir" pairs, dir being
# what the dynamic loader makes of $LIB: lib/x86_64-linux-gnu and lib/i386-linux-gnu in the
# Bottles Flatpak runtime, lib and lib32 on the host (Arch; Debian-like hosts use the same
# names as the Flatpak runtime).
zero_size_lib_dirs() {
    if [ "$BACKEND" = bottles ] || [ -d /usr/lib/x86_64-linux-gnu ]; then
        echo "x86_64:lib/x86_64-linux-gnu i386:lib/i386-linux-gnu"
    else
        echo "x86_64:lib i386:lib32"
    fi
}

# Wine's sync setting, as Bottles applies the "Gaming" environment's `sync: ntsync`
# (_apply_sync_environment in Bottles' winecommand.py): ntsync if the kernel offers it and
# the runner supports it, else fsync.
bottle_sync_env() {
    local sync=ntsync
    [ "$BACKEND" = prefix ] || sync=$(sed -n 's/^    sync: //p' "$BOTTLE_DIR/bottle.yml")
    case $sync in
        esync) echo WINEESYNC=1 ;;
        fsync) echo WINEFSYNC=1 ;;
        wine|ntsync)
            if [ -r /dev/ntsync ] && grep -q /dev/ntsync "$RUNNER_DIR/bin/wineserver"; then echo WINENTSYNC=1
            elif [ "$sync" = ntsync ]; then echo WINEFSYNC=1; fi ;;
    esac
}

# launch_env CHANNELS: sets LAUNCH_ENV to the environment Bottles starts a program of this
# bottle with (see `ps e` of a Bottles launch), WINEDEBUG=CHANNELS, then the bottle's own
# variables (SteamAppId, DOTNET_..., LD_PRELOAD, ...).
launch_env() {
    local sync line
    sync=$(bottle_sync_env)
    LAUNCH_ENV=(
        WINEPREFIX="$BOTTLE_DIR" WINEARCH=win64 BOTTLE="$(basename "$BOTTLE_DIR")"
        ${sync:+"$sync"} WINE_LARGE_ADDRESS_AWARE=1 STAGING_SHARED_MEMORY=1
        WINEDLLOVERRIDES="winemenubuilder=;easyanticheat_x86,easyanticheat_x64=b,n;beclient,beclient_x64=b,n"
        LD_LIBRARY_PATH="$RUNNER_DIR/lib:$RUNNER_DIR/lib/wine/x86_64-unix:$RUNNER_DIR/lib/wine/i386-unix"
        DXVK_SHADER_CACHE_PATH="$BOTTLE_DIR/cache/dxvk_shader" VKD3D_SHADER_CACHE_PATH="$BOTTLE_DIR/cache/vkd3d_shader"
        MESA_SHADER_CACHE_DIR="$BOTTLE_DIR/cache/mesa_shader"
        WINEDEBUG="$1"
    )
    while IFS= read -r line; do [ -z "$line" ] || LAUNCH_ENV+=("$line"); done < <(bottle_env_vars)
}

# in_bottle_sandbox DIR COMMAND...: run COMMAND in DIR where the bottle's programs run:
# inside the Bottles Flatpak sandbox, or on the host for the prefix.
in_bottle_sandbox() {
    if [ "$BACKEND" = bottles ]; then
        # shellcheck disable=SC2016 # expanded by the inner bash
        flatpak run --command=bash "$APP" -c 'cd "$1" && shift && exec "$@"' _ "$@"
    else
        (cd "$1" && shift && exec "$@")
    fi
}

# find_altium [ALTIUM_DIR]
# Sets ALTIUM_DIR (the newest AD* folder unless given) and AD (Altium's folder on the
# host); fails if Altium Designer is not installed in the bottle (after load_bottle_dir).
ALTIUM_ROOT_REL="drive_c/Program Files/Altium"
find_altium() {
    local altium_root="$BOTTLE_DIR/$ALTIUM_ROOT_REL"
    ALTIUM_DIR=${1:-}
    if [ -z "$ALTIUM_DIR" ]; then
        ALTIUM_DIR=$(find "$altium_root" -maxdepth 2 -iname 'X2.EXE' -printf '%h\n' 2>/dev/null \
            | sort -V | tail -1 | xargs -r -d '\n' basename)
    fi
    AD="$altium_root/$ALTIUM_DIR"
    [ -n "$ALTIUM_DIR" ] && [ -f "$AD/X2.EXE" ]
}

# load_bottle NAME [ALTIUM_DIR]
# load_bottle_dir and find_altium; dies if Altium Designer is not installed.
load_bottle() {
    load_bottle_dir "$1"
    find_altium "${2:-}" || die "Altium Designer not found under $BOTTLE_DIR/$ALTIUM_ROOT_REL (use --altium-dir)"
}

# PIDs of processes running in the bottle (their WINEPREFIX is the bottle).
# One grep over every environ file: a pipeline per process took over 2 s with ~500 processes,
# and the monitor hook (refresh-displays.sh) calls this several times.
bottle_pids() {
    grep -lzxF "WINEPREFIX=$BOTTLE_DIR" /proc/[0-9]*/environ 2>/dev/null | sed 's|^/proc/||; s|/environ$||'
    return 0
}

# PID of the running Altium (X2.EXE) in the bottle, if any.
altium_pid() {
    local pid
    for pid in $(bottle_pids); do
        # argv[0] only: start.exe's command line also contains ...\X2.EXE
        if tr '\0' '\n' 2>/dev/null < "/proc/$pid/cmdline" | sed -n 1p | grep -qiE '\\X2\.EXE$'; then echo "$pid"; return; fi
    done
}

# PID of the bottle's wineserver, if it is running.
wineserver_pid() {
    local pid
    for pid in $(bottle_pids); do
        if tr '\0' '\n' 2>/dev/null < "/proc/$pid/cmdline" | sed -n 1p | grep -q '/wineserver$'; then echo "$pid"; return; fi
    done
}

# Run a command inside the Flatpak sandbox of the bottle's running Wine session, so it
# talks to the same wineserver. (A second `flatpak run` of Bottles 67 shares the session's
# /tmp, and so finds its wineserver, but a second wineserver on the same prefix would
# corrupt the registry, so this does not rely on it.) Prefers the wineserver's sandbox:
# processes of an earlier session can outlive their wineserver; if none is left, Wine
# starts a new wineserver there.
# `flatpak enter` starts with an empty environment, so the session's display variables are
# passed along (without DISPLAY, Wine falls back to a fake 1024x768 display).
in_running_bottle() {
    if [ "$BACKEND" = prefix ]; then
        # No sandbox: the wineserver of the prefix is found through WINEPREFIX.
        [ -n "$(bottle_pids)" ] || die "the bottle is not running"
        env HOME="$HOME" WINEPREFIX="$BOTTLE_DIR" "$@"
        return
    fi
    local pids pid instance vars
    pid=$(wineserver_pid)
    if [ -z "$pid" ]; then
        pids=$(bottle_pids)  # no `| head -1`: with pipefail its SIGPIPE would fail the caller
        pid=${pids%%$'\n'*}
    fi
    [ -n "$pid" ] || die "the bottle is not running"
    instance=$(sed -n 's/^instance-id=//p' "/proc/$pid/root/.flatpak-info" 2>/dev/null)
    [ -n "$instance" ] || die "cannot find the Flatpak sandbox of PID $pid"
    mapfile -t vars < <(tr '\0' '\n' 2>/dev/null < "/proc/$pid/environ" \
        | grep -E '^(DISPLAY|WAYLAND_DISPLAY|XAUTHORITY|XDG_RUNTIME_DIR)=')
    flatpak enter "$instance" env "${vars[@]}" HOME="$HOME" WINEPREFIX="$BOTTLE_DIR" "$@"
}

# wine_running ARGS...: run "wine ARGS" in the bottle's running session.
wine_running() { in_running_bottle WINEDEBUG="${WINEDEBUG:--all}" "$RUNNER_DIR/bin/wine" "$@"; }

# Windows PID (hex, as winedbg prints it) of X2.EXE in the running session.
altium_winpid() {
    wine_running winedbg --command "info proc" 2>/dev/null | awk '!found && tolower($0) ~ /x2\.exe/ {print $1; found = 1}'
}

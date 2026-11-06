#!/usr/bin/env bash
# Start Altium the way Bottles does, but with Wine/DXVK output in a log file.
#
#   scripts/debug-launch.sh [--bottle NAME] [--debug CHANNELS] [--log FILE] [--env NAME=VALUE]... [DOCUMENT]
#
#   --debug   WINEDEBUG channels (default: fixme-all,warn+seh,+timestamp)
#             e.g. +loaddll (which DLLs load, and where), +bcrypt, +exec,+winebrowser
#             (link opening), +process (programs started), +thread
#   --log     log file (default: <bottle>/altium-on-linux/logs/altium-<time>.log)
#   --env     extra environment variable, after the bottle's own (repeatable), e.g.
#             DISABLE_ALTIUM_PRESENT_WAIT=1 for a run without the present-wait layer
#   DOCUMENT  a file to open on start (host or Windows path), e.g. a .PcbDoc; handy
#             for reproducing a problem without clicking through the UI.
#
# Runs in the foreground until Altium exits. Combine with scripts/watchdog.sh when
# chasing memory leaks.
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

BOTTLE=Altium
CHANNELS=fixme-all,warn+seh,+timestamp
LOG=
DOC=
EXTRA_ENV=()
while [ $# -gt 0 ]; do
    case $1 in
        --bottle) BOTTLE=$2; shift 2 ;;
        --debug) CHANNELS=$2; shift 2 ;;
        --log) LOG=$2; shift 2 ;;
        --env) EXTRA_ENV+=("$2"); shift 2 ;;
        -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *) DOC=$1; shift ;;
    esac
done

load_bottle "$BOTTLE"
[ -z "$(bottle_pids)" ] || die "the bottle is already running; close Altium first"
mkdir -p "$STAGE/logs"
LOG=${LOG:-$STAGE/logs/altium-$(date +%Y%m%d-%H%M%S).log}
if [ "$BACKEND" = bottles ]; then
    case $LOG in "$HOME"/.var/app/$APP/*) ;; *) die "the log must be inside $HOME/.var/app/$APP (the sandbox cannot write elsewhere)";; esac
fi
if [ -n "$DOC" ] && [ -e "$DOC" ]; then DOC=$(winpath "$(realpath "$DOC")"); fi

# The environment Bottles starts Altium with, then the bottle's own variables.
launch_env "$CHANNELS"
env_args=("${LAUNCH_ENV[@]}" DXVK_LOG_LEVEL=info DXVK_LOG_PATH=none "${EXTRA_ENV[@]}")
sync_env=$(bottle_sync_env)

args=("C:\\Program Files\\Altium\\$ALTIUM_DIR\\X2.EXE")
[ -z "$DOC" ] || args+=("$DOC")

say "Starting Altium ($ALTIUM_DIR) with WINEDEBUG=$CHANNELS, ${sync_env:-server-side sync}"
say "Log: $LOG"
in_bottle_sandbox "$AD" env "${env_args[@]}" "$RUNNER_DIR/bin/wine" start /wait /d "C:\\Program Files\\Altium\\$ALTIUM_DIR" "${args[@]}" \
    > "$LOG" 2>&1 || true
say "Altium exited. Log: $LOG"

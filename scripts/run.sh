#!/usr/bin/env bash
# Start Altium Designer, its installer or another Windows program in the bottle, with the
# environment Bottles would use (scripts/lib.sh launch_env). Made for the prefix backend,
# which has no Bottles to start programs from; works for a Bottles bottle too.
#
#   scripts/run.sh altium [DOCUMENT]     start Altium Designer (optionally opening DOCUMENT)
#   scripts/run.sh exe FILE [ARGS...]    run a Windows program, e.g. the Altium installer
#   scripts/run.sh wine ARGS...          run wine itself (winecfg, regedit, ...)
#   scripts/run.sh stop                  end every program of the bottle
#
# Options before the command: --bottle NAME (a Bottles bottle other than Altium).
# Wine's output goes to <bottle>/altium-on-linux/logs/run-<command>.log (overwritten each
# time). Runs in the foreground until the program exits.
set -euo pipefail
# shellcheck source=scripts/lib.sh
. "$(dirname "$0")/lib.sh"

BOTTLE=Altium
while [ $# -gt 0 ]; do
    case $1 in
        --bottle) BOTTLE=$2; shift 2 ;;
        -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *) break ;;
    esac
done
[ $# -gt 0 ] || die "no command (altium, exe, wine or stop; see --help)"
CMD=$1; shift

load_bottle_dir "$BOTTLE"
mkdir -p "$STAGE/logs"
LOG=$STAGE/logs/run-$CMD.log
launch_env fixme-all
WINE=$RUNNER_DIR/bin/wine

case $CMD in
    altium)
        find_altium || die "Altium Designer is not installed in $BOTTLE_DIR (scripts/run.sh exe <installer>)"
        [ -z "$(altium_pid)" ] || die "Altium is already running"
        args=("C:\\Program Files\\Altium\\$ALTIUM_DIR\\X2.EXE")
        if [ $# -gt 0 ]; then
            doc=$1
            [ ! -e "$doc" ] || doc=$(winpath "$(realpath "$doc")")
            args+=("$doc")
        fi
        say "Starting Altium Designer ($ALTIUM_DIR); log: $LOG"
        in_bottle_sandbox "$AD" env "${LAUNCH_ENV[@]}" "$WINE" start /wait /d "C:\\Program Files\\Altium\\$ALTIUM_DIR" "${args[@]}" \
            > "$LOG" 2>&1
        ;;
    exe)
        [ $# -gt 0 ] || die "exe needs a file"
        file=$(realpath "$1"); shift
        [ -f "$file" ] || die "no such file: $file"
        say "Running $(basename "$file"); log: $LOG"
        # As Bottles' "Run Executable…": start /unix from the program's own folder (the
        # offline installer looks for its packages next to it).
        in_bottle_sandbox "$(dirname "$file")" env "${LAUNCH_ENV[@]}" "$WINE" start /wait /unix "$file" "$@" > "$LOG" 2>&1
        ;;
    wine)
        in_bottle_sandbox "$BOTTLE_DIR" env "${LAUNCH_ENV[@]}" "$WINE" "$@"
        ;;
    stop)
        [ -n "$(bottle_pids)" ] || { echo "The bottle is not running."; exit 0; }
        in_bottle_sandbox "$BOTTLE_DIR" env WINEPREFIX="$BOTTLE_DIR" "$RUNNER_DIR/bin/wineserver" -k
        ;;
    *) die "unknown command: $CMD (altium, exe, wine or stop)" ;;
esac

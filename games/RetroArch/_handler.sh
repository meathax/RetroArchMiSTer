#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Frontier discovers games/RetroArch/_handler.sh for CONF_STR name "RetroArch".
# exec preserves the daemon's child PID: no unmanaged emulator grandchildren.
set -euo pipefail
GAMEDIR="${FRONTIER_GAME_DIR:-/media/fat/games/RetroArch}"
CORE_FILE="${FRONTIER_CORE_FILE:-/tmp/CORENAME}"
[[ -d "$GAMEDIR" ]] || { echo '[RetroArch] Game directory missing' >&2; exit 72; }
cd "$GAMEDIR"
ACTIVE_CORE=""
if [[ -r "$CORE_FILE" ]]; then IFS= read -r ACTIVE_CORE < "$CORE_FILE" || true; fi
ACTIVE_CORE="${ACTIVE_CORE%$'\r'}"
# Per-family RBFs (one key game per family) are opened through an MRA whose
# <rbf> names the family RBF and whose <setname> names the FBNeo set. Main then
# reports the MRA setname as CORENAME and the RBF's own CONF_STR name as
# RBFNAME; every family RBF keeps CONF_STR name "RetroArch", so the
# [RetroArch] main=Mister_RetroArch handoff and this handler still apply.
RBF_FILE="${FRONTIER_RBF_FILE:-/tmp/RBFNAME}"
ACTIVE_RBF=""
if [[ -r "$RBF_FILE" ]]; then IFS= read -r ACTIVE_RBF < "$RBF_FILE" || true; fi
ACTIVE_RBF="${ACTIVE_RBF%$'\r'}"
MRA_SETNAME=""
if [[ "$ACTIVE_CORE" != RetroArch ]]; then
    [[ "$ACTIVE_RBF" == RetroArch && "$ACTIVE_CORE" =~ ^[a-z0-9_]{1,32}$ ]] || {
        echo '[RetroArch] Expected active core name RetroArch (or an MRA setname on a RetroArch RBF)' >&2
        exit 73
    }
    MRA_SETNAME="$ACTIVE_CORE"
fi
if [[ -f SOURCE_ONLY_NOT_BOOTABLE || -f STEP01_NOT_BOOTABLE ]]; then
    echo '[RetroArch] Source-only candidate. ARM runtime, reserved memory and RBF are not hardware-qualified.' >&2
    exit 78
fi
# Recover an interrupted settings transaction before configuration is required.
# Legacy bundles without the helper retain their normal startup path.
if [[ -f ./restore_defaults.sh ]]; then
    bash ./restore_defaults.sh --root "${GAMEDIR%/games/RetroArch}" --recover || exit 72
fi
[[ -x ./RetroArch && -f ./retroarch.cfg ]] || { echo '[RetroArch] Runtime binary or configuration missing' >&2; exit 72; }
# Explicit opt-in diagnostic bundle marker. Only MAME video is replaced;
# the source/default runtime and other cores retain their normal display.
if [[ -f MAME_SCREEN_DIAGNOSTICS ]]; then
    export FRONTIER_MAME_DIAG=1
    export FRONTIER_TIMING_REPORT=${FRONTIER_TIMING_REPORT:-$GAMEDIR/logs/timing.json}
elif [[ -f MAME_TIMING_ONLY ]]; then
    unset FRONTIER_MAME_DIAG
    export FRONTIER_TIMING_REPORT=${FRONTIER_TIMING_REPORT:-$GAMEDIR/logs/timing-clean.json}
fi
# Qualification-only opt-ins written and removed by tools/mister_session.py.
# Neither file is part of an end-user bundle.
if [[ -f QUALIFICATION_INPUT_SCRIPT.txt ]]; then
    export FRONTIER_INPUT_SCRIPT="$GAMEDIR/QUALIFICATION_INPUT_SCRIPT.txt"
fi
if [[ -f FRONTIER_DELTA_COPY ]]; then
    export FRONTIER_DELTA_COPY=1
fi
if [[ -f FRONTIER_SUBSYS_TIMERS ]]; then
    export FRONTIER_SUBSYS_TIMERS=1
    export FRONTIER_SUBSYS_REPORT="$GAMEDIR/logs/mame-subsystimers.json"
fi
# Scheduler weight only (SCHED_OTHER nice -10), never a real-time class.
PRIORITY=()
if [[ -f FRONTIER_PRIORITY ]]; then
    PRIORITY=(nice -n -10)
fi
if [[ -f FRONTIER_VIDEO_WORKER ]]; then
    export FRONTIER_VIDEO_WORKER=1
fi
# FPGA sound/video boards (not bit-exact audio; not hardware-qualified): opt-in
# marker files only. Unset keeps software sound and software rendering.
if [[ -f FRONTIER_SOUND_BOARDS ]]; then
    export FRONTIER_SOUND_BOARDS=1
fi
if [[ -f FRONTIER_VIDEO_BOARDS ]]; then
    export FRONTIER_VIDEO_BOARDS=1
fi
# Establish exclusive transport ownership before mutating any runtime state. A
# legacy Frontier observer may also discover this handler while the resident
# custom Main owns the core; that invocation must fail without rotating the live
# owner's logs or session report.
case "${FRONTIER_BACKEND:-}" in
mister-main)
    [[ "${FRONTIER_CUSTOM_MAIN:-}" == 1 ]] || {
        echo '[RetroArch] mister-main backend requires the resident Mister_RetroArch owner' >&2
        exit 74
    }
    [[ "${FRONTIER_MEM_FD:-}" =~ ^[0-9]+$ && -e "/proc/$$/fd/$FRONTIER_MEM_FD" ]] || {
        echo '[RetroArch] resident Main did not provide a valid inherited transport descriptor' >&2
        exit 74
    }
    ;;
mister-uio)
    [[ "${FRONTIER_ALLOW_UIO:-}" == 1 ]] || {
        echo '[RetroArch] direct handler launch is disabled; select RetroArch.rbf so Mister_RetroArch owns hps_io' >&2
        exit 74
    }
    if [[ -z "${FRONTIER_UIO:-}" ]]; then
        UIO_SYSFS_ROOT="${FRONTIER_UIO_SYSFS_ROOT:-/sys/class/uio}"
        UIO_DEV_ROOT="${FRONTIER_UIO_DEV_ROOT:-/dev}"
        UIO_MATCH=""
        for UIO_SYS in "$UIO_SYSFS_ROOT"/uio*; do
            [[ -d "$UIO_SYS" && -r "$UIO_SYS/name" && -r "$UIO_SYS/version" ]] || continue
            IFS= read -r UIO_NAME < "$UIO_SYS/name" || true
            IFS= read -r UIO_VERSION < "$UIO_SYS/version" || true
            UIO_NAME="${UIO_NAME%$'\r'}"
            UIO_VERSION="${UIO_VERSION%$'\r'}"
            if [[ "$UIO_NAME" == retroarch-frontier-v1 && "$UIO_VERSION" == 1-nocache-reserved ]]; then
                [[ -z "$UIO_MATCH" ]] || { echo '[RetroArch] Multiple matching Frontier UIO devices found' >&2; exit 74; }
                UIO_MATCH="${UIO_SYS##*/}"
            fi
        done
        [[ -n "$UIO_MATCH" ]] || {
            echo '[RetroArch] Verified Frontier UIO provider not found (retroarch-frontier-v1 / 1-nocache-reserved)' >&2
            exit 74
        }
        FRONTIER_UIO="$UIO_DEV_ROOT/$UIO_MATCH"
    fi
    export FRONTIER_UIO
    ;;
*)
    echo '[RetroArch] launch must come from the resident Mister_RetroArch main= wrapper' >&2
    exit 74
    ;;
esac
# One mkdir only when something is missing (a fork costs more than the checks on the A9).
MISSING_DIRS=()
for d in logs saves states system config/remaps playlists info roms \
    saves/FBNeo states/FBNeo-Frontier21-6bb3167a-musashi system/fbneo \
    saves/DOSBox-pure states/DOSBox-pure-Frontier18 system/DOSBox-pure; do
    [[ -d "$d" ]] || MISSING_DIRS+=("$d")
done
[[ ${#MISSING_DIRS[@]} -eq 0 ]] || mkdir -p "${MISSING_DIRS[@]}"
[[ ! -f logs/retroarch.log ]] || mv -f logs/retroarch.log logs/retroarch.log.prev
# Runtime log target: resident Main points FRONTIER_LOG_DIR at tmpfs for the
# session (no SD writes while playing) and copies a bounded tail back to
# logs/retroarch.log on exit. Any other value keeps the SD path.
RA_LOG=logs/retroarch.log
if [[ "${FRONTIER_LOG_DIR:-}" == /tmp/retroarch-frontier && -d "$FRONTIER_LOG_DIR" ]]; then
    RA_LOG="$FRONTIER_LOG_DIR/retroarch.log"
fi
# Write counters from the real mapping at shutdown, before it is unmapped.
# Preserve the previous run and do not label target records as mock playback.
if [[ -z "${FRONTIER_REPORT:-}" ]]; then
    [[ ! -f logs/session.json ]] || mv -f logs/session.json logs/session.json.prev
    export FRONTIER_REPORT="$GAMEDIR/logs/session.json"
fi
# Payload selection + preflight (docs/LAUNCH_FORMAT.md): an .ra payload named by
# an MGL (FRONTIER_LAUNCH_XML), an MRA setname, or launch_game.txt. The library
# checks core/content/BIOS/config/CRC, writes the machine-readable result file
# custom Main shows on the OSD, and exits non-zero on failure so Main returns to
# menu.rbf. It never silently falls back to RGUI when a payload was requested.
# MRA: an explicit RetroArch core remark selects MAME 2003-Plus or FBNeo.
# Without it, MAME is selected when the set exists in games/mame2003plus
# (including clones/), roms/MAME2003 or the legacy roms paths. The frontend
# still checks the RBF's compiled board mask and falls back to software video if
# the family board is absent or faults; FRONTIER_NO_VIDEO_BOARDS forces software.
[[ -r ./launch_payload.sh ]] || { echo '[RetroArch] launch_payload.sh missing' >&2; exit 72; }
# shellcheck source=launch_payload.sh
source ./launch_payload.sh
lp_select
if [[ "$LP_MODE" == game ]]; then
    if [[ "$LP_SOURCE" == mra ]]; then
        if [[ -f FRONTIER_NO_VIDEO_BOARDS ]]; then
            unset FRONTIER_VIDEO_BOARDS
        else
            export FRONTIER_VIDEO_BOARDS=1
        fi
    fi
    # MiSTer OSD Menus > Reset MAME/RetroArch Settings: Main stopped this game
    # cleanly and relaunched us; restore its defaults before RetroArch starts.
    if [[ -n "${FRONTIER_GAME_RESET:-}" && -f ./reset_game_settings.sh ]]; then
        RESET_SET=${LP_CONTENT##*/}; RESET_SET=${RESET_SET%.*}
        bash ./reset_game_settings.sh --root "${GAMEDIR%/games/RetroArch}" \
            --kind "$FRONTIER_GAME_RESET" --set "$RESET_SET" ||
            echo '[RetroArch] game settings reset failed; settings unchanged' >&2
    fi
    unset FRONTIER_GAME_RESET
    # Optional OSD core options / per-game settings (docs/OSD_OPTIONS.md); opt-in marker.
    if [[ -f FRONTIER_OSD_OPTIONS && -r ./osd_options_hook.sh ]]; then
        # shellcheck source=osd_options_hook.sh
        source ./osd_options_hook.sh
        osd_options_prepare
    fi
    exec ${PRIORITY[@]+"${PRIORITY[@]}"} "$GAMEDIR/RetroArch" "${LP_ARGS[@]}" >> "$RA_LOG" 2>&1
fi
# Default: RGUI prebound favourites (single-confirm launch, no startup scan).
exec ${PRIORITY[@]+"${PRIORITY[@]}"} "$GAMEDIR/RetroArch" --config "$GAMEDIR/retroarch.cfg" --menu >> "$RA_LOG" 2>&1

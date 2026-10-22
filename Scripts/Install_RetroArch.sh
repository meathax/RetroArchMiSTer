#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# The one RetroArch Frontier setup script. Run it from the MiSTer Scripts menu
# after copying READY to the SD card. It prepares the MiSTer to launch
# _Other/RetroArch.rbf and _Other/RetroForge.rbf: it registers both custom Main selectors
# in MiSTer.ini (with a timestamped backup) and removes older setup scripts:
#
#   [RetroArch]
#   main=Mister_RetroArch
#
#   [RetroForge]
#   main=Mister_RetroForge
#
# Both cores then use the MiSTer.ini video settings for HDMI. Display output
# (HDMI or 15 kHz CRT) is one shared choice in games/RetroArch/config/frontier/
# display.cfg; with no file it is HDMI. The installer never guesses CRT. It
# removes display lines older installers put in [RetroForge] (one was a 15 kHz
# mode: "no signal" on HDMI). To switch without a picture, run from a terminal
# (or copy this script to a name ending in _crt.sh or _hdmi.sh and run that
# copy from the Scripts menu):
#
#   Install_RetroArch.sh crt     # 15 kHz CRT on the analog output
#   Install_RetroArch.sh hdmi    # HDMI (analog output stays dark)
#
# "Install_RetroArch.sh uninstall" removes only the two main= selectors.
#
# Before registering anything the installer checks that stock Main supports
# main=, that the copied sidecars/RBFs/runtime match READY_MANIFEST.json, and
# that both sidecars load on this MiSTer Linux. If a check fails it removes the
# two selectors (exit 70): a sidecar that cannot run would leave HDMI with no
# signal after the RBF loads. Each launch writes
# games/RetroArch/logs/retroarch-launch.log or retroforge-launch.log.
set -eu

ROOT=${FRONTIER_MISTER_ROOT:-/media/fat}
INI=${FRONTIER_MISTER_INI:-}
ACTION=${1:-install}
PREFLIGHT=""
DISPLAY_CHOICE=""
case "${0##*/}" in
    *_[Cc][Rr][Tt].sh) DISPLAY_CHOICE=crt15 ;;
    *_[Hh][Dd][Mm][Ii].sh) DISPLAY_CHOICE=hdmi ;;
esac
case "$ACTION" in
    install|--install) ACTION=install ;;
    crt|--crt) ACTION=install; DISPLAY_CHOICE=crt15 ;;
    hdmi|--hdmi) ACTION=install; DISPLAY_CHOICE=hdmi ;;
    uninstall|--uninstall|remove|--remove) ACTION=uninstall ;;
    -h|--help) echo "usage: Install_RetroArch.sh [install|crt|hdmi|uninstall]"; exit 0 ;;
    *) echo "Unknown action: $ACTION (use install, crt, hdmi or uninstall)" >&2; exit 64 ;;
esac

if [ -z "$INI" ]; then
    if [ -e "$ROOT/MiSTer.ini" ] || [ ! -e "$ROOT/mister.ini" ]; then
        INI="$ROOT/MiSTer.ini"
    else
        INI="$ROOT/mister.ini"
    fi
fi
[ ! -L "$INI" ] && [ -f "$INI" ] || {
    echo "MiSTer.ini is missing or unsafe: $INI" >&2; exit 65;
}

RETROFORGE=0
PROFILE=auto
PROFILE_FILE="$ROOT/games/RetroArch/package-profile"
if [ -e "$PROFILE_FILE" ] || [ -L "$PROFILE_FILE" ]; then
    [ ! -L "$PROFILE_FILE" ] && [ -f "$PROFILE_FILE" ] || exit 65
    PROFILE=$(cat "$PROFILE_FILE")
    case "$PROFILE" in retroarch|retroforge) ;; *) echo "Invalid package profile" >&2; exit 65;; esac
fi
if [ "$ACTION" = install ]; then
    for file in Mister_RetroArch _Other/RetroArch.rbf games/RetroArch/RetroArch \
        games/RetroArch/_handler.sh games/RetroArch/cores/mame2003_plus_libretro.so
    do
        [ ! -L "$ROOT/$file" ] && [ -s "$ROOT/$file" ] || {
            echo "Copy the READY package first; missing or unsafe: $file" >&2; exit 67;
        }
    done
    for marker in SOURCE_ONLY_NOT_BOOTABLE STEP01_NOT_BOOTABLE QUALIFICATION_ONLY_NOT_RELEASE; do
        [ ! -e "$ROOT/games/RetroArch/$marker" ] || {
            echo "Qualification guard prevents installation: $marker" >&2; exit 78;
        }
    done
    if [ "$PROFILE" != retroarch ] && { [ "$PROFILE" = retroforge ] || [ -e "$ROOT/Mister_RetroForge" ] || [ -e "$ROOT/_Other/RetroForge.rbf" ]; }; then
        for file in Mister_RetroForge _Other/RetroForge.rbf; do
            [ ! -L "$ROOT/$file" ] && [ -s "$ROOT/$file" ] || {
                echo "Incomplete RetroForge payload: $file" >&2; exit 67;
            }
        done
        RETROFORGE=1
    fi
    # Preflight. After stock Main loads one of these RBFs it hands over to the
    # sidecar named by main=; until that sidecar sets the video mode nothing
    # drives HDMI, so a sidecar that cannot run means "no signal" with no way
    # back except a power cycle. Never register main= unless it can run.
    STOCK_MAIN="$ROOT/MiSTer"
    if [ ! -s "$STOCK_MAIN" ] || ! grep -a -q 'core requires exec' "$STOCK_MAIN"; then
        PREFLIGHT="stock MiSTer Main is missing or too old for main= (update MiSTer first)"
    fi
    # Copied bytes must match the package (a truncated or altered copy of a
    # sidecar or RBF fails the same way). The extensionless executables are the
    # files an FTP/sync tool in text ("ASCII") mode silently rewrites, which
    # leaves HDMI with no signal; the package carries a .elf copy of each that
    # no tool treats as text, so a damaged one is restored from it.
    MANIFEST="$ROOT/READY_MANIFEST.json"
    manifest_bad() {
        awk -v root="$ROOT" '
            /"path":/ { p=$0; sub(/^[^:]*: *"/, "", p); sub(/".*$/, "", p); next }
            /"sha256":/ && p != "" {
                s=$0; sub(/^[^:]*: *"/, "", s); sub(/".*$/, "", s)
                if (p ~ /^(Mister_RetroArch|Mister_RetroForge|_Other\/RetroArch\.rbf|_Other\/RetroForge\.rbf|games\/RetroArch\/RetroArch|games\/RetroArch\/_handler\.sh|games\/RetroArch\/cores\/mame2003_plus_libretro\.so|games\/RetroArch\/\.mamefrontend\/retroforge|games\/RetroArch\/\.payload\/[A-Za-z_]+\.elf)$/)
                    print s "  " root "/" p
                p=""
            }' "$MANIFEST" | sha256sum -c 2>/dev/null | grep -v ': OK$' || true
    }
    if [ -z "$PREFLIGHT" ] && [ -f "$MANIFEST" ] && [ ! -L "$MANIFEST" ]; then
        BAD=$(manifest_bad)
        if [ -n "$BAD" ]; then
            for file in Mister_RetroArch Mister_RetroForge games/RetroArch/RetroArch games/RetroArch/.mamefrontend/retroforge; do
                SAFE="$ROOT/games/RetroArch/.payload/${file##*/}.elf"
                echo "$BAD" | grep -q "/$file: " || continue
                echo "$BAD" | grep -q "/${SAFE#$ROOT/}: " && continue
                [ ! -L "$SAFE" ] && [ -s "$SAFE" ] && [ ! -L "$ROOT/$file" ] || continue
                cp -f "$SAFE" "$ROOT/$file.new" && mv -f "$ROOT/$file.new" "$ROOT/$file" \
                    && echo "Restored $file from the binary-safe copy (it was altered in transfer; copy READY in binary mode)."
            done
            BAD=$(manifest_bad)
        fi
        [ -z "$BAD" ] || PREFLIGHT="copied files do not match the package (copy READY again in binary mode: an FTP/sync tool in text mode corrupts the extensionless programs): $(echo "$BAD" | sed "s#$ROOT/##" | tr '\n' ' ')"
    fi
    # The sidecars must load on this MiSTer Linux (libraries, glibc symbols).
    LDSO=${FRONTIER_LDSO:-/lib/ld-linux-armhf.so.3}
    if [ -z "$PREFLIGHT" ] && [ -x "$LDSO" ]; then
        for file in Mister_RetroArch Mister_RetroForge; do
            [ "$file" != Mister_RetroForge ] || [ "$RETROFORGE" -eq 1 ] || continue
            [ -e "$ROOT/$file" ] || continue
            if ! OUT=$("$LDSO" --list "$ROOT/$file" 2>&1) || echo "$OUT" | grep -q 'not found'; then
                PREFLIGHT="$file cannot run on this MiSTer Linux: $(echo "$OUT" | grep 'not found' | head -n 3 | tr '\n' ' ')"
                break
            fi
        done
    fi
    if [ -n "$PREFLIGHT" ]; then
        echo "Install stopped: $PREFLIGHT" >&2
        echo "Removing the RetroArch/RetroForge main= selectors so these RBFs cannot hand over to a sidecar that cannot run." >&2
        ACTION=uninstall
    fi
fi

if [ "$ACTION" = install ]; then
    frontend_layout_migrate() { :; }
    frontend_layout_restore() { :; }
fi
if [ "$ACTION" = install ] && [ "$RETROFORGE" -eq 1 ]; then
    # The helper moves a legacy _Other/.mamefrontend; without one there is nothing to move.
    MIGRATION="$ROOT/games/RetroArch/migrate_frontend.sh"
    if [ ! -L "$MIGRATION" ] && [ -s "$MIGRATION" ]; then
        . "$MIGRATION"
    elif [ -e "$ROOT/_Other/.mamefrontend" ] || [ -L "$ROOT/_Other/.mamefrontend" ]; then
        echo "Copy the READY package first; missing or unsafe: games/RetroArch/migrate_frontend.sh" >&2; exit 67
    else
        frontend_layout_migrate() { :; }
        frontend_layout_restore() { :; }
    fi
fi

# One lock for every MiSTer.ini writer; never expose a partially written INI.
LOCK="$INI.retroarch-lock"
mkdir "$LOCK" 2>/dev/null || { echo "MiSTer.ini setup is already running: $LOCK" >&2; exit 75; }
TMP=""
COMMITTED=0
LAYOUT_BACKUP="$ROOT/games/RetroArch/.layout-backups/$(date -u +%Y%m%dT%H%M%SZ).$$"
cleanup() {
    rc=$?
    trap - 0 HUP INT TERM
    if [ "$ACTION" = install ] && [ "$COMMITTED" -eq 0 ]; then
        frontend_layout_restore "$LAYOUT_BACKUP" || rc=$?
    fi
    [ -z "$TMP" ] || rm -f "$TMP"
    rmdir "$LOCK" 2>/dev/null || true
    exit "$rc"
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
if [ "$ACTION" = install ]; then
    frontend_layout_migrate "$LAYOUT_BACKUP"
    if [ -d "$LAYOUT_BACKUP" ]; then cp -p "$INI" "$LAYOUT_BACKUP/MiSTer.ini"; fi
fi
TMP=$(mktemp "$INI.retroarch-new.XXXXXX")

# One AWK pass handles both sections, duplicate sections/keys, case, BOM and CRLF.
# The sidecars choose the display themselves; only the selectors are written.
awk -v action="$ACTION" -v retroforge="$RETROFORGE" '
function emit(value) { printf "%s%s\n", value, cr }
function selector() {
    installed[target]=1
    if (action != "install" || (target == "RetroForge" && !retroforge)) return
    emit("main=Mister_" target)
}
{
    line=$0
    if (NR == 1 && line ~ /\r$/) cr="\r"
    sub(/\r$/, "", line)
    header=line
    sub(/^\357\273\277/, "", header)
    if (header ~ /^[ \t]*\[[^]]+\][ \t]*([;#].*)?$/) {
        if (target && !installed[target]) selector()
        sub(/^[ \t]*\[/, "", header)
        sub(/\].*$/, "", header)
        gsub(/^[ \t]+|[ \t]+$/, "", header)
        header=tolower(header)
        target=(header == "retroforge" ? "RetroForge" : header == "retroarch" ? "RetroArch" : "")
        if (target) seen[target]=1
    }
    if (target && tolower(line) ~ /^[ \t]*main[ \t]*=/) {
        if (!installed[target]) selector()
        next
    }
    # Drop every display line earlier installers wrote (15 kHz, 640x480 and
    # 1080p modes: the 15 kHz one is "no signal" on HDMI); settings the user
    # added are kept.
    if (action == "install" && target == "RetroForge") {
        key=tolower(line); gsub(/[ \t]/, "", key)
        if (key == "video_mode=320,15,30,35,240,4,4,14,6294,-hsync,-vsync" ||
            key == "video_mode=640,16,96,48,480,10,2,33,25175,-hsync,-vsync" ||
            key == "video_mode=1920,88,44,148,1080,4,5,36,148500,+hsync,+vsync" ||
            key == "vga_scaler=1" || key == "forced_scandoubler=0" || key == "fb_size=1") next
    }
    print $0
}
END {
    if (target && !installed[target]) selector()
    if (action != "install") exit
    for (i=1; i<=2; i++) {
        target=(i == 1 ? "RetroArch" : "RetroForge")
        if (target == "RetroForge" && !retroforge) continue
        if (!seen[target]) {
            if (NR > 0 || i > 1) emit("")
            emit("[" target "]")
            selector()
        }
    }
}' "$INI" > "$TMP"

if [ "$ACTION" = install ]; then
    chmod 755 "$ROOT/Mister_RetroArch" "$ROOT/games/RetroArch/RetroArch" "$ROOT/games/RetroArch/_handler.sh"
    [ "$RETROFORGE" -eq 0 ] || chmod 755 "$ROOT/Mister_RetroForge"
    # Older releases shipped several setup/launcher scripts; this one replaces them all.
    for old in Install-RetroArch.sh RetroArch.sh RetroArch_Setup.sh RetroForge.sh RetroForge_Setup.sh; do
        if [ -f "$ROOT/Scripts/$old" ] && [ ! -L "$ROOT/Scripts/$old" ]; then rm -f "$ROOT/Scripts/$old"; fi
    done
fi

# Shared display choice: only an explicit crt/hdmi request changes it, and it
# rewrites only output=. There is no auto-detect: analog settings such as
# composite_sync often sit alongside an HDMI TV, and guessing CRT there gives
# "no signal" on HDMI. The default (no file) is HDMI.
if [ "$ACTION" = install ]; then
    DISPLAY_CFG="$ROOT/games/RetroArch/config/frontier/display.cfg"
    if [ -f "$DISPLAY_CFG" ] && [ -z "$DISPLAY_CHOICE" ] && grep -q '^output=crt15' "$DISPLAY_CFG"; then
        echo "Display output is 15 kHz CRT. On an HDMI TV run: Install_RetroArch.sh hdmi"
    fi
    if [ -n "$DISPLAY_CHOICE" ]; then
        [ ! -L "$DISPLAY_CFG" ] && { [ ! -e "$DISPLAY_CFG" ] || [ -f "$DISPLAY_CFG" ]; } || {
            echo "display.cfg is unsafe: $DISPLAY_CFG" >&2; exit 65;
        }
        mkdir -p "${DISPLAY_CFG%/*}"
        DISPLAY_TMP=$(mktemp "$DISPLAY_CFG.new.XXXXXX")
        if [ -f "$DISPLAY_CFG" ] && grep -q '^version=' "$DISPLAY_CFG" && grep -q '^output=' "$DISPLAY_CFG"; then
            sed "s/^output=.*/output=$DISPLAY_CHOICE/" "$DISPLAY_CFG" > "$DISPLAY_TMP"
        else
            printf 'version=2\noutput=%s\ncrt_height=fit\ncrt_deflicker=off\ncrt_overscan_x=0\ncrt_overscan_y=0\nhdmi_scale=aspect_integer\n' \
                "$DISPLAY_CHOICE" > "$DISPLAY_TMP"
        fi
        mv -f "$DISPLAY_TMP" "$DISPLAY_CFG"
        echo "Display output: $DISPLAY_CHOICE"
    fi
fi

if cmp -s "$INI" "$TMP"; then
    COMMITTED=1
    echo "RetroArch package is already configured ($ACTION; RetroForge=$RETROFORGE)."
    [ -z "$PREFLIGHT" ] || exit 70
    exit 0
fi
chmod "$(stat -c '%a' "$INI" 2>/dev/null || echo 644)" "$TMP"
BACKUP="$INI.retroarch-backup.$(date -u +%Y%m%dT%H%M%SZ).$$"
cp -p "$INI" "$BACKUP"
mv -f "$TMP" "$INI"
TMP=""
COMMITTED=1
echo "RetroArch package $ACTION complete (RetroForge=$RETROFORGE). Backup: $BACKUP"
[ -z "$PREFLIGHT" ] || { echo "Install stopped: $PREFLIGHT" >&2; exit 70; }

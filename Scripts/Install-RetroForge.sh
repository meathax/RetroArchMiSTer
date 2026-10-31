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
# Both cores drive HDMI (MiSTer.ini video settings) and the analog CRT output at
# the same time, so there is no display choice to make or switch. The installer
# removes display lines older installers put in [RetroForge] (one was a 15 kHz
# mode: "no signal" on HDMI) and never touches games/RetroArch/config/frontier/
# display.cfg. Old "crt"/"hdmi" arguments are accepted as a plain install.
#
# "Install-RetroForge.sh uninstall" removes only the two main= selectors.
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
EXPLICIT_INI=$INI
ACTION=${1:-install}
CHECK_ONLY=0
PREFLIGHT=""
show_error() {
    MESSAGE="RetroForge installation FAILED. Do not launch RetroForge yet.

$1

Fix the error above, then rerun Scripts/Install-RetroForge.sh. For missing or damaged package files, rerun Downloader with file_checking = verify_integrity and the RetroForge database enabled first. Check SD-card free space and write access.

An RBF without its main= selector can show an empty RetroForge OSD; rebooting will not repair the installation."
    printf '%s\n' "$MESSAGE" >&2
    if [ -t 0 ] && [ -t 1 ] && command -v dialog >/dev/null 2>&1; then
        dialog --clear --title "RetroForge installation failed" --msgbox "$MESSAGE" 22 76 || true
    fi
}
case "$ACTION" in
    # crt/hdmi switched a display choice in older releases; both outputs now run together.
    install|--install|crt|--crt|hdmi|--hdmi) ACTION=install ;;
    verify|--verify) ACTION=install; CHECK_ONLY=1 ;;
    uninstall|--uninstall|remove|--remove) ACTION=uninstall ;;
    -h|--help) echo "usage: Install-RetroForge.sh [install|verify|uninstall]"; exit 0 ;;
    *) echo "Unknown action: $ACTION (use install or uninstall)" >&2; exit 64 ;;
esac

if [ -z "$INI" ]; then
    if [ -e "$ROOT/MiSTer.ini" ] || [ ! -e "$ROOT/mister.ini" ]; then
        INI="$ROOT/MiSTer.ini"
    else
        INI="$ROOT/mister.ini"
    fi
fi
[ ! -L "$INI" ] && [ -f "$INI" ] || {
    show_error "MiSTer.ini is missing or unsafe: $INI"; exit 65;
}
PRIMARY_INI=$INI

# Hold the same lock through repairs, unpacking, migration and selector commit.
# A leftover lock is deliberately not stolen: another installer may still own it.
LOCK="$ROOT/.retroforge-install-lock"
if [ -e "$INI.retroarch-lock" ] || ! mkdir "$LOCK" 2>/dev/null; then
    show_error "MiSTer.ini setup is already running or its lock cannot be created: $LOCK. After an interrupted run, reboot and confirm no installer is running before removing a leftover lock."
    exit 75
fi
TMP=""
COMMITTED=0
LAYOUT_BACKUP="$ROOT/games/RetroArch/.layout-backups/$(date -u +%Y%m%dT%H%M%SZ).$$"
frontend_layout_restore() { :; }
cleanup() {
    rc=$?
    trap - 0 HUP INT TERM
    if [ "$ACTION" = install ] && [ "$COMMITTED" -eq 0 ]; then
        frontend_layout_restore "$LAYOUT_BACKUP" || rc=$?
    fi
    [ -z "$TMP" ] || rm -f "$TMP"
    rm -f "$LOCK/checksums" "$LOCK/verify.log"
    rmdir "$LOCK" 2>/dev/null || true
    if [ "$rc" -ne 0 ]; then
        show_error "${PREFLIGHT:-The configuration was not confirmed (exit $rc). See the preceding error. INI: $INI}"
    fi
    exit "$rc"
}
trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

safe_path() {
    [ ! -L "$ROOT" ] || return 1
    part=$1
    while [ "$part" != "$ROOT" ] && [ "$part" != / ] && [ -n "$part" ]; do
        [ ! -L "$part" ] || return 1
        part=${part%/*}
    done
}
for directory in "$ROOT" "$ROOT/games/RetroArch" "$ROOT/_Other" "$ROOT/Scripts"; do
    safe_path "$directory" || { echo "Unsafe linked installation path: $directory" >&2; exit 65; }
done

# Main can select any of these alternate files. Configure the same selectors
# in each one, rather than reporting success for an unused default INI.
check_ini_paths() {
    for candidate in "$PRIMARY_INI" "$ROOT"/[Mm][Ii][Ss][Tt][Ee][Rr]_*.[Ii][Nn][Ii]; do
        [ -z "$EXPLICIT_INI" ] || [ "$candidate" = "$PRIMARY_INI" ] || continue
        [ -e "$candidate" ] || [ -L "$candidate" ] || continue
        if ! safe_path "$candidate" || [ ! -f "$candidate" ]; then
            PREFLIGHT="Unsafe INI file: $candidate. No launch selectors were installed."
            exit 65
        fi
    done
}
check_ini_paths

RETROFORGE=0
RETROFORGE_CRT=0
[ ! -e "$ROOT/_Other/RetroForge CRT.rbf" ] || RETROFORGE_CRT=1
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
            PREFLIGHT="Incomplete package: missing or unsafe $file. Rerun Downloader successfully, then rerun Install-RetroForge.sh.";
        }
    done
    for marker in SOURCE_ONLY_NOT_BOOTABLE STEP01_NOT_BOOTABLE QUALIFICATION_ONLY_NOT_RELEASE; do
        [ ! -e "$ROOT/games/RetroArch/$marker" ] || {
            echo "Qualification guard prevents installation: $marker" >&2; exit 78;
        }
    done
    if [ "$PROFILE" != retroarch ] && { [ "$PROFILE" = retroforge ] || [ -e "$ROOT/Mister_RetroForge" ] || [ -e "$ROOT/_Other/RetroForge.rbf" ] || { [ -f "$ROOT/READY_MANIFEST.json" ] && grep -q '"path":[[:space:]]*"_Other/RetroForge.rbf"' "$ROOT/READY_MANIFEST.json"; }; }; then
        for file in Mister_RetroForge _Other/RetroForge.rbf; do
            [ ! -L "$ROOT/$file" ] && [ -s "$ROOT/$file" ] || {
                PREFLIGHT="Incomplete RetroForge payload: $file. Rerun Downloader successfully, then rerun Install-RetroForge.sh.";
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
    MANIFEST=${FRONTIER_INSTALL_CHECKSUMS:-"$ROOT/READY_MANIFEST.json"}
    SUMFILE=0
    [ -z "${FRONTIER_INSTALL_CHECKSUMS:-}" ] || SUMFILE=1
    manifest_bad() {
        while read -r expected file; do
            if ! safe_path "$ROOT/$file" || [ ! -f "$ROOT/$file" ]; then
                echo "$file: missing or unsafe"
                continue
            fi
            actual=$(sha256sum "$ROOT/$file") || { echo "$file: read failed"; continue; }
            actual=${actual%% *}
            [ "$actual" = "$expected" ] || echo "$file: expected $expected; received $actual"
        done < "$LOCK/checksums"
    }
    if [ -z "$PREFLIGHT" ]; then
        if [ ! -s "$MANIFEST" ] || [ -L "$MANIFEST" ]; then
            PREFLIGHT="READY_MANIFEST.json is missing, empty or unsafe; rerun Downloader with the RetroForge database enabled, then rerun this installer"
        # The package writer emits one path/hash property per line. Reject
        # unsupported formatting, omitted critical rows and invalid/duplicate hashes.
        elif ! awk -v rf="$RETROFORGE" -v crt="$RETROFORGE_CRT" -v sums="$SUMFILE" '
            BEGIN {
                n=split("Mister_RetroArch _Other/RetroArch.rbf games/RetroArch/RetroArch games/RetroArch/_handler.sh games/RetroArch/cores/mame2003_plus_libretro.so", a, " ")
                for (i=1;i<=n;i++) required[a[i]]=1
                if (rf) { required["Mister_RetroForge"]=1; required["_Other/RetroForge.rbf"]=1; required["games/RetroArch/.mamefrontend/retroforge"]=1 }
                if (rf && crt) required["_Other/RetroForge CRT.rbf"]=1
            }
            function record(p,s) {
                if ((p in required) || p ~ /^games\/RetroArch\/\.payload\/[A-Za-z_]+\.elf$/ || p ~ /^games\/RetroArch\/[A-Za-z_]+\.sh$/ || p == "_Arcade/cores/RetroArch.rbf") {
                    if (seen[p]++ || length(s)!=64 || s ~ /[^0-9a-f]/) bad=1
                    print s "  " p
                }
            }
            sums { record($2,$1); next }
            /"path":/ { p=$0; sub(/^[^:]*: *"/, "", p); sub(/".*$/, "", p); next }
            /"sha256":/ && p != "" {
                s=$0; sub(/^[^:]*: *"/, "", s); sub(/".*$/, "", s)
                record(p,s); p=""
            }
            NF { last=$0 }
            END { for (p in required) if (!seen[p]) bad=1; if (!sums && last !~ /^}[\r ]*$/) bad=1; exit bad }
        ' "$MANIFEST" > "$LOCK/checksums"; then
            PREFLIGHT="READY_MANIFEST.json is incomplete or unsupported; rerun Downloader to obtain a complete matching package"
        fi
    fi
    if [ -z "$PREFLIGHT" ]; then
        BAD=$(manifest_bad)
        if [ -n "$BAD" ] && [ "$CHECK_ONLY" -eq 0 ]; then
            for file in Mister_RetroArch Mister_RetroForge games/RetroArch/RetroArch games/RetroArch/.mamefrontend/retroforge; do
                SAFE="$ROOT/games/RetroArch/.payload/${file##*/}.elf"
                echo "$BAD" | grep -F -q "$file: " || continue
                safe_path "$SAFE" && safe_path "$ROOT/$file" || continue
                expected=$(awk -v p="$file" '$2==p {print $1}' "$LOCK/checksums")
                backup_hash=$(awk -v p="${SAFE#$ROOT/}" '$2==p {print $1}' "$LOCK/checksums")
                [ -n "$expected" ] && [ "$expected" = "$backup_hash" ] && [ -s "$SAFE" ] || continue
                actual=$(sha256sum "$SAFE") || continue
                [ "${actual%% *}" = "$expected" ] || continue
                TMP=$(mktemp "$ROOT/$file.repair.XXXXXX")
                if cp "$SAFE" "$TMP" && actual=$(sha256sum "$TMP") && [ "${actual%% *}" = "$expected" ]; then
                    mv -f "$TMP" "$ROOT/$file"
                    TMP=""
                    echo "Restored $file from its verified binary-safe copy."
                else
                    rm -f "$TMP"; TMP=""
                fi
            done
            BAD=$(manifest_bad)
        fi
        [ -z "$BAD" ] || PREFLIGHT="copied files do not match the package:
$BAD
Rerun Downloader with the RetroForge database enabled, wait for successful completion, then rerun Install-RetroForge.sh. For damaged files, set file_checking = verify_integrity under [MiSTer] in /media/fat/downloader.ini before rerunning Downloader. Check download filters and free SD-card space. For manual copies, replace the complete READY package in binary mode. Do not edit checksums or mix releases."
    fi
    # The sidecars must load on this MiSTer Linux (libraries, glibc symbols).
    LDSO=${FRONTIER_LDSO:-/lib/ld-linux-armhf.so.3}
    if [ -z "$PREFLIGHT" ] && [ ! -x "$LDSO" ]; then
        PREFLIGHT="ARM runtime loader is missing: $LDSO; update MiSTer Linux before installing"
    fi
    if [ -z "$PREFLIGHT" ]; then
        for file in Mister_RetroArch Mister_RetroForge games/RetroArch/RetroArch games/RetroArch/.mamefrontend/retroforge games/RetroArch/cores/mame2003_plus_libretro.so; do
            [ "$file" != Mister_RetroForge ] || [ "$RETROFORGE" -eq 1 ] || continue
            [ "$file" != games/RetroArch/.mamefrontend/retroforge ] || [ "$RETROFORGE" -eq 1 ] || continue
            [ -e "$ROOT/$file" ] || continue
            if ! OUT=$("$LDSO" --list "$ROOT/$file" 2>&1) || echo "$OUT" | grep -q 'not found'; then
                PREFLIGHT="$file cannot run on this MiSTer Linux: $(echo "$OUT" | head -n 6 | tr '\n' ' ')"
                break
            fi
        done
    fi
    if [ "$CHECK_ONLY" -eq 1 ]; then
        [ -z "$PREFLIGHT" ] || { printf '%s\n' "$PREFLIGHT" >&2; exit 70; }
        echo "RetroForge installation integrity and ARM dependencies verified. Physical boot is a separate check."
        exit 0
    fi
    if [ -n "$PREFLIGHT" ]; then
        echo "Install stopped: $PREFLIGHT" >&2
        if safe_path "$ROOT/games/RetroArch/logs" && mkdir -p "$ROOT/games/RetroArch/logs"; then
            LOG="$ROOT/games/RetroArch/logs/retroforge-install.log"
            if [ ! -L "$LOG" ]; then printf '%s\n' "$PREFLIGHT" > "$LOG" || true; fi
        fi
        echo "Removing the RetroArch/RetroForge main= selectors so these RBFs cannot hand over to a sidecar that cannot run." >&2
        ACTION=uninstall
    fi
fi

want_mras() {
    case "${FRONTIER_INSTALL_MRAS:-ask}" in
        yes) return 0 ;;
        no) return 1 ;;
        ask) ;;
        *) PREFLIGHT="Invalid FRONTIER_INSTALL_MRAS value (use ask, yes or no)."; exit 64 ;;
    esac
    if [ -t 0 ] && [ -t 1 ] && command -v dialog >/dev/null 2>&1; then
        if dialog --clear --title "RetroForge: optional MRA files" --defaultno \
            --yes-label "Yes" --no-label "No" --yesno \
            "Install the optional MRA game launchers now?\n\nYou can also install them later in RetroForge Options.\n\nController: D-pad Left/Right selects Yes or No; the confirm button accepts; Back skips." 15 72; then
            return 0
        else
            choice_status=$?
            case "$choice_status" in 1|255) ;; *) echo "MRA menu unavailable (exit $choice_status); skipping optional files." >&2 ;; esac
            return 1
        fi
    fi
    echo "MRA files skipped: no interactive menu is available. Install them later in RetroForge Options, or rerun with FRONTIER_INSTALL_MRAS=yes."
    return 1
}

# MRA launchers ship as one zip (games/RetroArch/.mamefrontend/mras.zip). Unpack them with the frontend's own
# unpacker (same safety rules as the snaps: only *.mra under _Arcade/_MeatCores/_RetroArch, .part + CRC + rename,
# never outside the SD card tree). This runs before anything that needs the MRAs. A failure only warns: the install
# continues and RetroForge offers the MRA install again at its next start (or Options > Install MRAs).
if [ "$ACTION" = install ]; then
    [ "$RETROFORGE" -eq 0 ] || chmod 755 "$ROOT/games/RetroArch/.mamefrontend/retroforge"
    MRAS_ZIP="$ROOT/games/RetroArch/.mamefrontend/mras.zip"
    MRAS_TOOL="$ROOT/games/RetroArch/.mamefrontend/retroforge"
    if [ -f "$MRAS_ZIP" ] && [ ! -L "$MRAS_ZIP" ]; then
        if [ -x "$MRAS_TOOL" ] && [ ! -L "$MRAS_TOOL" ]; then
          if want_mras; then
            echo "Installing the MRA launchers (about a minute on the first install)..."
            if MAME2003PLUS_ROOT="$ROOT" "$MRAS_TOOL" --unpack-mras; then :; else
                echo "Warning: the MRAs were not fully installed; RetroForge offers it again at its next start." >&2
            fi
          else
            echo "Optional MRA installation skipped."
          fi
        else
            echo "Warning: mras.zip is present but the RetroForge program is missing; MRAs not installed." >&2
        fi
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

# Never expose a partially written INI.
if [ "$ACTION" = install ]; then
    frontend_layout_migrate "$LAYOUT_BACKUP"
    if [ -d "$LAYOUT_BACKUP" ]; then cp -p "$INI" "$LAYOUT_BACKUP/MiSTer.ini"; fi
fi
verify_selectors() {
    awk -v action="$ACTION" -v rf="$RETROFORGE" -v crt="$RETROFORGE_CRT" '
        { line=$0; sub(/\r$/, "", line); sub(/^\357\273\277/, "", line) }
        line ~ /^[ \t]*\[/ {
            section=tolower(line); sub(/^[ \t]*\[[ \t]*/, "", section); sub(/[ \t]*\].*$/, "", section)
        }
        section ~ /^(retroarch|retroforge|retroforge crt)$/ && tolower(line) ~ /^[ \t]*main[ \t]*=/ {
            value=line; sub(/^[^=]*=[ \t]*/, "", value); sub(/[ \t]*$/, "", value)
            expected=(section == "retroarch" ? "Mister_RetroArch" : "Mister_RetroForge")
            if (value != expected) bad=1
            count[section]++
        }
        END {
            install=(action == "install")
            if (count["retroarch"] != install || count["retroforge"] != (install && rf) || count["retroforge crt"] != (install && rf && crt)) bad=1
            exit bad
        }
    ' "$1"
}

configure_ini() {
INI=$1
TMP=$(mktemp "$INI.retroarch-new.XXXXXX")

# One AWK pass handles both sections, duplicate sections/keys, case, BOM and CRLF.
# The sidecars choose the display themselves; only the selectors are written.
awk -v action="$ACTION" -v retroforge="$RETROFORGE" -v crt="$RETROFORGE_CRT" '
function emit(value) { printf "%s%s\n", value, cr }
function selector() {
    installed[target]=1
    if (action != "install" || (target ~ /^RetroForge/ && !retroforge)) return
    if (target == "RetroForge CRT" && !crt) return
    emit("main=Mister_" (target == "RetroForge CRT" ? "RetroForge" : target))
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
        target=(header == "retroforge crt" ? "RetroForge CRT" : header == "retroforge" ? "RetroForge" : header == "retroarch" ? "RetroArch" : "")
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
    for (i=1; i<=3; i++) {
        target=(i == 1 ? "RetroArch" : i == 2 ? "RetroForge" : "RetroForge CRT")
        if (target ~ /^RetroForge/ && !retroforge) continue
        if (target == "RetroForge CRT" && !crt) continue
        if (!seen[target]) {
            if (NR > 0 || i > 1) emit("")
            emit("[" target "]")
            selector()
        }
    }
}' "$INI" > "$TMP"
if ! verify_selectors "$TMP"; then
    PREFLIGHT="Could not write the required main= selector lines correctly in $INI. The original file was kept."
    exit 74
fi

if ! cmp -s "$INI" "$TMP"; then
    chmod "$(stat -c '%a' "$INI" 2>/dev/null || echo 644)" "$TMP"
    BACKUP="$INI.retroarch-backup.$(date -u +%Y%m%dT%H%M%SZ).$$"
    cp -p "$INI" "$BACKUP"
    mv -f "$TMP" "$INI"
    TMP=""
    echo "INI backup: $BACKUP"
else
    rm -f "$TMP"; TMP=""
fi
if ! verify_selectors "$INI"; then
    PREFLIGHT="Selector readback failed for $INI. Check SD-card write errors and restore its .retroarch-backup file if necessary."
    exit 74
fi
echo "Verified launch selectors ($ACTION): $INI"
}

if [ "$ACTION" = install ]; then
    chmod 755 "$ROOT/Mister_RetroArch" "$ROOT/games/RetroArch/RetroArch" "$ROOT/games/RetroArch/_handler.sh"
    [ "$RETROFORGE" -eq 0 ] || chmod 755 "$ROOT/Mister_RetroForge"
    # Older releases shipped several setup/launcher scripts; this one replaces them all.
    for old in Install_RetroArch.sh Install-RetroArch.sh RetroArch.sh RetroArch_Setup.sh RetroForge.sh RetroForge_Setup.sh; do
        if [ -f "$ROOT/Scripts/$old" ] && [ ! -L "$ROOT/Scripts/$old" ]; then rm -f "$ROOT/Scripts/$old"; fi
    done
fi

for candidate in "$PRIMARY_INI" "$ROOT"/[Mm][Ii][Ss][Tt][Ee][Rr]_*.[Ii][Nn][Ii]; do
    [ -z "$EXPLICIT_INI" ] || [ "$candidate" = "$PRIMARY_INI" ] || continue
    [ -f "$candidate" ] || continue
    configure_ini "$candidate"
done
COMMITTED=1
if [ -n "$PREFLIGHT" ]; then
    echo "Unsafe launch selectors disabled. RetroForge is NOT ready to launch."
else
    echo "RetroArch package $ACTION complete (RetroForge=$RETROFORGE)."
fi
[ -z "$PREFLIGHT" ] || { echo "Install stopped: $PREFLIGHT" >&2; exit 70; }

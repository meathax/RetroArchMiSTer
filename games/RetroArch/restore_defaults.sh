#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Settings-only recovery, independent of RetroArch and its configuration parser.
set -euo pipefail
shopt -s nullglob nocaseglob nocasematch
MODE=restore
KEEP_OUTPUT=0
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
while (($#)); do
    case "$1" in
        --root) (($#>=2)) || exit 64; ROOT=$2; shift 2;;
        --recover) MODE=recover; shift;;
        --restore) MODE=restore; shift;;
        --reset-output) KEEP_OUTPUT=0; shift;;
        --keep-output) KEEP_OUTPUT=1; shift;;
        *) echo 'Unknown recovery argument' >&2; exit 64;;
    esac
done
die() { echo "Restore RetroArch defaults: $*" >&2; exit 1; }
[[ "$ROOT" = /* && "$ROOT" != / && -d "$ROOT" && ! -L "$ROOT" ]] || die 'Unsafe SD root'
ROOT=${ROOT%/}
[[ $(cd -- "$ROOT" && pwd -P) = "$ROOT" ]] || die 'SD root must be a physical, canonical path'
RA="$ROOT/games/RetroArch"
exists() { [[ -e "$1" || -L "$1" ]]; }
parent_dir() { if [[ "$1" = */* ]]; then printf '%s' "${1%/*}"; else printf '.'; fi; }
# Never traverse a settings symlink. A leaf link can be quarantined by rename.
parents_safe() {
    local rel=$1 walk=$ROOT part p
    local -a parts
    [[ "$rel" != /* && "$rel" != *$'\n'* && "$rel" != *$'\t'* && "$rel" != *$'\r'* ]] || return 1
    IFS=/ read -r -a parts <<< "$rel"
    for ((p=0;p<${#parts[@]}-1;p++)); do
        part=${parts[p]}; [[ -n "$part" && "$part" != . && "$part" != .. ]] || return 1
        walk+="/$part"; [[ ! -L "$walk" ]] || return 1
        [[ ! -e "$walk" || -d "$walk" ]] || return 1
    done
    [[ ${parts[-1]} != . && ${parts[-1]} != .. && -n ${parts[-1]} ]]
}
parents_safe games/RetroArch/sentinel && [[ -d "$RA" ]] || die 'Unsafe RetroArch directory'
for leaf in settings-backups .settings-reset.lock; do
    [[ ! -L "$RA/$leaf" ]] || die 'Unsafe recovery storage'
done
mkdir -p "$RA/settings-backups"
BACKUPS="$RA/settings-backups"
PENDING="$BACKUPS/pending"
exec 9>"$RA/.settings-reset.lock"
if [[ $MODE = recover ]]; then
    flock -w 30 9 || die 'A restore is still running; retry launch'
else
    flock -n 9 || die 'A restore is already running'
fi
[[ ! -L "$PENDING" ]] || die 'Unsafe recovery journal'
archive_pending() {
    local label=$1
    mv -- "$PENDING" "$BACKUPS/${label}-$(date +%Y%m%d-%H%M%S)-$$"
    sync
}
allowed_target() {
    local rel=$1 leaf=${1#games/RetroArch/}
    case "$rel" in
        games/RetroArch/config|games/RetroArch/autoconfig|games/RetroArch/launch_game.txt|\
        'games/RetroArch/saves/MAME 2003-Plus/mame2003-plus/cfg'|\
        games/RetroArch/saves/mame2003-plus/cfg|games/RetroArch/system/mame2003-plus/cfg|\
        MiSTer.ini|config/RetroArch.CFG|config/inputs/RetroArch_*.map) return 0;;
        games/RetroArch/*)
            [[ "$leaf" != */* && ( "$leaf" = *.cfg || "$leaf" = *.opt || "$leaf" = *.rmp ) ]];;
        *) return 1;;
    esac
}
validate_plan() {
    local had rel
    [[ -f "$PENDING/plan" && ! -L "$PENDING/plan" && ! -L "$PENDING/state" ]] || return 1
    while IFS=$'\t' read -r had rel; do
        [[ "$had" = 0 || "$had" = 1 ]] || return 1
        allowed_target "$rel" && parents_safe "$rel" &&
          parents_safe "games/RetroArch/settings-backups/pending/old/$rel" || return 1
    done < "$PENDING/plan"
}
rollback() {
    local had rel trash
    validate_plan || return 1
    trash=$(mktemp -d "$PENDING/discard.XXXXXX") || return 1
    while IFS=$'\t' read -r had rel; do
        if exists "$PENDING/old/$rel"; then
            if exists "$ROOT/$rel"; then
                mkdir -p "$trash/$(parent_dir "$rel")" || return 1
                if [[ "$rel" = MiSTer.ini && -f "$ROOT/$rel" && ! -L "$ROOT/$rel" ]]; then
                    cp -- "$ROOT/$rel" "$trash/$rel" || return 1
                else
                    mv -- "$ROOT/$rel" "$trash/$rel" || return 1
                fi
            fi
            mkdir -p "$ROOT/$(parent_dir "$rel")" || return 1
            mv -- "$PENDING/old/$rel" "$ROOT/$rel" || return 1
        elif [[ "$had" = 0 ]] && exists "$ROOT/$rel"; then
            mkdir -p "$trash/$(parent_dir "$rel")" || return 1
            mv -- "$ROOT/$rel" "$trash/$rel" || return 1
        fi
    done < "$PENDING/plan"
    sync
}
if [[ -d "$PENDING" ]]; then
    if [[ -f "$PENDING/state" && ! -L "$PENDING/state" ]] &&
       [[ $(cat "$PENDING/state") = COMMITTED ]]; then
        archive_pending restored
    elif [[ ! -e "$PENDING/plan" && ! -L "$PENDING/plan" ]]; then
        # No journal means staging stopped before any original was touched.
        archive_pending staging-interrupted
    else
        rollback || die 'Interrupted restore needs recovery; settings backup retained'
        archive_pending interrupted-rolled-back
    fi
fi
[[ $MODE = recover ]] && exit 0
if pidof RetroArch retroarch Mister_RetroArch >/dev/null 2>&1; then
    die 'Close RetroArch and open RetroForge before restoring'
fi

DEFAULTS="$RA/settings-defaults"
[[ -d "$DEFAULTS" && ! -L "$DEFAULTS" && -f "$DEFAULTS/manifest.sha256" ]] || die 'Reinstall bundle: factory defaults missing'
[[ -z $(find "$DEFAULTS" ! -type f ! -type d -print -quit) ]] || die 'Unsafe factory defaults'
declare -A seen=()
count=0
while read -r digest rel; do
    [[ "$digest" =~ ^[0-9a-f]{64}$ && -n "$rel" && "$rel" != /* && "$rel" != *\\* &&
       "$rel" != *'..'* && "$rel" != *$'\t'* && "$rel" != *$'\r'* &&
       ( "$rel" = retroarch.cfg || "$rel" = config/* ) ]] || die 'Invalid factory manifest'
    [[ ! ${seen[$rel]+present} ]] || die 'Duplicate factory default'
    seen[$rel]=1; ((count+=1))
done < "$DEFAULTS/manifest.sha256"
[[ ${seen[retroarch.cfg]+present} && ${seen[config/MAME 2003-Plus/MAME 2003-Plus.opt]+present} ]] || die 'Incomplete factory defaults'
[[ $(find "$DEFAULTS" -type f | wc -l) -eq $((count+1)) ]] || die 'Unlisted factory defaults'
(cd "$DEFAULTS" && sha256sum -c manifest.sha256) || die 'Factory defaults checksum failed'
for driver in video audio input input_joypad; do
    grep -Eq "^${driver}_driver = \"frontier\"[[:space:]]*$" "$DEFAULTS/retroarch.cfg" || die 'Invalid factory drivers'
done

output=hdmi
DISPLAY="$RA/config/frontier/display.cfg"
if ((KEEP_OUTPUT)) && [[ ! -L "$RA/config" && ! -L "$RA/config/frontier" && ! -L "$DISPLAY" && -f "$DISPLAY" ]]; then
    while IFS='=' read -r key value; do
        value=${value%$'\r'}
        if [[ "$key" = output && ( "$value" = hdmi || "$value" = crt15 ) ]]; then output=$value; fi
    done < "$DISPLAY"
fi
targets=(MiSTer.ini games/RetroArch/retroarch.cfg games/RetroArch/config games/RetroArch/autoconfig
         games/RetroArch/launch_game.txt
         'games/RetroArch/saves/MAME 2003-Plus/mame2003-plus/cfg'
         games/RetroArch/saves/mame2003-plus/cfg games/RetroArch/system/mame2003-plus/cfg)
for path in "$RA"/*.cfg "$RA"/*.opt "$RA"/*.rmp "$ROOT/config"/RetroArch.CFG "$ROOT/config/inputs"/RetroArch_*.map; do
    rel=${path#"$ROOT/"}
    [[ "$rel" = games/RetroArch/retroarch.cfg ]] || targets+=("$rel")
done
for rel in "${targets[@]}"; do
    allowed_target "$rel" && parents_safe "$rel" || die 'Unsafe settings path; nothing reset'
done
[[ ! -L "$ROOT/MiSTer.ini" && ( ! -e "$ROOT/MiSTer.ini" || -f "$ROOT/MiSTer.ini" ) ]] || die 'Unsafe MiSTer.ini; nothing reset'
mkdir "$PENDING"
mkdir "$PENDING/image" "$PENDING/old"
cp -R -- "$DEFAULTS/config" "$PENDING/image/config"
cp -- "$DEFAULTS/retroarch.cfg" "$PENDING/image/retroarch.cfg"
# Reset only RetroArch's owned Main section. Global and other-core configuration
# is retained, including comments and existing line endings in those sections.
ini_source=/dev/null
[[ ! -f "$ROOT/MiSTer.ini" ]] || ini_source="$ROOT/MiSTer.ini"
awk '
    /^[[:space:]]*\[/ {
        name=$0; sub(/^[[:space:]]*\[/,"",name); sub(/\].*$/,"",name);
        gsub(/^[[:space:]]+|[[:space:]]+$/,"",name);
        skip=(tolower(name)=="retroarch");
    }
    !skip {print}
    END {print ""; print "[RetroArch]"; print "main=Mister_RetroArch"}
' "$ini_source" > "$PENDING/image/MiSTer.ini"
mkdir -p "$PENDING/image/config/frontier"
printf 'version=2\noutput=%s\ncrt_height=fit\ncrt_deflicker=off\ncrt_overscan_x=0\ncrt_overscan_y=0\nhdmi_scale=aspect_integer\n' "$output" > "$PENDING/image/config/frontier/display.cfg"
for rel in "${targets[@]}"; do
    had=0; exists "$ROOT/$rel" && had=1
    printf '%s\t%s\n' "$had" "$rel"
done > "$PENDING/plan.part"
mv "$PENDING/plan.part" "$PENDING/plan"
sync # Durable originals/absence journal before any settings rename.
in_transaction=1
on_exit() {
    local status=$?
    trap - EXIT
    if ((in_transaction)) && ((status)); then
        if rollback; then archive_pending failed-rolled-back;
        else echo 'Recovery pending; backup retained. Retry Restore RetroArch defaults.' >&2; fi
    fi
    exit "$status"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for rel in "${targets[@]}"; do
    if exists "$ROOT/$rel"; then
        mkdir -p "$PENDING/old/$(parent_dir "$rel")"
        if [[ "$rel" = MiSTer.ini ]]; then
            # The shared INI is never absent: snapshot it, then atomically replace
            # only after the new image is ready. Failed copies are not originals.
            cp -- "$ROOT/$rel" "$PENDING/old/$rel.part"
            mv -- "$PENDING/old/$rel.part" "$PENDING/old/$rel"
        else
            mv -- "$ROOT/$rel" "$PENDING/old/$rel"
        fi
        sync
    fi
done
mv -- "$PENDING/image/retroarch.cfg" "$RA/retroarch.cfg"
mv -- "$PENDING/image/config" "$RA/config"
mv -- "$PENDING/image/MiSTer.ini" "$ROOT/MiSTer.ini"
sync
printf 'COMMITTED\n' > "$PENDING/state.part"
mv "$PENDING/state.part" "$PENDING/state"
sync
in_transaction=0
archive_pending restored
echo 'RetroArch defaults restored; previous settings are in games/RetroArch/settings-backups'

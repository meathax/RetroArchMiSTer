#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# MiSTer OSD Menus > "Reset MAME Settings" / "Reset RetroArch Settings" for one
# game (docs/OSD_OPTIONS.md). _handler.sh runs this with FRONTIER_GAME_RESET
# after Mister_RetroArch stopped the game cleanly, before RetroArch starts again.
#
#   mame       MAME 2003-Plus's own per-game file cfg/<set>.cfg (controls,
#              DIP switches, MAME menu settings): working, legacy and
#              MiSTer-layout mirror copies.
#   retroarch  RetroArch per-game files: game override config/<core>/<set>.cfg,
#              core options config/<core>/<set>.opt, remap
#              config/remaps/<core>/<set>.rmp and the MiSTer OSD Core Options
#              layer config/games/<set>.cfg.
#
# Every file found is moved to settings-backups/game-reset-<kind>-<set>-<stamp>/
# (never deleted); a shipped default in settings-defaults/ is then copied back.
# Saves, save states, NVRAM, high scores and global settings are not touched.
set -euo pipefail
KIND=
SET=
ROOT=/media/fat
CANON=${FRONTIER_SAVE_CANON:-/media/fat/saves/RetroArch}
while (($#)); do
    case "$1" in
        --kind) (($#>=2)) || exit 64; KIND=$2; shift 2;;
        --set) (($#>=2)) || exit 64; SET=$2; shift 2;;
        --root) (($#>=2)) || exit 64; ROOT=$2; shift 2;;
        --canon) (($#>=2)) || exit 64; CANON=$2; shift 2;;
        *) echo 'reset_game_settings: unknown argument' >&2; exit 64;;
    esac
done
die() { echo "[RetroArch] game settings reset: $*" >&2; exit 1; }
[[ "$KIND" == mame || "$KIND" == retroarch ]] || die "unknown kind '$KIND'"
[[ "$SET" =~ ^[A-Za-z0-9_]{1,32}$ ]] || die "invalid set name"
[[ "$ROOT" == /* && "$ROOT" != / && -d "$ROOT" && ! -L "$ROOT" ]] || die 'unsafe SD root'
ROOT=${ROOT%/}
RA="$ROOT/games/RetroArch"
[[ -d "$RA" && ! -L "$RA" ]] || die 'RetroArch directory missing'
CORE='MAME 2003-Plus'

# No component below $1 may be a symlink: a rename must never leave the tree.
inside() {  # base relative
    local walk=$1 part
    local -a parts
    IFS=/ read -r -a parts <<< "$2"
    for part in "${parts[@]::${#parts[@]}-1}"; do
        [[ -n "$part" && "$part" != . && "$part" != .. ]] || return 1
        walk+="/$part"
        [[ ! -L "$walk" ]] || return 1
    done
    [[ -n "${parts[-1]}" && "${parts[-1]}" != . && "${parts[-1]}" != .. ]]
}
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP="$RA/settings-backups/game-reset-$KIND-$SET-$STAMP-$$"
[[ ! -L "$RA/settings-backups" ]] || die 'unsafe backup directory'
moved=0
restored=0
take() {  # base relative backup-subdir
    local base=$1 rel=$2 sub=$3 dest
    inside "$base" "$rel" || die "unsafe path $rel"
    [[ -e "$base/$rel" || -L "$base/$rel" ]] || return 0
    dest="$BACKUP/$sub/$rel"
    mkdir -p -- "${dest%/*}"
    mv -- "$base/$rel" "$dest"
    moved=$((moved + 1))
}
if [[ "$KIND" == mame ]]; then
    for rel in "saves/$CORE/mame2003-plus/cfg/$SET.cfg" "saves/mame2003-plus/cfg/$SET.cfg" \
               "system/mame2003-plus/cfg/$SET.cfg"; do
        take "$RA" "$rel" game
    done
    if [[ "$CANON" == /* && -d "$CANON" && ! -L "$CANON" ]]; then
        for rel in "$CORE/mame2003-plus/cfg/$SET.cfg" "$CORE/mame2003-plus/cfg/$SET.cfg.prev"; do
            take "$CANON" "$rel" mister-saves
        done
    fi
else
    for rel in "config/$CORE/$SET.cfg" "config/$CORE/$SET.opt" "config/remaps/$CORE/$SET.rmp" \
               "config/games/$SET.cfg"; do
        take "$RA" "$rel" game
        default="$RA/settings-defaults/$rel"
        if [[ -f "$default" && ! -L "$default" ]] && inside "$RA" "settings-defaults/$rel"; then
            mkdir -p -- "$(dirname -- "$RA/$rel")"
            cp -- "$default" "$RA/$rel"
            restored=$((restored + 1))
        fi
    done
fi
sync
where=
((moved == 0)) || where=" to ${BACKUP#"$RA"/}"
echo "[RetroArch] reset $KIND settings for $SET: $moved file(s) backed up$where, $restored shipped default(s) restored" >&2

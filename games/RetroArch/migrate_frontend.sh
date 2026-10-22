#!/bin/sh
# Frontend layout migration library. ROOT is the SD-card root.
# Keep colliding legacy files in the journal; move missing files without copying
# gigabytes of media. The journal also makes a failed install reversible.
_frontend_layout_check() {
    local source="$1" destination="$2" entry name
    for entry in "$source"/* "$source"/.[!.]* "$source"/..?*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        name=${entry##*/}
        [ ! -L "$entry" ] && [ ! -L "$destination/$name" ] || return 65
        if [ -d "$entry" ]; then
            [ ! -e "$destination/$name" ] || [ -d "$destination/$name" ] || return 65
            _frontend_layout_check "$entry" "$destination/$name" || return "$?"
        else
            [ -f "$entry" ] || return 65
            [ ! -e "$destination/$name" ] || [ -f "$destination/$name" ] || return 65
        fi
    done
}

_frontend_layout_merge() {
    local source="$1" destination="$2" moved="$3" entry name
    mkdir -p "$destination" "$moved" || return "$?"
    for entry in "$source"/* "$source"/.[!.]* "$source"/..?*; do
        [ -e "$entry" ] || continue
        name=${entry##*/}
        if [ -d "$entry" ]; then
            _frontend_layout_merge "$entry" "$destination/$name" "$moved/$name" || return "$?"
        elif [ ! -e "$destination/$name" ]; then
            : > "$moved/$name" || return "$?"
            mv "$entry" "$destination/$name" || return "$?"
        fi
    done
}

_frontend_layout_unmerge() {
    local moved="$1" destination="$2" legacy="$3" entry name
    for entry in "$moved"/* "$moved"/.[!.]* "$moved"/..?*; do
        [ -e "$entry" ] || continue
        name=${entry##*/}
        if [ -d "$entry" ]; then
            _frontend_layout_unmerge "$entry" "$destination/$name" "$legacy/$name" || return "$?"
            rmdir "$destination/$name" 2>/dev/null || true
        elif [ -f "$destination/$name" ]; then
            mkdir -p "$legacy" || return "$?"
            mv "$destination/$name" "$legacy/$name" || return "$?"
        fi
    done
}

frontend_layout_migrate() {
    local journal="$1" legacy="$ROOT/_Other/.mamefrontend" data="$ROOT/games/RetroArch/.mamefrontend" directory
    for directory in "$ROOT/_Other" "$ROOT/games" "$ROOT/games/RetroArch" "$legacy" "$data"; do
        [ ! -L "$directory" ] || return 65
        [ ! -e "$directory" ] || [ -d "$directory" ] || return 65
    done
    if [ -d "$data" ] && [ -n "$(find "$data" -type l -print)" ]; then return 65; fi
    [ -d "$legacy" ] || return 0
    _frontend_layout_check "$legacy" "$data" || return "$?"
    [ ! -e "$journal" ] && [ ! -L "$journal" ] || return 65
    mkdir -p "$journal" "$ROOT/games/RetroArch" || return "$?"
    mv "$legacy" "$journal/legacy" || return "$?"
    _frontend_layout_merge "$journal/legacy" "$data" "$journal/moved"
}

frontend_layout_restore() {
    local journal="$1" legacy="$ROOT/_Other/.mamefrontend" data="$ROOT/games/RetroArch/.mamefrontend"
    [ -d "$journal/legacy" ] || return 0
    [ ! -L "$legacy" ] && [ ! -L "$data" ] || return 65
    _frontend_layout_check "$journal/legacy" "$legacy" || return "$?"
    mkdir -p "$legacy" || return "$?"
    # Keep the backed-up conflicts intact so the rollback receipt stays valid.
    cp -pR "$journal/legacy/." "$legacy/" || return "$?"
    _frontend_layout_unmerge "$journal/moved" "$data" "$legacy" || return "$?"
    rmdir "$data" 2>/dev/null || true
}

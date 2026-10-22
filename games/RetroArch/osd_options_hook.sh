#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Sourced by _handler.sh after lp_select (docs/OSD_OPTIONS.md).
#
# Opt-in: does nothing unless the marker file FRONTIER_OSD_OPTIONS exists in the
# game directory. When enabled it resolves global < core < game core options
# with osd_options_tool, then appends a generated RetroArch config (via
# --appendconfig) that points core_options_path at the resolved file and turns
# off the RetroArch game/folder/per-core option lookups so nothing else is mixed
# in. Never fatal: any failure leaves LP_ARGS untouched (stock options).
#
# Uses LP_CORE, LP_CONTENT, LP_ARGS (array) and P_cfg (the payload's cfg= value). Runs once at launch, never per frame.

osd_options_prepare() {
    [[ -f FRONTIER_OSD_OPTIONS ]] || return 0
    local tool="${FRONTIER_OSD_TOOL:-$GAMEDIR/osd_options_tool}"
    local dir="${FRONTIER_OSD_DIR:-/tmp/frontier-osd}"
    if [[ ! -x "$tool" ]]; then
        echo "[RetroArch] osd options: $tool missing; using stock options" >&2
        return 0
    fi
    # A previous run's receiver marker or live file must not be trusted.
    rm -rf -- "$dir" 2>/dev/null || true
    mkdir -p -- "$dir" && chmod 700 "$dir" || return 0
    # Payload cfg= (docs/LAUNCH_FORMAT.md): author-shipped per-game defaults, read-only here.
    local -a extra=()
    [[ -z "${P_cfg:-}" ]] || extra=(--payload-cfg "$P_cfg")
    # Session description for custom Main's OSD page (frontier_osd_page.cpp).
    {
        printf 'root = "%s"\n' "$GAMEDIR"
        printf 'core = "%s"\n' "$LP_CORE"
        printf 'content = "%s"\n' "$LP_CONTENT"
        [[ -z "${P_cfg:-}" ]] || printf 'payload_cfg = "%s"\n' "$P_cfg"
    } > "$dir/session.info" || return 0
    local out
    if ! out=$("$tool" resolve --root "$GAMEDIR" --core "$LP_CORE" --content "$LP_CONTENT" ${extra[@]+"${extra[@]}"} --out-dir "$dir" 2>&1); then
        echo "[RetroArch] osd options: resolve failed; using stock options: $out" >&2
        return 0
    fi
    [[ -s "$dir/effective.cfg" ]] || return 0
    echo "[RetroArch] osd options: $out" >&2
    # RetroArch keeps only the LAST --appendconfig argument, but that argument
    # may list several files separated by '|' (retroarch 1.22.2 configuration.c).
    local i n=${#LP_ARGS[@]} done=0
    for ((i = 0; i < n; i++)); do
        if [[ "${LP_ARGS[i]}" == --appendconfig && $((i + 1)) -lt n ]]; then
            LP_ARGS[i+1]="${LP_ARGS[i+1]}|$dir/effective.cfg"
            done=1
            break
        fi
    done
    if [[ $done == 0 ]]; then
        LP_ARGS=(--appendconfig "$dir/effective.cfg" "${LP_ARGS[@]}")
    fi
    export FRONTIER_OSD_DIR="$dir"
}

#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Launch payload parsing + preflight for _handler.sh (see docs/LAUNCH_FORMAT.md).
# Sourced, never executed. Runs with the game directory as the current directory.
#
#   lp_select   picks a payload (MGL, MRA setname, launch_game.txt) or menu mode,
#               runs preflight, writes the machine-readable result file and
#               sets LP_MODE (menu|game), LP_SOURCE, LP_ARGS (array), LP_CORE,
#               LP_CONTENT. On any failure it writes status=fail and exits with
#               the documented code; it never falls back to --menu silently.
#
# No eval, no expansion of payload values. Requires bash, sed, grep, wc, tr;
# perl only when a crc32: verify item is used; sha1sum only for sha1: items.

LP_RESULT="${FRONTIER_LAUNCH_RESULT:-/tmp/retroarch-launch-result}"
LP_MODE=menu
LP_SOURCE=menu
LP_ARGS=()
LP_CORE=""
LP_CONTENT=""
LP_TITLE=""
LP_NOTICE=""
MRA_CORE=""

# Printable ASCII only: every byte outside the set becomes '?' (what `tr -c` did). Pure bash, no fork:
# the result is left in LP_A; lp_ascii prints it for the (rare) failure-path callers.
lp_ascii_set() {  # $1 text, $2 max width
    local LC_ALL=C s=$1
    s=${s//[^A-Za-z0-9 ._()+,:@\/#-]/\?}
    LP_A=${s:0:$2}
}
lp_ascii() {  # $1 text, $2 max width -> printable ASCII, no '|' or '='-breaking newlines
    lp_ascii_set "$1" "$2"
    printf '%s' "$LP_A"
}

lp_write_result() {  # status code reason osd1 osd2 osd3
    local tmp="$LP_RESULT.tmp.$$" a_core a_content a_title a_rbf a_o1 a_o2="" a_o3=""
    lp_ascii_set "$LP_CORE" 32; a_core=$LP_A
    lp_ascii_set "$LP_CONTENT" 96; a_content=$LP_A
    lp_ascii_set "${LP_TITLE:-$LP_CONTENT}" 40; a_title=$LP_A
    lp_ascii_set "${ACTIVE_RBF:-}" 32; a_rbf=$LP_A
    lp_ascii_set "${4:-}" 32; a_o1=$LP_A
    if [[ -n "${5:-}" ]]; then lp_ascii_set "$5" 32; a_o2=$LP_A; fi
    if [[ -n "${6:-}" ]]; then lp_ascii_set "$6" 32; a_o3=$LP_A; fi
    {
        printf 'schema=1\nstatus=%s\ncode=%s\nreason=%s\n' "$1" "$2" "$3"
        printf 'core=%s\ncontent=%s\ntitle=%s\nrbf=%s\n' "$a_core" "$a_content" "$a_title" "$a_rbf"
        printf 'osd1=%s\n' "$a_o1"
        [[ -z "${5:-}" ]] || printf 'osd2=%s\n' "$a_o2"
        [[ -z "${6:-}" ]] || printf 'osd3=%s\n' "$a_o3"
    } > "$tmp" 2>/dev/null && mv -f -- "$tmp" "$LP_RESULT" 2>/dev/null || rm -f -- "$tmp" 2>/dev/null || true
}

lp_fail() {  # code reason line2 line3 [stderr detail]
    local code=$1 reason=$2 l2=$3 l3=${4:-} detail=${5:-}
    lp_write_result fail "$code" "$reason" "${LP_TITLE:-${LP_CONTENT:-Launch failed}}" "$l2" "$l3"
    echo "[RetroArch] launch preflight failed: $reason (${detail:-$l2})" >&2
    exit "$code"
}

lp_safe_rel() {  # relative path, no traversal, conservative charset
    local p=$1
    [[ -n "$p" && "$p" != /* && "$p" != *..* && ${#p} -le 200 ]] || return 1
    [[ "$p" =~ ^[A-Za-z0-9._/\ ()+@-]+$ ]]
}

lp_zip_index() {  # $1 zip file -> lines "member crc32hex size" from the central directory
    perl -e '
        open(my $f,"<:raw",$ARGV[0]) or exit 2;
        my $sz=-s $f; my $n=$sz<66000?$sz:66000;
        seek($f,$sz-$n,0); read($f,my $b,$n);
        my $i=rindex($b,"PK\x05\x06"); exit 3 if $i<0;
        my ($d,$cd,$ed,$e,$cs,$co,$cl)=unpack("v v v v V V v",substr($b,$i+4,18));
        seek($f,$co,0); read($f,my $c,$cs)==$cs or exit 4;
        my $p=0;
        for (1..$e) {
            exit 5 unless substr($c,$p,4) eq "PK\x01\x02";
            my ($crc,$csz,$usz,$nl,$el,$kl)=unpack("V V V v v v",substr($c,$p+16,18));
            my $name=substr($c,$p+46,$nl);
            printf "%s %08x %d\n",$name,$crc,$usz;
            $p+=46+$nl+$el+$kl;
        }' "$1"
}

lp_parse_payload() {  # $1 file; sets P_* variables
    P_core= P_content= P_bios= P_cfg= P_title= P_orientation= P_verify=
    local file=$1 size line key val n=0 seen=" "
    size=$(wc -c < "$file" 2>/dev/null) || size=0
    size=${size// /}
    [[ "$size" -le 4096 ]] || lp_fail 65 payload_invalid "Payload too large" "" "payload $file is $size bytes"
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        n=$((n + 1))
        [[ $n -le 32 ]] || lp_fail 65 payload_invalid "Payload has too many lines" "" "more than 32 lines"
        [[ "$line" == *=* ]] || lp_fail 65 payload_invalid "Bad payload line $n" "Expected key=value" "line $n has no '='"
        key="${line%%=*}"
        val="${line#*=}"
        [[ "$seen" != *" $key "* ]] || lp_fail 65 payload_invalid "Duplicate key: $(lp_ascii "$key" 16)" "" "duplicate key $key"
        seen="$seen$key "
        case "$key" in
            core) P_core=$val ;;
            content) P_content=$val ;;
            bios) P_bios=$val ;;
            cfg) P_cfg=$val ;;
            title) P_title=$val ;;
            orientation) P_orientation=$val ;;
            verify) P_verify=$val ;;
            *) lp_fail 65 payload_invalid "Unknown key: $(lp_ascii "$key" 16)" "" "unknown key '$key'" ;;
        esac
    done < "$file"
    [[ -n "$P_core" && -n "$P_content" ]] || lp_fail 65 payload_invalid "Payload needs core= and content=" "" "missing core or content"
    LP_TITLE=$(lp_ascii "$P_title" 40)
}

lp_core_library() {
    case "$1" in
        mame2003plus) echo cores/mame2003_plus_libretro.so ;;
        *) return 1 ;;
    esac
}

lp_resolve_content() {  # sets LP_CONTENT (relative path); echoes nothing
    if [[ "$P_content" =~ ^[a-z0-9_]{1,32}$ ]]; then
        case "$P_core" in
            mame2003plus)
                # User romsets live at /media/fat/games/mame2003plus, beside GAMEDIR.
                # Keep the older folders as compatibility fallbacks.
                local c
                for c in "../mame2003plus/$P_content.zip" "../mame2003plus/clones/$P_content.zip" \
                         "roms/MAME2003/$P_content.zip" \
                         "roms/$P_content.zip" "../mame2003/$P_content.zip"; do
                    LP_CONTENT=$c; [[ -f "$c" ]] && break
                done
                [[ -f "$LP_CONTENT" ]] || LP_CONTENT="roms/$P_content.zip"
                ;;
            fbneo)
                LP_CONTENT="roms/FBNeo/$P_content.zip"
                local c
                for c in roms/FBNeo/*/"$P_content".zip; do if [[ -f "$c" ]]; then LP_CONTENT="$c"; break; fi; done
                ;;
            dosbox_pure)
                local c
                for c in "roms/DOSBox/$P_content.dosz" "roms/$P_content.dosz" \
                         "roms/DOSBox/$P_content.zip" "roms/$P_content.zip"; do
                    LP_CONTENT=$c; [[ -f "$c" ]] && break
                done
                [[ -f "$LP_CONTENT" ]] || LP_CONTENT="roms/DOSBox/$P_content.dosz"
                ;;
            *) lp_fail 65 payload_invalid "Set name needs path" "roms/... for this core" "bare set name not valid for $P_core" ;;
        esac
    else
        lp_safe_rel "$P_content" && [[ "$P_content" == roms/* ]] || \
            lp_fail 65 payload_invalid "Bad content path" "Must be roms/<file>" "content='$P_content'"
        LP_CONTENT=$P_content
    fi
}

# MAME 2003-Plus reads cfg/default.cfg on every launch and cfg/<set>.cfg for the
# game; its parser trusts each stored sequence length, so a damaged file (seen
# 2026-10-15: default.cfg holding two concatenated 8 KiB copies) overruns a
# 16-entry stack array and every MAME launch dies with SIGSEGV. Validate both
# files and move a damaged one (working and canonical copies) into
# logs/cfg-quarantine/, so the core starts with defaults and rewrites it on exit.
lp_mame_cfg_valid() {  # $1 file -> 0 valid/unknown format, 1 damaged
    od -An -v -tu1 "$1" 2>/dev/null | awk '
        { for (i = 1; i <= NF; i++) b[n++] = $i + 0 }
        function u16(p) { return b[p] * 256 + b[p+1] }
        function seq(   len) { if (p + 2 > n) return 0; len = u16(p); p += 2
            if (len > 16 || p + 4 * len > n) return 0; p += 4 * len; return 1 }
        END {
            if (n < 8 || b[0] != 77 || b[1] != 65 || b[2] != 77 || b[3] != 69) exit 1
            # A second header anywhere means concatenated/torn writes.
            for (q = 1; q + 3 < n; q++)
                if (b[q] == 77 && b[q+1] == 65 && b[q+2] == 77 && b[q+3] == 69 && (b[q+4] == 67 || b[q+4] == 68)) exit 1
            # default.cfg v7: (type u32, default seq, seq) records up to EOF.
            if (b[4] == 68 && b[5] == 69 && b[6] == 70 && b[7] == 7) {
                for (p = 8; p < n; ) { if (p + 4 > n) exit 1; p += 4; if (!seq() || !seq()) exit 1 }
            }
            exit 0
        }'
}
lp_mame_cfg_guard() {  # $1 set name
    local rel="MAME 2003-Plus/mame2003-plus/cfg" canon=${FRONTIER_SAVE_CANON:-/media/fat/saves/RetroArch}
    local name f q stamp
    for name in default "$1"; do
        [[ -n "$name" ]] || continue
        f="saves/$rel/$name.cfg"
        [[ -s "$f" ]] || continue
        lp_mame_cfg_valid "$f" && continue
        stamp=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo bad)
        q="logs/cfg-quarantine"; mkdir -p "$q"
        mv -f "$f" "$q/$name.cfg.$stamp" 2>/dev/null || rm -f "$f"
        if [[ -f "$canon/$rel/$name.cfg" ]] && ! lp_mame_cfg_valid "$canon/$rel/$name.cfg"; then
            mv -f "$canon/$rel/$name.cfg" "$q/$name.cfg.canonical.$stamp" 2>/dev/null || rm -f "$canon/$rel/$name.cfg"
        fi
        echo "[RetroArch] damaged MAME $name.cfg moved to $q; defaults will be used" >&2
    done
}

lp_preflight() {  # after lp_parse_payload
    local lib item rest member crc want_size zi have
    LP_CORE=$P_core
    lib=$(lp_core_library "$P_core") || lp_fail 65 payload_invalid "Core unavailable" "Only MAME 2003-Plus is shipped" "core=$P_core"
    case "$P_orientation" in ''|auto|0|90|180|270) ;; *) lp_fail 65 payload_invalid "Bad orientation" "" "orientation=$P_orientation" ;; esac
    lp_resolve_content
    [[ -f "$lib" ]] || lp_fail 72 core_missing "Core file missing" "$(lp_ascii "${lib##*/}" 32)" "library $lib missing"
    [[ -s "$LP_CONTENT" ]] || lp_fail 66 content_missing "ROM/game file missing:" "$(lp_ascii "${LP_CONTENT##*/}" 32)" "content $LP_CONTENT missing or empty"
    if [[ -n "$P_bios" ]]; then
        local -a items
        IFS=, read -r -a items <<< "$P_bios"
        for item in "${items[@]}"; do
            lp_safe_rel "$item" || lp_fail 65 payload_invalid "Bad bios path" "" "bios='$item'"
            [[ -s "$item" ]] || lp_fail 67 bios_missing "BIOS missing:" "$(lp_ascii "${item##*/}" 32)" "bios $item missing or empty"
        done
    fi
    if [[ -n "$P_cfg" ]]; then
        lp_safe_rel "$P_cfg" && [[ "$P_cfg" == config/*.cfg ]] || lp_fail 65 payload_invalid "Bad cfg path" "Must be config/*.cfg" "cfg='$P_cfg'"
        [[ -f "$P_cfg" ]] || lp_fail 66 cfg_missing "Game config missing:" "$(lp_ascii "${P_cfg##*/}" 32)" "cfg $P_cfg missing"
    fi
    if [[ -n "$P_verify" ]]; then
        zi=""
        local -a vitems
        IFS=, read -r -a vitems <<< "$P_verify"
        for item in "${vitems[@]}"; do
            case "$item" in
                size:*)
                    want_size=${item#size:}
                    [[ "$want_size" =~ ^[0-9]{1,12}$ ]] || lp_fail 65 payload_invalid "Bad verify item" "" "verify '$item'"
                    have=$(wc -c < "$LP_CONTENT" | tr -d ' ')
                    [[ "$have" == "$want_size" ]] || lp_fail 68 verify_failed "Size mismatch:" "$(lp_ascii "${LP_CONTENT##*/}" 32)" "size $have != $want_size for $LP_CONTENT"
                    ;;
                sha1:*)
                    want_size=${item#sha1:}
                    [[ "$want_size" =~ ^[0-9a-fA-F]{40}$ ]] || lp_fail 65 payload_invalid "Bad verify item" "" "verify '$item'"
                    command -v sha1sum >/dev/null 2>&1 || lp_fail 68 verify_unavailable "Cannot verify (no sha1sum)" "" "sha1sum missing"
                    have=$(sha1sum < "$LP_CONTENT" | cut -d' ' -f1)
                    [[ "${have,,}" == "${want_size,,}" ]] || lp_fail 68 verify_failed "Hash mismatch:" "$(lp_ascii "${LP_CONTENT##*/}" 32)" "sha1 $have != $want_size"
                    ;;
                crc32:*)
                    rest=${item#crc32:}
                    member=${rest%%:*}; rest=${rest#*:}
                    crc=${rest%%:*}
                    want_size=""; [[ "$rest" == *:* ]] && want_size=${rest#*:}
                    [[ -n "$member" && "$crc" =~ ^[0-9a-fA-F]{8}$ && ( -z "$want_size" || "$want_size" =~ ^[0-9]{1,12}$ ) ]] || \
                        lp_fail 65 payload_invalid "Bad verify item" "" "verify '$item'"
                    command -v perl >/dev/null 2>&1 || lp_fail 68 verify_unavailable "Cannot verify (no perl)" "" "perl missing"
                    [[ -n "$zi" ]] || zi=$(lp_zip_index "$LP_CONTENT") || lp_fail 68 verify_failed "Not a valid zip:" "$(lp_ascii "${LP_CONTENT##*/}" 32)" "zip index failed for $LP_CONTENT"
                    have=$(printf '%s\n' "$zi" | awk -v m="$member" '{ nm=$1; for(i=2;i<=NF-2;i++) nm=nm " " $i; if (nm==m) { print $(NF-1), $NF; exit } }')
                    [[ -n "$have" ]] || lp_fail 68 verify_failed "ROM part missing in zip:" "$(lp_ascii "$member" 32)" "member '$member' not in $LP_CONTENT"
                    [[ "${have%% *}" == "${crc,,}" ]] || lp_fail 68 verify_failed "CRC mismatch:" "$(lp_ascii "$member" 32)" "crc32 ${have%% *} != ${crc,,} for $member"
                    [[ -z "$want_size" || "${have##* }" == "$want_size" ]] || lp_fail 68 verify_failed "Size mismatch:" "$(lp_ascii "$member" 32)" "size ${have##* } != $want_size for $member"
                    ;;
                *) lp_fail 65 payload_invalid "Bad verify item" "" "verify '$item'" ;;
            esac
        done
    fi
    if [[ "$P_core" == mame2003plus ]]; then
        local cfgset=${LP_CONTENT##*/}; cfgset=${cfgset%.zip}
        lp_mame_cfg_guard "$cfgset"
    fi
    LP_ARGS=(--config "$GAMEDIR/retroarch.cfg")
    [[ -z "$P_cfg" ]] || LP_ARGS+=(--appendconfig "$GAMEDIR/$P_cfg")
    LP_ARGS+=(-L "$GAMEDIR/$lib" "$GAMEDIR/$LP_CONTENT")
    [[ -z "$P_orientation" ]] || export FRONTIER_ORIENTATION="$P_orientation"
    # Qualification note: log only. No on-screen popup (owner, 2026-10-09): a warn
    # result makes Main show the title + "Speed not yet verified" box on every launch.
    if [[ -f qualified_titles.txt ]]; then
        local base=${LP_CONTENT##*/}; base=${base%.zip}
        # Whole-line match of "<core>:<set>" (what grep -x -F did), without a fork.
        local qline qfound=0
        while IFS= read -r qline || [[ -n "$qline" ]]; do
            if [[ "$qline" == "$P_core:$base" || "$qline" == "$P_core:$P_content" ]]; then qfound=1; break; fi
        done < qualified_titles.txt
        [[ "$qfound" == 1 ]] || LP_NOTICE=unqualified
    fi
    [[ -z "$LP_NOTICE" ]] || \
        echo "[RetroArch] notice: $P_core:$base has no physical full-speed receipt (not in qualified_titles.txt)" >&2
    lp_write_result ok 0 none "${LP_TITLE:-$LP_CONTENT}" "Launching..."
}

lp_mgl_payload() {  # $1 xml path -> echoes payload basename (first <file path=...*.ra>) or nothing
    local xml=$1 size tag p
    [[ -r "$xml" ]] || return 0
    size=$(wc -c < "$xml" | tr -d ' ')
    [[ "$size" -le 16384 ]] || return 0
    while IFS= read -r tag; do
        p=$(printf '%s' "$tag" | sed -n 's/.*[[:space:]]path="\([^"]*\)".*/\1/p')
        [[ -n "$p" ]] || p=$(printf '%s' "$tag" | sed -n "s/.*[[:space:]]path='\([^']*\)'.*/\1/p")
        [[ "$p" == *.ra ]] || continue
        printf '%s' "${p##*/}"
        return 0
    done < <(tr '\n\r' '  ' < "$xml" | grep -o '<file[^>]*>')
}

lp_select() {  # sets LP_MODE etc.; uses MRA_SETNAME, ACTIVE_RBF from the handler
    local payload="" xml="${FRONTIER_LAUNCH_XML:-}" first="" mra_remark="" has_selector=0
    [[ ! -e "$LP_RESULT" ]] || rm -f -- "$LP_RESULT" 2>/dev/null || true
    LP_MODE=menu; LP_SOURCE=menu
    if [[ -f launch_game.txt ]]; then
        has_selector=1
        IFS= read -r first < launch_game.txt || true
        first="${first%$'\r'}"
        # Consume our one-shot even when an explicit MRA or MGL wins below.
        # A failed or superseded request must not hijack the next menu launch.
        if [[ "$first" == launch/retroforge.ra ]]; then
            rm -f -- launch_game.txt || lp_fail 73 launch_request_failed "Cannot consume launch" "Check SD-card writes"
        fi
    fi
    [[ -z "$xml" || "$xml" == /* || -r "$xml" ]] || xml="${FRONTIER_FAT_ROOT:-/media/fat}/$xml"
    MRA_CORE=""
    if [[ -n "${MRA_SETNAME:-}" && "$xml" == *.[mM][rR][aA] && -r "$xml" ]]; then
        mra_remark=$(sed -n 's|^[[:space:]]*<remark>RetroArch core: \(.*\)</remark>[[:space:]]*$|\1|p' "$xml" | head -n 1)
        if [[ -n "$mra_remark" ]]; then
            case "$mra_remark" in
                mame2003plus) MRA_CORE=$mra_remark ;;
                *) lp_fail 65 payload_invalid "Bad MRA core marker" "Use MAME 2003-Plus" "MRA core marker='$mra_remark'" ;;
            esac
        fi
    fi
    if [[ -n "$xml" && "$xml" == *.[mM][gG][lL] ]]; then
        local b
        b=$(lp_mgl_payload "$xml")
        if [[ -n "$b" ]]; then
            lp_safe_rel "$b" && [[ "$b" != */* ]] || lp_fail 65 payload_invalid "Bad MGL payload name" "" "mgl path basename '$b'"
            payload="launch/$b"; LP_SOURCE=mgl
        fi
    fi
    if [[ -z "$payload" && -n "${MRA_SETNAME:-}" ]]; then
        if [[ -f "launch/$MRA_SETNAME.ra" ]]; then
            payload="launch/$MRA_SETNAME.ra"
        else
            # This shipped runtime contains only MAME. Missing MAME content
            # fails its preflight; a legacy set never selects a retired core.
            P_core=mame2003plus
            P_content=$MRA_SETNAME P_bios= P_cfg= P_title= P_orientation= P_verify=
            LP_SOURCE=mra; LP_MODE=game
            lp_preflight
            return 0
        fi
        LP_SOURCE=mra
    fi
    if [[ -z "$payload" && "$has_selector" == 1 ]]; then
        if [[ "$first" == *.ra ]]; then
            lp_safe_rel "$first" || lp_fail 65 payload_invalid "Bad launch_game.txt path" "" "launch_game.txt='$first'"
            payload=$first; LP_SOURCE=launch_txt
        else
            case "$first" in
                roms/DOSBox/*.dosz|roms/DOSBox/*.zip|roms/*.dosz) P_core=dosbox_pure ;;
                roms/FBNeo/*.zip) P_core=fbneo ;;
                roms/*.zip) P_core=mame2003plus ;;
                *) lp_fail 65 payload_invalid "launch_game.txt invalid" "Use .ra, .dosz or roms/x.zip" "launch_game.txt must name a launch payload or supported content path" ;;
            esac
            [[ "$first" != *..* ]] || lp_fail 66 content_missing "Bad content path" "" "content path invalid"
            lp_safe_rel "$first" || lp_fail 65 payload_invalid "Bad content path" "" "content='$first'"
            P_content=$first P_bios= P_cfg= P_title= P_orientation= P_verify=
            LP_SOURCE=launch_txt; LP_MODE=game
            lp_preflight
            return 0
        fi
    fi
    [[ -n "$payload" ]] || return 0
    [[ "$payload" == launch/* || "$LP_SOURCE" == launch_txt ]] || lp_fail 65 payload_invalid "Payload outside launch/" "" "payload $payload"
    lp_safe_rel "$payload" || lp_fail 65 payload_invalid "Bad payload path" "" "payload $payload"
    [[ -f "$payload" ]] || { LP_TITLE=${payload##*/}; lp_fail 66 content_missing "Launch file missing:" "$(lp_ascii "${payload##*/}" 32)" "payload $payload missing"; }
    lp_parse_payload "$payload"
    LP_MODE=game
    lp_preflight
}

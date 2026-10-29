#!/bin/sh
# Staged MAME installer library. The installer embeds these functions; no SSH here.
# User media/preferences belong in games/RetroArch/.mamefrontend.
export LC_ALL=C TZ=UTC

_frontier_layout_fail() { printf '%s\n' "frontend layout: $*" >&2; return 65; }

_frontier_layout_tools() {
  for tool in basename cmp cp find mv mkdir sort stat sha256sum touch chmod xargs rm; do
    command -v "$tool" >/dev/null 2>&1 ||
      { _frontier_layout_fail "required tool unavailable: $tool"; return 65; }
  done
}


# Intents are complete, validated tiny records written BEFORE transaction renames.
# A post-move marker is advisory. No recovery path deletes a sole original tree.
frontier_tx_intent_matches() (
  intent=$1; state=$2; target=$3
  test -f "$intent" && test ! -L "$intent" || return 1
  case "$state" in present|absent|staged) ;; *) return 65;; esac
  case "$target" in Mister_RetroArch|_Other/RetroArch.rbf|games/RetroArch|Scripts/RetroArch_Setup.sh|Scripts/Install_RetroArch.sh|Scripts/Install-RetroForge.sh|_Other/.mamefrontend|_Arcade/_MeatCores/_RetroArch) ;; *) return 65;; esac
  printf '%s\n' "$state|$target" | cmp -s - "$intent"
)

frontier_tx_intent_write() (
  intent=$1; state=$2; target=$3
  if test -e "$intent" || test -L "$intent"; then
    frontier_tx_intent_matches "$intent" "$state" "$target" ||
      { _frontier_layout_fail "existing intent is invalid"; return 65; }
    return 0
  fi
  test ! -e "$intent.new" && test ! -L "$intent.new" ||
    { _frontier_layout_fail "intent temporary already exists"; return 65; }
  printf '%s\n' "$state|$target" > "$intent.new" || return $?
  frontier_tx_intent_matches "$intent.new" "$state" "$target" || return $?
  mv "$intent.new" "$intent" || return $?
  frontier_tx_intent_matches "$intent" "$state" "$target" || return $?
)

frontier_tx_move() (
  source=$1; destination=$2; parent=${destination%/*}
  test -e "$source" || test -L "$source" ||
    { _frontier_layout_fail "rename source missing"; return 65; }
  test ! -e "$destination" && test ! -L "$destination" ||
    { _frontier_layout_fail "rename destination occupied"; return 65; }
  test -d "$parent" && test ! -L "$parent" ||
    { _frontier_layout_fail "rename parent invalid"; return 65; }
  source_device=$(stat -c '%d' "$source") && destination_device=$(stat -c '%d' "$parent") || return $?
  test "$source_device" = "$destination_device" ||
    { _frontier_layout_fail "cross-filesystem transaction move refused"; return 65; }
  mv -T -- "$source" "$destination" || return $?
  test ! -e "$source" && test ! -L "$source" &&
    { test -e "$destination" || test -L "$destination"; } ||
    { _frontier_layout_fail "rename positions invalid"; return 65; }
)

_frontier_layout_dirs() (
  for dir in "$ROOT/_Other" "$ROOT/games" "$ROOT/games/RetroArch"; do
    test ! -L "$dir" || { _frontier_layout_fail "symlink parent refused"; return 65; }
    if test -e "$dir"; then
      test -d "$dir" || { _frontier_layout_fail "non-directory parent refused"; return 65; }
    fi
  done
)

_frontier_layout_tree() (
  tree=$1
  test ! -L "$tree" || { _frontier_layout_fail "symlink refused"; return 65; }
  test -e "$tree" || return 0
  test -d "$tree" && test -r "$tree" && test -x "$tree" ||
    { _frontier_layout_fail "unreadable/non-directory frontend root"; return 65; }
  nl='
'
  cr=$(printf '\r'); tab=$(printf '\t')
  for entry in "$tree"/* "$tree"/.[!.]* "$tree"/..?*; do
    test -e "$entry" || test -L "$entry" || continue
    name=${entry##*/}
    case "$name" in *"$nl"*|*"$cr"*|*"$tab"*)
      _frontier_layout_fail "newline/CR/tab name refused"; return 65;; esac
    test ! -L "$entry" || { _frontier_layout_fail "symlink entry refused"; return 65; }
    if test -d "$entry"; then
      _frontier_layout_tree "$entry" || return $?
    elif test -f "$entry" && test -r "$entry"; then
      :
    else
      _frontier_layout_fail "special/unreadable entry refused"; return 65
    fi
  done
)

_frontier_layout_check() (
  src=$1; dst=$2
  test -e "$src" || return 0
  for entry in "$src"/* "$src"/.[!.]* "$src"/..?*; do
    test -e "$entry" || continue
    name=${entry##*/}
    other=$dst/$name
    test -e "$other" || continue
    if test -d "$entry" && test -d "$other"; then
      _frontier_layout_check "$entry" "$other" || return $?
    elif test -f "$entry" && test -f "$other"; then
      cmp -s "$entry" "$other" ||
        { _frontier_layout_fail "different bytes or read error at $name"; return 65; }
    else
      _frontier_layout_fail "file/directory conflict at $name"; return 65
    fi
  done
)

_frontier_layout_copy() (
  src=$1; dst=$2; prefer=$3
  test -e "$src" || return 0
  fresh=0
  if test ! -e "$dst"; then mkdir "$dst" || return $?; fresh=1; fi
  for entry in "$src"/* "$src"/.[!.]* "$src"/..?*; do
    test -e "$entry" || continue
    name=${entry##*/}
    if test -d "$entry"; then
      _frontier_layout_copy "$entry" "$dst/$name" "$prefer" || return $?
    elif test ! -e "$dst/$name" || test "$prefer" -eq 1; then
      cp -p "$entry" "$dst/$name" || return $?
    fi
  done
  if test "$fresh" -eq 1 || test "$prefer" -eq 1; then
    mode=$(stat -c '%a' "$src") || return $?
    chmod "$mode" "$dst" && touch -r "$src" "$dst" || return $?
  fi
)

_frontier_layout_coverage() (
  src=$1; dst=$2
  test -e "$src" || return 0
  test -d "$dst" || { _frontier_layout_fail "missing destination directory"; return 65; }
  for entry in "$src"/* "$src"/.[!.]* "$src"/..?*; do
    test -e "$entry" || continue
    name=${entry##*/}
    if test -d "$entry"; then
      _frontier_layout_coverage "$entry" "$dst/$name" || return $?
    else
      test -f "$dst/$name" && cmp -s "$entry" "$dst/$name" ||
        { _frontier_layout_fail "missing/changed destination bytes"; return 65; }
    fi
  done
)

_frontier_layout_signature() (
  tree=$1; prefix=$2
  _frontier_layout_tree "$tree" || return $?
  if test ! -e "$tree"; then
    printf '%s\n' absent > "$prefix.meta" && : > "$prefix.sums" || return $?
    return 0
  fi
  # Intermediate files make find/sort/read errors observable; no success-masking pipe.
  (cd "$tree" && find . -printf '%y\t%P\t%m\t%T@\0' > "$prefix.meta.unsorted") || return $?
  sort -z "$prefix.meta.unsorted" > "$prefix.meta" || return $?
  (cd "$tree" && find . -type f -print0 > "$prefix.files.unsorted") || return $?
  sort -z "$prefix.files.unsorted" > "$prefix.files" || return $?
  (cd "$tree" && xargs -0 -r -n 64 sha256sum < "$prefix.files") > "$prefix.sums" || return $?
)

_frontier_layout_matches() (
  expected=$1; tree=$2; actual=$3
  _frontier_layout_signature "$tree" "$actual" || return $?
  cmp -s "$expected.meta" "$actual.meta" && cmp -s "$expected.sums" "$actual.sums" ||
    { _frontier_layout_fail "source or verification signature changed"; return 65; }
)

frontier_layout_prepare() (
  plan=$1
  legacy=$ROOT/_Other/.mamefrontend
  live=$ROOT/games/RetroArch/.mamefrontend
  staged=$STAGE/games/RetroArch/.mamefrontend
  _frontier_layout_tools || return $?
  _frontier_layout_dirs || return $?
  for tree in "$legacy" "$live" "$staged"; do _frontier_layout_tree "$tree" || return $?; done
  _frontier_layout_check "$legacy" "$live" || return $?
  _frontier_layout_check "$legacy" "$staged" || return $?
  _frontier_layout_check "$live" "$staged" || return $?
  test ! -e "$plan" && test ! -L "$plan" || { _frontier_layout_fail "reused preflight"; return 65; }
  mkdir "$plan" || return $?
  _frontier_layout_signature "$legacy" "$plan/legacy.expected" || return $?
  _frontier_layout_signature "$live" "$plan/live.expected" || return $?
  if test -e "$legacy"; then : > "$plan/.legacy.present" || return $?; fi
  _frontier_layout_copy "$live" "$staged" 1 || return $?
  _frontier_layout_copy "$legacy" "$staged" 0 || return $?
  _frontier_layout_coverage "$live" "$staged" || return $?
  _frontier_layout_coverage "$legacy" "$staged" || return $?
  _frontier_layout_matches "$plan/legacy.expected" "$legacy" "$plan/legacy.after-copy" || return $?
  _frontier_layout_matches "$plan/live.expected" "$live" "$plan/live.after-copy" || return $?
  _frontier_layout_signature "$staged" "$plan/stage.expected" || return $?
)

frontier_layout_begin() (
  plan=$1; journal=$2
  _frontier_layout_dirs || return $?
  _frontier_layout_matches "$plan/legacy.expected" "$ROOT/_Other/.mamefrontend" "$plan/legacy.before-move" || return $?
  _frontier_layout_matches "$plan/live.expected" "$ROOT/games/RetroArch/.mamefrontend" "$plan/live.before-move" || return $?
  test ! -e "$journal" && test ! -L "$journal" || { _frontier_layout_fail "reused journal"; return 65; }
  # The existing installer requires its backup below the same filesystem root.
  root_device=$(stat -c '%d' "$ROOT") && backup_device=$(stat -c '%d' "$BACKUP") || return $?
  test "$root_device" = "$backup_device" || { _frontier_layout_fail "cross-filesystem backup refused"; return 65; }
  if test -e "$ROOT/_Other/.mamefrontend"; then
    legacy_device=$(stat -c '%d' "$ROOT/_Other/.mamefrontend") || return $?
    test "$legacy_device" = "$backup_device" || { _frontier_layout_fail "cross-filesystem legacy refused"; return 65; }
  fi
  frontier_tx_move "$plan" "$journal" || return $?
  if test -f "$journal/.legacy.present"; then frontier_tx_move "$ROOT/_Other/.mamefrontend" "$journal/legacy" || return $?; fi
)

frontier_layout_verify() (
  journal=$1; data=$2; scratch=$3
  test ! -e "$scratch" && mkdir "$scratch" || return $?
  _frontier_layout_matches "$journal/stage.expected" "$data" "$scratch/stage" || return $?
  _frontier_layout_matches "$journal/live.expected" "$BACKUP/payload/games/RetroArch/.mamefrontend" "$scratch/live" || return $?
  _frontier_layout_matches "$journal/legacy.expected" "$journal/legacy" "$scratch/legacy" || return $?
  _frontier_layout_coverage "$BACKUP/payload/games/RetroArch/.mamefrontend" "$data" || return $?
  _frontier_layout_coverage "$journal/legacy" "$data" || return $?
  test ! -e "$ROOT/_Other/.mamefrontend" && test ! -L "$ROOT/_Other/.mamefrontend" ||
    { _frontier_layout_fail "legacy path reappeared"; return 65; }
)

frontier_layout_restore() (
  journal=$1; scratch=$2
  test -d "$journal" || return 0
  test -f "$journal/.legacy.present" || return 0
  _frontier_layout_dirs || return $?
  test ! -e "$scratch" && mkdir "$scratch" || return $?
  if test -e "$journal/legacy" || test -L "$journal/legacy"; then
    test ! -e "$ROOT/_Other/.mamefrontend" && test ! -L "$ROOT/_Other/.mamefrontend" ||
      { _frontier_layout_fail "restoration destination occupied"; return 65; }
    _frontier_layout_matches "$journal/legacy.expected" "$journal/legacy" "$scratch/before" || return $?
    frontier_tx_intent_write "$journal/.legacy.restore.intent" present _Other/.mamefrontend || return $?
    frontier_tx_move "$journal/legacy" "$ROOT/_Other/.mamefrontend" || return $?
    : > "$journal/.legacy.restored" || return $?
  fi
  _frontier_layout_matches "$journal/legacy.expected" "$ROOT/_Other/.mamefrontend" "$scratch/after" || return $?
)

frontier_layout_undo_restore() (
  journal=$1; scratch=$2
  test -f "$journal/.legacy.present" || return 0
  if ! frontier_tx_intent_matches "$journal/.legacy.restore.intent" present _Other/.mamefrontend; then
    test ! -e "$journal/.legacy.restore.intent" && test ! -L "$journal/.legacy.restore.intent" ||
      { _frontier_layout_fail "legacy restore intent invalid"; return 65; }
    return 0
  fi
  _frontier_layout_dirs || return $?
  test ! -e "$scratch" && mkdir "$scratch" || return $?
  if test -e "$journal/legacy" || test -L "$journal/legacy"; then
    test ! -e "$ROOT/_Other/.mamefrontend" && test ! -L "$ROOT/_Other/.mamefrontend" ||
      { _frontier_layout_fail "both legacy rename positions occupied"; return 65; }
    _frontier_layout_matches "$journal/legacy.expected" "$journal/legacy" "$scratch/not-moved" || return $?
  else
    _frontier_layout_matches "$journal/legacy.expected" "$ROOT/_Other/.mamefrontend" "$scratch/before" || return $?
    frontier_tx_move "$ROOT/_Other/.mamefrontend" "$journal/legacy" || return $?
    _frontier_layout_matches "$journal/legacy.expected" "$journal/legacy" "$scratch/after" || return $?
  fi
  if test -f "$journal/.legacy.restored" && test ! -L "$journal/.legacy.restored"; then
    rm -f "$journal/.legacy.restored" || return $?
  fi
  rm "$journal/.legacy.restore.intent" || return $?
)

# Generated launchers live only in the project-owned Arcade subtree. User files
# with unequal candidate names refuse the operation; all other files are copied
# with metadata into the staging tree before the existing transactional rename.
frontier_mra_prepare() {
  mra_plan=$1
  for mra_parent in "$ROOT/_Arcade" "$ROOT/_Arcade/_MeatCores" "$ROOT/_Arcade/_MeatCores/_RetroArch"; do
    test ! -L "$mra_parent" || { _frontier_layout_fail "MRA symlink parent refused"; return 65; }
    if test -e "$mra_parent"; then
      test -d "$mra_parent" || { _frontier_layout_fail "MRA non-directory parent refused"; return 65; }
    fi
  done
  _frontier_layout_tree "$ROOT/_Arcade/_MeatCores/_RetroArch" || return $?
  _frontier_layout_tree "$STAGE/_Arcade/_MeatCores/_RetroArch" || return $?
  _frontier_layout_check "$ROOT/_Arcade/_MeatCores/_RetroArch" "$STAGE/_Arcade/_MeatCores/_RetroArch" || return $?
  test ! -e "$mra_plan" && test ! -L "$mra_plan" || return 65
  mkdir "$mra_plan" || return $?
  _frontier_layout_signature "$ROOT/_Arcade/_MeatCores/_RetroArch" "$mra_plan/live.expected" || return $?
  _frontier_layout_copy "$ROOT/_Arcade/_MeatCores/_RetroArch" "$STAGE/_Arcade/_MeatCores/_RetroArch" 1 || return $?
  _frontier_layout_coverage "$ROOT/_Arcade/_MeatCores/_RetroArch" "$STAGE/_Arcade/_MeatCores/_RetroArch" || return $?
  (cd "$STAGE" && sha256sum -c games/RetroArch/generated-mras.sha256) || return $?
}

frontier_mra_before_snapshot() {
  _frontier_layout_matches "$1/live.expected" "$ROOT/_Arcade/_MeatCores/_RetroArch" "$1/live.before-move"
}

frontier_mra_verify() {
  _frontier_layout_coverage "$BACKUP/payload/_Arcade/_MeatCores/_RetroArch" "$ROOT/_Arcade/_MeatCores/_RetroArch" || return $?
  (cd "$ROOT" && sha256sum -c games/RetroArch/generated-mras.sha256) || return $?
}

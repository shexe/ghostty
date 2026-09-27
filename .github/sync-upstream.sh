#!/usr/bin/env bash
# Rebase this fork's branches onto upstream Ghostty main.
#
# pixel-scroll and kitty-streaming are replayed onto the new Ghostty commit,
# then scroll-fixes, seamless-resize and main onto the new pixel-scroll. Each
# commit keeps its author, committer and dates, so a commit that is unchanged
# on an unchanged parent keeps its SHA, and the copies of a branch inside the
# branches that merge it stay identical to the branch itself. Merges are redone
# against the replayed side, with conflicts resolved the way the original
# merges resolved them (learned with rerere, as git's contrib/rerere-train.sh
# does). Anything else that conflicts, or a commit that becomes empty, stops
# the sync.
#
# The result is left in the local branches, and ghostty-main is set to the new
# Ghostty commit. Nothing is pushed. Prints one line per branch and, under
# GitHub Actions, sets the step output changed=true|false.
#
# Usage: .github/sync-upstream.sh [<ghostty-commit>]   (default: upstream/main)

set -euo pipefail

branches="pixel-scroll kitty-streaming scroll-fixes seamless-resize main"

# rerere is enabled for this run only, not written to the repository config.
export GIT_CONFIG_COUNT=2
export GIT_CONFIG_KEY_0=rerere.enabled GIT_CONFIG_VALUE_0=true
export GIT_CONFIG_KEY_1=rerere.autoUpdate GIT_CONFIG_VALUE_1=true

fail() {
    echo "sync: $*" >&2
    exit 1
}

short() { git rev-parse --short "$1"; }

# The published tip of a branch.
published() { git rev-parse --verify -q "refs/remotes/origin/$1^{commit}" || fail "no origin/$1"; }

# Run a git command with the author and committer of commit $1.
as_commit() {
    local c="$1"
    shift
    GIT_AUTHOR_NAME="$(git log -1 --format=%an "$c")" \
    GIT_AUTHOR_EMAIL="$(git log -1 --format=%ae "$c")" \
    GIT_AUTHOR_DATE="$(git log -1 --format=%aI "$c")" \
    GIT_COMMITTER_NAME="$(git log -1 --format=%cn "$c")" \
    GIT_COMMITTER_EMAIL="$(git log -1 --format=%ce "$c")" \
    GIT_COMMITTER_DATE="$(git log -1 --format=%cI "$c")" \
        "$@"
}

# Record how the fork's existing merges resolved their conflicts.
learn_resolutions() {
    local m
    for m in $(git rev-list --merges "$1"); do
        git checkout -q --detach "$m^1"
        if ! git merge -q --no-edit "$m^2" >/dev/null 2>&1 &&
            [ -s "$(git rev-parse --git-path MERGE_RR)" ]; then
            git rerere
            git checkout -q "$m" -- .
            git rerere
        fi
        git reset -q --hard
    done
}

# After a stopped merge or cherry-pick of $1, fail unless rerere resolved it.
check_resolved() {
    local unmerged
    unmerged="$(git diff --name-only --diff-filter=U)"
    if [ -n "$unmerged" ]; then
        fail "$(short "$1") $(git log -1 --format=%s "$1"): conflicts in:
$unmerged"
    fi
    if git diff --cached --quiet; then
        fail "$(short "$1") $(git log -1 --format=%s "$1"): is empty on the new base (Ghostty may now cover it)"
    fi
}

# replay <branch> <old base> <new base>: rebuild the branch's first-parent
# commits after the old base on top of the new base.
replay() {
    local branch="$1" base="$2" onto="$3" c side new_side msg
    git checkout -q --detach "$onto"
    for c in $(git rev-list --reverse --first-parent "$base..$(published "$branch")"); do
        if side="$(git rev-parse -q --verify "$c^2")"; then
            new_side="$(awk -v k="$side" '$1 == k { print $2; exit }' "$map")"
            [ -n "$new_side" ] ||
                fail "$branch: $(short "$c") merges $(short "$side"), which no replayed branch contains"
            msg="$(git rev-parse --git-path sync-msg)"
            git log -1 --format=%B "$c" >"$msg"
            if ! as_commit "$c" git merge -q --no-ff --no-edit -F "$msg" "$new_side" >/dev/null; then
                check_resolved "$c"
                as_commit "$c" git commit -q -F "$msg"
            fi
        elif ! as_commit "$c" git cherry-pick "$c" >/dev/null 2>&1; then
            check_resolved "$c"
            as_commit "$c" git -c core.editor=true cherry-pick --continue >/dev/null
        fi
        echo "$c $(git rev-parse HEAD)" >>"$map"
    done
    git branch -f "$branch" HEAD
}

main() {
    local onto base kbase p0 p1 b changed=false
    onto="$(git rev-parse --verify "${1:-upstream/main}^{commit}")"
    git diff --quiet HEAD || fail "the working tree has changes"

    map="$(mktemp)"
    trap 'rm -f "$map"; git cherry-pick --abort 2>/dev/null || git merge --abort 2>/dev/null || true' EXIT

    base="$(git merge-base "$(published pixel-scroll)" "$onto")"
    kbase="$(git merge-base "$(published kitty-streaming)" "$onto")"
    p0="$(published pixel-scroll)"

    learn_resolutions "$base..$(published main)"

    replay pixel-scroll "$base" "$onto"
    p1="$(git rev-parse pixel-scroll)"
    replay kitty-streaming "$kbase" "$onto"
    replay scroll-fixes "$p0" "$p1"
    replay seamless-resize "$p0" "$p1"
    replay main "$p0" "$p1"
    git branch -f ghostty-main "$onto"
    git checkout -q main

    for b in ghostty-main $branches; do
        old="$(git rev-parse -q --verify "refs/remotes/origin/$b" || echo none)"
        new="$(git rev-parse "$b")"
        if [ "$old" = "$new" ]; then
            echo "$b: unchanged ($(short "$new"))"
        else
            echo "$b: ${old:0:9} -> $(short "$new")"
            changed=true
        fi
    done
    echo "changed=$changed"
    [ -z "${GITHUB_OUTPUT:-}" ] || echo "changed=$changed" >>"$GITHUB_OUTPUT"
}

# Parsed in full before it runs, since checkouts replace this file.
main "$@"
exit

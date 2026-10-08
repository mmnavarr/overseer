#!/bin/bash
# Run inside an operation terminal: wt and its hooks inherit this PTY.
set -u

if [ "$#" -ne 6 ]; then
    printf 'Usage: worktree-operation.sh MODE WT REPOSITORY TARGET OPTION RECEIPT\n' >&2
    exit 64
fi

mode=$1
wt=$2
repo=$3
target=$4
option=$5
receipt=$6
case "$mode" in
    create) label='Worktree creation' ;;
    remove) label='Worktree removal' ;;
    *) printf 'Unknown operation: %s\n' "$mode" >&2; exit 64 ;;
esac
recorded=0
receipt_tmp=''

record_status() {
    local status=$1
    if [ "$recorded" -eq 1 ]; then
        return
    fi
    if [ -z "$receipt_tmp" ]; then
        receipt_tmp=$(/usr/bin/mktemp "${receipt}.tmp.XXXXXX") || {
            printf 'Cannot create completion receipt at %s (command exit %s).\n' "$receipt" "$status" >&2
            return 1
        }
    fi
    if printf '%s\n' "$status" > "$receipt_tmp" && /bin/mv -f "$receipt_tmp" "$receipt"; then
        recorded=1
        receipt_tmp=''
    else
        printf 'Cannot publish completion receipt at %s (command exit %s).\n' "$receipt" "$status" >&2
        return 1
    fi
}

on_exit() {
    local status=$?
    trap - EXIT
    if [ "$recorded" -eq 0 ]; then
        record_status "$status"
        printf '\n%s command completed; review output above\n' "$label"
        printf 'Command exit status: %s\n' "$status"
    fi
    if [ -n "$receipt_tmp" ]; then
        /bin/rm -f "$receipt_tmp"
    fi
    # Only after the receipt: Overseer treats a missing PID file plus a missing
    # receipt as a helper that never started.
    /bin/rm -f "${receipt}.pid"
    exit "$status"
}

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# Check receipt writability before creating anything. mktemp uses mode 0600.
receipt_tmp=$(/usr/bin/mktemp "${receipt}.tmp.XXXXXX") || exit 73
# Overseer checks this PID before treating a vanished terminal as a failure.
printf '%s\n' "$$" > "${receipt}.pid" || exit 73

remove_worktree() {
    # Recheck identity and cleanliness immediately before handing off to wt.
    # Use an absolute path, not a branch shortcut that could target another tree.
    local root common target_common git_dir branch changes
    root=$(git -C "$target" rev-parse --show-toplevel) || return 1
    common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir) || return 1
    target_common=$(git -C "$target" rev-parse --path-format=absolute --git-common-dir) || return 1
    git_dir=$(git -C "$target" rev-parse --path-format=absolute --git-dir) || return 1
    if [ "$root" != "$target" ] || [ "$target_common" != "$common" ] || [ "$git_dir" = "$common" ]; then
        printf 'Refusing removal: target is not a linked worktree of this project.\n' >&2
        return 1
    fi
    branch=$(git -C "$target" symbolic-ref --quiet --short HEAD)
    if [ "$?" -gt 1 ] || [ "$branch" != "$option" ]; then
        printf 'Refusing removal: the worktree branch changed after confirmation.\n' >&2
        return 1
    fi
    changes=$(git -C "$target" status --porcelain=v1 --untracked-files=normal) || return 1
    if [ -n "$changes" ]; then
        printf 'Refusing removal: worktree has uncommitted or untracked files.\n' >&2
        return 1
    fi
    "$wt" -C "$repo" remove --foreground --no-delete-branch -- "$target"
    local status=$?
    if [ "$status" -eq 0 ] && [ -e "$target" ]; then
        printf 'Removal returned success but the worktree path still exists.\n' >&2
        return 1
    fi
    return "$status"
}

# No pipeline, substitution, redirection, backgrounding, --yes or --no-hooks:
# project/user hooks see the original terminal and retain approval prompts.
if [ "$mode" = create ]; then
    "$wt" -C "$repo" switch --create --base "$option" --no-cd "$target"
else
    remove_worktree
fi
status=$?
record_status "$status"
printf '\n%s command completed; review output above\n' "$label"
printf 'Command exit status: %s\n' "$status"

# The controller can consume the receipt now; leave hook output on screen.
if [ -t 0 ]; then
    printf '\nPress Enter when you have finished reviewing this output. '
    IFS= read -r _ || :
fi
exit "$status"

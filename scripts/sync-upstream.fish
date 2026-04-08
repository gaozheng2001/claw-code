#!/usr/bin/env fish

set -g SYNC_DRY_RUN 0
set -l use_stash 1
set -l upstream_remote upstream
set -l origin_remote origin
set -l mirror_branch main
set -l work_branch my-main
set -l feature_branch ""

set -g SYNC_ORIGINAL_BRANCH ""
set -g SYNC_STASHED 0
set -g SYNC_STASH_NAME ""

function usage
    echo "Usage: scripts/sync-upstream.fish [options]"
    echo ""
    echo "Options:"
    echo "  --upstream <remote>         Upstream remote name (default: upstream)"
    echo "  --origin <remote>           Origin remote name (default: origin)"
    echo "  --mirror-branch <branch>    Branch mirrored from upstream (default: main)"
    echo "  --work-branch <branch>      Branch carrying local fixes (default: my-main)"
    echo "  --feature-branch <branch>   Optional feature branch to merge into work branch"
    echo "  --no-stash                  Do not stash uncommitted changes"
    echo "  --dry-run                   Print commands without executing"
    echo "  -h, --help                  Show this help"
end

function restore_context
    if test -n "$SYNC_ORIGINAL_BRANCH"
        git checkout $SYNC_ORIGINAL_BRANCH >/dev/null 2>&1
    end
    if test $SYNC_STASHED -eq 1
        if git stash list | grep -q $SYNC_STASH_NAME
            git stash pop >/dev/null
        end
    end
end

function run_or_fail
    if test $SYNC_DRY_RUN -eq 1
        echo "[dry-run]" (string join " " -- $argv)
        return 0
    end

    $argv
    or begin
        echo "FAILED:" (string join " " -- $argv) >&2
        restore_context
        exit 1
    end
end

while test (count $argv) -gt 0
    switch $argv[1]
        case -h --help
            usage
            exit 0
        case --upstream --origin --mirror-branch --work-branch --feature-branch
            if test (count $argv) -lt 2
                echo "Missing value for" $argv[1] >&2
                usage
                exit 2
            end
            set -l option $argv[1]
            set -l value $argv[2]
            switch $option
                case --upstream
                    set upstream_remote $value
                case --origin
                    set origin_remote $value
                case --mirror-branch
                    set mirror_branch $value
                case --work-branch
                    set work_branch $value
                case --feature-branch
                    set feature_branch $value
            end
            set argv $argv[3..-1]
            continue
        case --no-stash
            set use_stash 0
        case --dry-run
            set SYNC_DRY_RUN 1
        case '*'
            echo "Unknown option:" $argv[1] >&2
            usage
            exit 2
    end
    set argv $argv[2..-1]
end

set -g SYNC_ORIGINAL_BRANCH (git branch --show-current)
if test -z "$SYNC_ORIGINAL_BRANCH"
    echo "Could not determine current branch" >&2
    exit 1
end

if test $use_stash -eq 1
    set -l pending_changes (git status --porcelain)
    if test (count $pending_changes) -gt 0
        set -g SYNC_STASH_NAME "auto-sync-"(date +%Y%m%d-%H%M%S)
        run_or_fail git stash push -u -m $SYNC_STASH_NAME
        set -g SYNC_STASHED 1
    end
end

run_or_fail git fetch $upstream_remote --prune

if git show-ref --verify --quiet refs/heads/$mirror_branch
    run_or_fail git checkout $mirror_branch
else if git ls-remote --exit-code --heads $origin_remote $mirror_branch >/dev/null 2>&1
    run_or_fail git checkout -b $mirror_branch "$origin_remote/$mirror_branch"
else
    echo "Mirror branch '$mirror_branch' not found on remote '$origin_remote'." >&2
    restore_context
    exit 1
end
run_or_fail git merge --ff-only "$upstream_remote/$mirror_branch"
run_or_fail git push $origin_remote $mirror_branch

if git show-ref --verify --quiet refs/heads/$work_branch
    run_or_fail git checkout $work_branch
else if git ls-remote --exit-code --heads $origin_remote $work_branch >/dev/null 2>&1
    run_or_fail git checkout -b $work_branch "$origin_remote/$work_branch"
else
    run_or_fail git checkout -b $work_branch $mirror_branch
end

if git merge-base --is-ancestor $mirror_branch HEAD
    echo "$work_branch already includes $mirror_branch"
else
    run_or_fail git merge --no-ff $mirror_branch -m "merge upstream $mirror_branch"
end

if test -n "$feature_branch"
    if git show-ref --verify --quiet refs/heads/$feature_branch
        if git merge-base --is-ancestor $feature_branch HEAD
            echo "$feature_branch already merged into $work_branch"
        else
            run_or_fail git merge --no-ff $feature_branch -m "merge feature branch $feature_branch"
        end
    else
        echo "Feature branch '$feature_branch' does not exist locally; skipping."
    end
end

run_or_fail git push -u $origin_remote $work_branch
run_or_fail git checkout $SYNC_ORIGINAL_BRANCH

if test $SYNC_STASHED -eq 1
    if git stash list | grep -q $SYNC_STASH_NAME
        if test $SYNC_DRY_RUN -eq 1
            echo "[dry-run] git stash pop"
        else
            git stash pop
            or begin
                echo "WARNING: stash pop had conflicts; resolve manually." >&2
                exit 1
            end
        end
    end
end

echo "DONE: synced $mirror_branch and refreshed $work_branch"

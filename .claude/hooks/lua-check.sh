#!/usr/bin/env bash
# PostToolUse hook: after any Lua edit in this repo, run tests/run.sh (~0.7s) and
# hand failures straight back on exit 2, so a break surfaces at the edit that
# caused it rather than three edits later.
#
# It runs the *whole* suite, not just the linter, because the two tiers catch
# disjoint things -- measured, not assumed:
#
#   lua-language-server  syntax errors, undefined globals, type mismatches.
#     Does NOT catch cross-module breakage: deleting util.pr_url while pr.lua
#     still calls it is reported as "no problems found", even at --checklevel=Hint.
#   the headless smoke test  actually loads every module and calls into them, so
#     it does catch exactly that (and command registration, and the opts plumbing).
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

file="$(jq -r '.tool_input.file_path // .tool_response.filePath // empty' 2>/dev/null)"
[[ "$file" == *.lua ]] || exit 0        # not lua -- nothing to do
[[ "$file" == "$repo"/* ]] || exit 0    # not this repo's lua

out="$("$repo/tests/run.sh" 2>&1)" && exit 0

clean() {
    sed -e 's/\x1b\[[0-9;]*m//g' -e 's/\r/\n/g' <<<"$1" \
        | grep -vE '^\s*$|^\s*Initializing|^\s*[>=]+ *[0-9]+/[0-9]+'
}

# Distinguish "this edit broke it" from "it was already broken": run the same
# suite at HEAD in a throwaway worktree and compare the failing test names.
# Measured: an fzf-pin refactor once broke this repo's spec, and the next
# unrelated litre edit got blamed for it.
fails() { grep -E '^\s*FAIL' <<<"$1" | sed 's/^\s*//' | sort -u; }
now_fails="$(fails "$(clean "$out")")"
head_fails=""
wt="$(mktemp -d)"
if [[ -n "$now_fails" ]] && git -C "$repo" worktree add --detach --quiet "$wt" HEAD 2>/dev/null; then
    head_out="$("$wt/tests/run.sh" 2>&1)" || true
    head_fails="$(fails "$(clean "$head_out")")"
    git -C "$repo" worktree remove --force "$wt" 2>/dev/null
fi
rm -rf "$wt"

if [[ -n "$now_fails" && "$now_fails" == "$head_fails" ]]; then
    msg="tests/run.sh failed, but the same tests already fail at HEAD -- pre-existing breakage, not this edit. Find what broke them before piling more changes on:"
else
    msg="tests/run.sh failed (these failures are new vs HEAD):"
fi
{
    echo "$msg"
    clean "$out"
} >&2
exit 2

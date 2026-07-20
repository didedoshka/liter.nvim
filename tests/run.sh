#!/usr/bin/env bash
# Offline checks for litre: static analysis + the end-to-end spec. No network,
# no cmake, no dap -- safe anywhere. There is no standalone lua on this box:
# `nvim --clean -l` is the Lua runtime.
#
#   tests/run.sh          both tiers
#   tests/run.sh spec     just the spec
#   tests/run.sh check    just lua-language-server
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
what="${1:-all}"
rc=0

if [[ "$what" == "all" || "$what" == "check" ]]; then
    if command -v lua-language-server >/dev/null 2>&1; then
        echo "== lua-language-server --check"
        # must point at the repo root or .luarc.json is not found and every
        # `vim` is an undefined global
        out="$(cd "$repo" && timeout 300 lua-language-server --check "$repo" \
            --checklevel=Warning 2>&1)"
        if grep -q "no problems found" <<<"$out"; then
            echo "  ok    no problems"
        else
            echo "$out" | sed -e 's/^/  /'
            rc=1
        fi
    else
        echo "== lua-language-server not installed -- skipping static check"
    fi
fi

if [[ "$what" == "all" || "$what" == "spec" ]]; then
    echo "== spec (nvim --clean)"
    # isolated XDG_DATA_HOME so param state never touches the real one
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    # one nvim per spec: the advanced spec consumes the typeahead and mutates
    # config.opts, so it must not share a process with the base spec
    for spec in "$repo"/tests/spec*.lua; do
        XDG_DATA_HOME="$tmp" timeout 120 nvim --clean --headless -l "$spec" || rc=1
    done
fi

exit $rc

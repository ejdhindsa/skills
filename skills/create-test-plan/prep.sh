#!/bin/bash
# Deterministic prep for /create-test-plan.
#
#   prep.sh <repo> --candidates
#       Prints the branch, ticket key, how far HEAD is from each base candidate
#       (develop, main, master) and the uncommitted files, so the base branch and
#       whether to include uncommitted changes can be asked in one round.
#
#   prep.sh <repo> --base <branch> --out <dir> [--ticket <KEY>] [--fetch]
#       Writes <dir>/<repo>.md (the digest) plus the diff files it names, and prints
#       the digest path as the last line.

set -uo pipefail

DATA="${CREATE_TEST_PLAN_HOME:-$HOME/.claude/create-test-plan}"
REPO="" BASE="" OUT="" TICKET="" MODE="digest" FETCH=0

need_value() {
    if [[ $# -lt 2 || -z "$2" ]]; then
        echo "$1 needs a value" >&2
        exit 2
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --candidates) MODE="candidates"; shift ;;
        --base) need_value "$@"; BASE="$2"; shift 2 ;;
        --out) need_value "$@"; OUT="$2"; shift 2 ;;
        --ticket) need_value "$@"; TICKET="$2"; shift 2 ;;
        --fetch) FETCH=1; shift ;;
        -*) echo "Unknown option: $1" >&2; exit 2 ;;
        *)
            if [[ -n "$REPO" ]]; then
                echo "Unexpected argument: $1" >&2
                exit 2
            fi
            REPO="$1"; shift ;;
    esac
done

if [[ -z "$REPO" || ! -d "$REPO" ]]; then
    echo "Usage: prep.sh <repo> --candidates | prep.sh <repo> --base <branch> --out <dir> [--ticket <KEY>] [--fetch]" >&2
    exit 2
fi
REPO="$(cd "$REPO" && pwd)"
NAME="$(basename "$REPO")"
g() { git -C "$REPO" "$@"; }

if ! g rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Not a git repo: $REPO" >&2
    exit 1
fi

branch="$(g branch --show-current)"
[[ -z "$branch" ]] && branch="detached at $(g rev-parse --short HEAD)"
[[ -z "$TICKET" ]] && TICKET="$(grep -oE '[A-Z][A-Z0-9]+-[0-9]+' <<<"$branch" | head -1)"

resolve_ref() {
    if g rev-parse --verify -q "origin/$1" >/dev/null; then
        echo "origin/$1"
    elif g rev-parse --verify -q "$1" >/dev/null; then
        echo "$1"
    fi
}

if [[ "$MODE" == "candidates" ]]; then
    echo "repo: $NAME"
    echo "branch: $branch"
    echo "ticket key: ${TICKET:-none in branch name}"
    echo "origin/HEAD: $(g symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo unset)"
    found=0
    for b in develop main master; do
        ref="$(resolve_ref "$b")"
        [[ -z "$ref" ]] && continue
        mb="$(g merge-base HEAD "$ref" 2>/dev/null)" || continue
        found=1
        echo "candidate: $b ref=$ref ahead=$(g rev-list --count "$mb..HEAD") behind=$(g rev-list --count "HEAD..$ref") merge-base=$(g rev-parse --short "$mb")"
    done
    [[ $found -eq 0 ]] && echo "candidate: none of develop, main, master exists"
    g status --short --untracked-files=all | sed 's/^/uncommitted: /'
    exit 0
fi

if [[ -z "$BASE" || -z "$OUT" ]]; then
    echo "Digest mode needs --base and --out" >&2
    exit 2
fi

if [[ $FETCH -eq 1 ]]; then
    if command -v timeout >/dev/null; then
        timeout 20 git -C "$REPO" fetch --quiet origin "$BASE" 2>/dev/null || echo "fetch failed, using the local ref" >&2
    else
        git -C "$REPO" fetch --quiet origin "$BASE" 2>/dev/null || echo "fetch failed, using the local ref" >&2
    fi
fi

base_ref="$(resolve_ref "$BASE")"
if [[ -z "$base_ref" ]]; then
    echo "Base branch not found in $NAME: $BASE (neither origin/$BASE nor $BASE)" >&2
    exit 1
fi
mb="$(g merge-base HEAD "$base_ref" 2>/dev/null)"
if [[ -z "$mb" ]]; then
    echo "No merge-base between HEAD and $base_ref in $NAME" >&2
    exit 1
fi
head="$(g rev-parse HEAD)"

mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
DIGEST="$OUT/$NAME.md"
COMMITTED="$OUT/$NAME.committed.diff"
WORKTREE="$OUT/$NAME.worktree.diff"
g diff "$mb" HEAD >"$COMMITTED"
status="$(g status --short --untracked-files=all)"
if [[ -n "$status" ]]; then
    g diff "$mb" >"$WORKTREE"
else
    rm -f "$WORKTREE"
fi

key="${TICKET:-$(tr '/ ' '--' <<<"$branch")}"

spec_for() {
    local f="$1" dir base stem ext
    dir="$(dirname "$f")"; base="$(basename "$f")"; stem="${base%.*}"; ext="${base##*.}"
    case "$base" in *.spec.*|*.test.*) echo "$f"; return ;; esac
    for c in "$dir/$stem.spec.$ext" "$dir/$stem.test.$ext" "$dir/__tests__/$stem.spec.$ext" "$dir/__tests__/$stem.test.$ext"; do
        [[ -f "$REPO/$c" ]] && echo "$c"
    done
}

{
    echo "# $NAME"
    echo
    echo "- path: $REPO"
    echo "- branch: $branch"
    echo "- ticket key: ${TICKET:-none in branch name}"
    echo "- plan key: $key"
    echo "- base: $BASE ($base_ref)"
    echo "- merge-base: $(g rev-parse --short "$mb")"
    echo "- head: $(g rev-parse --short "$head")"
    echo "- commits since merge-base: $(g rev-list --count "$mb..HEAD")"
    echo
    echo "## Commits (oldest first)"
    g log --reverse --format='- %h %s' "$mb..HEAD"
    echo
    echo "## Changed files, committed (status, +added -removed)"
    paste <(g diff --name-status "$mb" HEAD | awk '{print $1}') <(g diff --numstat "$mb" HEAD) |
        awk -F'\t' '{printf "- %s %s (+%s -%s)\n", $1, $4, $2, $3}'
    echo
    echo "## Uncommitted changes (not in the committed diff)"
    if [[ -n "$status" ]]; then
        while IFS= read -r line; do
            path="${line:3}"
            note=""
            case "$(basename "$path")" in
                *.env|.env|.env.*|*.env.*)
                    keys="$(g diff -U0 -- "$path" 2>/dev/null | grep -E '^[+-][A-Za-z_][A-Za-z0-9_]*=' | cut -c2- | cut -d= -f1 | sort -u | tr '\n' ' ')"
                    note=" (env file; keys changed, values not shown: ${keys:-none tracked})" ;;
            esac
            echo "- \`$line\`$note"
        done <<<"$status"
        echo
        echo "Tracked uncommitted changes against the merge-base: $WORKTREE ($(wc -l <"$WORKTREE") lines). Untracked files above are not in any diff; read them directly."
    else
        echo "- none"
    fi
    echo
    echo "## Specs for changed files"
    specs="$(g diff --name-only "$mb" HEAD | while IFS= read -r f; do spec_for "$f"; done | sort -u)"
    if [[ -n "$specs" ]]; then sed 's/^/- /' <<<"$specs"; else echo "- none found next to the changed files"; fi
    echo
    echo "## Tooling"
    if [[ -f "$REPO/package.json" ]]; then
        echo "package.json scripts:"
        python3 -c 'import json,sys; s=json.load(open(sys.argv[1])).get("scripts",{}); [print(f"- {k}: {v}") for k,v in s.items()]' "$REPO/package.json" 2>/dev/null
        bins=""
        for b in jest vitest mocha eslint prettier moleculer-runner env-cmd playwright; do
            [[ -e "$REPO/node_modules/.bin/$b" ]] && bins="$bins $b"
        done
        echo "- node_modules/.bin:${bins:- none of the known runners (node_modules missing?)}"
    fi
    for f in .nvmrc .node-version .tool-versions; do
        [[ -f "$REPO/$f" ]] && echo "- $f: $(head -1 "$REPO/$f")"
    done
    compose="$(cd "$REPO" && ls docker-compose*.y*ml compose*.y*ml 2>/dev/null | tr '\n' ' ')"
    echo "- compose files: ${compose:-none}"
    envs="$(cd "$REPO" && ls -a | grep -E '(^\.env|\.env$|\.env\.)' | tr '\n' ' ')"
    echo "- env files (names only): ${envs:-none}"
    mocks="$(cd "$REPO" && find . -path ./node_modules -prune -o -type d \( -name mocks -o -name __mocks__ -o -name mock \) -print 2>/dev/null | head -10 | tr '\n' ' ')"
    echo "- mock folders: ${mocks:-none}"
    [[ -d "$REPO/repl-commands" ]] && echo "- repl-commands: $(ls "$REPO/repl-commands" | wc -l) files"
    echo
    echo "## Standards and setup docs present"
    for f in CLAUDE.md AGENTS.md .claude/CLAUDE.md CONTRIBUTING.md STYLE.md README.md docs; do
        [[ -e "$REPO/$f" ]] && echo "- $f"
    done
    echo
    echo "## Environment notes"
    if [[ -f "$DATA/env/$NAME.md" ]]; then
        echo "- $DATA/env/$NAME.md (last changed $(python3 -c 'import os,sys,datetime; print(datetime.date.fromtimestamp(os.path.getmtime(sys.argv[1])))' "$DATA/env/$NAME.md"))"
    else
        echo "- missing: $DATA/env/$NAME.md (run discovery)"
    fi
    echo
    echo "## Existing plan for this key"
    if [[ -f "$DATA/plans/$key/plan.json" ]]; then
        python3 - "$DATA/plans/$key/plan.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))["meta"]
print(f"- {sys.argv[1]}")
print(f"- url: {m.get('url') or 'not published'}")
for r in m.get("repos", []):
    print(f"- {r['name']}: head {r['head']}, base {r['base']}, merge-base {r['mergeBase']}")
print(f"- updated: {m.get('updated')}, dry run: {(m.get('dryRun') or {}).get('outcome', 'none')}")
PY
    else
        echo "- none ($DATA/plans/$key/plan.json)"
    fi
    echo
    echo "## Earlier test plans"
    shopt -s nullglob
    for p in "$DATA"/plans/*/plan.json; do
        [[ "$p" == "$DATA/plans/$key/plan.json" ]] && continue
        python3 -c 'import json,sys; m=json.load(open(sys.argv[1]))["meta"]; t=m.get("ticket") or {}; print("- " + sys.argv[1] + ": " + " ".join(x for x in (t.get("key"), m.get("title")) if x) + " [" + ", ".join(r["name"] for r in m.get("repos", [])) + "]")' "$p" 2>/dev/null
    done
    for p in "$REPO"/plans/*test-plan*; do echo "- $p (older format)"; done
    shopt -u nullglob
    echo
    echo "## Diff files"
    echo "- committed: $COMMITTED ($(wc -l <"$COMMITTED") lines)"
    [[ -f "$WORKTREE" ]] && echo "- tracked uncommitted vs merge-base: $WORKTREE ($(wc -l <"$WORKTREE") lines)"
} >"$DIGEST"

echo "$DIGEST"

#!/bin/bash
# Builds a compact digest of one repo's branch work (committed + uncommitted vs the
# merge-base with its root branch) so the drill starts from one small file instead of
# many git round-trips. Full diffs are written to a side file and read only on demand.
#
# Usage: prep.sh <repo-path> [--base <branch>] [--out <dir>]
# Last line of stdout: path to the digest.

set -uo pipefail

REPO=""
BASE_OVERRIDE=""
OUT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base) BASE_OVERRIDE="$2"; shift 2 ;;
        --out) OUT_DIR="$2"; shift 2 ;;
        *)
            if [[ -z "$REPO" ]]; then REPO="$1"; else echo "Unexpected argument: $1" >&2; exit 2; fi
            shift ;;
    esac
done

[[ -z "$REPO" ]] && { echo "Usage: prep.sh <repo-path> [--base <branch>] [--out <dir>]" >&2; exit 2; }
REPO="$(cd "$REPO" && pwd)" || exit 1
REPO_NAME="$(basename "$REPO")"
g() { git -C "$REPO" "$@"; }
g rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "Not a git repo: $REPO" >&2; exit 1; }

[[ -z "$OUT_DIR" ]] && OUT_DIR="$(mktemp -d -t what-did-i-do.XXXXXX)"
mkdir -p "$OUT_DIR"
DIGEST="$OUT_DIR/${REPO_NAME}.digest.md"
FULLDIFF="$OUT_DIR/${REPO_NAME}.diff"

root_ref=""
if [[ -n "$BASE_OVERRIDE" ]]; then
    for ref in "origin/$BASE_OVERRIDE" "$BASE_OVERRIDE"; do
        g rev-parse --verify "$ref" >/dev/null 2>&1 && { root_ref="$ref"; break; }
    done
    [[ -z "$root_ref" ]] && { echo "--base $BASE_OVERRIDE does not resolve in $REPO_NAME" >&2; exit 1; }
else
    symref="$(g symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || true)"
    if [[ -n "$symref" ]]; then
        root_ref="origin/${symref#refs/remotes/origin/}"
    else
        for c in develop main master; do
            g rev-parse --verify "origin/$c" >/dev/null 2>&1 && { root_ref="origin/$c"; break; }
        done
    fi
fi
[[ -z "$root_ref" ]] && { echo "Could not resolve a root branch in $REPO_NAME" >&2; exit 1; }

merge_base="$(g merge-base HEAD "$root_ref" 2>/dev/null || true)"
[[ -z "$merge_base" ]] && { echo "Could not compute merge-base against $root_ref in $REPO_NAME" >&2; exit 1; }

branch="$(g rev-parse --abbrev-ref HEAD)"
ticket="$(grep -oE '[A-Z][A-Z0-9]+-[0-9]+' <<<"$branch" | head -1)"

# Secrets, lockfiles and generated output are never useful to drill on and are expensive to read.
EXCLUDES=(':(exclude)*.env' ':(exclude)*.env.*' ':(exclude)package-lock.json' ':(exclude)yarn.lock'
          ':(exclude)pnpm-lock.yaml' ':(exclude)*.min.js' ':(exclude)dist/**' ':(exclude)coverage/**')

{
    echo "# what-did-i-even-do digest: $REPO_NAME"
    echo
    echo "- repo path: $REPO"
    echo "- branch: $branch"
    echo "- ticket key: ${ticket:-none found in branch name}"
    echo "- root: $root_ref"
    echo "- merge-base: $merge_base"
    echo "- HEAD: $(g rev-parse --short HEAD)"
    echo "- full diff (read hunks on demand, do not read whole if large): $FULLDIFF"
    echo
    echo "## Commits on branch"
    g log --no-merges --format='- %h %s' "$merge_base..HEAD" | head -40
    echo
    echo "## Changed files (committed + uncommitted, vs merge-base)"
    echo '```'
    g diff --stat=120 "$merge_base" -- . "${EXCLUDES[@]}" | tail -60
    echo '```'
    echo
    echo "## Excluded from drilling (names only)"
    excluded="$(g diff --name-only "$merge_base" | grep -E '(\.env($|\.)|lock\.json$|\.lock$|lock\.yaml$|\.min\.js$|^dist/|^coverage/)')"
    if [[ -n "$excluded" ]]; then sed 's/^/- /' <<<"$excluded"; else echo "- none"; fi
    echo
    echo "## Untracked files"
    untracked="$(g ls-files --others --exclude-standard)"
    if [[ -n "$untracked" ]]; then sed 's/^/- /' <<<"$untracked"; else echo "- none"; fi
    echo
    echo "## Changed functions/methods per file (from hunk headers)"
    g diff -U0 "$merge_base" -- . "${EXCLUDES[@]}" | awk '
        /^diff --git/ { file=$4; sub(/^b\//, "", file); next }
        /^@@/ { ctx=$0; sub(/^@@[^@]*@@ ?/, "", ctx); if (ctx != "" && !seen[file SUBSEP ctx]++) print "- " file ": " ctx }
    ' | head -80
    echo
    echo "## Plan/notes files mentioning the ticket"
    if [[ -n "$ticket" ]]; then
        found="$(cd "$REPO" && find . -maxdepth 3 -type f -iname "*${ticket}*" -not -path './node_modules/*' -not -path './.git/*' 2>/dev/null)"
        if [[ -n "$found" ]]; then sed "s|^\./|- $REPO/|" <<<"$found"; else echo "- none"; fi
    else
        echo "- no ticket key, skipped"
    fi
} > "$DIGEST"

g diff "$merge_base" -- . "${EXCLUDES[@]}" > "$FULLDIFF"
lines="$(grep -cE '^[+-][^+-]' "$FULLDIFF" || true)"
for f in $(g ls-files --others --exclude-standard | grep -vE '\.env($|\.)'); do
    echo "=== untracked: $f ===" >> "$FULLDIFF"
    head -300 "$REPO/$f" >> "$FULLDIFF" 2>/dev/null
done

printf '\n## Size\n- changed lines (approx): %s\n' "$lines" >> "$DIGEST"

echo "$DIGEST"

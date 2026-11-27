#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$HOME/.claude/skills"
for skill in "$DIR"/skills/*/; do
    name="$(basename "$skill")"
    dest="$HOME/.claude/skills/$name"
    if [[ -e "$dest" && ! -L "$dest" ]]; then
        echo "skipped $name: $dest is a real folder, not a link. Move it away and rerun." >&2
        continue
    fi
    ln -sfn "${skill%/}" "$dest"
    echo "linked $name"
done

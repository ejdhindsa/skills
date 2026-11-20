#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$HOME/.claude/skills"
ln -sfn "$DIR/skills/what-did-i-even-do" "$HOME/.claude/skills/what-did-i-even-do"

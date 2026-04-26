#!/usr/bin/env bash
set -euo pipefail

SKILL_DIR=".claude/skills/drawio"
mkdir -p "$SKILL_DIR"

# 公式リポジトリからSKILL.mdを取得
curl -fsSL \
  https://raw.githubusercontent.com/jgraph/drawio-mcp/main/skill-cli/drawio/SKILL.md \
  -o "$SKILL_DIR/SKILL.md"

echo "drawio skill installed to $SKILL_DIR"

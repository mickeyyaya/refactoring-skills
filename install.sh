#!/usr/bin/env bash
set -euo pipefail

SKILLS_DIR="${HOME}/.claude/skills"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_DIR="${SCRIPT_DIR}/skills"

if [ ! -d "$SOURCE_DIR" ]; then
  echo "Error: skills directory not found at ${SOURCE_DIR}"
  exit 1
fi

mkdir -p "$SKILLS_DIR"

installed=0
for skill_dir in "$SOURCE_DIR"/*/; do
  skill_name=$(basename "$skill_dir")
  target="${SKILLS_DIR}/${skill_name}"

  if [ -d "$target" ] && [ -f "${target}/SKILL.md" ]; then
    echo "Updating: ${skill_name}"
  else
    echo "Installing: ${skill_name}"
  fi

  mkdir -p "$target"
  cp "${skill_dir}/SKILL.md" "${target}/SKILL.md"
  installed=$((installed + 1))
done

echo ""
echo "Done. ${installed} refactoring skills installed to ${SKILLS_DIR}/"
echo "Restart Claude Code to pick up the new skills."

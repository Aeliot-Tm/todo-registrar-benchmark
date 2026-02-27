#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

CONFIG_FILE="$ROOT_DIR/config/projects.json"
PROJECTS_DIR="$ROOT_DIR/projects"

TODO_REGISTRAR_VERSION=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['todo_registrar_version'])")

mapfile -t PROJECTS < <(python3 -c "
import json
data = json.load(open('$CONFIG_FILE'))
for p in data['projects']:
    print('{slug}|{display_name}|{repo_url}|{version}|{git_tag}'.format(**p))
")

echo "Setting up target projects for todo-registrar $TODO_REGISTRAR_VERSION ..."
echo

for entry in "${PROJECTS[@]}"; do
    IFS='|' read -r slug display_name repo_url version git_tag <<< "$entry"

    target_dir="$PROJECTS_DIR/$slug"

    if [[ -d "$target_dir/.git" ]]; then
        echo "[$display_name] Already cloned at $target_dir — skipping."
    else
        echo "[$display_name] Cloning $repo_url @ $git_tag ..."
        git clone --depth 1 --branch "$git_tag" "$repo_url" "$target_dir"
        echo "[$display_name] Done."
    fi
    echo
done

echo "All projects are ready."

#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

CONFIG_FILE="$ROOT_DIR/config/projects.json"
PROJECTS_DIR="$ROOT_DIR/projects"
REPORTS_DIR="$ROOT_DIR/reports"
STUB_CONFIG_FILE="$ROOT_DIR/config/.todo-registrar.php"
STATS_FILENAME=".benchmark-stats.json"

TODO_REGISTRAR_VERSION=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE'))['todo_registrar_version'])")

mapfile -t PROJECTS < <(python3 -c "
import json
data = json.load(open('$CONFIG_FILE'))
for p in data['projects']:
    print('{slug}|{display_name}|{repo_url}|{version}|{git_tag}'.format(**p))
")

IMAGE="ghcr.io/aeliot-tm/todo-registrar:${TODO_REGISTRAR_VERSION}"
DATE=$(date +%Y-%m-%d)
REPORT_FILE="$REPORTS_DIR/todo-registrar-${TODO_REGISTRAR_VERSION}_${DATE}.md"

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────

format_number() {
    printf "%'.f" "$1"
}

format_bytes() {
    local bytes=$1
    local mb
    mb=$(echo "scale=0; $bytes / 1048576" | bc)
    echo "${mb} MB"
}

format_ms() {
    local ms=$1
    local sec
    sec=$(echo "scale=1; $ms / 1000" | bc)
    echo "${sec} s"
}

# ──────────────────────────────────────────────────────────────────────────────
# Pre-flight checks
# ──────────────────────────────────────────────────────────────────────────────

if ! command -v docker &>/dev/null; then
    echo "Error: docker is not available. Mount the Docker socket: -v /var/run/docker.sock:/var/run/docker.sock" >&2
    exit 1
fi

mkdir -p "$REPORTS_DIR"

echo "Pulling Docker image $IMAGE ..."
docker pull "$IMAGE"
echo

# Detect PHP version from the image
PHP_VERSION=$(docker run --rm --entrypoint php "$IMAGE" --version 2>/dev/null | head -1 | grep -oE 'PHP [0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "PHP unknown")

# Collect host system info (available via shared kernel)
CPU_MODEL=$(awk -F: '/model name/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}' /proc/cpuinfo 2>/dev/null || echo "unknown")
CPU_CORES=$(nproc 2>/dev/null || grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "?")
RAM_GB=$(awk '/MemTotal/ {printf "%.0f GB", $2/1048576}' /proc/meminfo 2>/dev/null || echo "unknown")

# ──────────────────────────────────────────────────────────────────────────────
# Run benchmarks
# ──────────────────────────────────────────────────────────────────────────────

declare -a RESULTS  # slug|display_name|repo_url|version|git_tag|php_files|php_lines|todo_count|elapsed_ms|peak_memory_bytes

for entry in "${PROJECTS[@]}"; do
    IFS='|' read -r slug display_name repo_url version git_tag <<< "$entry"

    project_dir="$PROJECTS_DIR/$slug"
    stats_file="$project_dir/$STATS_FILENAME"

    if [[ ! -d "$project_dir/.git" ]]; then
        echo "[$display_name] Project not found at $project_dir." >&2
        echo "[$display_name] Run scripts/setup.sh first." >&2
        exit 1
    fi

    echo "[$display_name] Resetting project to a clean state ..."
    git -C "$project_dir" checkout -- .
    rm -f "$stats_file"

    echo "[$display_name] Counting PHP files and lines ..."
    php_files=$(find "$project_dir" -type f -name "*.php" -not -path "*/vendor/*" | wc -l | tr -d ' ')
    php_lines=$(find "$project_dir" -type f -name "*.php" -not -path "*/vendor/*" -exec cat {} + | wc -l | tr -d ' ')

    echo "[$display_name] PHP files: $(format_number "$php_files"), lines: $(format_number "$php_lines")"

    echo "[$display_name] Running todo-registrar $TODO_REGISTRAR_VERSION ..."
    START_MS=$(python3 -c "import time; print(int(time.time() * 1000))")
    docker run --rm \
        -v "$project_dir:/code" \
        -v "$STUB_CONFIG_FILE:/code/.todo-registrar.php:ro" \
        "$IMAGE" \
        2>&1 || true
    ELAPSED_MS=$(( $(python3 -c "import time; print(int(time.time() * 1000))") - START_MS ))

    if [[ ! -f "$stats_file" ]]; then
        echo "[$display_name] Warning: stats file not found at $stats_file — no TODOs registered or stub failed." >&2
        todo_count=0
        peak_memory_bytes=0
    else
        todo_count=$(python3 -c "import json; d=json.load(open('$stats_file')); print(d['count'])")
        peak_memory_bytes=$(python3 -c "import json; d=json.load(open('$stats_file')); print(d['peak_memory_bytes'])")
    fi

    echo "[$display_name] TODOs registered: $todo_count, time: $(format_ms "$ELAPSED_MS"), memory: $(format_bytes "$peak_memory_bytes")"

    echo "[$display_name] Resetting injected keys ..."
    git -C "$project_dir" checkout -- .
    rm -f "$stats_file"

    RESULTS+=("${slug}|${display_name}|${repo_url}|${version}|${git_tag}|${php_files}|${php_lines}|${todo_count}|${ELAPSED_MS}|${peak_memory_bytes}")
    echo
done

# ──────────────────────────────────────────────────────────────────────────────
# Generate report
# ──────────────────────────────────────────────────────────────────────────────

echo "Generating report: $REPORT_FILE ..."

{
    echo "# TODO Registrar — Performance Report"
    echo
    echo "- **Version:** [${TODO_REGISTRAR_VERSION}](https://github.com/Aeliot-Tm/todo-registrar/releases/tag/${TODO_REGISTRAR_VERSION})"
    echo "- **Date:** ${DATE}"
    echo "- **Environment:** Docker (\`${IMAGE}\`), ${PHP_VERSION}"
    echo "- **CPU:** ${CPU_MODEL} (${CPU_CORES} cores)"
    echo "- **RAM:** ${RAM_GB}"
    echo
    echo "| Project | Version | PHP Files | PHP Lines | TODOs Registered | Time | Peak Memory |"
    echo "|---------|---------|----------:|----------:|-----------------:|-----:|------------:|"

    for result in "${RESULTS[@]}"; do
        IFS='|' read -r slug display_name repo_url version git_tag php_files php_lines todo_count elapsed_ms peak_memory_bytes <<< "$result"

        tag_url="${repo_url}/releases/tag/${git_tag}"
        fmt_files=$(format_number "$php_files")
        fmt_lines=$(format_number "$php_lines")
        fmt_todos=$(format_number "$todo_count")
        fmt_time=$(format_ms "$elapsed_ms")
        fmt_memory=$(format_bytes "$peak_memory_bytes")

        echo "| [${display_name}](${repo_url}) | [${version}](${tag_url}) | ${fmt_files} | ${fmt_lines} | ${fmt_todos} | ${fmt_time} | ${fmt_memory} |"
    done
} > "$REPORT_FILE"

echo
echo "Report saved to: $REPORT_FILE"

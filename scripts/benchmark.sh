#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

CONFIG_FILE="$ROOT_DIR/config/projects.json"
PROJECTS_DIR="$ROOT_DIR/projects"
REPORTS_DIR="$ROOT_DIR/reports"
STUB_CONFIG_FILE="$ROOT_DIR/config/.todo-registrar.php"
STATS_FILENAME=".benchmark-stats.json"
REPORT_FILENAME=".todo-registrar-report.json"

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

declare -a RESULTS  # slug|display_name|repo_url|version|git_tag|php_files|php_lines|comments_detected|todo_total|elapsed_ms|peak_memory_bytes

for entry in "${PROJECTS[@]}"; do
    IFS='|' read -r slug display_name repo_url version git_tag <<< "$entry"

    project_dir="$PROJECTS_DIR/$slug"
    stats_file="$project_dir/$STATS_FILENAME"
    report_file="$project_dir/$REPORT_FILENAME"

    if [[ ! -d "$project_dir/.git" ]]; then
        echo "[$display_name] Project not found at $project_dir." >&2
        echo "[$display_name] Run scripts/setup.sh first." >&2
        exit 1
    fi

    echo "[$display_name] Resetting project to a clean state ..."
    git -C "$project_dir" checkout -- .
    rm -f "$stats_file" "$report_file"

    echo "[$display_name] Running todo-registrar $TODO_REGISTRAR_VERSION ..."
    START_MS=$(python3 -c "import time; print(int(time.time() * 1000))")
    docker run --rm \
        -v "$project_dir:/code" \
        -v "$STUB_CONFIG_FILE:/code/.todo-registrar.php:ro" \
        --entrypoint stdbuf \
        "$IMAGE" \
        -o0 -e0 php -d output_buffering=0 -d implicit_flush=1 -d memory_limit=1024M /usr/local/bin/todo-registrar \
        --report-format=json \
        --report-path=/code/$REPORT_FILENAME \
        2>&1 || true
    ELAPSED_MS=$(( $(python3 -c "import time; print(int(time.time() * 1000))") - START_MS ))

    if [[ ! -f "$report_file" ]]; then
        echo "[$display_name] Warning: report file not found — todo-registrar may not support --report-format." >&2
        php_files=0
        php_lines=0
        comments_detected=0
        todo_total=0
    else
        php_files=$(python3 -c "
import json
d = json.load(open('$report_file'))
print(d.get('summary', {}).get('files', {}).get('analyzed', 0))
")
        comments_detected=$(python3 -c "
import json
d = json.load(open('$report_file'))
print(d.get('summary', {}).get('comments', {}).get('detected', 0))
")
        todo_total=$(python3 -c "
import json
d = json.load(open('$report_file'))
print(d.get('summary', {}).get('todos', {}).get('total', 0))
")
        php_lines=$(python3 -c "
import json, os
d = json.load(open('$report_file'))
project_dir = '$project_dir'
total = 0
for f in d.get('files', []):
    p = f.get('path', '')
    if p.startswith('/code/'):
        p = p[6:]
    elif p.startswith('/code'):
        p = p[5:]
    path = os.path.normpath(os.path.join(project_dir, p))
    if os.path.isfile(path):
        with open(path, 'rb') as fp:
            total += sum(1 for _ in fp)
print(total)
")
    fi

    if [[ ! -f "$stats_file" ]]; then
        peak_memory_bytes=0
    else
        peak_memory_bytes=$(python3 -c "import json; d=json.load(open('$stats_file')); print(d.get('peak_memory_bytes', 0))")
    fi

    echo "[$display_name] Files: $(format_number "$php_files"), lines: $(format_number "$php_lines"), comments: $(format_number "$comments_detected"), TODOs: $(format_number "$todo_total"), time: $(format_ms "$ELAPSED_MS"), memory: $(format_bytes "$peak_memory_bytes")"

    echo "[$display_name] Resetting injected keys ..."
    git -C "$project_dir" checkout -- .
    rm -f "$stats_file" "$report_file"

    RESULTS+=("${slug}|${display_name}|${repo_url}|${version}|${git_tag}|${php_files}|${php_lines}|${comments_detected}|${todo_total}|${ELAPSED_MS}|${peak_memory_bytes}")
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
    echo "| Project | Version | PHP Files | PHP Lines | Comments | TODOs | Time | Peak Memory |"
    echo "|---------|---------|----------:|----------:|---------:|------:|-----:|------------:|"

    for result in "${RESULTS[@]}"; do
        IFS='|' read -r slug display_name repo_url version git_tag php_files php_lines comments_detected todo_total elapsed_ms peak_memory_bytes <<< "$result"

        tag_url="${repo_url}/releases/tag/${git_tag}"
        fmt_files=$(format_number "$php_files")
        fmt_lines=$(format_number "$php_lines")
        fmt_comments=$(format_number "$comments_detected")
        fmt_todos=$(format_number "$todo_total")
        fmt_time=$(format_ms "$elapsed_ms")
        fmt_memory=$(format_bytes "$peak_memory_bytes")

        echo "| [${display_name}](${repo_url}) | [${version}](${tag_url}) | ${fmt_files} | ${fmt_lines} | ${fmt_comments} | ${fmt_todos} | ${fmt_time} | ${fmt_memory} |"
    done
} > "$REPORT_FILE"

echo
echo "Report saved to: $REPORT_FILE"

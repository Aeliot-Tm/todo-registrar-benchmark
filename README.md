# TODO Registrar — Performance Benchmark

Performance benchmark for [TODO Registrar](https://github.com/Aeliot-Tm/todo-registrar) — a tool
that detects TODO/FIXME/etc. comments in PHP code and registers them as issues in trackers
like GitHub Issues, GitLab, JIRA, and others.

## Latest benchmark

The latest report is always available in **[benchmark.md](benchmark.md)**.

> It is created by the running on standard GitHub Action.

## How it works

The benchmark runs `todo-registrar` against several real-world PHP projects using a **stub registrar**
— it counts TODOs and measures memory usage without actually creating any issues in any tracker.
This gives a realistic picture of the tool's scanning and parsing performance.

Measured metrics per project:

- number of PHP files and lines of code scanned
- number of TODO-comments detected
- execution time
- peak memory usage

### Running locally

**Requirements:** Docker only.

All tools (`python3`, `bc`, `git`, Docker CLI) run inside a container defined in [Dockerfile](Dockerfile).
The container shares the host Docker socket so it can pull and run the `todo-registrar` image internally.

1. Clone target projects (one-time setup, skipped if already done)
   ```shell
   docker compose run --rm benchmark bash scripts/setup.sh
   ```
2. Run benchmark — writes a report to reports/
   ```shell
   docker compose run --rm benchmark bash scripts/benchmark.sh
   ```

The report is saved to `reports/todo-registrar-{version}_{date}.md`.

### Adding projects

Edit [`config/projects.json`](config/projects.json):

```json
{
    "todo_registrar_version": "3.3.0",
    "projects": [
        {
            "slug": "my-project",
            "display_name": "My Project",
            "repo_url": "https://github.com/owner/repo",
            "version": "1.0.0",
            "git_tag": "v1.0.0"
        }
    ]
}
```

Then run `bash scripts/setup.sh` to clone the new project.

### Project structure

```
.github/workflows/
  benchmark.yml          — GitHub Actions workflow (manual trigger)
config/
  projects.json          — list of projects and todo-registrar version to benchmark
  .todo-registrar.php    — stub config (no real issue tracker, records stats to JSON)
scripts/
  setup.sh               — clone target projects locally
  benchmark.sh           — run benchmark and write a Markdown report to reports/
projects/                — projects to be analized (gitignored)
reports/                 — generated reports (gitignored)
benchmark.md             — latest report committed to the repository
```

**License**: [MIT](LICENSE)

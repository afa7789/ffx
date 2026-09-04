#!/usr/bin/env bash
#
# Startup latency benchmarks for ffx.
#
# Measures wall-clock time for common CLI commands using hyperfine.
# Results are written to benchmarks/results/ in JSON format for CI consumption.
#
# Usage:
#   ./benchmarks/startup.sh              # run all benchmarks
#   ./benchmarks/startup.sh --quick      # fewer iterations (20 runs)
#   ./benchmarks/startup.sh --ci         # CI settings (100 runs, skip build)
#
# Requires: hyperfine (https://github.com/sharkdp/hyperfine)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FFX_BIN="${REPO_ROOT}/zig-out/bin/ffx"
RESULTS_DIR="${REPO_ROOT}/benchmarks/results"
SESSION_FIXTURE_ROOT="${TMPDIR:-/tmp}/ffx-session-list-benchmark-$$"
SESSION_FIXTURE_HOME="${SESSION_FIXTURE_ROOT}/home"
SESSION_FIXTURE_WORKSPACE="${SESSION_FIXTURE_ROOT}/workspace"
GENERAL_FIXTURE_HOME="${SESSION_FIXTURE_ROOT}/general-home"

cleanup() {
  rm -rf "$SESSION_FIXTURE_ROOT"
}
trap cleanup EXIT

if ! command -v hyperfine &>/dev/null; then
  echo "error: hyperfine is not installed"
  echo "       brew install hyperfine  (macOS)"
  echo "       apt install hyperfine   (Debian/Ubuntu)"
  echo "       cargo install hyperfine (Rust/Cargo)"
  exit 1
fi

RUNS=100
WARMUP=10
SKIP_BUILD=false
SHELL_OPTS=(-N)
case "${1:-}" in
  --quick)  RUNS=20;  WARMUP=3 ;;
  --ci)     RUNS=100; WARMUP=10; SKIP_BUILD=true ;;
esac

if [ "$SKIP_BUILD" = false ]; then
  echo "Building ffx (ReleaseSafe)..."
  (cd "$REPO_ROOT" && zig build -Doptimize=ReleaseSafe)
fi

if [ ! -x "$FFX_BIN" ]; then
  echo "error: ffx binary not found at $FFX_BIN"
  exit 1
fi

mkdir -p "$RESULTS_DIR"
rm -f "${RESULTS_DIR}/tasks.json"
mkdir -p "$SESSION_FIXTURE_HOME" "$SESSION_FIXTURE_WORKSPACE" "$GENERAL_FIXTURE_HOME"
mkdir -p "$GENERAL_FIXTURE_HOME/.ffx"
chmod 700 "$GENERAL_FIXTURE_HOME/.ffx"
printf '%s\n' \
  '{"model":"openai/gpt-5.4","effort":"high","fast_mode":false,"startup_scrollback":true,"prompt_history":{"enabled":true},"statusLine":{"sandbox":true,"context":true},"permission":{"bash":{"git status *":"allow"}}}' \
  > "$GENERAL_FIXTURE_HOME/.ffx/settings.json"
chmod 600 "$GENERAL_FIXTURE_HOME/.ffx/settings.json"
python3 "${REPO_ROOT}/benchmarks/session_list_fixture.py" \
  --home "$SESSION_FIXTURE_HOME" \
  --workspace "$SESSION_FIXTURE_WORKSPACE"

if [ -x /usr/bin/true ]; then
  TRUE_BIN=/usr/bin/true
elif [ -x /bin/true ]; then
  TRUE_BIN=/bin/true
else
  TRUE_BIN=true
fi

echo "=== ffx startup benchmarks ==="
echo "binary: $FFX_BIN"
echo "runs:   $RUNS (warmup: $WARMUP)"
echo ""

# Baseline: process launch floor on this host. This is reported for context;
# the budget checker still enforces each ffx command's raw wall-clock mean.
echo "--- process baseline ---"
HOME="$GENERAL_FIXTURE_HOME" hyperfine \
  "${SHELL_OPTS[@]}" \
  --runs "$RUNS" \
  --warmup "$WARMUP" \
  --export-json "${RESULTS_DIR}/baseline.json" \
  --command-name "process baseline" \
  "$TRUE_BIN"

echo ""

# Benchmark 0: ffx startup (CLI dispatch, no TTY needed)
echo "--- ffx (startup) ---"
HOME="$GENERAL_FIXTURE_HOME" FFX_BENCH=1 hyperfine \
  "${SHELL_OPTS[@]}" \
  --runs "$RUNS" \
  --warmup "$WARMUP" \
  --export-json "${RESULTS_DIR}/startup.json" \
  --command-name "ffx (startup)" \
  "$FFX_BIN"

echo ""

# Benchmark 1: ffx help (minimal startup path)
echo "--- ffx help ---"
HOME="$GENERAL_FIXTURE_HOME" hyperfine \
  "${SHELL_OPTS[@]}" \
  --runs "$RUNS" \
  --warmup "$WARMUP" \
  --export-json "${RESULTS_DIR}/help.json" \
  --command-name "ffx help" \
  "$FFX_BIN help"

echo ""

# Benchmark 2: ffx status --json (config load + JSON serialize)
echo "--- ffx status --json ---"
HOME="$GENERAL_FIXTURE_HOME" hyperfine \
  "${SHELL_OPTS[@]}" \
  --runs "$RUNS" \
  --warmup "$WARMUP" \
  --export-json "${RESULTS_DIR}/status.json" \
  --command-name "ffx status --json" \
  "$FFX_BIN status --json"

echo ""

# Benchmark 3: ffx doctor --json (system checks)
echo "--- ffx doctor --json ---"
HOME="$GENERAL_FIXTURE_HOME" hyperfine \
  "${SHELL_OPTS[@]}" \
  --runs "$RUNS" \
  --warmup "$WARMUP" \
  --export-json "${RESULTS_DIR}/doctor.json" \
  --command-name "ffx doctor --json" \
  "$FFX_BIN doctor --json"

echo ""

# Benchmark 4: ffx sessions --json (file I/O path)
echo "--- ffx sessions --json ---"
HOME="$SESSION_FIXTURE_HOME" hyperfine \
  "${SHELL_OPTS[@]}" \
  --runs "$RUNS" \
  --warmup "$WARMUP" \
  --export-json "${RESULTS_DIR}/sessions.json" \
  --command-name "ffx sessions --json" \
  "$FFX_BIN sessions --json"

echo ""

# Benchmark 5: ffx background --json (file I/O path)
echo "--- ffx background --json ---"
(
  cd "$SESSION_FIXTURE_WORKSPACE"
  HOME="$SESSION_FIXTURE_HOME" hyperfine \
    "${SHELL_OPTS[@]}" \
    --runs "$RUNS" \
    --warmup "$WARMUP" \
    --export-json "${RESULTS_DIR}/background.json" \
    --command-name "ffx background --json" \
    "$FFX_BIN background --json"
)

echo ""

# Combine results into a single summary for CI
echo "--- summary ---"
python3 "${REPO_ROOT}/benchmarks/summarize.py"
python3 "${REPO_ROOT}/benchmarks/check_budgets.py"

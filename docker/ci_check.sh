#!/usr/bin/env bash
# CI helper — build + run check for the Advanced Rust code corpus.
#
# Builds the docker-compose "runner" image (if not already present) and runs the
# in-container batch driver (docker/test_all.sh) over the requested corpus dirs,
# then evaluates the results and exits non-zero if any file failed to BUILD or RUN.
#
# This is the batch equivalent of the per-file invocation documented in
# docker-compose.yml ("docker compose run --rm runner <file>"): it uses the same
# image and the same build/run logic (rustc vs cargo, edition 2021/2024, nightly)
# that docker/run.sh applies per file — just over every file at once.
#
# Usage:
#   docker/ci_check.sh                    # examples exercises solutions
#   docker/ci_check.sh examples
#   docker/ci_check.sh exercises solutions
#
# Env:
#   RUNNER_IMAGE   image tag to use / build (default: advanced-rust-runner)
#
# Exit status: 0 = everything built and ran; 1 = a real build/run/output failure;
#              2 = infrastructure error (image build or container run failed).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
IMAGE="${RUNNER_IMAGE:-advanced-rust-runner}"
MANIFEST="$ROOT/CODE_MANIFEST.json"

dirs=("$@")
[ ${#dirs[@]} -gt 0 ] || dirs=(examples exercises solutions)

# Intentionally-incomplete lab starters carry status="starter-incomplete" in the
# manifest. They are SUPPOSED not to compile until the reader finishes them, so a
# STARTER_NOCOMPILE on these is expected — only an UNEXPECTED one is a regression.
expected_nocompile=""
# Read the manifest on stdin so the interpreter never has to resolve a path.
extract='import json,sys; m=json.load(sys.stdin); print("\n".join(f["path"] for f in m["files"] if f.get("status")=="starter-incomplete"))'
if [ -f "$MANIFEST" ]; then
  for cand in python3 python; do
    command -v "$cand" >/dev/null 2>&1 || continue
    if out="$("$cand" -c "$extract" < "$MANIFEST" 2>/dev/null)"; then
      expected_nocompile="${out//$'\r'/}"   # tolerate a stub interpreter / CRLF
      break
    fi
  done
fi
is_expected_nocompile() {
  [ -n "$expected_nocompile" ] || return 1
  printf '%s\n' "$expected_nocompile" | grep -Fxq "$1"
}

# 1. Ensure the runner image exists. In CI a separate, cached step builds it; this
#    fallback keeps the script self-contained for local runs.
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "::group::docker build $IMAGE"
  docker build -t "$IMAGE" "$ROOT/docker" || { echo "::error::runner image build failed"; exit 2; }
  echo "::endgroup::"
fi

# 2. Run the batch driver inside the container, repo mounted read-only at /work —
#    exactly the mount docker-compose.yml uses for the runner service.
results="$(mktemp)"
echo "::group::test_all.sh ${dirs[*]}"
docker run --rm \
  -v "$ROOT":/work:ro \
  -w /work \
  --entrypoint bash \
  "$IMAGE" /work/docker/test_all.sh "${dirs[@]}" | tee "$results"
run_pipe=("${PIPESTATUS[@]}")   # capture immediately — any later command clobbers PIPESTATUS
echo "::endgroup::"
if [ "${run_pipe[0]}" -ne 0 ] || [ "${run_pipe[1]:-0}" -ne 0 ]; then
  echo "::error::batch driver failed (docker exit ${run_pipe[0]}, tee exit ${run_pipe[1]:-0})"
  rm -f "$results"; exit 2
fi

# 3. Evaluate the TSV emitted by test_all.sh:  <STATUS>\t<relpath>\t<base64 detail>
fail=0
declare -A count
print_detail() { printf '%s' "$1" | base64 -d 2>/dev/null | sed 's/^/      /'; }

while IFS=$'\t' read -r st rel detail; do
  [ -n "${st:-}" ] || continue
  count["$st"]=$(( ${count["$st"]:-0} + 1 ))
  case "$st" in
    FAIL_BUILD_RUN|MISMATCH)
      fail=1
      echo "::error file=$rel::$st"
      echo "----- $st  $rel"
      print_detail "$detail"; echo
      ;;
    STARTER_NOCOMPILE)
      if is_expected_nocompile "$rel"; then
        count["STARTER_NOCOMPILE_EXPECTED"]=$(( ${count["STARTER_NOCOMPILE_EXPECTED"]:-0} + 1 ))
        echo "----- STARTER_NOCOMPILE (expected, by design)  $rel"
      else
        fail=1
        echo "::error file=$rel::starter unexpectedly failed to compile"
        echo "----- STARTER_NOCOMPILE (UNEXPECTED)  $rel"
        print_detail "$detail"; echo
      fi
      ;;
  esac
done < "$results"
rm -f "$results"

echo
echo "==================== summary: ${dirs[*]} ===================="
for k in PASS RAN_OK STARTER_OK SKIP_WASM SKIP_CUDA STARTER_NOCOMPILE STARTER_NOCOMPILE_EXPECTED MISMATCH FAIL_BUILD_RUN; do
  [ -n "${count[$k]:-}" ] && printf '  %-28s %d\n' "$k" "${count[$k]}"
done
echo "============================================================"
if [ "$fail" -ne 0 ]; then
  echo "RESULT: FAIL — at least one file failed to build or run."
else
  echo "RESULT: OK — everything built and ran (known-incomplete starters excused)."
fi
exit "$fail"

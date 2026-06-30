#!/usr/bin/env bash
#
# mayhem/test.sh — RUN gjson.rs's OWN test suite (already compiled by mayhem/build.sh
# via `cargo test --no-run` into $SRC/mayhem/test-target). This script only RUNS it.
#
# Anti-reward-hack: we assert on the suite's OUTPUT MARKERS ("test result: ok. N
# passed; M failed"), not just exit status — a PATCH that neuters the program to
# exit(0) produces no such marker (or 0 passed) and FAILS here. Emits a CTRF summary.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

TARGET_DIR="$SRC/mayhem/test-target"

# Locate the prebuilt unit-test runner(s) (cargo names them <crate>-<hash>). The lib
# tests live in src/test.rs (#[cfg(test)]), compiled into the gjson test binary.
mapfile -t RUNNERS < <(find "$TARGET_DIR/debug/deps" -maxdepth 1 -type f -name 'gjson-*' -executable 2>/dev/null)
if [ "${#RUNNERS[@]}" -eq 0 ]; then
  echo "FATAL: no prebuilt test runner under $TARGET_DIR/debug/deps — build.sh should have produced it" >&2
  emit_ctrf "cargo-test" 0 1
  exit 1
fi

passed_total=0
failed_total=0
saw_marker=0

for runner in "${RUNNERS[@]}"; do
  echo "=== running $runner ==="
  # Run from $SRC so the tests find testfiles/twitter.json (relative path).
  out="$("$runner" --test-threads="$MAYHEM_JOBS" 2>&1)" && rc=0 || rc=$?
  echo "$out"
  # Parse libtest summary: "test result: ok. 12 passed; 0 failed; 0 ignored; ..."
  while IFS= read -r line; do
    if [[ "$line" =~ test\ result:.*\ ([0-9]+)\ passed\;\ ([0-9]+)\ failed ]]; then
      passed_total=$(( passed_total + ${BASH_REMATCH[1]} ))
      failed_total=$(( failed_total + ${BASH_REMATCH[2]} ))
      saw_marker=1
    fi
  done <<< "$out"
  # A runner that exits nonzero but printed no failure marker still counts as a failure.
  if [ "$rc" -ne 0 ] && [ "$saw_marker" -eq 0 ]; then
    failed_total=$(( failed_total + 1 ))
  fi
done

# No summary marker at all ⇒ the binary never ran the real suite (neutered/no-op) ⇒ FAIL.
if [ "$saw_marker" -eq 0 ]; then
  echo "FATAL: no libtest 'test result:' marker seen — suite did not run" >&2
  emit_ctrf "cargo-test" 0 1
  exit 1
fi
# Sanity floor: the suite must actually pass tests (12 #[test] in src/test.rs).
if [ "$passed_total" -eq 0 ]; then
  echo "FATAL: 0 tests passed — oracle would be vacuous" >&2
  emit_ctrf "cargo-test" 0 $(( failed_total > 0 ? failed_total : 1 ))
  exit 1
fi

emit_ctrf "cargo-test" "$passed_total" "$failed_total"

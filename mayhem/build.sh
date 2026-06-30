#!/usr/bin/env bash
#
# mayhem/build.sh — build gjson.rs's cargo-fuzz target as a sanitized libFuzzer binary
# (OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS), then build the upstream test
# suite (normal flags) so mayhem/test.sh can RUN it.
#
# Runs inside the commit image (RUST mayhem/Dockerfile) as `mayhem` in /mayhem.
# Toolchain + cargo registry at $CARGO_HOME=/opt/toolchains/rust/cargo (absolute,
# $HOME-independent). AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS
# script OFFLINE — this first (online) build populates the registry; do NOT hard-code
# --offline (the rlenv runtime exports CARGO_NET_OFFLINE=true for the re-run).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# Sanitizers (§6.1): the base provides clang $SANITIZER_FLAGS (ASan+UBSan, halting).
# rustc can't consume those clang flags, but we honor the KNOB: when $SANITIZER_FLAGS
# is non-empty we instrument the Rust build with ASan (the OSS-Fuzz Rust path); an
# explicit empty `--build-arg SANITIZER_FLAGS=` yields an un-sanitized build. We
# reference $SANITIZER_FLAGS so the fuzzed code is sanitized by default.
RUST_SAN=""
if [ -n "${SANITIZER_FLAGS:-}" ]; then
  RUST_SAN="-Zsanitizer=address"
fi

# Debug info (§6.2 item 10): the produced binary MUST carry DWARF < 4 (Mayhem triage
# can't read DWARF >= 4). rustc nightly defaults to DWARF-5, so we pin -Zdwarf-version=3
# for Rust code. The libfuzzer-sys cc shim is compiled by clang (DWARF-5 default), so we
# pin its DWARF too via CFLAGS/CXXFLAGS. $RUST_DEBUG_FLAGS threads any extra base pins.
export RUSTFLAGS="${RUSTFLAGS:-} ${RUST_DEBUG_FLAGS:-} --cfg fuzzing ${RUST_SAN} -Zdwarf-version=3 -Cdebuginfo=1 -Cforce-frame-pointers"
export CFLAGS="${CFLAGS:-} -gdwarf-3"
export CXXFLAGS="${CXXFLAGS:-} -gdwarf-3"

# The bundled ASan runtime archive that `-Zsanitizer=address` links is precompiled
# with clang (DWARF-5) and ships with full debug info, which would otherwise land
# DWARF-5 compile units in the final binary and fail the DWARF < 4 gate. Strip the
# debug info from that runtime archive (a toolchain artifact, NOT project code).
# Idempotent: re-running --strip-debug on an already-stripped archive is a no-op,
# so the offline PATCH re-run stays clean.
if [ -n "${RUST_SAN}" ]; then
  RT_LIB_DIR="$(rustc --print sysroot)/lib/rustlib/x86_64-unknown-linux-gnu/lib"
  for asan in "$RT_LIB_DIR"/librustc-*_rt.asan.a; do
    [ -f "$asan" ] || continue
    if [ -w "$asan" ]; then
      objcopy --strip-debug "$asan" "$asan.stripped" && mv "$asan.stripped" "$asan"
      echo "stripped debug info from bundled ASan runtime: $asan"
    fi
  done
fi

# Additive cargo-fuzz crate (upstream's own extra/fuzz/ is afl-based, not cargo-fuzz).
FUZZ_DIR="mayhem/fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

# Discover every target from the crate's fuzz_targets/ dir (one binary per target).
FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

# Use the image's DEFAULT toolchain (the Dockerfile pinned it).
for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  cargo fuzz build --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

# ── Build the upstream test suite too (clean, NON-sanitized build) ─────────────
# mayhem/test.sh only RUNS this; it never compiles. Debug build (no --release) so
# debug_assertions/assert! stay live — the oracle must bite a neutered binary.
# CARGO_TARGET_DIR is fixed under $SRC so test.sh finds the runner deterministically.
echo "=== cargo test --no-run (upstream suite, normal flags) ==="
# Build WITHOUT the fuzzing RUSTFLAGS / CFLAGS (a clean, non-sanitized compile).
env -u RUSTFLAGS -u CFLAGS -u CXXFLAGS \
  cargo test --no-run --target-dir "$SRC/mayhem/test-target" 2>&1 | tail -20

echo "build.sh complete"

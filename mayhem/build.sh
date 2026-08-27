#!/usr/bin/env bash
#
# mayhem/build.sh — build hiredis's fuzz harnesses + its own functional test suite.
#
# One Mayhem target, a libFuzzer harness over raw bytes (no file I/O, no absolute paths):
#   - resp_reader_fuzzer     Drives redisReader (read.c) directly — the RESP2/RESP3 protocol parser
#                            that decodes whatever a Redis-speaking peer sends over the wire
#                            (hiredis.c uses it the same way: feed+GetReply in a loop). The real
#                            security-relevant surface (CVE-2021-32765 lived here).
#
# format_command_fuzzer (upstream's old OSS-Fuzz harness) is deliberately NOT ported — see
# repos/hiredis.yaml `dismissals: dropped-target:format_command_fuzzer` for the reason: upstream
# itself deleted it (commit fa073c17df44), explaining it feeds redisFormatCommand() a random
# *format* string with no matching varargs, which is UB by construction, not a hiredis defect —
# it cannot find real bugs. §6.2 item 12's OSS-Fuzz-harness-parity rule still nominally applies
# (google/oss-fuzz's build script wasn't updated to match upstream's own deletion), but restoring
# a harness upstream removed as structurally incapable of finding bugs is gate-shaped busywork,
# not real coverage.
#
# Oracle (mayhem/test.sh) needs TWO binaries from this script, built with the project's NORMAL
# (unsanitized) flags so they stay an honest, independent functional check:
#   /mayhem/hiredis-test-oracle   hiredis's own test.c suite (hundreds of test_cond() assertions),
#                                 exercised against a REAL redis-server started by test.sh.
#   /mayhem/resp_kat              a tiny standalone KAT probe (mayhem/resp_kat.c) that parses a FIXED
#                                 RESP buffer with no server involved at all — belt-and-suspenders.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${SRC:=/mayhem}"
export CC LIB_FUZZING_ENGINE MAYHEM_JOBS
cd "$SRC"

# ---------------------------------------------------------------------------------------------
# 1) ORACLE build — hiredis's OWN test binary + a clean libhiredis.a, with the project's NORMAL
#    flags (NOT $SANITIZER_FLAGS, NOT $DEBUG_FLAGS): an independent, honest functional build.
#    hiredis's Makefile has its OWN `DEBUG_FLAGS` variable (?= -g -ggdb) — pin it explicitly on
#    the command line (highest make-variable precedence) so it can't pick up our fuzz-build
#    $DEBUG_FLAGS from the environment and so this build stays genuinely "normal flags".
#    `make clean` before AND after: before, so a PATCH-tier re-run on an already-built tree
#    doesn't link against leftover sanitized objects from a prior run; after, so step 2 starts
#    from a clean tree instead of reusing these normal-flags objects.
make clean
make USE_SSL=0 DEBUG_FLAGS="-g -ggdb" -j"$MAYHEM_JOBS" hiredis-test
cp hiredis-test /mayhem/hiredis-test-oracle
$CC -O2 -g -I. -o /mayhem/resp_kat mayhem/resp_kat.c libhiredis.a
make clean

# ---------------------------------------------------------------------------------------------
# 2) FUZZ build — hiredis itself, sanitized. Append -fsanitize=fuzzer-no-link to the LIBRARY
#    compile UNCONDITIONALLY (even when $SANITIZER_FLAGS is empty) so libFuzzer's SanCov coverage
#    instruments hiredis's own object code, not just the harness TU — otherwise the harness
#    builds, passes local fuzz-smoke, and records 0 edges once actually fuzzed.
make USE_SSL=0 OPTIMIZATION=-O1 DEBUG_FLAGS="$DEBUG_FLAGS" \
     CFLAGS="-fsanitize=fuzzer-no-link $SANITIZER_FLAGS" \
     -j"$MAYHEM_JOBS" static

FUZZ_CFLAGS="-std=c99 -pedantic -fPIC -fsanitize=fuzzer-no-link $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -I."

# ---------------------------------------------------------------------------------------------
# 3) Each harness, twice: the libFuzzer binary (Mayhem target) and a standalone run-once
#    reproducer (no fuzzing engine — takes one input file, natural crash, easy local repro).
for h in resp_reader_fuzzer; do
  # shellcheck disable=SC2086
  $CC $FUZZ_CFLAGS $LIB_FUZZING_ENGINE "mayhem/${h}.c" libhiredis.a -o "/mayhem/${h}"
  # shellcheck disable=SC2086
  $CC $FUZZ_CFLAGS "$STANDALONE_FUZZ_MAIN" "mayhem/${h}.c" libhiredis.a -o "/mayhem/${h}-standalone"
done

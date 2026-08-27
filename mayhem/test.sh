#!/usr/bin/env bash
#
# mayhem/test.sh — RUN (never build) hiredis's own functional test suite + a standalone KAT probe.
# Both binaries were built by mayhem/build.sh with the project's NORMAL (unsanitized) flags, so this
# is an honest, independent functional oracle — dynamically linked (the sabotage shim can neuter it).
#
# Two layered checks:
#  1. /mayhem/hiredis-test-oracle — hiredis's OWN test.c suite (~100+ test_cond() assertions: exact
#     RESP-serialization byte comparisons, exact parsed-reply-type/value checks, blocking I/O
#     behavior) run against a REAL redis-server this script starts. This is the primary oracle.
#  2. /mayhem/resp_kat — a fixed-input KAT probe (no server, no sockets): parses a known RESP buffer
#     and asserts EXACT output. Belt-and-suspenders per the netnew brief §4 — unconditional, no
#     skip-if-missing guard.
#
# A neutered program (LD_PRELOAD _exit(0) shim) makes BOTH binaries exit immediately with no output:
# hiredis-test-oracle would print 0 PASSED lines (we require a real minimum), and resp_kat would
# print nothing (mismatching the exact expected string) — either alone fails this script.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "${SRC:-/mayhem}"

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

TOTAL_PASSED=0
TOTAL_FAILED=0
TOTAL_SKIPPED=0

# ---------------------------------------------------------------------------------------------
# 1) KAT probe — fixed input, exact expected output, no server needed. Run FIRST: unconditional,
#    cheap, and gives an independent signal even if the server-backed suite below can't start.
KAT_BIN=/mayhem/resp_kat
if [ ! -x "$KAT_BIN" ]; then
  echo "missing $KAT_BIN — run mayhem/build.sh first" >&2
  TOTAL_FAILED=$((TOTAL_FAILED + 1))
else
  kat_out="$("$KAT_BIN" 2>&1)"; kat_rc=$?
  kat_expected="$(printf 'SET\nfoo\nhello')"
  echo "--- resp_kat output ---"
  printf '%s\n' "$kat_out"
  if [ "$kat_rc" -eq 0 ] && [ "$kat_out" = "$kat_expected" ]; then
    echo "resp_kat: OK (parsed *3\\r\\n\$3\\r\\nSET... -> SET/foo/hello)"
    TOTAL_PASSED=$((TOTAL_PASSED + 1))
  else
    echo "resp_kat: MISMATCH (rc=$kat_rc, expected 'SET\\nfoo\\nhello', got: $kat_out)" >&2
    TOTAL_FAILED=$((TOTAL_FAILED + 1))
  fi
fi

# ---------------------------------------------------------------------------------------------
# 2) hiredis's own functional suite against a REAL redis-server.
BIN=/mayhem/hiredis-test-oracle
if [ ! -x "$BIN" ]; then
  echo "missing $BIN — run mayhem/build.sh first" >&2
  TOTAL_FAILED=$((TOTAL_FAILED + 1))
  emit_ctrf "hiredis-test+resp_kat" "$TOTAL_PASSED" "$TOTAL_FAILED" "$TOTAL_SKIPPED"
  exit $?
fi

REDIS_SERVER_BIN="$(command -v redis-server || true)"
if [ -z "$REDIS_SERVER_BIN" ]; then
  echo "redis-server not found in PATH — mayhem/Dockerfile must apt-get install redis-server" >&2
  TOTAL_FAILED=$((TOTAL_FAILED + 1))
  emit_ctrf "hiredis-test+resp_kat" "$TOTAL_PASSED" "$TOTAL_FAILED" "$TOTAL_SKIPPED"
  exit $?
fi

WORKDIR="$(mktemp -d)"
PIDFILE="$WORKDIR/redis.pid"
SOCK="$WORKDIR/redis.sock"
PORT=56379

cat > "$WORKDIR/redis.conf" <<EOF
daemonize yes
pidfile $PIDFILE
port $PORT
bind 127.0.0.1
unixsocket $SOCK
unixsocketperm 777
enable-debug-command local
EOF

cleanup() {
  [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null
  rm -rf "$WORKDIR" 2>/dev/null
}
trap cleanup EXIT INT TERM

"$REDIS_SERVER_BIN" "$WORKDIR/redis.conf"

tries=0
while [ ! -S "$SOCK" ]; do
  sleep 1
  tries=$((tries + 1))
  if [ "$tries" -ge 30 ]; then
    echo "redis-server did not come up (no unix socket after 30s)" >&2
    TOTAL_FAILED=$((TOTAL_FAILED + 1))
    emit_ctrf "hiredis-test+resp_kat" "$TOTAL_PASSED" "$TOTAL_FAILED" "$TOTAL_SKIPPED"
    exit $?
  fi
done

out="$("$BIN" -h 127.0.0.1 -p "$PORT" -s "$SOCK" --skip-throughput --skip-inherit-fd 2>&1)"
rc=$?
echo "--- hiredis-test-oracle output ---"
printf '%s\n' "$out"

# test_cond() (test.c) prints a color-coded "PASSED"/"FAILED" banner PER ASSERTION — count those
# exactly (the ANSI codes distinguish them from the final plain-text "*** N TESTS FAILED ***"
# summary line, which also contains the bare word FAILED but must not be double-counted).
# -F (fixed string): the ANSI codes contain literal '[' characters that a regex engine would
# otherwise try to parse as bracket-expressions ("Unmatched [" — caught by running this for real,
# not just by inspection).
passed=$(printf '%s' "$out" | grep -cF $'\033[0;32mPASSED\033[0;0m')
failed=$(printf '%s' "$out" | grep -cF $'\033[0;31mFAILED\033[0;0m')
skipped=$(printf '%s' "$out" | grep -oE '\(([0-9]+) skipped\)' | grep -oE '[0-9]+' | tail -1)
skipped=${skipped:-0}

# Unconditional floor: hiredis's suite runs 100+ test_cond() assertions in the default (no SSL, no
# async) build. If a neutered binary produced empty/near-empty output, `passed` would be near 0 —
# treat that as a hard failure regardless of `rc` (a sabotaged binary can still _exit(0) cleanly).
MIN_EXPECTED_PASSED=50
if [ "$passed" -lt "$MIN_EXPECTED_PASSED" ]; then
  echo "hiredis-test-oracle: only $passed PASSED assertions seen (expected >= $MIN_EXPECTED_PASSED) — treating as a failed/neutered run" >&2
  failed=$((failed + 1))
fi
if [ "$rc" -ne 0 ] && [ "$failed" -eq 0 ]; then
  failed=$((failed + 1))
fi

TOTAL_PASSED=$((TOTAL_PASSED + passed))
TOTAL_FAILED=$((TOTAL_FAILED + failed))
TOTAL_SKIPPED=$((TOTAL_SKIPPED + skipped))

emit_ctrf "hiredis-test+resp_kat" "$TOTAL_PASSED" "$TOTAL_FAILED" "$TOTAL_SKIPPED"

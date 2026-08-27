# finding: unbounded allocation from an attacker-declared RESP array/map length

**Target:** `resp_reader_fuzzer`
**Class:** resource exhaustion (OOM abort under ASan), not memory corruption
**Reproducer:** `repro` (12 bytes: `*317321733\r\n`)

## Cause

`redisReader` bounds the *number* of multi-bulk elements it will accept via
`REDIS_READER_MAX_ARRAY_ELEMENTS` (`read.h`, `(1LL<<32) - 1`, i.e. ~4.29 billion) and, for
map/attribute replies specifically, an additional `LLONG_MAX/2`-ish cap (`read.c`,
`processAggregateItem`, around line 606-613). Both caps are generous enough that a small, well-formed
RESP array header can still request an allocation far larger than any reasonable process budget:

```
hiredis.c:184  r->element = hi_calloc(elements, sizeof(redisReply*));
```

Declaring an array of 317,321,733 elements (`elements * sizeof(redisReply*)` = ~2.5 GB on a 64-bit
build) makes that one `calloc` call the very first thing the reader does with the input — no data for
those elements needs to be present in the buffer yet, `redisReaderFeed` doesn't need to see all of it.
Under ASan this aborts as an allocator OOM; without ASan, `hi_calloc` would either succeed (handing an
attacker-controlled multi-GB allocation to a process from ~12 bytes of input — an amplification/DoS
primitive) or return NULL, which the reader does handle cleanly (`createArrayObject` frees and returns
NULL, `redisReaderGetReply` reports `REDIS_ERR_OOM`) — so this is NOT a crash/memory-safety bug in
non-ASan builds, "just" a cheap way to make a client allocate multiple GB from a tiny reply.

## Reproduce

```
/mayhem/resp_reader_fuzzer -runs=1 mayhem/resp_reader_fuzzer/known-findings/oom-large-array-elements/repro
# ==PID==ERROR: AddressSanitizer: out of memory: allocator is trying to allocate ~0x??????? bytes
#   #... in hi_calloc alloc.h
#   #... in createArrayObject hiredis.c:184
#   #... in processAggregateItem read.c:618
#   #... in redisReaderGetReply read.c:846
```

Found via fork-mode exploration (`-fork=4 -ignore_crashes=1 -ignore_ooms=1 -ignore_timeouts=1
-max_total_time=30`, seeded from `mayhem/resp_reader_fuzzer/testsuite/`) then minimized with
`-minimize_crash=1`. libFuzzer/ASan's default per-allocation and RSS limits are what turn this into an
abort quickly; a real client without those limits would simply attempt the full allocation.

## Impact

Low-to-moderate: a malicious or compromised Redis-protocol peer (or a MITM on an unauthenticated/
unencrypted connection) can make a hiredis-based client attempt a multi-gigabyte allocation from a
~12-byte reply, before any of the declared elements have actually arrived. Repeated replies amplify
this into a memory-exhaustion DoS against the client process. Not remotely exploitable for memory
corruption — `hi_calloc` failure is handled (NULL check present).

## Suggested upstream fix (not applied here — see below)

Cap the *product* `elements * sizeof(redisReply*)` (and the map `elements * 2 * sizeof(...)`) against a
much smaller, configurable ceiling before calling `hi_calloc`, independent of the existing
`REDIS_READER_MAX_ARRAY_ELEMENTS` element-count cap — e.g. reject when the byte size implied by
`elements` exceeds a few tens of MB unless the caller has opted into a larger reader buffer budget.

This finding is intentionally NOT patched/guarded in this port (per the netnew integration policy:
"do NOT guard crashes or OOMs" — masking them would just hide the bug from Mayhem, not fix hiredis).
It is left as a live target for the fuzzer/PATCH-tier grading, and reported here for visibility.

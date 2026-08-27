/*
 * mayhem/resp_reader_fuzzer.c — libFuzzer harness for hiredis's RESP protocol parser.
 *
 * This drives redisReader (read.c) directly on attacker-controlled bytes, exactly the way
 * hiredis's own redisContext uses it internally (hiredis.c: redisReaderFeed()+redisReaderGetReply()
 * in a loop) — i.e. this is the code path that parses whatever a Redis-protocol-speaking peer sends
 * over the wire. It is the real security-relevant surface (CVE-2021-32765 was an integer overflow
 * in exactly this parser), unlike the old (upstream-removed) format_command_fuzzer which fuzzed the
 * *client's own* command-formatting function.
 *
 * No file I/O, no absolute paths — bytes come from the fuzzer only (SPEC/netnew-worker-prompt §3).
 */
#include <stddef.h>
#include <stdint.h>

#include "hiredis.h"
#include "read.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    redisReader *reader = redisReaderCreate();
    if (reader == NULL)
        return 0;

    /* Feed the whole input in one shot; redisReaderFeed copies it into the reader's own buffer, so
     * the fuzzer-owned `data` pointer does not need to outlive this call. */
    if (redisReaderFeed(reader, (const char *)data, size) != REDIS_OK) {
        redisReaderFree(reader);
        return 0;
    }

    /* Drain every complete reply the buffered bytes contain (a single input can encode more than
     * one RESP message back-to-back — the reader parses each pipelined reply on its own GetReply
     * call, same as a real client draining a pipelined response). */
    void *reply;
    while (redisReaderGetReply(reader, &reply) == REDIS_OK && reply != NULL) {
        freeReplyObject(reply);
    }

    redisReaderFree(reader);
    return 0;
}

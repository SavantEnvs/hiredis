/*
 * mayhem/resp_kat.c — known-answer-test probe for the RESP protocol parser.
 *
 * Independent of hiredis's own (network-backed) test suite: feeds a FIXED RESP byte buffer straight
 * into redisReader (no server, no sockets) and asserts the EXACT parsed fields against values lifted
 * by hand from the RESP spec / hiredis's own read.c unit tests (test_reply_reader in test.c). Built
 * with the project's NORMAL (non-sanitized) flags, dynamically linked, so mayhem/test.sh has a
 * behavioral check that in no way depends on the network stack being reachable — this is the
 * belt-and-suspenders probe layered on top of the full functional suite per the netnew brief §4
 * ("Three or four such assertions is enough. This is mandatory, not a fallback for awkward runners").
 *
 * Input:  "*3\r\n$3\r\nSET\r\n$3\r\nfoo\r\n$5\r\nhello\r\n"   (a 3-element RESP array of bulk strings —
 *          the wire encoding of the client command `SET foo hello`)
 * Output: exactly "SET\nfoo\nhello\n" on stdout, exit 0. Any mismatch (wrong type, wrong element
 *          count, wrong bytes, or the probe binary not even running) is a FAILURE, unconditionally —
 *          no skip-if-missing guard.
 */
#include <stdio.h>
#include <string.h>

#include "hiredis.h"
#include "read.h"

int main(void) {
    static const char buf[] = "*3\r\n$3\r\nSET\r\n$3\r\nfoo\r\n$5\r\nhello\r\n";
    const size_t buflen = sizeof(buf) - 1;

    redisReader *r = redisReaderCreate();
    if (r == NULL) {
        fprintf(stderr, "KAT: redisReaderCreate failed\n");
        return 1;
    }

    if (redisReaderFeed(r, buf, buflen) != REDIS_OK) {
        fprintf(stderr, "KAT: redisReaderFeed failed: %s\n", r->errstr);
        redisReaderFree(r);
        return 1;
    }

    void *replyv = NULL;
    if (redisReaderGetReply(r, &replyv) != REDIS_OK || replyv == NULL) {
        fprintf(stderr, "KAT: redisReaderGetReply failed: %s\n", r->errstr);
        redisReaderFree(r);
        return 1;
    }

    redisReply *reply = (redisReply *)replyv;
    if (reply->type != REDIS_REPLY_ARRAY || reply->elements != 3) {
        fprintf(stderr, "KAT: unexpected top-level reply (type=%d elements=%zu)\n",
                reply->type, reply->elements);
        freeReplyObject(replyv);
        redisReaderFree(r);
        return 1;
    }

    static const char *expect[3] = {"SET", "foo", "hello"};
    for (size_t i = 0; i < 3; i++) {
        redisReply *e = reply->element[i];
        if (e == NULL || e->type != REDIS_REPLY_STRING ||
            e->len != strlen(expect[i]) || memcmp(e->str, expect[i], e->len) != 0) {
            fprintf(stderr, "KAT: element %zu mismatch\n", i);
            freeReplyObject(replyv);
            redisReaderFree(r);
            return 1;
        }
        printf("%s\n", e->str);
    }

    freeReplyObject(replyv);
    redisReaderFree(r);
    return 0;
}

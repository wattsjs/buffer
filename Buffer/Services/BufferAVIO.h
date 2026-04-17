#ifndef BUFFER_AVIO_H
#define BUFFER_AVIO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// One-time init for libavformat's network stack (TLS, DNS, etc.). Idempotent.
void buffer_avio_init(void);

/// Result of a completed fetch.
typedef struct {
    uint8_t *data;         // caller must free() (malloc'd)
    size_t   length;
    int      status_code;  // synthetic: 200 on non-empty success, 204 on EOF-zero, negative on error
    char     error[256];   // human-readable; empty on success
} BufferAvioResult;

/// Synchronously fetch `url` using libavformat's HTTP protocol. Blocks the
/// calling thread; must be invoked off the main thread. All string args may
/// be NULL except `url`.
///
/// extra_headers: single string with each header joined by `\r\n`,
/// terminated with a trailing `\r\n`. e.g. "Cookie: x=1\r\nX-Foo: bar\r\n".
BufferAvioResult buffer_avio_fetch(const char *url,
                                   const char *user_agent,
                                   const char *referer,
                                   const char *extra_headers);

/// Release memory inside a result. After this call, `.data` is NULL and
/// `.length` is 0. Safe on already-freed results.
void buffer_avio_result_free(BufferAvioResult *r);

#ifdef __cplusplus
}
#endif

#endif

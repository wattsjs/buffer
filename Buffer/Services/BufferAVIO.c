#include "BufferAVIO.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Deliberately avoid including any ffmpeg headers. Clang auto-imports on
// `#include <Libavformat/...>` and MPVKit's Clang module umbrella maps fail
// to build because `hwcontext_amf.h` references an AMD GPU SDK not present
// on macOS. Forward-declare the handful of symbols we need and let the
// dynamic linker resolve them against the already-linked MPVKit dylibs.

typedef struct AVIOContext AVIOContext;
typedef struct AVDictionary AVDictionary;

extern int avformat_network_init(void);
extern int avio_open2(AVIOContext **s, const char *url, int flags,
                      const void *int_cb, AVDictionary **options);
extern int avio_read(AVIOContext *s, unsigned char *buf, int size);
extern int avio_closep(AVIOContext **s);

extern int  av_dict_set(AVDictionary **pm, const char *key, const char *value, int flags);
extern int  av_dict_set_int(AVDictionary **pm, const char *key, int64_t value, int flags);
extern void av_dict_free(AVDictionary **m);
extern int  av_strerror(int errnum, char *errbuf, size_t errbuf_size);

// `AVIO_FLAG_READ` == 1 per <libavformat/avio.h>. Hard-code so we don't
// need to include the header.
#define BUFFER_AVIO_FLAG_READ 1

static pthread_once_t s_init_once = PTHREAD_ONCE_INIT;

static void do_init(void) {
    avformat_network_init();
}

void buffer_avio_init(void) {
    pthread_once(&s_init_once, do_init);
}

void buffer_avio_result_free(BufferAvioResult *r) {
    if (!r) return;
    free(r->data);
    r->data = NULL;
    r->length = 0;
}

static void fill_error(BufferAvioResult *r, int code) {
    r->status_code = code < 0 ? code : -1;
    char buf[256] = {0};
    av_strerror(code, buf, sizeof(buf));
    if (buf[0] != '\0') {
        snprintf(r->error, sizeof(r->error), "%s", buf);
    }
}

BufferAvioResult buffer_avio_fetch(const char *url,
                                   const char *user_agent,
                                   const char *referer,
                                   const char *extra_headers) {
    BufferAvioResult result;
    memset(&result, 0, sizeof(result));

    buffer_avio_init();

    AVDictionary *opts = NULL;
    if (user_agent && user_agent[0]) {
        av_dict_set(&opts, "user_agent", user_agent, 0);
    }
    if (referer && referer[0]) {
        av_dict_set(&opts, "referer", referer, 0);
    }
    if (extra_headers && extra_headers[0]) {
        av_dict_set(&opts, "headers", extra_headers, 0);
    }
    av_dict_set(&opts, "follow", "1", 0);
    av_dict_set(&opts, "reconnect", "1", 0);
    av_dict_set(&opts, "reconnect_streamed", "1", 0);
    av_dict_set_int(&opts, "rw_timeout", 20 * 1000 * 1000, 0);  // 20s in µs

    AVIOContext *avio = NULL;
    int rc = avio_open2(&avio, url, BUFFER_AVIO_FLAG_READ, NULL, &opts);
    av_dict_free(&opts);

    if (rc < 0 || !avio) {
        fill_error(&result, rc);
        return result;
    }

    size_t cap = 64 * 1024;
    size_t len = 0;
    uint8_t *buf = (uint8_t *)malloc(cap);
    if (!buf) {
        avio_closep(&avio);
        result.status_code = -1;
        snprintf(result.error, sizeof(result.error), "malloc failed");
        return result;
    }

    const size_t MAX_TOTAL = 256UL * 1024UL * 1024UL;
    while (len < MAX_TOTAL) {
        if (len == cap) {
            size_t new_cap = cap * 2;
            if (new_cap > MAX_TOTAL) new_cap = MAX_TOTAL;
            uint8_t *grown = (uint8_t *)realloc(buf, new_cap);
            if (!grown) {
                free(buf);
                avio_closep(&avio);
                result.status_code = -1;
                snprintf(result.error, sizeof(result.error), "realloc failed");
                return result;
            }
            buf = grown;
            cap = new_cap;
        }
        int want = (int)(cap - len);
        if (want > 65536) want = 65536;
        int n = avio_read(avio, buf + len, want);
        if (n <= 0) break;
        len += (size_t)n;
    }

    avio_closep(&avio);

    result.data = buf;
    result.length = len;
    result.status_code = len > 0 ? 200 : 204;
    return result;
}

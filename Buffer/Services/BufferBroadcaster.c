#include "BufferBroadcaster.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <Libavformat/avformat.h>
#include <Libavformat/avio.h>
#include <Libavcodec/avcodec.h>
#include <Libavcodec/codec_par.h>
#include <Libavutil/dict.h>
#include <Libavutil/error.h>
#include <Libavutil/mem.h>
#include <Libavutil/rational.h>
#include <Libavutil/mathematics.h>

#define MAX_SINKS 16
#define OUTPUT_IO_BUFFER_SIZE (64 * 1024)

// Ring buffer that keeps the most recent muxed MPEG-TS bytes so a newly
// attached sink gets a replay — including PAT/PMT + at least one keyframe —
// before live bytes start flowing. mpegts PAT/PMT repeat on the order of
// 100 ms, keyframes every 1–2 s, so ~8 MB is comfortably >1 keyframe
// window at typical 10 Mbps IPTV rates.
#define REPLAY_RING_CAPACITY (8 * 1024 * 1024)

typedef struct {
    int token;
    BufferSinkCallbacks cb;
    int alive;
} Sink;

struct BufferBroadcaster {
    char *input_url;
    char *user_agent;
    char *referer;

    pthread_t thread;
    int thread_started;

    // Sink list protected by sinks_mutex.
    pthread_mutex_t sinks_mutex;
    Sink sinks[MAX_SINKS];
    int next_token;

    // Delivery-drain gate. `write_to_sinks` / `notify_eof` snapshot the
    // sink list under `sinks_mutex`, release the lock, then invoke
    // callbacks with stack-local copies of `cb` (ctx included). Without
    // this counter, `remove_sink` could return while a worker was still
    // about to invoke the just-cleared sink's callback — the Swift caller
    // then releases the adapter, and the delayed callback dereferences
    // freed memory inside `NWConnection.send`. `deliveries_in_flight` is
    // bumped before the unlocked callback loop runs and drained after;
    // `remove_sink` waits on the condvar until it's 0, guaranteeing no
    // further callback can fire against a ctx it has cleared.
    pthread_cond_t delivery_cond;
    int deliveries_in_flight;

    // Stop flag set from free(); worker checks between packets.
    volatile int stop_requested;

    // ffmpeg context (touched only by worker thread).
    AVFormatContext *in_ctx;
    AVFormatContext *out_ctx;
    AVIOContext *out_avio;
    uint8_t *out_avio_buffer;

    // Stream index mapping from input to output (indexed by input idx;
    // -1 means "skip"). Only video+audio streams are copied.
    int *stream_mapping;
    int stream_mapping_size;

    // Replay ring: most recent muxed MPEG-TS bytes. Protected by
    // sinks_mutex (same lock used for the sinks array — both are touched
    // on every write, cheap to share one lock).
    uint8_t *ring;
    size_t ring_capacity;
    size_t ring_head;   // write cursor
    size_t ring_size;   // how much of the ring is valid (≤ capacity)
};

static int write_to_sinks(void *opaque, const uint8_t *buf, int buf_size);

static void copy_str(char **dst, const char *src) {
    if (!src) { *dst = NULL; return; }
    size_t n = strlen(src) + 1;
    *dst = (char *)malloc(n);
    if (*dst) memcpy(*dst, src, n);
}

static void format_error(int rc, char *buf, size_t n) {
    if (!buf || n == 0) return;
    char tmp[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(rc, tmp, sizeof(tmp));
    snprintf(buf, n, "%s (rc=%d)", tmp[0] ? tmp : "unknown ffmpeg error", rc);
}

// Log callback forwards libavformat/libavcodec messages to stderr with a
// prefix we can filter on. Enabled at info level so we see the HLS
// playlist-parse errors that otherwise disappear inside libav.
static void buffer_av_log(void *ptr, int level, const char *fmt, va_list vl) {
    if (level > AV_LOG_INFO) return;
    char msg[1024];
    vsnprintf(msg, sizeof(msg), fmt, vl);
    // Trim trailing newline so our own prefix keeps lines tidy.
    size_t len = strlen(msg);
    while (len > 0 && (msg[len-1] == '\n' || msg[len-1] == '\r')) {
        msg[--len] = 0;
    }
    if (len == 0) return;

    // Every libav context whose log lines we care about starts with an
    // `AVClass *` as its first field — that's how FFmpeg's own log.c
    // resolves the class pointer. Single-dereference only; my earlier
    // double-dereference read past the struct into garbage and crashed
    // with EXC_BAD_ACCESS on dlsym'd pointers. Some callers pass a raw
    // non-AVClass pointer, so `av_class_from_obj`-style defensive checks
    // matter; we additionally guard on a non-NULL `item_name` before
    // invoking it.
    const char *cls = "?";
    if (ptr) {
        const AVClass *avc = *(const AVClass *const *)ptr;
        if (avc && avc->item_name) {
            const char *name = avc->item_name((void *)ptr);
            if (name) cls = name;
        }
    }
    const char *lvl = "info";
    if (level <= AV_LOG_ERROR)      lvl = "error";
    else if (level <= AV_LOG_WARNING) lvl = "warn";
    fprintf(stderr, "[ffmpeg %s %s] %s\n", lvl, cls, msg);
}

static void ring_append(BufferBroadcaster *b, const uint8_t *buf, size_t len) {
    if (!b->ring || b->ring_capacity == 0) return;
    // If incoming chunk exceeds capacity, only keep the tail.
    if (len >= b->ring_capacity) {
        memcpy(b->ring, buf + (len - b->ring_capacity), b->ring_capacity);
        b->ring_head = 0;
        b->ring_size = b->ring_capacity;
        return;
    }
    size_t first = b->ring_capacity - b->ring_head;
    if (first > len) first = len;
    memcpy(b->ring + b->ring_head, buf, first);
    size_t remaining = len - first;
    if (remaining > 0) {
        memcpy(b->ring, buf + first, remaining);
    }
    b->ring_head = (b->ring_head + len) % b->ring_capacity;
    b->ring_size = b->ring_size + len;
    if (b->ring_size > b->ring_capacity) b->ring_size = b->ring_capacity;
}

// Deliver the ring contents in chronological order to a single sink. Used
// at sink-attach time to replay recent PAT/PMT/keyframe so mpv can decode
// from byte zero instead of waiting for the next keyframe.
static void ring_replay_to(BufferBroadcaster *b, BufferSinkCallbacks cb) {
    if (!cb.on_bytes || !b->ring || b->ring_size == 0) return;
    if (b->ring_size < b->ring_capacity) {
        // Ring hasn't wrapped yet — bytes 0..ring_size are valid in order.
        cb.on_bytes(cb.ctx, b->ring, b->ring_size);
        return;
    }
    // Ring full — oldest byte is at ring_head, newest at ring_head-1.
    size_t first_len = b->ring_capacity - b->ring_head;
    if (first_len > 0) {
        cb.on_bytes(cb.ctx, b->ring + b->ring_head, first_len);
    }
    if (b->ring_head > 0) {
        cb.on_bytes(cb.ctx, b->ring, b->ring_head);
    }
}

// Called from worker thread. Stores bytes in the replay ring AND fans
// them out to every live sink. The sink-list snapshot is taken under the
// same lock that protects the ring — this ensures that a sink added
// concurrently either (a) sees the ring up to and including this chunk and
// does NOT receive it again, or (b) receives this chunk live and did not
// see it in the ring — never both, never neither.
static int write_to_sinks(void *opaque, const uint8_t *buf, int buf_size) {
    BufferBroadcaster *b = (BufferBroadcaster *)opaque;
    if (!b || buf_size <= 0) return buf_size;

    BufferSinkCallbacks snapshot[MAX_SINKS];
    int n = 0;
    pthread_mutex_lock(&b->sinks_mutex);
    ring_append(b, buf, (size_t)buf_size);
    for (int i = 0; i < MAX_SINKS; i++) {
        if (b->sinks[i].alive) {
            snapshot[n++] = b->sinks[i].cb;
        }
    }
    b->deliveries_in_flight++;
    pthread_mutex_unlock(&b->sinks_mutex);

    for (int i = 0; i < n; i++) {
        if (snapshot[i].on_bytes) {
            snapshot[i].on_bytes(snapshot[i].ctx, buf, (size_t)buf_size);
        }
    }

    pthread_mutex_lock(&b->sinks_mutex);
    b->deliveries_in_flight--;
    if (b->deliveries_in_flight == 0) {
        pthread_cond_broadcast(&b->delivery_cond);
    }
    pthread_mutex_unlock(&b->sinks_mutex);
    return buf_size;
}

static void notify_eof(BufferBroadcaster *b) {
    BufferSinkCallbacks snapshot[MAX_SINKS];
    int n = 0;
    pthread_mutex_lock(&b->sinks_mutex);
    for (int i = 0; i < MAX_SINKS; i++) {
        if (b->sinks[i].alive) {
            snapshot[n++] = b->sinks[i].cb;
            b->sinks[i].alive = 0;
        }
    }
    b->deliveries_in_flight++;
    pthread_mutex_unlock(&b->sinks_mutex);
    for (int i = 0; i < n; i++) {
        if (snapshot[i].on_eof) {
            snapshot[i].on_eof(snapshot[i].ctx);
        }
    }
    pthread_mutex_lock(&b->sinks_mutex);
    b->deliveries_in_flight--;
    if (b->deliveries_in_flight == 0) {
        pthread_cond_broadcast(&b->delivery_cond);
    }
    pthread_mutex_unlock(&b->sinks_mutex);
}

// Build output AVFormatContext with mpegts muxer writing into write_to_sinks.
static int build_output(BufferBroadcaster *b, char *error, size_t error_size) {
    int rc = avformat_alloc_output_context2(&b->out_ctx, NULL, "mpegts", NULL);
    if (rc < 0 || !b->out_ctx) {
        format_error(rc, error, error_size);
        return -1;
    }

    // Custom AVIO writing to our fan-out.
    b->out_avio_buffer = (uint8_t *)av_malloc(OUTPUT_IO_BUFFER_SIZE);
    if (!b->out_avio_buffer) {
        snprintf(error, error_size, "av_malloc failed");
        return -1;
    }
    b->out_avio = avio_alloc_context(
        b->out_avio_buffer, OUTPUT_IO_BUFFER_SIZE,
        1,  // write mode
        b,
        NULL,
        write_to_sinks,
        NULL
    );
    if (!b->out_avio) {
        av_free(b->out_avio_buffer);
        b->out_avio_buffer = NULL;
        snprintf(error, error_size, "avio_alloc_context failed");
        return -1;
    }
    b->out_ctx->pb = b->out_avio;
    b->out_ctx->flags |= AVFMT_FLAG_FLUSH_PACKETS;

    // Copy each relevant input stream to a matching output stream.
    b->stream_mapping = (int *)calloc(b->in_ctx->nb_streams, sizeof(int));
    if (!b->stream_mapping) {
        snprintf(error, error_size, "stream mapping alloc failed");
        return -1;
    }
    b->stream_mapping_size = b->in_ctx->nb_streams;

    for (int i = 0; i < (int)b->in_ctx->nb_streams; i++) {
        AVStream *in_s = b->in_ctx->streams[i];
        int type = in_s->codecpar->codec_type;
        if (type != AVMEDIA_TYPE_AUDIO && type != AVMEDIA_TYPE_VIDEO) {
            b->stream_mapping[i] = -1;
            continue;
        }
        AVStream *out_s = avformat_new_stream(b->out_ctx, NULL);
        if (!out_s) {
            snprintf(error, error_size, "avformat_new_stream failed");
            return -1;
        }
        rc = avcodec_parameters_copy(out_s->codecpar, in_s->codecpar);
        if (rc < 0) {
            format_error(rc, error, error_size);
            return -1;
        }
        out_s->codecpar->codec_tag = 0;
        b->stream_mapping[i] = out_s->index;
    }

    AVDictionary *hdr_opts = NULL;
    // mpegts ignores most options; this is harmless for future use.
    rc = avformat_write_header(b->out_ctx, &hdr_opts);
    av_dict_free(&hdr_opts);
    if (rc < 0) {
        format_error(rc, error, error_size);
        return -1;
    }

    return 0;
}

// Open `b->in_ctx` against `b->input_url` with the same libavformat options
// used at first-open. Caller owns deciding whether to tear down the old
// context first. Returns 0 on success; populates `error` on failure.
static int open_input_with_options(BufferBroadcaster *b, char *error, size_t error_size) {
    AVDictionary *opts = NULL;
    if (b->user_agent && b->user_agent[0]) {
        av_dict_set(&opts, "user_agent", b->user_agent, 0);
    }
    if (b->referer && b->referer[0]) {
        av_dict_set(&opts, "referer", b->referer, 0);
    }
    // libavformat reconnect (covers single-socket network hiccups without
    // tearing down the demuxer).
    av_dict_set(&opts, "reconnect", "1", 0);
    av_dict_set(&opts, "reconnect_streamed", "1", 0);
    av_dict_set(&opts, "reconnect_on_network_error", "1", 0);
    av_dict_set(&opts, "reconnect_on_http_error", "5xx", 0);
    av_dict_set_int(&opts, "reconnect_delay_max", 5, 0);
    av_dict_set_int(&opts, "rw_timeout", 20 * 1000 * 1000, 0);

    // HLS demuxer tuning. `seg_max_retry` is the biggest win: its default
    // of 0 means a single bad segment kills the demuxer. Setting it to 5
    // lets ffmpeg paper over most provider-side glitches before we escalate
    // to a full reopen. `m3u8_hold_counters` and `max_reload` stay at their
    // generous defaults (1000).
    av_dict_set_int(&opts, "seg_max_retry", 5, 0);

    int rc = avformat_open_input(&b->in_ctx, b->input_url, NULL, &opts);
    av_dict_free(&opts);
    if (rc < 0) {
        format_error(rc, error, error_size);
        return rc;
    }

    rc = avformat_find_stream_info(b->in_ctx, NULL);
    if (rc < 0) {
        format_error(rc, error, error_size);
        avformat_close_input(&b->in_ctx);
        return rc;
    }
    return 0;
}

// Check that a freshly re-opened input has the same stream topology as the
// one we initially built the output muxer against. If codecs or stream
// count differ, the new input can't be mapped onto the existing PAT/PMT
// and we have to tear down. Returns 1 if compatible, 0 otherwise.
static int streams_compatible_with_mapping(BufferBroadcaster *b) {
    if (!b->in_ctx || !b->stream_mapping) return 0;
    if ((int)b->in_ctx->nb_streams != b->stream_mapping_size) return 0;
    for (int i = 0; i < b->stream_mapping_size; i++) {
        int out_idx = b->stream_mapping[i];
        AVStream *in_s = b->in_ctx->streams[i];
        if (!in_s || !in_s->codecpar) return 0;
        int type = in_s->codecpar->codec_type;
        int is_av = (type == AVMEDIA_TYPE_AUDIO || type == AVMEDIA_TYPE_VIDEO);
        // Skip-streams (mapping == -1) were non-av originally; they must
        // still be non-av now.
        if (out_idx < 0) {
            if (is_av) return 0;
            continue;
        }
        if (!is_av) return 0;
        if (out_idx >= (int)b->out_ctx->nb_streams) return 0;
        AVStream *out_s = b->out_ctx->streams[out_idx];
        if (!out_s || !out_s->codecpar) return 0;
        if (in_s->codecpar->codec_id != out_s->codecpar->codec_id) return 0;
    }
    return 1;
}

// Sleep for `seconds` while periodically re-checking stop_requested so
// teardown isn't held up by a long backoff.
static void interruptible_sleep(BufferBroadcaster *b, double seconds) {
    const double tick = 0.1;
    double remaining = seconds;
    while (remaining > 0 && !b->stop_requested) {
        double slice = remaining < tick ? remaining : tick;
        struct timespec ts;
        ts.tv_sec = (time_t)slice;
        ts.tv_nsec = (long)((slice - (double)ts.tv_sec) * 1e9);
        nanosleep(&ts, NULL);
        remaining -= slice;
    }
}

// Time-window budget for continuous reopen failures before we give up and
// signal EOF to sinks. Shorter than mpv's own retry deadline so the app
// still gets a chance to escalate.
#define REOPEN_TOTAL_WINDOW_SECONDS 60.0

static void *worker_main(void *arg) {
    BufferBroadcaster *b = (BufferBroadcaster *)arg;
    AVPacket *pkt = av_packet_alloc();
    if (!pkt) return NULL;

    int reopen_attempt = 0;
    struct timespec failure_start = {0};
    int in_failure_window = 0;

    while (!b->stop_requested) {
        int rc = av_read_frame(b->in_ctx, pkt);
        if (rc >= 0) {
            // Healthy read — reset the failure tracker.
            reopen_attempt = 0;
            in_failure_window = 0;

            if (pkt->stream_index < 0 || pkt->stream_index >= b->stream_mapping_size) {
                av_packet_unref(pkt);
                continue;
            }
            int out_idx = b->stream_mapping[pkt->stream_index];
            if (out_idx < 0) {
                av_packet_unref(pkt);
                continue;
            }

            AVStream *in_s = b->in_ctx->streams[pkt->stream_index];
            AVStream *out_s = b->out_ctx->streams[out_idx];

            // Rescale timestamps from input's time_base to the output
            // stream. After a reopen the input's PTS origin may jump
            // forward — mpegts downstream tolerates this (mpv treats it
            // as a discontinuity and resyncs) so we don't bother
            // synthesising an offset here.
            av_packet_rescale_ts(pkt, in_s->time_base, out_s->time_base);
            pkt->stream_index = out_idx;
            pkt->pos = -1;

            int werr = av_interleaved_write_frame(b->out_ctx, pkt);
            av_packet_unref(pkt);
            if (werr < 0) {
                // Muxer error — our own pipeline, not the upstream. Not
                // recoverable.
                fprintf(stderr, "[broadcaster] muxer write failed rc=%d — stopping\n", werr);
                break;
            }
            continue;
        }

        // Read error: either upstream EOF, network hiccup, or malformed
        // segment. Try to reopen the input so sinks never see EOF.
        if (b->stop_requested) break;

        char rdmsg[AV_ERROR_MAX_STRING_SIZE] = {0};
        av_strerror(rc, rdmsg, sizeof(rdmsg));
        fprintf(stderr, "[broadcaster] av_read_frame rc=%d (%s) — attempting reopen #%d\n",
                rc, rdmsg, reopen_attempt + 1);

        if (!in_failure_window) {
            clock_gettime(CLOCK_MONOTONIC, &failure_start);
            in_failure_window = 1;
        } else {
            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            double elapsed = (double)(now.tv_sec - failure_start.tv_sec)
                           + (double)(now.tv_nsec - failure_start.tv_nsec) / 1e9;
            if (elapsed > REOPEN_TOTAL_WINDOW_SECONDS) {
                fprintf(stderr, "[broadcaster] reopen window exhausted (%.1fs) — giving up\n",
                        elapsed);
                break;
            }
        }

        // Exponential backoff capped at 5s: 0.25, 0.5, 1, 2, 4, 5, 5, ...
        double delay = 0.25 * (double)(1 << (reopen_attempt < 5 ? reopen_attempt : 5));
        if (delay > 5.0) delay = 5.0;
        interruptible_sleep(b, delay);
        reopen_attempt++;
        if (b->stop_requested) break;

        // Discard the old input; keep the muxer + avio intact so PAT/PMT
        // and continuity counters keep flowing from the sinks' point of
        // view.
        avformat_close_input(&b->in_ctx);

        // Retry loop: keep trying to reopen within the failure window. On
        // each failure, back off again (up to the 5s cap). The outer read
        // loop needs `in_ctx` non-NULL before it can run av_read_frame,
        // so we can't just `continue` to it.
        int reopened = 0;
        while (!b->stop_requested) {
            char err[256] = {0};
            if (open_input_with_options(b, err, sizeof(err)) == 0) {
                if (!streams_compatible_with_mapping(b)) {
                    fprintf(stderr, "[broadcaster] reopen produced incompatible stream topology — giving up\n");
                    avformat_close_input(&b->in_ctx);
                    // Escape the outer loop too.
                    goto fatal;
                }
                fprintf(stderr, "[broadcaster] reopen OK — resuming\n");
                reopened = 1;
                break;
            }
            fprintf(stderr, "[broadcaster] reopen failed: %s — will retry\n", err);

            struct timespec now;
            clock_gettime(CLOCK_MONOTONIC, &now);
            double elapsed = (double)(now.tv_sec - failure_start.tv_sec)
                           + (double)(now.tv_nsec - failure_start.tv_nsec) / 1e9;
            if (elapsed > REOPEN_TOTAL_WINDOW_SECONDS) {
                fprintf(stderr, "[broadcaster] reopen window exhausted (%.1fs) — giving up\n",
                        elapsed);
                goto fatal;
            }

            double d = 0.25 * (double)(1 << (reopen_attempt < 5 ? reopen_attempt : 5));
            if (d > 5.0) d = 5.0;
            interruptible_sleep(b, d);
            reopen_attempt++;
        }
        if (!reopened) break; // stop_requested during retry
    }
    goto done;

fatal:
done:;

    av_packet_free(&pkt);

    if (b->out_ctx && b->out_ctx->pb) {
        av_write_trailer(b->out_ctx);
    }

    notify_eof(b);
    return NULL;
}

BufferBroadcaster *buffer_broadcaster_create(const char *input_url,
                                             const char *user_agent,
                                             const char *referer,
                                             char *error, size_t error_size) {
    if (!input_url) {
        snprintf(error, error_size, "input_url null");
        return NULL;
    }

    // Ensure network init + install our log callback once. Install it
    // even if the caller is reusing the module, since AVFormatContext's
    // per-open errors only surface through the log callback (the return
    // code tells us a number; the *why* comes through av_log).
    static int net_inited = 0;
    if (!net_inited) {
        avformat_network_init();
        av_log_set_level(AV_LOG_INFO);
        av_log_set_callback(buffer_av_log);
        net_inited = 1;
    }

    BufferBroadcaster *b = (BufferBroadcaster *)calloc(1, sizeof(*b));
    if (!b) { snprintf(error, error_size, "calloc failed"); return NULL; }

    pthread_mutex_init(&b->sinks_mutex, NULL);
    pthread_cond_init(&b->delivery_cond, NULL);
    b->next_token = 1;
    b->ring_capacity = REPLAY_RING_CAPACITY;
    b->ring = (uint8_t *)malloc(b->ring_capacity);
    if (!b->ring) {
        snprintf(error, error_size, "ring alloc failed");
        pthread_cond_destroy(&b->delivery_cond);
        pthread_mutex_destroy(&b->sinks_mutex);
        free(b);
        return NULL;
    }

    copy_str(&b->input_url, input_url);
    copy_str(&b->user_agent, user_agent);
    copy_str(&b->referer, referer);

    fprintf(stderr, "[broadcaster] avformat_open_input START url=%s ua=%s referer=%s\n",
            input_url,
            user_agent ? user_agent : "(none)",
            referer ? referer : "(none)");
    int rc = open_input_with_options(b, error, error_size);
    if (rc < 0) {
        fprintf(stderr, "[broadcaster] avformat_open_input FAILED url=%s: %s\n",
                input_url, error);
        buffer_broadcaster_free(b);
        return NULL;
    }
    fprintf(stderr, "[broadcaster] avformat_open_input + find_stream_info OK url=%s format=%s nb_streams=%u\n",
            input_url,
            b->in_ctx && b->in_ctx->iformat ? b->in_ctx->iformat->name : "?",
            b->in_ctx ? b->in_ctx->nb_streams : 0);

    if (build_output(b, error, error_size) != 0) {
        buffer_broadcaster_free(b);
        return NULL;
    }

    if (pthread_create(&b->thread, NULL, worker_main, b) != 0) {
        snprintf(error, error_size, "pthread_create failed");
        buffer_broadcaster_free(b);
        return NULL;
    }
    b->thread_started = 1;

    return b;
}

int buffer_broadcaster_add_sink(BufferBroadcaster *b, BufferSinkCallbacks cb) {
    if (!b) return 0;
    int assigned = 0;
    pthread_mutex_lock(&b->sinks_mutex);
    // Replay ring BEFORE marking the sink alive — that way `write_to_sinks`
    // won't double-deliver the current chunk. This blocks the worker
    // thread if it's trying to write; replay is fast (memcpy + socket
    // send) so the stall is brief.
    ring_replay_to(b, cb);
    for (int i = 0; i < MAX_SINKS; i++) {
        if (!b->sinks[i].alive) {
            b->sinks[i].alive = 1;
            b->sinks[i].cb = cb;
            b->sinks[i].token = b->next_token++;
            assigned = b->sinks[i].token;
            break;
        }
    }
    pthread_mutex_unlock(&b->sinks_mutex);
    return assigned;
}

void buffer_broadcaster_remove_sink(BufferBroadcaster *b, int token) {
    if (!b || token <= 0) return;
    pthread_mutex_lock(&b->sinks_mutex);
    for (int i = 0; i < MAX_SINKS; i++) {
        if (b->sinks[i].alive && b->sinks[i].token == token) {
            b->sinks[i].alive = 0;
            b->sinks[i].cb.ctx = NULL;
            b->sinks[i].cb.on_bytes = NULL;
            b->sinks[i].cb.on_eof = NULL;
            break;
        }
    }
    // Wait for any in-flight fan-out to finish. A worker may have
    // snapshotted this sink's cb before we cleared it and still be
    // mid-call; returning now would let the Swift caller release the
    // adapter out from under that callback. The worker is single-threaded
    // per broadcaster, so this waits for at most one delivery pass.
    while (b->deliveries_in_flight > 0) {
        pthread_cond_wait(&b->delivery_cond, &b->sinks_mutex);
    }
    pthread_mutex_unlock(&b->sinks_mutex);
}

int buffer_broadcaster_sink_count(BufferBroadcaster *b) {
    if (!b) return 0;
    int n = 0;
    pthread_mutex_lock(&b->sinks_mutex);
    for (int i = 0; i < MAX_SINKS; i++) {
        if (b->sinks[i].alive) n++;
    }
    pthread_mutex_unlock(&b->sinks_mutex);
    return n;
}

void buffer_broadcaster_get_stream_info(BufferBroadcaster *b, BufferStreamInfo *out) {
    if (!out) return;
    memset(out, 0, sizeof(*out));
    if (!b || !b->in_ctx) return;

    // Codec parameters are frozen after avformat_find_stream_info, so this
    // is safe to read without taking the sinks lock. The worker thread
    // only reads packets; it doesn't mutate codecpar or frame-rate fields.
    for (unsigned i = 0; i < b->in_ctx->nb_streams; i++) {
        AVStream *s = b->in_ctx->streams[i];
        if (!s || !s->codecpar) continue;
        int type = s->codecpar->codec_type;
        if (type == AVMEDIA_TYPE_VIDEO && out->video_width == 0) {
            out->video_width = s->codecpar->width;
            out->video_height = s->codecpar->height;
            const char *name = avcodec_get_name(s->codecpar->codec_id);
            if (name) {
                snprintf(out->video_codec, sizeof(out->video_codec), "%s", name);
            }
            // Prefer avg_frame_rate; fall back to r_frame_rate. Either can
            // be {0,0} when the container doesn't carry frame timing.
            AVRational r = s->avg_frame_rate;
            if (r.num == 0 || r.den == 0) r = s->r_frame_rate;
            if (r.num > 0 && r.den > 0) {
                out->video_fps = (double)r.num / (double)r.den;
            }
        } else if (type == AVMEDIA_TYPE_AUDIO && out->audio_codec[0] == 0) {
            const char *name = avcodec_get_name(s->codecpar->codec_id);
            if (name) {
                snprintf(out->audio_codec, sizeof(out->audio_codec), "%s", name);
            }
        }
    }
}

void buffer_broadcaster_free(BufferBroadcaster *b) {
    if (!b) return;
    b->stop_requested = 1;
    if (b->thread_started) {
        pthread_join(b->thread, NULL);
    }

    if (b->out_ctx) {
        avformat_free_context(b->out_ctx);
        b->out_ctx = NULL;
    }
    if (b->out_avio) {
        avio_context_free(&b->out_avio);
    }
    if (b->out_avio_buffer) {
        av_free(b->out_avio_buffer);
    }
    if (b->in_ctx) {
        avformat_close_input(&b->in_ctx);
    }
    free(b->stream_mapping);
    free(b->input_url);
    free(b->user_agent);
    free(b->referer);
    free(b->ring);
    pthread_cond_destroy(&b->delivery_cond);
    pthread_mutex_destroy(&b->sinks_mutex);
    free(b);
}

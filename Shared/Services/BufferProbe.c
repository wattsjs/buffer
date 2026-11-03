#include "BufferProbe.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// Pull in the real ffmpeg headers from MPVKit's xcframeworks. Including
// `<Libavformat/avformat.h>` resolves through the framework's Headers dir
// without going through the umbrella module map (which trips on AMF on
// macOS — already mitigated by Buffer/ffmpeg-compat/AMF/, but we still
// stick to direct framework-style includes for these probe helpers).
#include <Libavformat/avformat.h>
#include <Libavcodec/codec_par.h>
#include <Libavcodec/avcodec.h>
#include <Libavutil/dict.h>
#include <Libavutil/rational.h>
#include <Libavutil/error.h>

static pthread_once_t s_init_once = PTHREAD_ONCE_INIT;

static void do_init(void) {
    avformat_network_init();
}

void buffer_probe_init(void) {
    pthread_once(&s_init_once, do_init);
}

// ffmpeg's interrupt callback fires at IO points. Returning non-zero asks
// avformat to abort the in-flight operation, surfacing as AVERROR_EXIT.
typedef struct {
    struct timespec deadline;
} ProbeInterrupt;

static int now_after_deadline(const struct timespec *deadline) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    if (now.tv_sec > deadline->tv_sec) return 1;
    if (now.tv_sec < deadline->tv_sec) return 0;
    return now.tv_nsec >= deadline->tv_nsec;
}

static int interrupt_cb(void *opaque) {
    ProbeInterrupt *p = (ProbeInterrupt *)opaque;
    return now_after_deadline(&p->deadline) ? 1 : 0;
}

static double elapsed_seconds_since(const struct timespec *start) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    double s = (double)(now.tv_sec - start->tv_sec);
    s += ((double)now.tv_nsec - (double)start->tv_nsec) / 1.0e9;
    return s;
}

static void copy_codec_name(char *dst, size_t cap, enum AVCodecID id) {
    const char *n = avcodec_get_name(id);
    if (!n) {
        dst[0] = '\0';
        return;
    }
    snprintf(dst, cap, "%s", n);
}

static void fill_error(BufferProbeResult *r, int code) {
    r->status_code = code;
    char buf[256] = {0};
    av_strerror(code, buf, sizeof(buf));
    if (buf[0] != '\0') {
        snprintf(r->error, sizeof(r->error), "%s", buf);
    } else {
        snprintf(r->error, sizeof(r->error), "ffmpeg error %d", code);
    }
}

BufferProbeResult buffer_probe_stream(const char *url, int timeout_seconds) {
    BufferProbeResult result;
    memset(&result, 0, sizeof(result));
    result.duration_us = -1;

    if (!url || !url[0]) {
        result.status_code = -22; // EINVAL
        snprintf(result.error, sizeof(result.error), "missing url");
        return result;
    }

    buffer_probe_init();

    if (timeout_seconds <= 0) timeout_seconds = 10;

    struct timespec start;
    clock_gettime(CLOCK_MONOTONIC, &start);

    ProbeInterrupt interrupt;
    clock_gettime(CLOCK_MONOTONIC, &interrupt.deadline);
    interrupt.deadline.tv_sec += timeout_seconds;

    AVFormatContext *fmt = avformat_alloc_context();
    if (!fmt) {
        result.status_code = -12; // ENOMEM
        snprintf(result.error, sizeof(result.error), "alloc context failed");
        return result;
    }

    fmt->interrupt_callback.callback = interrupt_cb;
    fmt->interrupt_callback.opaque = &interrupt;

    AVDictionary *opts = NULL;
    // Keep the probe cheaper than full playback, but give live HLS a little
    // more runway so 4K / delayed-SPS streams can still surface codec params.
    av_dict_set(&opts, "probesize", "1000000", 0);           // 1 MB
    av_dict_set(&opts, "analyzeduration", "3000000", 0);     // 3.0s in µs
    av_dict_set(&opts, "user_agent", "Buffer/1.0", 0);
    av_dict_set(&opts, "rw_timeout",
                (char[32]){0}, 0);
    {
        char rw[32];
        snprintf(rw, sizeof(rw), "%lld", (long long)timeout_seconds * 1000LL * 1000LL);
        av_dict_set(&opts, "rw_timeout", rw, 0);
    }
    av_dict_set(&opts, "reconnect", "0", 0);

    int rc = avformat_open_input(&fmt, url, NULL, &opts);
    av_dict_free(&opts);

    if (rc < 0) {
        if (now_after_deadline(&interrupt.deadline)) {
            result.status_code = -1000;
            snprintf(result.error, sizeof(result.error), "probe timed out");
        } else {
            fill_error(&result, rc);
        }
        if (fmt) avformat_close_input(&fmt);
        result.probe_seconds = elapsed_seconds_since(&start);
        return result;
    }

    // Tighten the deadline now that we're connected. Establishing the
    // connection can be slow on origin-side, but once bytes are flowing we
    // only need enough to read codec params — no point spending the full
    // budget reading data we'll throw away.
    clock_gettime(CLOCK_MONOTONIC, &interrupt.deadline);
    interrupt.deadline.tv_sec += 4;

    rc = avformat_find_stream_info(fmt, NULL);
    if (rc < 0) {
        // Some live streams produce a usable format context but no detailed
        // stream info before the analyzeduration window expires. Don't bail —
        // surface what we did get and keep going.
        if (now_after_deadline(&interrupt.deadline)) {
            // timed out: still try to read whatever streams ffmpeg has.
        }
    }

    result.bit_rate = fmt->bit_rate;
    result.duration_us = fmt->duration; // AV_NOPTS_VALUE if unknown

    int picked_video = 0;
    int picked_audio = 0;

    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        AVStream *st = fmt->streams[i];
        if (!st || !st->codecpar) continue;
        AVCodecParameters *par = st->codecpar;

        if (par->codec_type == AVMEDIA_TYPE_VIDEO) {
            result.has_video = 1;
            if (!picked_video) {
                picked_video = 1;
                result.width = par->width;
                result.height = par->height;
                copy_codec_name(result.video_codec, sizeof(result.video_codec), par->codec_id);

                // Prefer avg_frame_rate. r_frame_rate is the "smallest tick"
                // and for MPEG-TS streams without an explicit avg rate it can
                // come back as 90000/1 (the TS time base) — clearly nonsense
                // as a display fps. Clamp to a sane band before accepting it.
                AVRational fr = st->avg_frame_rate;
                double candidate = (fr.den != 0 && fr.num != 0)
                    ? (double)fr.num / (double)fr.den : 0;
                if (candidate <= 0 || candidate > 240) {
                    fr = st->r_frame_rate;
                    candidate = (fr.den != 0 && fr.num != 0)
                        ? (double)fr.num / (double)fr.den : 0;
                    if (candidate > 240) candidate = 0;
                }
                if (candidate > 0) result.fps = candidate;
            }
        } else if (par->codec_type == AVMEDIA_TYPE_AUDIO) {
            result.has_audio = 1;
            if (!picked_audio) {
                picked_audio = 1;
                copy_codec_name(result.audio_codec, sizeof(result.audio_codec), par->codec_id);
                result.audio_channels = par->ch_layout.nb_channels;
                result.sample_rate = par->sample_rate;
            }
        }
    }

    avformat_close_input(&fmt);

    result.probe_seconds = elapsed_seconds_since(&start);
    result.status_code = 0;
    return result;
}

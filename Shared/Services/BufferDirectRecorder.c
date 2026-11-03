#include "BufferDirectRecorder.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <Libavformat/avformat.h>
#include <Libavcodec/avcodec.h>
#include <Libavcodec/codec_par.h>
#include <Libavutil/dict.h>
#include <Libavutil/error.h>
#include <Libavutil/mathematics.h>
#include <Libavutil/rational.h>

struct BufferDirectRecorder {
    char *input_url;
    char *output_path;
    char *user_agent;
    char *referer;

    pthread_t thread;
    int thread_started;
    volatile int stop_requested;
    int is_running;

    AVFormatContext *in_ctx;
    AVFormatContext *out_ctx;
    int *stream_mapping;
    int stream_mapping_size;

    pthread_mutex_t stats_mutex;
    int64_t bytes_written;
    char last_error[256];
    BufferDirectRecorderStreamInfo stream_info;
};

static pthread_once_t s_init_once = PTHREAD_ONCE_INIT;

static void recorder_do_init(void) {
    avformat_network_init();
}

void buffer_direct_recorder_init(void) {
    pthread_once(&s_init_once, recorder_do_init);
}

static void copy_str(char **dst, const char *src) {
    if (!src) {
        *dst = NULL;
        return;
    }
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

static int input_interrupt_cb(void *opaque) {
    BufferDirectRecorder *recorder = (BufferDirectRecorder *)opaque;
    return recorder && recorder->stop_requested;
}

static void fill_stream_info(BufferDirectRecorder *recorder) {
    if (!recorder || !recorder->in_ctx) return;

    memset(&recorder->stream_info, 0, sizeof(recorder->stream_info));

    for (unsigned i = 0; i < recorder->in_ctx->nb_streams; i++) {
        AVStream *st = recorder->in_ctx->streams[i];
        if (!st || !st->codecpar) continue;
        AVCodecParameters *par = st->codecpar;

        if (par->codec_type == AVMEDIA_TYPE_VIDEO && recorder->stream_info.video_codec[0] == '\0') {
            recorder->stream_info.video_width = par->width;
            recorder->stream_info.video_height = par->height;
            snprintf(recorder->stream_info.video_codec,
                     sizeof(recorder->stream_info.video_codec),
                     "%s",
                     avcodec_get_name(par->codec_id));

            AVRational fr = st->avg_frame_rate;
            double fps = (fr.den != 0 && fr.num != 0)
                ? (double)fr.num / (double)fr.den
                : 0;
            if (fps <= 0 || fps > 240) {
                fr = st->r_frame_rate;
                fps = (fr.den != 0 && fr.num != 0)
                    ? (double)fr.num / (double)fr.den
                    : 0;
                if (fps > 240) fps = 0;
            }
            recorder->stream_info.video_fps = fps;
        } else if (par->codec_type == AVMEDIA_TYPE_AUDIO && recorder->stream_info.audio_codec[0] == '\0') {
            snprintf(recorder->stream_info.audio_codec,
                     sizeof(recorder->stream_info.audio_codec),
                     "%s",
                     avcodec_get_name(par->codec_id));
        }
    }
}

static int open_input_with_options(BufferDirectRecorder *recorder, char *error, size_t error_size) {
    AVDictionary *opts = NULL;
    if (recorder->user_agent && recorder->user_agent[0]) {
        av_dict_set(&opts, "user_agent", recorder->user_agent, 0);
    }
    if (recorder->referer && recorder->referer[0]) {
        av_dict_set(&opts, "referer", recorder->referer, 0);
    }
    av_dict_set(&opts, "reconnect", "1", 0);
    av_dict_set(&opts, "reconnect_streamed", "1", 0);
    av_dict_set(&opts, "reconnect_on_network_error", "1", 0);
    av_dict_set(&opts, "reconnect_on_http_error", "5xx", 0);
    av_dict_set_int(&opts, "reconnect_delay_max", 5, 0);
    av_dict_set_int(&opts, "rw_timeout", 20 * 1000 * 1000, 0);
    av_dict_set_int(&opts, "probesize", 1 * 1024 * 1024, 0);
    av_dict_set_int(&opts, "analyzeduration", 3 * 1000 * 1000, 0);
    av_dict_set_int(&opts, "seg_max_retry", 5, 0);

    AVFormatContext *ctx = avformat_alloc_context();
    if (!ctx) {
        av_dict_free(&opts);
        snprintf(error, error_size, "avformat_alloc_context failed");
        return AVERROR(ENOMEM);
    }
    ctx->interrupt_callback.callback = input_interrupt_cb;
    ctx->interrupt_callback.opaque = recorder;

    recorder->in_ctx = ctx;
    int rc = avformat_open_input(&recorder->in_ctx, recorder->input_url, NULL, &opts);
    av_dict_free(&opts);
    if (rc < 0) {
        format_error(rc, error, error_size);
        recorder->in_ctx = NULL;
        return rc;
    }

    rc = avformat_find_stream_info(recorder->in_ctx, NULL);
    if (rc < 0) {
        format_error(rc, error, error_size);
        avformat_close_input(&recorder->in_ctx);
        return rc;
    }

    fill_stream_info(recorder);
    return 0;
}

static int build_output(BufferDirectRecorder *recorder, char *error, size_t error_size) {
    int rc = avformat_alloc_output_context2(&recorder->out_ctx, NULL, "mpegts", recorder->output_path);
    if (rc < 0 || !recorder->out_ctx) {
        format_error(rc, error, error_size);
        return -1;
    }

    recorder->stream_mapping = (int *)calloc(recorder->in_ctx->nb_streams, sizeof(int));
    if (!recorder->stream_mapping) {
        snprintf(error, error_size, "stream mapping alloc failed");
        return -1;
    }
    recorder->stream_mapping_size = recorder->in_ctx->nb_streams;

    for (int i = 0; i < (int)recorder->in_ctx->nb_streams; i++) {
        AVStream *in_s = recorder->in_ctx->streams[i];
        int type = in_s->codecpar->codec_type;
        if (type != AVMEDIA_TYPE_AUDIO && type != AVMEDIA_TYPE_VIDEO) {
            recorder->stream_mapping[i] = -1;
            continue;
        }

        AVStream *out_s = avformat_new_stream(recorder->out_ctx, NULL);
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
        recorder->stream_mapping[i] = out_s->index;
    }

    if (!(recorder->out_ctx->oformat->flags & AVFMT_NOFILE)) {
        rc = avio_open(&recorder->out_ctx->pb, recorder->output_path, AVIO_FLAG_WRITE);
        if (rc < 0) {
            format_error(rc, error, error_size);
            return -1;
        }
    }

    AVDictionary *hdr_opts = NULL;
    av_dict_set(&hdr_opts, "mpegts_flags", "pat_pmt_at_frames", 0);
    rc = avformat_write_header(recorder->out_ctx, &hdr_opts);
    av_dict_free(&hdr_opts);
    if (rc < 0) {
        format_error(rc, error, error_size);
        return -1;
    }

    return 0;
}

static void update_bytes_written(BufferDirectRecorder *recorder) {
    if (!recorder || !recorder->out_ctx || !recorder->out_ctx->pb) return;
    int64_t bytes = avio_tell(recorder->out_ctx->pb);
    if (bytes < 0) return;

    pthread_mutex_lock(&recorder->stats_mutex);
    recorder->bytes_written = bytes;
    pthread_mutex_unlock(&recorder->stats_mutex);
}

static void set_running(BufferDirectRecorder *recorder, int running) {
    if (!recorder) return;
    pthread_mutex_lock(&recorder->stats_mutex);
    recorder->is_running = running;
    pthread_mutex_unlock(&recorder->stats_mutex);
}

static void set_terminal_error(BufferDirectRecorder *recorder, int rc) {
    if (!recorder || recorder->stop_requested) return;
    char buf[sizeof(recorder->last_error)] = {0};
    format_error(rc, buf, sizeof(buf));
    pthread_mutex_lock(&recorder->stats_mutex);
    snprintf(recorder->last_error, sizeof(recorder->last_error), "%s", buf);
    pthread_mutex_unlock(&recorder->stats_mutex);
}

static void *worker_main(void *opaque) {
    BufferDirectRecorder *recorder = (BufferDirectRecorder *)opaque;
    AVPacket *pkt = av_packet_alloc();
    if (!pkt) {
        set_terminal_error(recorder, AVERROR(ENOMEM));
        set_running(recorder, 0);
        return NULL;
    }

    while (!recorder->stop_requested) {
        int rc = av_read_frame(recorder->in_ctx, pkt);
        if (rc < 0) {
            if (rc != AVERROR_EOF) {
                set_terminal_error(recorder, rc);
            }
            break;
        }

        if (pkt->stream_index < 0 || pkt->stream_index >= recorder->stream_mapping_size) {
            av_packet_unref(pkt);
            continue;
        }
        int out_idx = recorder->stream_mapping[pkt->stream_index];
        if (out_idx < 0) {
            av_packet_unref(pkt);
            continue;
        }

        AVStream *in_s = recorder->in_ctx->streams[pkt->stream_index];
        AVStream *out_s = recorder->out_ctx->streams[out_idx];
        av_packet_rescale_ts(pkt, in_s->time_base, out_s->time_base);
        pkt->stream_index = out_idx;
        pkt->pos = -1;

        int werr = av_interleaved_write_frame(recorder->out_ctx, pkt);
        av_packet_unref(pkt);
        if (werr < 0) {
            set_terminal_error(recorder, werr);
            break;
        }

        update_bytes_written(recorder);
    }

    av_packet_free(&pkt);
    if (recorder->out_ctx && recorder->out_ctx->pb) {
        av_write_trailer(recorder->out_ctx);
        update_bytes_written(recorder);
    }
    set_running(recorder, 0);
    return NULL;
}

BufferDirectRecorder *buffer_direct_recorder_create(const char *input_url,
                                                    const char *output_path,
                                                    const char *user_agent,
                                                    const char *referer,
                                                    char *error,
                                                    size_t error_size) {
    if (!input_url || !input_url[0] || !output_path || !output_path[0]) {
        if (error && error_size > 0) snprintf(error, error_size, "missing input or output path");
        return NULL;
    }

    buffer_direct_recorder_init();

    BufferDirectRecorder *recorder = (BufferDirectRecorder *)calloc(1, sizeof(*recorder));
    if (!recorder) {
        if (error && error_size > 0) snprintf(error, error_size, "calloc failed");
        return NULL;
    }

    pthread_mutex_init(&recorder->stats_mutex, NULL);
    copy_str(&recorder->input_url, input_url);
    copy_str(&recorder->output_path, output_path);
    copy_str(&recorder->user_agent, user_agent);
    copy_str(&recorder->referer, referer);

    if (open_input_with_options(recorder, error, error_size) < 0) {
        buffer_direct_recorder_free(recorder);
        return NULL;
    }
    if (build_output(recorder, error, error_size) != 0) {
        buffer_direct_recorder_free(recorder);
        return NULL;
    }

    if (pthread_create(&recorder->thread, NULL, worker_main, recorder) != 0) {
        if (error && error_size > 0) snprintf(error, error_size, "pthread_create failed");
        buffer_direct_recorder_free(recorder);
        return NULL;
    }
    recorder->thread_started = 1;
    set_running(recorder, 1);
    return recorder;
}

int64_t buffer_direct_recorder_bytes_written(BufferDirectRecorder *recorder) {
    if (!recorder) return 0;
    pthread_mutex_lock(&recorder->stats_mutex);
    int64_t value = recorder->bytes_written;
    pthread_mutex_unlock(&recorder->stats_mutex);
    return value;
}

int buffer_direct_recorder_is_running(BufferDirectRecorder *recorder) {
    if (!recorder) return 0;
    pthread_mutex_lock(&recorder->stats_mutex);
    int running = recorder->is_running;
    pthread_mutex_unlock(&recorder->stats_mutex);
    return running;
}

int buffer_direct_recorder_copy_error(BufferDirectRecorder *recorder,
                                      char *buffer,
                                      size_t buffer_size) {
    if (!buffer || buffer_size == 0) return 0;
    buffer[0] = '\0';
    if (!recorder) return 0;

    pthread_mutex_lock(&recorder->stats_mutex);
    int has_error = recorder->last_error[0] != '\0';
    if (has_error) {
        snprintf(buffer, buffer_size, "%s", recorder->last_error);
    }
    pthread_mutex_unlock(&recorder->stats_mutex);
    return has_error;
}

void buffer_direct_recorder_get_stream_info(BufferDirectRecorder *recorder,
                                            BufferDirectRecorderStreamInfo *out) {
    if (!out) return;
    memset(out, 0, sizeof(*out));
    if (!recorder) return;
    *out = recorder->stream_info;
}

void buffer_direct_recorder_free(BufferDirectRecorder *recorder) {
    if (!recorder) return;

    recorder->stop_requested = 1;
    if (recorder->thread_started) {
        pthread_join(recorder->thread, NULL);
        recorder->thread_started = 0;
    }

    if (recorder->in_ctx) {
        avformat_close_input(&recorder->in_ctx);
    }
    if (recorder->out_ctx) {
        if (!(recorder->out_ctx->oformat->flags & AVFMT_NOFILE) && recorder->out_ctx->pb) {
            avio_closep(&recorder->out_ctx->pb);
        }
        avformat_free_context(recorder->out_ctx);
        recorder->out_ctx = NULL;
    }

    pthread_mutex_destroy(&recorder->stats_mutex);
    free(recorder->stream_mapping);
    free(recorder->input_url);
    free(recorder->output_path);
    free(recorder->user_agent);
    free(recorder->referer);
    free(recorder);
}

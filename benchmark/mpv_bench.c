// mpv startup benchmark - measures time from loadfile to first frame
// Build: clang -o mpv_bench mpv_bench.c -F../.build/SourcePackages/artifacts/mpvkit/Libmpv-GPL/Libmpv.xcframework/macos-arm64_x86_64 -framework Libmpv -framework OpenGL -framework Cocoa
#include <mpv/client.h>
#include <mpv/render_gl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>

static double now_ms(void) {
    return CFAbsoluteTimeGetCurrent() * 1000.0;
}

static void check(int status, const char *msg) {
    if (status < 0) {
        fprintf(stderr, "mpv error (%s): %s\n", msg, mpv_error_string(status));
        exit(1);
    }
}

static void set_option(mpv_handle *h, const char *name, const char *value) {
    check(mpv_set_option_string(h, name, value), name);
}

// Mirror Buffer's MPVPlayer setupMPV options as closely as feasible
static void configure_mpv(mpv_handle *h, int buffer_seconds, int fast_probe) {
    // hwdec
    set_option(h, "hwdec", "videotoolbox");
    set_option(h, "hwdec-codecs", "all");
    set_option(h, "vd-lavc-dr", "yes");
    set_option(h, "vd-lavc-threads", "2");
    set_option(h, "vd-lavc-show-all", "no");

    // Video output - use libmpv + OpenGL (need GL context for actual rendering)
    // For benchmark, we just need first-frame callbacks, not actual pixels
    set_option(h, "vo", "libmpv");
    set_option(h, "gpu-api", "opengl");

    // Frame timing
    set_option(h, "video-sync", "audio");
    set_option(h, "interpolation", "no");

    // UI
    set_option(h, "osc", "no");
    set_option(h, "input-default-bindings", "no");
    set_option(h, "idle", "yes");
    set_option(h, "keep-open", "no");
    set_option(h, "terminal", "no");
    set_option(h, "osd-level", "0");
    set_option(h, "msg-level", "all=warn");
    set_option(h, "load-scripts", "no");
    set_option(h, "ytdl", "no");

    // Audio
    set_option(h, "volume", "100");
    set_option(h, "ao", "null");  // No audio output for benchmark

    // Caching - mirror the app's cache strategy
    set_option(h, "cache", "auto");
    char cache_secs[32];
    double cap = (double)buffer_seconds * 3;
    if (cap > 60) cap = 60;
    snprintf(cache_secs, sizeof(cache_secs), "%.0f", cap);
    set_option(h, "cache-secs", cache_secs);
    set_option(h, "cache-pause", "yes");
    set_option(h, "cache-pause-initial", "no");
    double wait = (double)buffer_seconds * 0.5;
    if (wait < 1.25) wait = 1.25;
    if (wait > 3.0) wait = 3.0;
    char cache_pause_wait[32];
    snprintf(cache_pause_wait, sizeof(cache_pause_wait), "%.2f", wait);
    set_option(h, "cache-pause-wait", cache_pause_wait);

    // Demuxer
    char demuxer_max[32];
    int mib = buffer_seconds * 6;
    if (mib < 96) mib = 96;
    if (mib > 256) mib = 256;
    snprintf(demuxer_max, sizeof(demuxer_max), "%dMiB", mib);
    set_option(h, "demuxer-max-bytes", demuxer_max);
    set_option(h, "demuxer-max-back-bytes", "8MiB");
    set_option(h, "demuxer-readahead-secs", cache_secs);
    set_option(h, "demuxer-hysteresis-secs", "0");
    set_option(h, "demuxer-thread", "yes");

    // ffmpeg demuxer tuning
    set_option(h, "demuxer-lavf-probe-info", "auto");
    set_option(h, "demuxer-lavf-o", "fflags=+discardcorrupt");
    if (fast_probe) {
        set_option(h, "demuxer-lavf-probesize", "65536");
        set_option(h, "demuxer-lavf-analyzeduration", "0.1");
    } else {
        set_option(h, "demuxer-lavf-probesize", "1048576");
        set_option(h, "demuxer-lavf-analyzeduration", "1.0");
    }

    // Network
    set_option(h, "network-timeout", "10");
    set_option(h, "stream-lavf-o", "rw_timeout=10000000");
    set_option(h, "user-agent", "Buffer/1.0");

    // GL settings
    set_option(h, "opengl-early-flush", "yes");
    set_option(h, "opengl-pbo", "yes");
    set_option(h, "opengl-swapinterval", "0");

    // Scaling
    set_option(h, "scale", "spline36");
    set_option(h, "cscale", "spline36");
    set_option(h, "dscale", "spline36");

    // Disable quality features
    set_option(h, "deband", "no");
    set_option(h, "dither", "no");
    set_option(h, "sigmoid-upscaling", "no");
    set_option(h, "correct-downscaling", "no");
    set_option(h, "linear-downscaling", "no");

    // Config
    set_option(h, "config", "no");

    check(mpv_initialize(h), "mpv_initialize");
}


static double first_frame_time_ms = 0;
static int got_first_frame = 0;

static void wakeup_cb(void *ctx) {
    // No-op: we poll in the main loop
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <url> [buffer_seconds] [fast_probe]\n", argv[0]);
        fprintf(stderr, "  buffer_seconds: network buffer in seconds (default: 5)\n");
        fprintf(stderr, "  fast_probe: 1 to use fast probe (64KB/0.1s), 0 for default (1MB/1s)\n");
        return 1;
    }

    const char *url = argv[1];
    int buffer_seconds = argc > 2 ? atoi(argv[2]) : 5;
    int fast_probe = argc > 3 ? atoi(argv[3]) : 0;
    if (buffer_seconds < 1) buffer_seconds = 5;

    mpv_handle *h = mpv_create();
    if (!h) {
        fprintf(stderr, "mpv_create failed\n");
        return 1;
    }

    configure_mpv(h, buffer_seconds, fast_probe);
    mpv_set_wakeup_callback(h, wakeup_cb, NULL);

    // Observe some properties
    mpv_observe_property(h, 0, "pause", MPV_FORMAT_FLAG);
    mpv_observe_property(h, 0, "paused-for-cache", MPV_FORMAT_FLAG);

    // Issue loadfile
    double start = now_ms();
    const char *cmd[] = {"loadfile", url, "replace", NULL};
    check(mpv_command(h, cmd), "loadfile");

    // Unpause to start playback
    int v = 0;
    mpv_set_property(h, "pause", MPV_FORMAT_FLAG, &v);

    // Event loop: wait for first video frame or timeout
    double timeout_at = now_ms() + 30000; // 30 second timeout
    int file_loaded = 0;

    while (now_ms() < timeout_at) {
        mpv_event *ev = mpv_wait_event(h, 0.1); // 100ms timeout
        if (!ev) continue;

        switch (ev->event_id) {
        case MPV_EVENT_NONE:
            break;
        case MPV_EVENT_SHUTDOWN:
            fprintf(stderr, "mpv shutdown\n");
            goto done;
        case MPV_EVENT_FILE_LOADED:
            file_loaded = 1;
            fprintf(stderr, "FILE_LOADED at %.0f ms\n", now_ms() - start);
            break;
        case MPV_EVENT_END_FILE: {
            mpv_event_end_file *ef = ev->data;
            fprintf(stderr, "END_FILE reason=%d error=%d at %.0f ms\n",
                    ef->reason, ef->error, now_ms() - start);
            goto done;
        }
        case MPV_EVENT_VIDEO_RECONFIG:
            fprintf(stderr, "VIDEO_RECONFIG at %.0f ms\n", now_ms() - start);
            break;
        case MPV_EVENT_PLAYBACK_RESTART:
            fprintf(stderr, "PLAYBACK_RESTART at %.0f ms\n", now_ms() - start);
            break;
        default:
            break;
        }

        // Check if we have a video frame yet
        if (file_loaded && !got_first_frame) {
            // mpv doesn't have a direct "first frame" event without render context.
            // We use PLAYBACK_RESTART fired after the first video frame.
        }
    }

    fprintf(stderr, "Timeout after 30s\n");

done: {
    double elapsed = now_ms() - start;
    // Print the key metric in a machine-parseable format
    printf("{\"elapsed_ms\": %.0f, \"file_loaded\": %d, \"url\": \"%s\"}\n",
           elapsed, file_loaded, url);
}

    mpv_terminate_destroy(h);
    return 0;
}

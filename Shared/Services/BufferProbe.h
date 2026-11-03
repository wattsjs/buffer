#ifndef BUFFER_PROBE_H
#define BUFFER_PROBE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Result of a stream probe. All string fields are NUL-terminated and are
/// always valid (empty if not present), so Swift can read them unconditionally.
typedef struct {
    int     status_code;       // 0 ok, negative on ffmpeg error, -1000 on timeout
    char    error[256];        // empty on success

    int     has_video;         // 1 if at least one video stream
    int     has_audio;         // 1 if at least one audio stream

    int     width;             // first video stream
    int     height;
    double  fps;               // avg_frame_rate, falling back to r_frame_rate
    char    video_codec[32];   // avcodec_get_name() of first video stream

    char    audio_codec[32];
    int     audio_channels;
    int     sample_rate;

    int64_t bit_rate;          // container bitrate (0 if unknown)
    int64_t duration_us;       // negative for live/unknown
    double  probe_seconds;     // wall-clock time spent probing
} BufferProbeResult;

/// Idempotent: ensures avformat_network_init has run.
void buffer_probe_init(void);

/// Synchronous probe. Blocks the calling thread; invoke off the main thread.
/// Returns within roughly `timeout_seconds` (the ffmpeg interrupt callback
/// is checked at IO boundaries; treat the timeout as advisory + a few seconds).
BufferProbeResult buffer_probe_stream(const char *url, int timeout_seconds);

#ifdef __cplusplus
}
#endif

#endif

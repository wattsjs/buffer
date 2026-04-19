#ifndef BUFFER_DIRECT_RECORDER_H
#define BUFFER_DIRECT_RECORDER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BufferDirectRecorder BufferDirectRecorder;

typedef struct {
    int     video_width;
    int     video_height;
    double  video_fps;
    char    video_codec[32];
    char    audio_codec[32];
} BufferDirectRecorderStreamInfo;

/// Idempotent: ensures avformat_network_init has run.
void buffer_direct_recorder_init(void);

/// Opens the upstream URL, prepares an MPEG-TS output file, and starts a
/// background copy loop. Returns NULL on failure and writes a human-readable
/// message into `error` when provided.
BufferDirectRecorder *buffer_direct_recorder_create(const char *input_url,
                                                    const char *output_path,
                                                    const char *user_agent,
                                                    const char *referer,
                                                    char *error,
                                                    size_t error_size);

/// Returns the most recent number of bytes written to disk.
int64_t buffer_direct_recorder_bytes_written(BufferDirectRecorder *recorder);

/// Returns non-zero while the background copy loop is still active.
int buffer_direct_recorder_is_running(BufferDirectRecorder *recorder);

/// Copies the recorder's terminal error, if any, into `buffer`. Returns
/// non-zero when an error message was present.
int buffer_direct_recorder_copy_error(BufferDirectRecorder *recorder,
                                      char *buffer,
                                      size_t buffer_size);

/// Returns stream characteristics captured during initial open.
void buffer_direct_recorder_get_stream_info(BufferDirectRecorder *recorder,
                                            BufferDirectRecorderStreamInfo *out);

/// Requests shutdown, waits for the worker thread to finish, and frees all
/// resources. Safe to call with NULL.
void buffer_direct_recorder_free(BufferDirectRecorder *recorder);

#ifdef __cplusplus
}
#endif

#endif

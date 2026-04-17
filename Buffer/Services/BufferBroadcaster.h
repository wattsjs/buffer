#ifndef BUFFER_BROADCASTER_H
#define BUFFER_BROADCASTER_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BufferBroadcaster BufferBroadcaster;

/// Invoked on the broadcaster's internal thread whenever a chunk of muxed
/// MPEG-TS bytes is produced. Implementations must not block for long —
/// queue to a ring buffer / write non-blocking to a socket.
typedef void (*BufferSinkOnBytes)(void *ctx, const uint8_t *bytes, size_t len);
typedef void (*BufferSinkOnEOF)(void *ctx);

typedef struct {
    BufferSinkOnBytes on_bytes;
    BufferSinkOnEOF on_eof;   // optional (may be NULL)
    void *ctx;
} BufferSinkCallbacks;

/// Open a broadcaster for `input_url`. Starts pulling and muxing
/// immediately on a background thread. Returns NULL on synchronous failure
/// (connect / handshake / probe errors). error buffer populated on failure.
BufferBroadcaster *buffer_broadcaster_create(const char *input_url,
                                             const char *user_agent,
                                             const char *referer,
                                             char *error, size_t error_size);

/// Register a byte sink. Bytes start flowing immediately (callback invoked
/// from the broadcaster's thread). Returns a positive token; 0 = failure.
int buffer_broadcaster_add_sink(BufferBroadcaster *b, BufferSinkCallbacks cb);

/// Remove a sink by token. Safe to call from any thread; the broadcaster
/// guarantees no more callbacks for that sink after this returns.
void buffer_broadcaster_remove_sink(BufferBroadcaster *b, int token);

/// Current number of active sinks. When this reaches zero the broadcaster
/// can be torn down.
int buffer_broadcaster_sink_count(BufferBroadcaster *b);

/// Stream characteristics captured from the input after
/// `avformat_find_stream_info`. Populated with zeros / empty strings for
/// any field the input didn't expose (e.g. audio_codec if the stream has
/// no audio, video_fps if the muxer didn't carry a frame rate).
typedef struct {
    int video_width;
    int video_height;
    char video_codec[32];
    double video_fps;
    char audio_codec[32];
} BufferStreamInfo;

/// Fill `out` from the broadcaster's already-probed input. Safe to call
/// any time after `buffer_broadcaster_create` succeeded.
void buffer_broadcaster_get_stream_info(BufferBroadcaster *b, BufferStreamInfo *out);

/// Stop the background thread and release all resources. Sinks are
/// implicitly removed.
void buffer_broadcaster_free(BufferBroadcaster *b);

#ifdef __cplusplus
}
#endif

#endif

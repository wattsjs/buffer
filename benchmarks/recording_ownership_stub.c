#include "recording_ownership_stub.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
struct BufferDirectRecorder { int running; };
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t condition = PTHREAD_COND_INITIALIZER;
static int held, creates, frees;
void fixture_recorder_hold(int value) {
    pthread_mutex_lock(&lock); held = value; pthread_cond_broadcast(&condition); pthread_mutex_unlock(&lock);
}
int fixture_recorder_creates(void) { pthread_mutex_lock(&lock); int value = creates; pthread_mutex_unlock(&lock); return value; }
int fixture_recorder_frees(void) { pthread_mutex_lock(&lock); int value = frees; pthread_mutex_unlock(&lock); return value; }
void buffer_direct_recorder_init(void) {}
BufferDirectRecorder *buffer_direct_recorder_create(const char *u, const char *p, const char *a, const char *r, char *e, size_t n) {
    pthread_mutex_lock(&lock); ++creates;
    while (held) pthread_cond_wait(&condition, &lock);
    pthread_mutex_unlock(&lock);
    BufferDirectRecorder *recorder = calloc(1, sizeof(*recorder)); recorder->running = 1; return recorder;
}
int64_t buffer_direct_recorder_bytes_written(BufferDirectRecorder *r) { return 0; }
int buffer_direct_recorder_is_running(BufferDirectRecorder *r) { return r->running; }
int buffer_direct_recorder_copy_error(BufferDirectRecorder *r, char *b, size_t n) { return 0; }
void buffer_direct_recorder_get_stream_info(BufferDirectRecorder *r, BufferDirectRecorderStreamInfo *out) {
    memset(out, 0, sizeof(*out)); out->video_width = 1920; out->video_height = 1080; out->video_fps = 50;
    strcpy(out->video_codec, "h264"); strcpy(out->audio_codec, "aac");
}
void buffer_direct_recorder_free(BufferDirectRecorder *r) {
    if (!r) return;
    pthread_mutex_lock(&lock); ++frees; pthread_mutex_unlock(&lock); free(r);
}

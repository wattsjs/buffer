#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreAudio/CoreAudio.h>
#include <gst/gst.h>
#include <gst/video/video.h>

// Native Cocoa host, GStreamer C API, VideoToolbox-only decode preference,
// AVSampleBufferDisplayLayer presentation and real CoreAudio sink.
@interface GSTProbePanel : NSPanel
@end
@implementation GSTProbePanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface GSTProbe : NSObject <NSApplicationDelegate> {
@public
    GstElement *pipeline;
    GstElement *videoSink;
    GstElement *audioSink;
    GstElement *adaptive;
    GstBus *bus;
    NSPanel *window;
    NSView *view;
    NSMutableSet<NSString *> *elements;
    NSTimer *timer;
    CFTimeInterval started;
    double seconds;
    double bufferSeconds;
    NSInteger startupMs;
    NSInteger bufferingPercent;
    BOOL attached;
    BOOL finished;
    NSString *lastError;
    int outputChannels;
    int mappedChannels;
}
- (void)sample;
@end

static NSString *argument(NSString *name) {
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    NSUInteger i = [args indexOfObject:name];
    return i != NSNotFound && i + 1 < args.count ? args[i + 1] : nil;
}

static void emit(NSDictionary *fields) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:fields options:NSJSONWritingSortedKeys error:nil];
    if (!data) return;
    fwrite("BUFFER_PLAYBACK_JSON ", 1, 21, stdout);
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

// Do not persist a device ID or name: the probe only needs the current layout.
// An explicit fixture matrix must match the output selected by osxaudiosink.
static int defaultOutputChannelCount(OSStatus *status) {
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    *status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &device);
    if (*status != noErr || device == kAudioObjectUnknown) return -1;
    address = (AudioObjectPropertyAddress){kAudioDevicePropertyStreamConfiguration,
        kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
    *status = AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size);
    if (*status != noErr || size < offsetof(AudioBufferList, mBuffers)) return -1;
    AudioBufferList *buffers = calloc(1, size);
    if (!buffers) return -1;
    *status = AudioObjectGetPropertyData(device, &address, 0, NULL, &size, buffers);
    int count = 0;
    if (*status == noErr && buffers->mNumberBuffers <=
            (size - offsetof(AudioBufferList, mBuffers)) / sizeof(AudioBuffer)) {
        for (UInt32 index = 0; index < buffers->mNumberBuffers; index++)
            count += buffers->mBuffers[index].mNumberChannels;
    }
    free(buffers);
    return count > 0 ? count : -1;
}

static BOOL validateAudioLayout(int *outputs, int *mapped, BOOL reportLayout) {
    OSStatus status = noErr;
    *outputs = defaultOutputChannelCount(&status);
    *mapped = [argument(@"--gst-audio-map") intValue];
    BOOL matches = *outputs > 0 && (*mapped == 0 || (*mapped >= 2 && *mapped <= 16 && *mapped == *outputs));
    if (reportLayout)
        emit(@{@"event": @"audio-layout", @"outputChannels": @(*outputs),
               @"mappedChannels": @(*mapped), @"status": @(status), @"layoutMatches": @(matches)});
    if (!matches) {
        emit(@{@"event": @"error", @"error": *outputs <= 0 ? @"cannot query default audio output layout" :
               @"explicit stereo fixture matrix does not match default output channel count",
               @"outputChannels": @(*outputs), @"mappedChannels": @(*mapped)});
    }
    return matches;
}

static void setStereoDeviceMatrix(GstElement *element, int outputs) {
    GValue matrix = G_VALUE_INIT;
    g_value_init(&matrix, GST_TYPE_ARRAY);
    for (int row = 0; row < outputs; row++) {
        GValue values = G_VALUE_INIT;
        g_value_init(&values, GST_TYPE_ARRAY);
        for (int column = 0; column < 2; column++) {
            GValue value = G_VALUE_INIT;
            g_value_init(&value, G_TYPE_FLOAT);
            g_value_set_float(&value, row == column ? 1.0f : 0.0f);
            gst_value_array_append_value(&values, &value);
            g_value_unset(&value);
        }
        gst_value_array_append_value(&matrix, &values);
        g_value_unset(&values);
    }
    g_object_set_property(G_OBJECT(element), "mix-matrix", &matrix);
    g_value_unset(&matrix);
}

static void elementSetup(GstElement *playbin, GstElement *element, gpointer context) {
    GSTProbe *probe = (__bridge GSTProbe *)context;
    GstElementFactory *factory = gst_element_get_factory(element);
    if (!factory) return;
    const gchar *name = gst_plugin_feature_get_name(GST_PLUGIN_FEATURE(factory));
    NSString *factoryName = [NSString stringWithUTF8String:name];
    if (!strcmp(name, "audioconvert") && probe->mappedChannels >= 2 && probe->mappedChannels <= 16) {
        // Explicit experiment for the stereo fixture and an unpositioned
        // multichannel device: retain L/R and silence the remaining channels.
        setStereoDeviceMatrix(element, probe->mappedChannels);
    }
    if (!strcmp(name, "hlsdemux2")) {
        // Explicit reserve bounds; actual forward levels are observed below.
        g_object_set(element, "max-buffering-time", (guint64)(probe->bufferSeconds * GST_SECOND),
                     "high-watermark-time", (guint64)(probe->bufferSeconds * GST_SECOND),
                     "low-watermark-time", (guint64)(1.5 * GST_SECOND),
                     "max-retries", 3, "retry-backoff-factor", 0.25,
                     "retry-backoff-max", 2.0, NULL);
        gst_object_ref(element);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (probe->adaptive) gst_object_unref(probe->adaptive);
            probe->adaptive = element;
        });
    }
    dispatch_async(dispatch_get_main_queue(), ^{ [probe->elements addObject:factoryName]; });
}

@implementation GSTProbe
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    if (!validateAudioLayout(&outputChannels, &mappedChannels, NO)) exit(1);
    gst_init(NULL, NULL);
    seconds = [argument(@"--validate-seconds") doubleValue] ?: 30;
    bufferSeconds = [argument(@"--validate-buffer") doubleValue] ?: 5;
    startupMs = -1;
    bufferingPercent = 100;
    elements = [NSMutableSet set];
    GstPluginFeature *decoder = gst_registry_find_feature(gst_registry_get(), "vtdec_hw", GST_TYPE_ELEMENT_FACTORY);
    if (!decoder) { emit(@{@"event": @"error", @"error": @"vtdec_hw unavailable"}); exit(1); }
    gst_plugin_feature_set_rank(decoder, GST_RANK_PRIMARY + 1000);
    gst_object_unref(decoder);
    pipeline = gst_element_factory_make("playbin3", "probe");
    NSString *sinkName = argument(@"--gst-sink") ?: @"avsamplebufferlayersink";
    videoSink = gst_element_factory_make(sinkName.UTF8String, "native-video");
    audioSink = gst_element_factory_make("osxaudiosink", "native-audio");
    if (!pipeline || !videoSink || !audioSink) { emit(@{@"event": @"error", @"error": @"required GStreamer element unavailable"}); exit(1); }
    gst_object_ref_sink(videoSink);
    gst_object_ref_sink(audioSink);
    g_signal_connect(pipeline, "element-setup", G_CALLBACK(elementSetup), (__bridge void *)self);
    g_object_set(pipeline, "uri", argument(@"--validate-url").UTF8String,
                 "video-sink", videoSink, "audio-sink", audioSink,
                 "buffer-duration", (gint64)(bufferSeconds * GST_SECOND), NULL);
    bus = gst_element_get_bus(pipeline);
    window = [[GSTProbePanel alloc] initWithContentRect:NSMakeRect(0, 0, 854, 480)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Buffer GStreamer Probe";
    window.floatingPanel = YES;
    window.hidesOnDeactivate = NO;
    window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    [window center];
    view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 854, 480)];
    view.wantsLayer = YES;
    window.contentView = view;
    [window orderFrontRegardless];
    if (GST_IS_VIDEO_OVERLAY(videoSink)) {
        gst_video_overlay_set_window_handle(GST_VIDEO_OVERLAY(videoSink), (guintptr)(__bridge void *)view);
        attached = YES;
    }
    started = CACurrentMediaTime();
    emit(@{@"event": @"start", @"engine": @"gstreamer", @"seconds": @(seconds), @"bufferSeconds": @(bufferSeconds),
           @"outputChannels": @(outputChannels), @"mappedChannels": @(mappedChannels),
           @"diagnosticWindowKey": @(window.isKeyWindow), @"diagnosticWindowMain": @(window.isMainWindow),
           @"diagnosticAppActive": @(NSApp.isActive),
           @"version": [NSString stringWithUTF8String:gst_version_string()]});
    GstStateChangeReturn state = gst_element_set_state(pipeline, GST_STATE_PLAYING);
    if (state == GST_STATE_CHANGE_FAILURE) { emit(@{@"event": @"error", @"error": @"cannot start pipeline"}); exit(1); }
    timer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { [self sample]; }];
}

- (void)sample {
    NSInteger elapsedMs = (NSInteger)((CACurrentMediaTime() - started) * 1000);
    GstMessage *message;
    while ((message = gst_bus_pop(bus))) {
        switch (GST_MESSAGE_TYPE(message)) {
            case GST_MESSAGE_ERROR: {
                GError *error = NULL; gchar *debug = NULL;
                gst_message_parse_error(message, &error, &debug);
                lastError = [NSString stringWithUTF8String:error->message];
                emit(@{@"event": @"error", @"elapsedMs": @(elapsedMs), @"error": lastError,
                       @"source": [NSString stringWithUTF8String:GST_OBJECT_NAME(message->src)],
                       @"debug": debug ? [NSString stringWithUTF8String:debug] : @""});
                g_error_free(error); g_free(debug); break;
            }
            case GST_MESSAGE_BUFFERING: {
                gint percent = 100;
                gst_message_parse_buffering(message, &percent);
                bufferingPercent = percent;
                gst_element_set_state(pipeline, percent < 100 ? GST_STATE_PAUSED : GST_STATE_PLAYING);
                break;
            }
            case GST_MESSAGE_CLOCK_LOST:
                gst_element_set_state(pipeline, GST_STATE_PAUSED);
                gst_element_set_state(pipeline, GST_STATE_PLAYING);
                break;
            default: break;
        }
        gst_message_unref(message);
    }
    if (!attached && g_object_class_find_property(G_OBJECT_GET_CLASS(videoSink), "layer")) {
        gpointer pointer = NULL;
        g_object_get(videoSink, "layer", &pointer, NULL);
        if (pointer) {
            CALayer *layer = (__bridge CALayer *)pointer;
            layer.frame = view.bounds;
            layer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
            [view.layer addSublayer:layer];
            attached = YES;
        }
    }
    guint64 rendered = 0, dropped = 0, audioRendered = 0;
    GstStructure *stats = NULL;
    GstElement *statsSink = videoSink;
    if (!g_object_class_find_property(G_OBJECT_GET_CLASS(statsSink), "stats")) {
        g_object_get(videoSink, "sink", &statsSink, NULL);
    }
    if (statsSink) g_object_get(statsSink, "stats", &stats, NULL);
    if (stats) {
        gst_structure_get_uint64(stats, "rendered", &rendered);
        gst_structure_get_uint64(stats, "dropped", &dropped);
        gst_structure_free(stats);
    }
    GstSample *lastSample = NULL;
    GstClockTime lastFrameStreamTime = GST_CLOCK_TIME_NONE;
    if (statsSink) g_object_get(statsSink, "last-sample", &lastSample, NULL);
    if (lastSample) {
        GstBuffer *buffer = gst_sample_get_buffer(lastSample);
        const GstSegment *segment = gst_sample_get_segment(lastSample);
        if (buffer && segment && GST_BUFFER_PTS_IS_VALID(buffer)) {
            lastFrameStreamTime = gst_segment_to_stream_time(segment, GST_FORMAT_TIME, GST_BUFFER_PTS(buffer));
        }
        gst_sample_unref(lastSample);
    }
    if (statsSink && statsSink != videoSink) gst_object_unref(statsSink);
    stats = NULL;
    g_object_get(audioSink, "stats", &stats, NULL);
    if (stats) { gst_structure_get_uint64(stats, "rendered", &audioRendered); gst_structure_free(stats); }
    gint64 position = 0;
    gst_element_query_position(pipeline, GST_FORMAT_TIME, &position);
    guint64 cacheVideo = 0, cacheAudio = 0;
    if (adaptive) g_object_get(adaptive, "current-level-time-video", &cacheVideo,
                              "current-level-time-audio", &cacheAudio, NULL);
    GstState state = GST_STATE_NULL;
    gst_element_get_state(pipeline, &state, NULL, 0);
    int width = 0, height = 0, audioChannels = 0;
    GstPad *audioPad = gst_element_get_static_pad(audioSink, "sink");
    GstCaps *audioCaps = gst_pad_get_current_caps(audioPad);
    if (audioCaps) {
        gst_structure_get_int(gst_caps_get_structure(audioCaps, 0), "channels", &audioChannels);
        gst_caps_unref(audioCaps);
    }
    gst_object_unref(audioPad);
    GstPad *pad = gst_element_get_static_pad(videoSink, "sink");
    GstCaps *caps = gst_pad_get_current_caps(pad);
    if (caps) {
        GstStructure *structure = gst_caps_get_structure(caps, 0);
        gst_structure_get_int(structure, "width", &width);
        gst_structure_get_int(structure, "height", &height);
        gst_caps_unref(caps);
    }
    gst_object_unref(pad);
    BOOL ready = attached && rendered > 0;
    if (ready && startupMs < 0) startupMs = elapsedMs;
    emit(@{@"event": @"sample", @"engine": @"gstreamer", @"elapsedMs": @(elapsedMs), @"generation": @1,
        @"sampleWallTime": @(NSDate.date.timeIntervalSince1970),
        @"lastFrameStreamTime": GST_CLOCK_TIME_IS_VALID(lastFrameStreamTime) ? @(lastFrameStreamTime / (double)GST_SECOND) : [NSNull null],
        @"time": @(MAX(0, position) / (double)GST_SECOND), @"cache": @(cacheVideo / (double)GST_SECOND),
        @"audioCache": @(cacheAudio / (double)GST_SECOND), @"rendered": @(ready), @"loading": @(!ready),
        @"playing": @(state == GST_STATE_PLAYING), @"buffering": @(bufferingPercent < 100),
        @"frameDrops": @(dropped), @"decoderDrops": @0, @"mistimed": @0, @"delayed": @0,
        @"renderedFrames": @(rendered), @"audioRenderedBuffers": @(audioRendered),
        @"dropMetricsAvailable": @YES, @"width": @(width), @"height": @(height),
        @"startupMs": @(startupMs), @"audioOutput": audioRendered > 0 ? @"osxaudiosink" : @"unavailable",
        @"audioChannels": @(audioChannels),
        @"diagnosticWindowKey": @(window.isKeyWindow), @"diagnosticWindowMain": @(window.isMainWindow),
        @"diagnosticAppActive": @(NSApp.isActive),
        @"avSyncSeconds": [NSNull null], @"elements": [[elements allObjects] sortedArrayUsingSelector:@selector(compare:)],
        @"hwdec": [elements containsObject:@"vtdec_hw"] ? @"videotoolbox-hardware" : @"unverified",
        @"error": lastError ?: @""});
    if (elapsedMs >= seconds * 1000) {
        emit(@{@"event": @"end", @"elapsedMs": @(elapsedMs)});
        [timer invalidate];
        gst_element_set_state(pipeline, GST_STATE_NULL);
        gst_object_unref(bus);
        gst_object_unref(pipeline);
        gst_object_unref(videoSink);
        gst_object_unref(audioSink);
        if (adaptive) gst_object_unref(adaptive);
        [NSApp terminate:nil];
    }
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        if ([NSProcessInfo.processInfo.arguments containsObject:@"--gst-audio-preflight"]) {
            int outputs = 0, mapped = 0;
            return validateAudioLayout(&outputs, &mapped, YES) ? 0 : 1;
        }
        NSApplication *application = NSApplication.sharedApplication;
        GSTProbe *probe = [GSTProbe new];
        [application setActivationPolicy:NSApplicationActivationPolicyAccessory];
        application.delegate = probe;
        [application run];
    }
    return 0;
}

#ifndef AMF_Factory_h
#define AMF_Factory_h
// Stub: MPVKit's Libavutil module references AMD's AMF SDK (Windows GPU
// encoders) via `hwcontext_amf.h`. macOS has no AMF, but the Clang module
// umbrella tries to build every header and fails without these. We stub
// the three type names referenced so the module can build.
typedef void AMFFactory;
typedef void AMFContext;
typedef int  AMF_MEMORY_TYPE;
#endif

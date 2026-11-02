#!/usr/bin/env python3
"""Bounded, local-only bundled-libmpv timestamp/seek experiment.

Reuses five existing H.264/AAC MPEG-TS segments. It changes only MPEG-TS
PTS/DTS/PCR fields, with no encoding, network, saved sources, or UI. Null
audio/video output does not qualify rendered playback performance.
"""
import argparse
import ctypes as c
import hashlib
import json
from pathlib import Path
import time

MOD=1<<33

def decode_pts(b):
    return ((b[0]>>1)&7)<<30 | b[1]<<22 | (b[2]>>1)<<15 | b[3]<<7 | b[4]>>1

def encode_pts(old, n):
    n %= MOD
    return bytes([(old[0]&0xf0)|((n>>29)&14)|1,(n>>22)&255,((n>>14)&254)|1,(n>>7)&255,((n<<1)&254)|1])

def shift_ts(data, seconds):
    out=bytearray(data)
    delta=round(seconds*90000)
    assert len(out)%188==0
    for i in range(0,len(out),188):
        assert out[i]==0x47
        mode=(out[i+3]>>4)&3
        if mode==0: continue
        pos=i+4
        if mode&2:
            size=out[pos]
            if size>=7 and out[pos+1]&0x10:
                p=pos+2
                b=out[p:p+6]
                base=(b[0]<<25)|(b[1]<<17)|(b[2]<<9)|(b[3]<<1)|(b[4]>>7)
                base=(base+delta)%MOD
                out[p:p+6]=bytes([(base>>25)&255,(base>>17)&255,(base>>9)&255,(base>>1)&255,((base&1)<<7)|(b[4]&127),b[5]])
            pos+=size+1
        if not mode&1 or not out[i+1]&0x40 or pos+14>i+188: continue
        if out[pos:pos+3]!=b'\0\0\1': continue
        flags=out[pos+7]>>6
        if flags&2:
            p=pos+9;out[p:p+5]=encode_pts(out[p:p+5],decode_pts(out[p:p+5])+delta)
        if flags==3:
            p=pos+14;out[p:p+5]=encode_pts(out[p:p+5],decode_pts(out[p:p+5])+delta)
    return bytes(out)

class Event(c.Structure):
    _fields_=[('event_id',c.c_int),('error',c.c_int),('reply_userdata',c.c_uint64),('data',c.c_void_p)]
class Log(c.Structure):
    _fields_=[('prefix',c.c_char_p),('level',c.c_char_p),('text',c.c_char_p),('log_level',c.c_int)]
def load_api(app):
    c.CDLL(str(app/'Contents/Frameworks/Sparkle.framework/Sparkle'))
    lib=c.CDLL(str(app/'Contents/MacOS/Buffer.debug.dylib'))
    lib.mpv_create.restype=c.c_void_p
    lib.mpv_initialize.argtypes=[c.c_void_p]
    lib.mpv_set_option_string.argtypes=[c.c_void_p,c.c_char_p,c.c_char_p]
    lib.mpv_set_property_string.argtypes=[c.c_void_p,c.c_char_p,c.c_char_p]
    lib.mpv_get_property.argtypes=[c.c_void_p,c.c_char_p,c.c_int,c.c_void_p]
    lib.mpv_get_property_string.argtypes=[c.c_void_p,c.c_char_p]
    lib.mpv_get_property_string.restype=c.c_void_p
    lib.mpv_free.argtypes=[c.c_void_p]
    lib.mpv_command.argtypes=[c.c_void_p,c.POINTER(c.c_char_p)]
    lib.mpv_wait_event.argtypes=[c.c_void_p,c.c_double]
    lib.mpv_wait_event.restype=c.POINTER(Event)
    lib.mpv_terminate_destroy.argtypes=[c.c_void_p]
    lib.mpv_request_log_messages.argtypes=[c.c_void_p,c.c_char_p]
    return lib

def get_double(lib,h,name):
    v=c.c_double()
    return v.value if lib.mpv_get_property(h,name.encode(),5,c.byref(v))>=0 else None

def get_string(lib,h,name):
    p=lib.mpv_get_property_string(h,name.encode())
    if not p: return None
    try: return c.string_at(p).decode()
    finally: lib.mpv_free(p)

def run(lib,fixture,options):
    h=lib.mpv_create()
    records=[]; logs=[]; events=[]; loaded=False; end=False
    try:
        base={'config':'no','vo':'null','ao':'null','idle':'yes','pause':'yes','terminal':'no','load-scripts':'no','ytdl':'no','hwdec':'no','video-sync':'audio','cache':'yes','cache-pause':'no','demuxer-readahead-secs':'15','speed':'8','demuxer-lavf-probesize':'2097152','demuxer-lavf-analyzeduration':'5'}
        for k,v in (base|options).items():
            ret=lib.mpv_set_option_string(h,k.encode(),v.encode())
            assert ret>=0,(k,v,ret)
        lib.mpv_request_log_messages(h,b'warn')
        assert lib.mpv_initialize(h)>=0
        assert lib.mpv_command(h,(c.c_char_p*4)(b'loadfile',str(fixture).encode(),b'replace',None))>=0
        start=time.monotonic();deadline=start+6
        last=0
        while time.monotonic()<deadline:
            e=lib.mpv_wait_event(h,0.01).contents
            if e.event_id==2:
                log=c.cast(e.data,c.POINTER(Log)).contents
                if len(logs)<100: logs.append({'prefix':log.prefix.decode(),'text':log.text.decode().strip()})
            if e.event_id==8:
                loaded=True
                events.append({'event':'loaded'})
                lib.mpv_set_property_string(h,b'pause',b'no')
            if e.event_id==6:
                events.append({'event':'start','playlistEntryID':c.cast(e.data,c.POINTER(c.c_int64)).contents.value})
            if e.event_id==7:
                end=True
                events.append({'event':'end'})
            now=time.monotonic()
            if now-last>.025:
                last=now
                records.append({'elapsed':now-start,**{p:get_double(lib,h,p) for p in ['time-pos','duration','demuxer-cache-duration','avsync']}})
            if end: break
        return {'fixture':fixture.name,'fixtureSHA256':hashlib.sha256(fixture.read_bytes()).hexdigest(),'options':options,'loaded':loaded,'ended':end,'maxDuration':max((r['duration'] or 0 for r in records),default=0),'maxCache':max((r['demuxer-cache-duration'] or 0 for r in records),default=0),'maxTime':max((r['time-pos'] or 0 for r in records),default=0),'logs':logs,'samples':records,'events':events,'mpvVersion':get_string(lib,h,'mpv-version'),'ffmpegVersion':get_string(lib,h,'ffmpeg-version')}
    finally:
        lib.mpv_terminate_destroy(h)

def seek_probe(lib,fixture,cache):
    h=lib.mpv_create(); logs=[]; results=[]
    try:
        opts={'config':'no','vo':'null','ao':'null','idle':'yes','pause':'yes','terminal':'no','load-scripts':'no','ytdl':'no','hwdec':'no','cache':cache,'cache-pause':'no','demuxer-readahead-secs':'15','demuxer-lavf-probesize':'2097152','demuxer-lavf-analyzeduration':'5','demuxer-lavf-o':'fflags=+discardcorrupt+genpts+igndts,correct_ts_overflow=0','demuxer-lavf-linearize-timestamps':'yes'}
        for k,v in opts.items():
            assert lib.mpv_set_option_string(h,k.encode(),v.encode())>=0
        lib.mpv_request_log_messages(h,b'warn')
        assert lib.mpv_initialize(h)>=0
        assert lib.mpv_command(h,(c.c_char_p*4)(b'loadfile',str(fixture).encode(),b'replace',None))>=0
        deadline=time.monotonic()+3;loaded=False
        def drain(seconds):
            until=time.monotonic()+seconds
            while time.monotonic()<until:
                e=lib.mpv_wait_event(h,0.01).contents
                if e.event_id==2:
                    log=c.cast(e.data,c.POINTER(Log)).contents
                    if len(logs)<100: logs.append(log.text.decode().strip())
        while time.monotonic()<deadline:
            e=lib.mpv_wait_event(h,0.01).contents
            if e.event_id==8: loaded=True;break
        drain(.5)
        # All targets belong to a ten-second clip. cache=no deliberately
        # forces low-level libavformat seeks, exposing linearization hazards.
        for target in [8,2,7]:
            ret=lib.mpv_command(h,(c.c_char_p*5)(b'seek',str(target).encode(),b'absolute',b'exact',None))
            drain(.5)
            results.append({'target':target,'returnCode':ret,**{x:get_double(lib,h,x) for x in ['time-pos','duration','demuxer-cache-duration']}})
        return {'fixture':fixture.name,'cache':cache,'loaded':loaded,'seeks':results,'logs':logs}
    finally: lib.mpv_terminate_destroy(h)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app',type=Path,required=True)
    parser.add_argument('--fixture-dir',type=Path,required=True)
    parser.add_argument('--output-dir',type=Path,required=True)
    args=parser.parse_args()
    out=args.output_dir.resolve();out.mkdir(parents=True,exist_ok=True)
    lib=load_api(args.app.resolve())
    segments=[(args.fixture_dir/f'segment-{n:03}.ts').read_bytes() for n in range(5)]
    fixture_defs={
        'continuous':[(s,500) for s in segments],
        'reset-367s':[(s,500 if i<3 else 132.92) for i,s in enumerate(segments)],
        'true-wrap':[(s,95439) for s in segments],
        'forward-367s':[(s,500 if i<3 else 867.08) for i,s in enumerate(segments)],
    }
    profiles={
        'current':{'demuxer-lavf-o':'fflags=+discardcorrupt+genpts+igndts'},
        'discard-only':{'demuxer-lavf-o':'fflags=+discardcorrupt'},
        'current-no-overflow':{'demuxer-lavf-o':'fflags=+discardcorrupt+genpts+igndts,correct_ts_overflow=0'},
        'current-linearize':{'demuxer-lavf-o':'fflags=+discardcorrupt+genpts+igndts','demuxer-lavf-linearize-timestamps':'yes'},
        'current-no-overflow-linearize':{'demuxer-lavf-o':'fflags=+discardcorrupt+genpts+igndts,correct_ts_overflow=0','demuxer-lavf-linearize-timestamps':'yes'},
        'discard-no-overflow-linearize':{'demuxer-lavf-o':'fflags=+discardcorrupt,correct_ts_overflow=0','demuxer-lavf-linearize-timestamps':'yes'},
    }
    reports=[]
    for name,parts in fixture_defs.items():
        fixture=out/f'{name}.ts';fixture.write_bytes(b''.join(shift_ts(s,shift) for s,shift in parts))
        for profile,opts in profiles.items():
            r=run(lib,fixture,opts);r['profile']=profile;reports.append(r)
            print(json.dumps({k:r[k] for k in ['fixture','profile','loaded','ended','maxDuration','maxCache','maxTime']}),flush=True)
    seeks=[seek_probe(lib,out/name,cache) for name in ['continuous.ts','reset-367s.ts','true-wrap.ts'] for cache in ['yes','no']]
    binary=args.app/'Contents/MacOS/Buffer.debug.dylib'
    report={'scope':'local headless demux/decode timing; no rendered performance or physical audio claim','binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest(),'cases':reports,'seekCases':seeks}
    (out/'report.json').write_text(json.dumps(report,indent=2))

if __name__=='__main__': main()

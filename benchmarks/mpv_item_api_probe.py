#!/usr/bin/env python3
"""Verify bundled libmpv item identity without running the Swift app entry.

Loads exported C symbols from Buffer.debug.dylib, opens only an explicit local
fixture, and disables audio/video output, scripts and configuration. No UI,
saved sources or provider connections are used. This is API evidence, not a
rendered-playback performance measurement.
"""
import argparse
import ctypes as c
import json
from pathlib import Path
import time


class NodeValue(c.Union):
    _fields_ = [('int64', c.c_int64), ('pointer', c.c_void_p)]


class Node(c.Structure):
    _fields_ = [('u', NodeValue), ('format', c.c_int)]


class NodeList(c.Structure):
    _fields_ = [('num', c.c_int), ('values', c.POINTER(Node)), ('keys', c.POINTER(c.c_char_p))]


class Event(c.Structure):
    _fields_ = [('event_id', c.c_int), ('error', c.c_int), ('reply_userdata', c.c_uint64), ('data', c.c_void_p)]


class EndFile(c.Structure):
    _fields_ = [('reason', c.c_int), ('error', c.c_int), ('entry', c.c_int64),
                ('insert_id', c.c_int64), ('insert_count', c.c_int)]


def run(app: Path, fixture: Path):
    if not fixture.is_file():
        raise ValueError('an existing local media fixture is required')
    c.CDLL(str(app / 'Contents/Frameworks/Sparkle.framework/Sparkle'))
    lib = c.CDLL(str(app / 'Contents/MacOS/Buffer.debug.dylib'))
    lib.mpv_create.restype = c.c_void_p
    lib.mpv_initialize.argtypes = [c.c_void_p]
    lib.mpv_set_option_string.argtypes = [c.c_void_p, c.c_char_p, c.c_char_p]
    lib.mpv_command_async.argtypes = [c.c_void_p, c.c_uint64, c.POINTER(c.c_char_p)]
    lib.mpv_wait_event.argtypes = [c.c_void_p, c.c_double]
    lib.mpv_wait_event.restype = c.POINTER(Event)
    lib.mpv_terminate_destroy.argtypes = [c.c_void_p]
    handle = lib.mpv_create()
    if not handle:
        raise RuntimeError('mpv_create failed')
    try:
        for name, value in [('config', 'no'), ('vo', 'null'), ('ao', 'null'),
                            ('idle', 'yes'), ('pause', 'yes'), ('terminal', 'no'),
                            ('load-scripts', 'no'), ('ytdl', 'no')]:
            if lib.mpv_set_option_string(handle, name.encode(), value.encode()) < 0:
                raise RuntimeError(f'option rejected: {name}')
        if lib.mpv_initialize(handle) < 0:
            raise RuntimeError('mpv_initialize failed')
        args = (c.c_char_p * 4)(b'loadfile', str(fixture).encode(), b'replace', None)
        if lib.mpv_command_async(handle, 11, args) < 0:
            raise RuntimeError('first local load rejected')
        # Deliberately leave A events undrained while its local file opens.
        # The old Swift handler would read desired-generation B for these.
        time.sleep(0.4)
        if lib.mpv_command_async(handle, 22, args) < 0:
            raise RuntimeError('second local load rejected')
        records, reply_entries, loaded_entries = [], {}, []
        started_entry = None
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            event = lib.mpv_wait_event(handle, 0.05).contents
            if event.event_id == 5:  # COMMAND_REPLY
                node = c.cast(event.data, c.POINTER(Node)).contents
                assert event.error >= 0 and node.format == 8, 'loadfile must return NODE_MAP'
                entries = c.cast(node.u.pointer, c.POINTER(NodeList)).contents
                values = {entries.keys[i].decode(): entries.values[i] for i in range(entries.num)}
                assert values['playlist_entry_id'].format == 4, 'entry ID must be INT64'
                entry = values['playlist_entry_id'].u.int64
                reply_entries[event.reply_userdata] = entry
                records.append({'event': 'reply', 'request': event.reply_userdata, 'entry': entry})
            elif event.event_id == 6:  # START_FILE
                started_entry = c.cast(event.data, c.POINTER(c.c_int64)).contents.value
                records.append({'event': 'start', 'entry': started_entry})
            elif event.event_id == 8:  # FILE_LOADED has no data
                assert not event.data, 'FILE_LOADED is paired through START_FILE'
                loaded_entries.append(started_entry)
                records.append({'event': 'loaded', 'entry': started_entry})
            elif event.event_id == 7:
                end = c.cast(event.data, c.POINTER(EndFile)).contents
                records.append({'event': 'end', 'entry': end.entry, 'reason': end.reason})
            if 22 in reply_entries and reply_entries[22] in loaded_entries:
                break
        assert set(reply_entries) == {11, 22}, 'both command reply identities are required'
        assert reply_entries[11] != reply_entries[22], 'new loads must have distinct entry IDs'
        assert reply_entries[11] in loaded_entries, 'fixture must contain queued A FILE_LOADED'
        assert reply_entries[22] in loaded_entries, 'replacement B must load'
        report = {'passed': True, 'scope': 'bundled C API and queued item events; no renderer',
                  'queuedOldLoadedEvents': loaded_entries.count(reply_entries[11]), 'events': records}
        print(json.dumps(report, sort_keys=True))
    finally:
        lib.mpv_terminate_destroy(handle)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--fixture', required=True, type=Path)
    args = parser.parse_args()
    run(args.app.resolve(), args.fixture.resolve())

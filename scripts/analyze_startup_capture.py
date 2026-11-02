#!/usr/bin/env python3
"""Offline startup/motion annotations; original qualification gates stay intact."""
import argparse
import json
import math
from pathlib import Path


def finite(value):
    return type(value) in (int, float) and math.isfinite(value)


def ready(sample):
    return sample.get('rendered') is True and sample.get('width', 0) > 0 and sample.get('height', 0) > 0


def clock(sample):
    value, age = sample.get('rawTimePos'), sample.get('rawTimePosAgeMs')
    if finite(value) and finite(age) and 0 <= age <= 2500:
        return value, 'fresh observed raw time-pos'
    return sample.get('time'), 'UI time-pos; quantized/coalesced'


def interval(a, b):
    dt = (b['elapsedMs'] - a['elapsedMs']) / 1000
    va, ba = clock(a)
    vb, bb = clock(b)
    valid = finite(dt) and dt > 0 and finite(va) and finite(vb)
    advance = vb - va if valid else None
    same_generation = a.get('generation') == b.get('generation')
    frames = b.get('renderedFrameCount', 0) - a.get('renderedFrameCount', 0)
    jump = valid and same_generation and ready(a) and ready(b) and (
        advance > dt + max(.25, dt * .25) or advance < -max(.25, dt * .25))
    requested = a.get('playbackRequested') is True and b.get('playbackRequested') is True
    paused = any(s.get(field) is True for s in (a, b)
                 for field in ('pause', 'pausedForCache', 'startupHoldActive'))
    visible = a.get('windowVisible') is True and b.get('windowVisible') is True
    motion = (valid and same_generation and requested and ready(a) and ready(b)
              and visible and not paused and not jump and advance >= .05 and frames > 0)
    return dict(startMs=a['elapsedMs'], endMs=b['elapsedMs'], duration=dt, advance=advance,
                frames=frames, generation=b.get('generation'), jump=bool(jump), motion=bool(motion),
                requested=requested, sameGeneration=same_generation, paused=paused,
                readyStart=ready(a), readyEnd=ready(b), clockBasis=ba if ba == bb else 'mixed clock basis')


def analyze_samples(samples):
    pairs = [interval(a, b) for a, b in zip(samples, samples[1:])]
    picture = next((s for s in samples if ready(s)), None)
    exact_picture = [s['startupMs'] for s in samples if ready(s) and finite(s.get('startupMs'))]
    sustained = next((i for i in range(len(pairs) - 1)
                      if pairs[i]['motion'] and pairs[i + 1]['motion']
                      and pairs[i]['generation'] == pairs[i + 1]['generation']), None)
    motion_start = pairs[sustained]['startMs'] if sustained is not None else None
    motion_upper = pairs[sustained]['endMs'] if sustained is not None else None
    post = [p for p in pairs if motion_start is not None and p['startMs'] >= motion_start
            and p['requested'] and p['duration'] > 0]
    disruptions = [p for p in post if not p['readyStart'] or (p['sameGeneration'] and not p['jump']
                    and (p['advance'] < .05 or p['frames'] <= 0))]
    discontinuities = []
    for i, pair in enumerate(pairs):
        if not pair['jump']:
            continue
        neighboring = []
        for radius in (1, 2, 3):
            a, b = samples[max(0, i - radius)], samples[min(len(samples) - 1, i + 1 + radius)]
            va, ba = clock(a)
            vb, bb = clock(b)
            neighboring.append(dict(wallSeconds=(b['elapsedMs'] - a['elapsedMs']) / 1000,
                clockSeconds=vb - va if finite(va) and finite(vb) else None,
                renderedFrames=b.get('renderedFrameCount', 0) - a.get('renderedFrameCount', 0),
                sameGeneration=a.get('generation') == b.get('generation'),
                clockBasis=ba if ba == bb else 'mixed clock basis'))
        discontinuities.append(dict(startMs=pair['startMs'], endMs=pair['endMs'],
            wallSeconds=pair['duration'], clockSeconds=pair['advance'], renderedFrames=pair['frames'],
            nextClockAdvance=pairs[i + 1]['advance'] if i + 1 < len(pairs) else None,
            clockBasis=pair['clockBasis'], neighboringWindows=neighboring))
    held = sum(p['duration'] for p in pairs if p['duration'] > 0 and p['requested'] and p['readyStart']
               and not p['motion'] and (motion_start is None or p['startMs'] < motion_start))
    flags = {key: sorted({s.get(key) for s in samples if type(s.get(key)) is bool})
             for key in ('startupReserveEnabled', 'startupTargetEnabled', 'nativeCacheOnlyEnabled')}
    return dict(samples=len(samples), firstPictureMs=min(exact_picture) if exact_picture else
                picture['elapsedMs'] if picture else None,
                firstMotionLowerMs=motion_start, firstMotionUpperMs=motion_upper,
                sustainedMotionConfirmedMs=pairs[sustained + 1]['endMs'] if sustained is not None else None,
                initialHeldPictureSeconds=held,
                postMotionObservedSeconds=sum(p['duration'] for p in post),
                postMotionSampledInterruptionSeconds=sum(p['duration'] for p in disruptions),
                postMotionClockNonprogressSeconds=sum(p['duration'] for p in post if p['sameGeneration']
                    and not p['jump'] and p['readyStart'] and p['advance'] < .05),
                postMotionRendererNonprogressSeconds=sum(p['duration'] for p in post if p['sameGeneration']
                    and p['readyStart'] and p['frames'] <= 0),
                postMotionSimultaneousClockFrameFreezeSeconds=sum(p['duration'] for p in post if p['sameGeneration']
                    and not p['jump'] and p['readyStart'] and p['advance'] < .05 and p['frames'] <= 0),
                postMotionReadinessLostSeconds=sum(p['duration'] for p in post if not p['readyStart']),
                discontinuities=discontinuities, flags=flags,
                maximumAppFloorPauses=max((s.get('cacheFloorPauses', 0) for s in samples), default=0),
                pauseEvidenceComplete=all(type(s.get('pause')) is bool and type(s.get('pausedForCache')) is bool
                                          for s in samples if ready(s)),
                measurementLimitations=[
                    'Annotations do not alter original report pass/fail or establish sustained qualification.',
                    'Moving startup is bracketed by samples and requires two consecutive clock/frame intervals.',
                    'UI time-pos can alias at 4Hz with its 0.25s publishing threshold; raw clock ages remain relevant.',
                    'Initial held pictures are reported separately, not silently removed from user-perceived startup.',
                    'Process CPU/memory includes library, guide, UI and decoder work; compare concurrent workloads separately.'])


def analyze_folder(folder):
    report = json.loads((folder / 'report.json').read_text())
    event_file = folder / 'events.jsonl'
    events = ([json.loads(line) for line in event_file.read_text().splitlines()] if event_file.exists()
              else report.get('events', []))
    samples = [e for e in events if e.get('event') == 'sample']
    cases = sorted({e.get('case', 0) for e in samples})
    result = []
    for case in cases:
        original = next((r for i, r in enumerate(report.get('cases', [])) if i == case), report)
        result.append(dict(case=case, originalPassed=original.get('passed'),
            originalFailures=original.get('failures'),
            **analyze_samples([s for s in samples if s.get('case', 0) == case])))
    return dict(folder=folder.name, artifactSHA256=report.get('binarySHA256'),
                annotationOnly=True, cases=result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folders', type=Path, nargs='+')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    result = [analyze_folder(folder) for folder in args.folders]
    text = json.dumps(result, indent=2) + '\n'
    if args.output:
        args.output.write_text(text)
    print(text, end='')


if __name__ == '__main__':
    main()

"""Motion-compensated flicker detector for a recorded EPG scroll.

For each consecutive pair of frames, estimate the vertical scroll shift from
the channel-logo column, align the frames, and measure the residual in each
horizontal region. Pure scrolling leaves ~0 residual; a row that flashes empty,
stale content, or labels drawn a frame late leave a residual spike.

Usage: python3 scripts/flicker-analyze.py <video> [--from SECONDS] [--to SECONDS]
"""
import argparse, subprocess, sys
import numpy as np

ap = argparse.ArgumentParser()
ap.add_argument("video")
ap.add_argument("--width", type=int, default=660)
ap.add_argument("--from", dest="start", type=float, default=0)
ap.add_argument("--to", dest="end", type=float, default=None)
args = ap.parse_args()

probe = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                        "stream=width,height", "-of", "csv=p=0", args.video], capture_output=True, text=True, check=True)
w0, h0 = map(int, probe.stdout.strip().split(","))
w = args.width
h = int(h0 * w / w0) // 2 * 2
cmd = ["ffmpeg", "-loglevel", "error", "-ss", str(args.start)]
if args.end is not None:
    cmd += ["-to", str(args.end)]
cmd += ["-i", args.video, "-vf", f"scale={w}:{h},format=gray", "-f", "rawvideo", "-"]
raw = subprocess.run(cmd, capture_output=True, check=True).stdout
frames = np.frombuffer(raw, np.uint8).reshape(-1, h, w).astype(np.int16)

# Layout fractions of the window (sidebar | logo column | programme grid).
top = int(h * 0.09)                      # below toolbar + time header
logo = (int(w * 0.135), int(w * 0.20))   # channel logo column
label = (int(w * 0.20), int(w * 0.45))   # pinned channel/time labels + first blocks
grid = (int(w * 0.45), w - 8)            # rest of the programme grid

def shift(a, b, region, search=90):
    """Vertical content shift from a to b estimated within one region."""
    x0, x1 = region
    ca, cb = a[top:, x0:x1], b[top:, x0:x1]
    n = ca.shape[0]
    best, best_dy = None, 0
    for dy in range(-search, search + 1):
        if dy >= 0:
            d = np.abs(ca[dy:] - cb[:n - dy]).mean()
        else:
            d = np.abs(ca[:n + dy] - cb[-dy:]).mean()
        if best is None or d < best:
            best, best_dy = d, dy
    return best_dy, float(best)

regions = (("logo", logo), ("label", label), ("grid", grid))
moving = 0
series = []
for i in range(len(frames) - 1):
    a, b = frames[i], frames[i + 1]
    if np.abs(a - b).mean() < 0.05:
        continue  # identical frame (capture duplicate or idle)
    moving += 1
    est = {name: shift(a, b, reg) for name, reg in regions}
    series.append((i, est))

def disagreement(est, x, y):
    return abs(est[x][0] - est[y][0])

print(f"frames={len(frames)} changingPairs={moving}")
for x, y in (("logo", "grid"), ("label", "grid"), ("logo", "label")):
    values = [disagreement(e, x, y) for _, e in series] or [0]
    bad = sum(v >= 2 for v in values)
    print(f"{x}-vs-{y}: pairs with >=2px drift={bad}/{len(values)} ({100 * bad / max(1, len(values)):.1f}%) max={max(values)}px")
for name in ("logo", "label", "grid"):
    errs = [e[name][1] for _, e in series] or [0]
    print(f"{name:5s} aligned-residual mean={np.mean(errs):.2f} p95={np.percentile(errs, 95):.2f} max={np.max(errs):.2f}")
worst = sorted(series, key=lambda s: -max(disagreement(s[1], "logo", "grid"), disagreement(s[1], "label", "grid")))[:8]
print("worst drift pairs (frame: logo/label/grid dy):")
for i, e in worst:
    print(f"  {i:5d} " + " ".join(f"{k}={e[k][0]:+d}" for k in ("logo", "label", "grid")))

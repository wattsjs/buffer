#!/usr/bin/env python3
"""Compare real AppKit EPG scrolling and the production header cache locally."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BASE_REF = "c0db442fa80bf058e69f927c50858cfdb559566b"
BASE_PATCH = ROOT / "benchmarks/results/epg-grid-baseline.patch"


def run(args, **kwargs):
    result = subprocess.run(args, text=True, capture_output=True, check=True, **kwargs)
    return result.stdout


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def sample_median(samples):
    if len(samples) != 7 or any(not isinstance(x, (int, float)) or not math.isfinite(x) or x <= 0 for x in samples):
        raise ValueError("Expected seven finite, positive timing samples")
    return statistics.median(samples)


def verify_scroll(before, after):
    fixture = "epg-appkit-horizontal-100x-672-blocks-v1"
    for report in (before, after):
        if report["fixture"] != fixture or report["rows"] != 1000:
            raise ValueError("Incompatible scroll fixture")
        if report["visible_rows"] <= 0 or report["overlay_entries"] < report["visible_rows"]:
            raise ValueError("Missing visible table/overlay evidence")
        if len(report["provider_calls"]) != 7:
            raise ValueError("Missing provider-call samples")
        sample_median(report["samples_ms"])
    if before["visible_rows"] != after["visible_rows"] or before["overlay_entries"] != after["overlay_entries"]:
        raise ValueError("Before/after viewport or overlay output differs")
    if any(x != 0 for x in after["provider_calls"]):
        raise ValueError("Horizontal scrolling rebuilt cached row metadata")


def baseline_source():
    # Reconstruct the initial uncommitted grid on its immutable Git base.
    # Apply the retained patch inside a temporary tree, never the workspace.
    source = run(["git", "show", f"{BASE_REF}:Buffer/Views/EPGScrollGrid.swift"], cwd=ROOT)
    with tempfile.TemporaryDirectory(prefix="epg-grid-baseline-") as directory:
        path = Path(directory) / "Buffer/Support/PerfMetrics.swift", "Buffer/Support/AppLog.swift", "Buffer/Views/EPGScrollGrid.swift"
        path.parent.mkdir(parents=True)
        path.write_text(source)
        subprocess.run(["patch", "--batch", "--silent", "-p1"], input=BASE_PATCH.read_text(),
                       text=True, cwd=directory, capture_output=True, check=True)
        return path.read_text()


def expose_probe_entrypoints(source):
    """Expose existing lifecycle bodies; their order and logic stay identical."""
    source = source.replace(
        "    func makeNSView(context: Context) -> EPGContainerView {\n        let container = EPGContainerView()",
        "    func makeNSView(context: Context) -> EPGContainerView {\n"
        "        makeContainer(coordinator: context.coordinator)\n    }\n\n"
        "    func makeContainer(coordinator: Coordinator) -> EPGContainerView {\n"
        "        let container = EPGContainerView()", 1)
    start = source.index("    func makeContainer(")
    end = source.index("    func updateNSView(", start)
    source = source[:start] + source[start:end].replace("context.coordinator", "coordinator") + source[end:]
    return source.replace(
        "    func updateNSView(_ container: EPGContainerView, context: Context) {\n"
        "        let coordinator = context.coordinator",
        "    func updateNSView(_ container: EPGContainerView, context: Context) {\n"
        "        updateContainer(container, coordinator: context.coordinator)\n    }\n\n"
        "    func updateContainer(_ container: EPGContainerView, coordinator: Coordinator) {", 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="Additional saved JSON report")
    args = parser.parse_args()
    scratch = ROOT / ".local/bench"
    scratch.mkdir(parents=True, exist_ok=True)
    before_source = scratch / "epg-grid-baseline-source.swift"
    original_source = baseline_source()
    before_source.write_text(expose_probe_entrypoints(original_source))
    shared = [ROOT / "Buffer/Models/SourceChannelIdentity.swift", ROOT / "Buffer/Models/Channel.swift", ROOT / "Buffer/Models/EPGProgram.swift",
              ROOT / "Buffer/Support/EPGTimelineInputs.swift", ROOT / "Buffer/Support/EPGTimeStripCache.swift",
              ROOT / "Buffer/Support/EPGGridStyle.swift"]
    harness = ROOT / "benchmarks/epg_grid_tests.swift"
    current_source = ROOT / "Buffer/Views/EPGScrollGrid.swift"
    executables = {}
    results = {}
    for label, source, flags in (("before", before_source, ["-DGRID_BASELINE"]), ("after", current_source, [])):
        executable = scratch / f"epg-grid-{label}-bench"
        run(["swiftc", *flags, *map(str, shared), str(source), str(harness), "-o", str(executable)], cwd=ROOT)
        executables[label] = executable
        arguments = [str(executable), "--benchmark"] + (["--headers"] if label == "after" else [])
        lines = run(arguments, cwd=ROOT).splitlines()
        results[label] = json.loads(lines[0])
        if label == "after":
            results["headers"] = json.loads(lines[1])
    verify_scroll(results["before"], results["after"])
    headers = results["headers"]
    if headers["fixture"] != "epg-header-100-ticks-694-labels-v1" or headers["titles"] != 694 or headers["ticks"] != 100:
        raise ValueError("Incompatible header fixture")
    medians = {
        "scroll_before_ms": sample_median(results["before"]["samples_ms"]),
        "scroll_after_ms": sample_median(results["after"]["samples_ms"]),
        "headers_previous_ms": sample_median(headers["previous_samples_ms"]),
        "headers_cached_ms": sample_median(headers["cached_samples_ms"]),
    }
    if medians["scroll_after_ms"] > medians["scroll_before_ms"] * 1.15 or medians["headers_cached_ms"] > medians["headers_previous_ms"] * 1.15:
        raise ValueError("EPG benchmark median regressed beyond 15%")
    now = datetime.now(timezone.utc)
    report = {
        "schema": 1, "timestamp_utc": now.isoformat(), "platform": platform.platform(),
        "architecture": platform.machine(), "swift": run(["swiftc", "--version"]).strip(),
        "configuration": "standalone swiftc default -Onone; same compiler and harness before/after",
        "baseline_git_ref": BASE_REF, "baseline_patch_sha256": digest(BASE_PATCH),
        "baseline_source_sha256": hashlib.sha256(original_source.encode()).hexdigest(),
        "baseline_probe_source_sha256": digest(before_source),
        "source_sha256": {str(path.relative_to(ROOT)): digest(path) for path in [current_source, harness, *shared]},
        "executable_sha256": {label: digest(path) for label, path in executables.items()},
        "results": results, "medians": medians,
        "limitations": ["Hidden standalone AppKit window with synthetic row metadata; no provider, decoder or full app measured",
                        "Scroll fixture drives 100 real NSClipView bounds changes after warm-up; no manual metadata callbacks",
                        "Header baseline reproduces previous formatting body; all titles/positions are checked for equivalence",
                        "Baseline grid lifecycle bodies have only probe entrypoint wrappers added"],
    }
    logs = ROOT / ".logs"
    logs.mkdir(exist_ok=True)
    outputs = [logs / "epg-grid-latest.json", logs / f"epg-grid-{now.strftime('%Y%m%dT%H%M%SZ')}.json"]
    if args.output:
        outputs.append(args.output.resolve())
    for path in outputs:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"medians": medians, "report": str(outputs[0]), "verdict": "PASS"}, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (subprocess.CalledProcessError, ValueError, KeyError, IndexError, json.JSONDecodeError) as error:
        raise SystemExit(f"EPG benchmark failed: {error}")

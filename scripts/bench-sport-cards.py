#!/usr/bin/env python3
"""Compare production sports-card identity checks, without app/provider access."""
import argparse
import datetime
import hashlib
import json
import pathlib
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCES = ["Buffer/Models/SourceChannelIdentity.swift", "Buffer/Models/Channel.swift", "Buffer/Models/EPGProgram.swift", "Buffer/Models/SportEvent.swift",
           "Buffer/Support/PerfMetrics.swift", "Buffer/Support/AppLog.swift", "Buffer/Services/StreamMatcher.swift", "Buffer/Support/SportEventMatchState.swift",
           "benchmarks/sport_card_context_benchmark.swift"]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(source, mode):
    executable = ROOT / f".local/bench/sport-card-context-{mode}"
    executable.parent.mkdir(parents=True, exist_ok=True)
    sources = [str(source) if name == "Buffer/Support/SportEventMatchState.swift" else name for name in SOURCES]
    command = ["swiftc", "-O", *sources, "-o", str(executable)]
    if mode == "before":
        command.extend(["-D", "DICTIONARY_CONTEXT"])
    subprocess.run(command, cwd=ROOT, check=True, timeout=90)
    result = json.loads(subprocess.check_output([str(executable)], cwd=ROOT, text=True, timeout=60))
    result.update(sourceSHA256=digest(source), executableSHA256=digest(executable))
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--before-source", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path, default=ROOT / ".logs/sport-card-context-latest.json")
    args = parser.parse_args()
    report = dict(schemaVersion=1, configuration="Standalone Swift -O production context equality",
                  recordedAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  sourceHashes={name: digest(ROOT / name) for name in SOURCES},
                  limitations="Context equality microbenchmark; not full-app CPU/RSS or a 28000-entry typical usage map. Production usage caps are 500 channels/100 groups; favorites can extend channel scores.")
    if args.before_source:
        source = args.before_source.resolve(strict=True)
        report["beforeSourcePath"] = str(source.relative_to(ROOT)) if source.is_relative_to(ROOT) else str(source)
        report["before"] = run(source, "before")
    report["after"] = run(ROOT / "Buffer/Support/SportEventMatchState.swift", "after")
    if "before" in report:
        old = {case["name"]: case for case in report["before"]["cases"]}
        for case in report["after"]["cases"]:
            baseline = old[case["name"]]
            if baseline["checksum"] != case["checksum"] or baseline["comparisons"] != case["comparisons"]:
                raise ValueError("Comparison semantics changed")
            case["medianReductionPercent"] = 100 * (1 - case["medianMs"] / baseline["medianMs"])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    for case in report["after"]["cases"]:
        reduction = case.get("medianReductionPercent")
        change = f" ({abs(reduction):.1f}% {'lower' if reduction >= 0 else 'higher'})" if reduction is not None else ""
        print(f"{case['name']}: {case['medianMs']:.3f}ms" + change)
    print(args.output)


if __name__ == "__main__":
    main()

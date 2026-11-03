import Foundation

/// Measures production functions with fixed fixtures. Compare separate builds;
/// these results do not pretend a no-op or a simulated sleep is an optimization.
enum PerformanceBenchmark {
    struct Measurement: Codable {
        let name: String
        let samplesMs: [Double]
        let checksum: Int
    }
    struct Report: Codable {
        let schema: Int
        let fixture: String
        let buildMetadata: BufferBuildConfiguration.Metadata
        let measurements: [Measurement]
    }

    static var shouldRun: Bool {
        // A wrong Release artifact must also answer metadata before saved
        // source bootstrap, allowing the harness to reject it safely.
        if CommandLine.arguments.contains("--build-metadata") { return true }
#if DEBUG
        return CommandLine.arguments.contains("--benchmark")
#else
        return false
#endif
    }

    static func runAndExit() -> Never {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let metadataOnly = CommandLine.arguments.contains("--build-metadata")
            let payload = metadataOnly ? try encoder.encode(BufferBuildConfiguration.metadata) : try encoder.encode(run())
            FileHandle.standardOutput.write(Data((metadataOnly ? BufferBuildConfiguration.outputPrefix : "BUFFER_BENCH_JSON ").utf8))
            FileHandle.standardOutput.write(payload)
            FileHandle.standardOutput.write(Data("\n".utf8))
            exit(0)
        } catch {
            fputs("Benchmark encoding failed\n", stderr)
            exit(1)
        }
    }

    private static func measure(_ name: String, expected: Int, _ operation: () -> Int) -> Measurement {
        // Warm-up and output validation prevent dead-code-eliminated timings.
        precondition(operation() == expected, "Incorrect output: \(name)")
        var samples: [Double] = []
        for _ in 0..<7 {
            let start = ContinuousClock.now
            let checksum = operation()
            let duration = start.duration(to: .now).components
            precondition(checksum == expected, "Unstable output: \(name)")
            samples.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
        }
        return Measurement(name: name, samplesMs: samples, checksum: expected)
    }

    static func run() -> Report {
        let count = 1_000
        let origin = Date(timeIntervalSince1970: 1_700_000_000)
        let channels = (0..<count).map { i in
            Channel(id: "ch-\(i)", name: "Sports \(i)", logoURL: nil, group: "Sports",
                    streamURL: URL(string: "http://127.0.0.1/\(i).m3u8")!, epgChannelID: "epg-\(i)")
        }
        let list = (0..<480).map { i in
            EPGProgram(id: "p-\(i)", channelID: "guide", title: "Fixture \(i)", description: "Match schedule",
                       start: origin.addingTimeInterval(Double(i * 1800)), end: origin.addingTimeInterval(Double((i + 1) * 1800)))
        }
        let dates = (0..<480).map { origin.addingTimeInterval(Double($0 * 1800 + 30)) }
        let playlist = "#EXTM3U\n" + channels.map {
            "#EXTINF:-1 tvg-id=\"\($0.id)\" group-title=\"Sports\",\($0.name)\n\($0.streamURL.absoluteString)"
        }.joined(separator: "\n")
        let xml = "<tv>" + (0..<count).map {
            "<programme start=\"20231114220000 +0000\" stop=\"20231114223000 +0000\" channel=\"epg-\($0)\"><title>Fixture \($0)</title><desc>Match schedule</desc></programme>"
        }.joined() + "</tv>"
        let xmlData = Data(xml.utf8)
        // Keep guide timestamps within StreamMatcher's rolling horizon. The
        // relative offsets and output counts remain fixed across builds.
        let indexOrigin = Date()
        let programs = Dictionary(uniqueKeysWithValues: channels.map { channel in
            (channel.epgChannelID!, (0..<48).map { i in
                EPGProgram(id: "\(channel.id)-\(i)", channelID: channel.epgChannelID!, title: "Fixture \(i)", description: "Match schedule",
                           start: indexOrigin.addingTimeInterval(Double(i * 1800)), end: indexOrigin.addingTimeInterval(Double((i + 1) * 1800)))
            })
        })
        // HD/SD/UHD variants commonly share a guide ID. Measure that case
        // separately instead of hiding it inside the unique-guide workload.
        let variants = channels + channels.map {
            Channel(id: $0.id + "-hd", name: $0.name + " HD", logoURL: nil,
                    group: $0.group, streamURL: $0.streamURL, epgChannelID: $0.epgChannelID)
        }
        let measurements = [
            measure("playlist-parse-1000", expected: count) { M3UParser.parse(playlist).count },
            measure("xmltv-parse-1000", expected: count) { XMLTVParser.parse(data: xmlData).count },
            measure("guide-lookup-480", expected: 480) {
                // Include preparation on every measured iteration. Production
                // prepares each guide once per publication and reuses it for
                // channel variants and later UI lookups, so this is conservative.
                let lookup = GuideLookup.Prepared(programs: list)
                var matches = 0
                for (i, date) in dates.enumerated() {
                    if lookup.program(containing: date)?.id == "p-\(i)" { matches += 1 }
                }
                return matches
            },
            measure("sports-index-48000", expected: count + 48_000) {
                let index = StreamMatcher.buildIndex(channels: channels, programs: programs)
                return index.entries.count + index.epgTitleCount
            },
            measure("sports-shared-guide-96000", expected: count * 2 + 96_000) {
                let index = StreamMatcher.buildIndex(channels: variants, programs: programs)
                return index.entries.count + index.epgTitleCount
            }
        ]
        return Report(schema: 3, fixture: "buffer-production-paths-v2",
                      buildMetadata: BufferBuildConfiguration.metadata, measurements: measurements)
    }
}

import Foundation
import Darwin

@main struct ParserMemoryBenchmark {
    static func main() throws {
        let kind = CommandLine.arguments[1]
        let count = Int(CommandLine.arguments[2])!
        let repetitions = Int(CommandLine.arguments[3])!
        let descriptionBytes = Int(CommandLine.arguments[4])!
        let fixture: Data
        if kind == "xml" {
            var xml = "<tv>"
            let description = String(repeating: "synthetic guide description ", count: descriptionBytes / 28)
            for index in 0..<count {
                xml += "<programme start=\"20261004000000 +0000\" stop=\"20261004003000 +0000\" channel=\"fixture-\(index % 128)\"><title>Fixture title \(index)</title><desc>\(description)</desc></programme>"
            }
            xml += "</tv>"
            fixture = Data(xml.utf8)
        } else {
            var playlist = "#EXTM3U\n"
            for index in 0..<count {
                let idAttribute = kind == "m3u-idless" ? "" : " tvg-id=\"fixture-\(index)\""
                playlist += "#EXTINF:-1\(idAttribute) tvg-name=\"Fixture channel \(index)\" group-title=\"Test\",Fixture \(index)\nhttp://127.0.0.1/fixture/\(index).ts\n"
            }
            fixture = Data(playlist.utf8)
        }
        let playlist = kind.hasPrefix("m3u") ? String(decoding: fixture, as: UTF8.self) : ""
        var elapsed: [Double] = []
        var capacity = 0
        var outputCount = 0
        var checksum: UInt64 = 0
        for iteration in 0..<repetitions {
            let result = autoreleasepool { () -> (Int, Int, UInt64, Double) in
                let started = ContinuousClock.now
                if kind == "xml" {
                    let programs = XMLTVParser.parse(data: fixture)
                    let duration = started.duration(to: .now).components
                    let ms = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
                    let sum = programs.reduce(UInt64(0)) { $0 &+ UInt64($1.title.utf8.count + $1.description.utf8.count) }
                    return (programs.count, programs.capacity, sum, ms)
                } else {
                    let channels = M3UParser.parse(playlist)
                    let duration = started.duration(to: .now).components
                    let ms = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
                    let sum = channels.reduce(UInt64(0)) { $0 &+ UInt64($1.name.utf8.count + $1.streamURL.path.utf8.count) }
                    return (channels.count, channels.capacity, sum, ms)
                }
            }
            precondition(result.0 == count, "parser output count differs")
            if iteration > 0 { elapsed.append(result.3) }
            outputCount = result.0
            capacity = result.1
            checksum = result.2
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let payload: [String: Any] = [
            "kind": kind, "inputBytes": fixture.count, "requestedCount": count,
            "count": outputCount, "capacity": capacity,
            "elementStride": kind == "xml" ? MemoryLayout<EPGProgram>.stride : MemoryLayout<Channel>.stride,
            "reservedElementBytes": capacity * (kind == "xml" ? MemoryLayout<EPGProgram>.stride : MemoryLayout<Channel>.stride),
            "checksum": checksum, "peakRSSBytes": usage.ru_maxrss,
            "samplesMs": elapsed
        ]
        let output = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        print(String(decoding: output, as: UTF8.self))
    }
}

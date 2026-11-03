import Foundation
import Darwin

// Decode benchmark: reference (JSONDecoder/JSONSerialization) vs columnar
// connector decoders on synthetic provider payloads. Each case runs in its
// own child process so peak RSS is attributable; allocations are counted by
// hooking the default malloc zone. Run via scripts/test-connectors.sh --bench.

nonisolated(unsafe) var allocationCount = 0
nonisolated(unsafe) var allocationCounting = false
nonisolated(unsafe) var originalMalloc: (@convention(c) (UnsafeMutablePointer<malloc_zone_t>?, Int) -> UnsafeMutableRawPointer?)?
nonisolated(unsafe) var originalCalloc: (@convention(c) (UnsafeMutablePointer<malloc_zone_t>?, Int, Int) -> UnsafeMutableRawPointer?)?
nonisolated(unsafe) var originalRealloc: (@convention(c) (UnsafeMutablePointer<malloc_zone_t>?, UnsafeMutableRawPointer?, Int) -> UnsafeMutableRawPointer?)?
nonisolated(unsafe) var originalTypedMalloc: (@convention(c) (UnsafeMutablePointer<malloc_zone_t>?, Int, malloc_type_id_t) -> UnsafeMutableRawPointer?)?
nonisolated(unsafe) var originalTypedCalloc: (@convention(c) (UnsafeMutablePointer<malloc_zone_t>?, Int, Int, malloc_type_id_t) -> UnsafeMutableRawPointer?)?
nonisolated(unsafe) var originalTypedRealloc: (@convention(c) (UnsafeMutablePointer<malloc_zone_t>?, UnsafeMutableRawPointer?, Int, malloc_type_id_t) -> UnsafeMutableRawPointer?)?

func installAllocationCounter() {
    var addresses: UnsafeMutablePointer<vm_address_t>?
    var zoneCount: UInt32 = 0
    malloc_get_all_zones(mach_task_self_, nil, &addresses, &zoneCount)
    guard zoneCount > 0, let zone = UnsafeMutablePointer<malloc_zone_t>(bitPattern: UInt(addresses![0])) else { return }
    let page = Int(getpagesize())
    mprotect(UnsafeMutableRawPointer(bitPattern: Int(bitPattern: zone) & ~(page - 1)), page * 2, PROT_READ | PROT_WRITE)
    originalMalloc = zone.pointee.malloc
    zone.pointee.malloc = { z, s in if allocationCounting { allocationCount &+= 1 }; return originalMalloc!(z, s) }
    originalCalloc = zone.pointee.calloc
    zone.pointee.calloc = { z, n, s in if allocationCounting { allocationCount &+= 1 }; return originalCalloc!(z, n, s) }
    originalRealloc = zone.pointee.realloc
    zone.pointee.realloc = { z, p, s in if allocationCounting { allocationCount &+= 1 }; return originalRealloc!(z, p, s) }
    if zone.pointee.version >= 16 {
        originalTypedMalloc = zone.pointee.malloc_type_malloc
        if originalTypedMalloc != nil {
            zone.pointee.malloc_type_malloc = { z, s, t in if allocationCounting { allocationCount &+= 1 }; return originalTypedMalloc!(z, s, t) }
        }
        originalTypedCalloc = zone.pointee.malloc_type_calloc
        if originalTypedCalloc != nil {
            zone.pointee.malloc_type_calloc = { z, n, s, t in if allocationCounting { allocationCount &+= 1 }; return originalTypedCalloc!(z, n, s, t) }
        }
        originalTypedRealloc = zone.pointee.malloc_type_realloc
        if originalTypedRealloc != nil {
            zone.pointee.malloc_type_realloc = { z, p, s, t in if allocationCounting { allocationCount &+= 1 }; return originalTypedRealloc!(z, p, s, t) }
        }
    }
}

func peakRSS() -> Int {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int(usage.ru_maxrss)
}

struct BenchCase {
    let name: String
    let prepare: () -> Any
    let legacy: (Any) -> Int
    let fast: (Any) -> Int
}

let config = ConnectorFixtures.config

/// Fixtures are generated once into .local/bench/fixtures and read back, so a
/// child's peak RSS reflects decoding rather than fixture generation.
func cachedFixture(_ name: String, _ make: () -> Data) -> Data {
    let url = URL(fileURLWithPath: ".local/bench/fixtures/\(name).json")
    if let data = try? Data(contentsOf: url) { return data }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = make()
    try! data.write(to: url)
    return data
}

func cachedFixtures(_ name: String, count: Int, _ make: (Int) -> Data) -> [Data] {
    let blob = cachedFixture(name) {
        var out = Data()
        for k in 0..<count {
            let item = make(k)
            var length = UInt32(item.count)
            out.append(Data(bytes: &length, count: 4))
            out.append(item)
        }
        return out
    }
    var result: [Data] = []
    var offset = 0
    blob.withUnsafeBytes { raw in
        while offset < raw.count {
            let length = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            result.append(Data(raw[(offset + 4)..<(offset + 4 + length)]))
            offset += 4 + length
        }
    }
    return result
}

func makeCases() -> [BenchCase] {
    var cases: [BenchCase] = []
    cases.append(BenchCase(name: "xtream.live_streams.60k", prepare: {
        (cachedFixture("live60k") { ConnectorFixtures.liveStreams(count: 60_000) }, ConnectorFixtures.liveCategories())
    }, legacy: { input in
        let (streams, categories) = input as! (Data, Data)
        return try! LegacyXtream.channels(streams, categories: LegacyXtream.categories(categories), config: config).count
    }, fast: { input in
        let (streams, categories) = input as! (Data, Data)
        return try! XtreamClient.decodeChannels(streams: streams, categories: categories, config: config).count
    }))
    cases.append(BenchCase(name: "xtream.live_streams.60k.columns_only", prepare: {
        (cachedFixture("live60k") { ConnectorFixtures.liveStreams(count: 60_000) }, ConnectorFixtures.liveCategories())
    }, legacy: { input in
        let (streams, categories) = input as! (Data, Data)
        _ = try! LegacyXtream.categories(categories)
        return try! JSONDecoder().decode([LegacyXtream.Stream].self, from: streams).count
    }, fast: { input in
        let (streams, categories) = input as! (Data, Data)
        _ = try! XtreamCategoryTable.decode(categories)
        return try! XtreamLiveStreamColumns.decode(streams).reduce(0) { $0 + $1.count }
    }))
    cases.append(BenchCase(name: "xtream.short_epg.5k_channels", prepare: {
        cachedFixtures("shortepg5k", count: 5_000) { ConnectorFixtures.shortEPG(streamID: $0, listings: 60) }
    }, legacy: { input in
        var total = 0
        for (k, data) in (input as! [Data]).enumerated() {
            total += try! LegacyXtream.catchupListings(data, channelID: "\(k)", epgID: "g\(k)", minimumStart: nil).programs.count
        }
        return total
    }, fast: { input in
        var total = 0
        for (k, data) in (input as! [Data]).enumerated() {
            total += try! XtreamClient.decodeCatchupListings(data, channelID: "\(k)", epgID: "g\(k)", minimumStart: nil).programs.count
        }
        return total
    }))
    cases.append(BenchCase(name: "xtream.vod_streams.40k", prepare: {
        (cachedFixture("vod40k") { ConnectorFixtures.vodStreams(count: 40_000) }, ConnectorFixtures.liveCategories(count: 130))
    }, legacy: { input in
        let (streams, categories) = input as! (Data, Data)
        return try! LegacyXtream.vodItems(streams, categories: LegacyXtream.categories(categories), config: config).count
    }, fast: { input in
        let (streams, categories) = input as! (Data, Data)
        return try! XtreamClient.decodeVODItems(streams: streams, categories: XtreamClient.decodeCategoryTable(categories), config: config).count
    }))
    cases.append(BenchCase(name: "xtream.series.15k", prepare: {
        (cachedFixture("series15k") { ConnectorFixtures.series(count: 15_000) }, ConnectorFixtures.liveCategories(count: 80))
    }, legacy: { input in
        let (data, categories) = input as! (Data, Data)
        return try! LegacyXtream.series(data, categories: LegacyXtream.categories(categories)).count
    }, fast: { input in
        let (data, categories) = input as! (Data, Data)
        return try! XtreamClient.decodeSeries(data, categories: XtreamClient.decodeCategoryTable(categories)).count
    }))
    cases.append(contentsOf: StalkerESPNBench.cases())
    return cases
}

func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

@main
struct ConnectorDecodeBenchmark {
    static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--case") {
            // Child: one case, one implementation.
            let name = arguments[index + 1]
            let fast = arguments[index + 2] == "fast"
            let runs = Int(arguments[index + 3]) ?? 5
            guard let bench = makeCases().first(where: { $0.name == name }) else { exit(2) }
            installAllocationCounter()
            let input = bench.prepare()
            let body = fast ? bench.fast : bench.legacy
            var times: [Double] = []
            var allocations = 0
            var resultCount = 0
            let rssBefore = peakRSS()
            for run in 0..<runs {
                allocationCount = 0
                allocationCounting = true
                let start = ContinuousClock.now
                resultCount = body(input)
                let elapsed = ContinuousClock.now - start
                allocationCounting = false
                if run == 0 { allocations = allocationCount }
                times.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
            }
            let peakDelta = max(0, peakRSS() - rssBefore)
            print("RESULT \(median(times)) \(allocations) \(peakDelta) \(resultCount)")
            exit(0)
        }

        let runs = 5
        print("connector decode benchmark — median of \(runs) runs; allocations = malloc calls in one run; peak = RSS growth over the prepared input")
        print(String(repeating: "-", count: 132))
        print("case".padding(toLength: 40, withPad: " ", startingAt: 0), "rows", "legacy ms", "fast ms", "speedup", "legacy allocs", "fast allocs", "legacy peak MB", "fast peak MB", separator: "\t")
        var json: [String] = []
        for bench in makeCases() {
            func child(_ impl: String) -> (Double, Int, Int, Int) {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: arguments[0])
                process.arguments = ["--case", bench.name, impl, "\(runs)"]
                let pipe = Pipe()
                process.standardOutput = pipe
                try! process.run()
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                let fields = output.split(separator: "\n").first { $0.hasPrefix("RESULT") }!.split(separator: " ")
                return (Double(fields[1])!, Int(fields[2])!, Int(fields[3])!, Int(fields[4])!)
            }
            let legacy = child("legacy")
            let fast = child("fast")
            precondition(legacy.3 == fast.3, "\(bench.name): result counts differ \(legacy.3) vs \(fast.3)")
            let speedup = legacy.0 / fast.0
            print(bench.name.padding(toLength: 40, withPad: " ", startingAt: 0), legacy.3,
                  String(format: "%.1f", legacy.0), String(format: "%.1f", fast.0), String(format: "%.1fx", speedup),
                  legacy.1, fast.1, String(format: "%.1f", Double(legacy.2) / 1_048_576), String(format: "%.1f", Double(fast.2) / 1_048_576),
                  separator: "\t")
            json.append("{\"case\":\"\(bench.name)\",\"rows\":\(legacy.3),\"legacyMs\":\(legacy.0),\"fastMs\":\(fast.0),\"speedup\":\(speedup),\"legacyAllocations\":\(legacy.1),\"fastAllocations\":\(fast.1),\"legacyPeakBytes\":\(legacy.2),\"fastPeakBytes\":\(fast.2)}")
        }
        print("CONNECTOR_BENCH_JSON [\(json.joined(separator: ","))]")

    }
}

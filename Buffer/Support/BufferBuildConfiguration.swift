import Foundation

/// Runtime evidence from the measured executable, independent of its path.
/// The optimized profile retains Debug instrumentation and is not a Release build.
enum BufferBuildConfiguration {
    static let outputPrefix = "BUFFER_BUILD_JSON "
    struct Metadata: Codable, Equatable {
        let schema: Int
        let configuration: String
        let swiftAssertions: String
        let swiftOptimization: String
        let debugInstrumentation: Bool
        let architecture: String
        let executableScope: String
    }

    static var metadata: Metadata {
        // Swift folds these queries at compile time. They also catch an -O
        // executable accidentally placed in the ordinary Debug build folder.
        let assertions: String
        if _isDebugAssertConfiguration() {
            assertions = "debug"
        } else if _isReleaseAssertConfiguration() {
            assertions = "release"
        } else {
            assertions = "unchecked"
        }
#if DEBUG
        let instrumented = true
#else
        let instrumented = false
#endif
#if arch(arm64)
        let architecture = "arm64"
#elseif arch(x86_64)
        let architecture = "x86_64"
#else
        let architecture = "other"
#endif
        let configuration: String
#if BUFFER_OPTIMIZED_INSTRUMENTED && DEBUG
        configuration = assertions == "release" ? "Optimized-Instrumented" : "Invalid-Optimized-Instrumented"
#elseif DEBUG
        configuration = assertions == "debug" ? "Debug-Onone" : "Unsupported-Debug-Optimized"
#else
        configuration = "Release"
#endif
        return Metadata(schema: 1, configuration: configuration,
                        swiftAssertions: assertions,
                        swiftOptimization: assertions == "debug" ? "unoptimized" : "optimized",
                        debugInstrumentation: instrumented, architecture: architecture,
                        executableScope: "full-macos-app")
    }

    static var metadataDictionary: [String: Any] {
        // All fields have fixed Codable representations.
        guard let data = try? JSONEncoder().encode(metadata),
              let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            preconditionFailure("Build metadata encoding failed")
        }
        return dictionary
    }
}

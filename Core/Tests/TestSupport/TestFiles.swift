// Where the tests find what they test against.
//
// The repository's own test data (testdata/, at the top) is made up: made-up words,
// pictures drawn by the tests. The maintainer's real presentations, kept beside the
// repository in "Pro Bundles (Some with exported slides)", are never committed; the
// tests that use them (ConversionTests/RealBundlesTests.swift) run only when that
// folder is there and PROTOPPTX_REAL_BUNDLES is set, and report numbers, never words.

import Foundation

public enum TestFiles {
    /// The top of the repository.
    public static let repository: URL = {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Core/Package.swift").path) { return url }
        }
        fatalError("the repository was not found above \(#filePath)")
    }()

    public static var testdata: URL { repository.appendingPathComponent("testdata") }

    /// The maintainer's own presentations, if they are here and their use was asked for.
    public static var realBundles: URL? {
        guard ProcessInfo.processInfo.environment["PROTOPPTX_REAL_BUNDLES"] != nil else { return nil }
        let url = repository.appendingPathComponent("Pro Bundles (Some with exported slides)")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// A new empty folder for one test's files.
    public static func scratchFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ProToPPTXTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

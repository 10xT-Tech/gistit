//
//  ForbiddenImportTests.swift
//  EnglishHelperTests
//
//  Enforces the dependency rule by scanning source on disk (located via #filePath):
//   • Domain stays pure (Foundation only).
//   • Presentation never imports an engine framework (AVFoundation / Speech / Vision / Anthropic).
//  Engine SDKs live ONLY in the Data (Adapters) layer.
//

import Testing
import Foundation

@Suite struct ForbiddenImportTests {

    /// Foundation is the sole allowance for Domain.
    static let domainForbidden: Set<String> = [
        "SwiftUI", "UIKit", "AppKit", "AVFoundation", "AVFAudio", "Speech", "Vision",
        "CoreData", "SwiftData", "Combine", "Photos", "PhotosUI",
        "UniformTypeIdentifiers", "CoreImage", "CoreGraphics", "Network",
        "AmplitudeSwift", "Sentry",
    ]

    /// Presentation may use SwiftUI/UIKit but never an engine/transport backend.
    static let presentationForbidden: Set<String> = [
        "AVFoundation", "AVFAudio", "Speech", "Vision", "CoreData", "SwiftData", "Network",
        "AmplitudeSwift", "Sentry",
    ]

    static func directory(_ layer: String) -> URL {
        URL(filePath: #filePath)            // …/Tests/ForbiddenImportTests.swift
            .deletingLastPathComponent()    // …/Tests
            .deletingLastPathComponent()    // repo root
            .appending(path: layer)
    }

    @Test func domainImportsOnlyFoundation() throws {
        try assertNoForbiddenImports(in: Self.directory("Domain"), forbidden: Self.domainForbidden)
    }

    @Test func presentationImportsNoEngineFrameworks() throws {
        try assertNoForbiddenImports(in: Self.directory("Presentation"), forbidden: Self.presentationForbidden)
    }

    @Test func domainDoesNotLeakTransportTypes() throws {
        for file in try swiftFiles(in: Self.directory("Domain")) {
            let source = try String(contentsOf: file, encoding: .utf8)
            for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
                // Strip line comments so documentation that merely *names* these types doesn't trip the check.
                let code = rawLine.split(separator: "//", maxSplits: 1,
                                         omittingEmptySubsequences: false).first.map(String.init) ?? ""
                #expect(
                    !code.contains("URLSession"),
                    "Domain/\(file.lastPathComponent) references a transport type (URLSession) in code"
                )
            }
        }
    }

    // MARK: helpers

    private func assertNoForbiddenImports(in directory: URL, forbidden: Set<String>) throws {
        let files = try swiftFiles(in: directory)
        #expect(!files.isEmpty, "Expected source files under \(directory.path)")
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for rawLine in source.split(separator: "\n") {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("import ") else { continue }
                let module = line.dropFirst("import ".count)
                    .split(separator: ".").first.map(String.init)?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                #expect(
                    !forbidden.contains(module),
                    "\(directory.lastPathComponent)/\(file.lastPathComponent) imports forbidden framework '\(module)'"
                )
            }
        }
    }

    private func swiftFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            result.append(url)
        }
        return result
    }
}

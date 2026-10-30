import Foundation
import Testing
@testable import LegadoCore

// Opt-in only: point LEGADO_SOURCE_PROBE_FILE at a downloaded JSON source pack.
// No remote source or response is included in the application or normal test run.
struct BookSourceRemoteProbe {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LEGADO_SOURCE_CHAIN_FILE"] != nil))
    func sampleReadingPipelines() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["LEGADO_SOURCE_CHAIN_FILE"])
        let sources = try BookSourceImporter().decode(Data(contentsOf: URL(fileURLWithPath: path)))
        var reports: [BookSourceDebugReport] = []
        let transport = ProbeTransport()
        let keyword = ProcessInfo.processInfo.environment["LEGADO_SOURCE_PROBE_KEYWORD"] ?? "斗罗大陆"
        for source in sources {
            var report = await BookSourceDebugger(transport: transport).run(source: source, keyword: keyword)
            report.contentPreview = nil
            reports.append(report)
            print("SOURCE_CHAIN \(source.bookSourceName) " + String(decoding: try JSONEncoder().encode(report), as: UTF8.self))
        }
        if let output = ProcessInfo.processInfo.environment["LEGADO_SOURCE_CHAIN_OUTPUT"] {
            try JSONEncoder().encode(reports).write(to: URL(fileURLWithPath: output))
            try JSONEncoder().encode(await transport.records()).write(to: URL(fileURLWithPath: output + ".requests.json"))
        }
        #expect(reports.count == sources.count)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LEGADO_SOURCE_PROBE_FILE"] != nil))
    func sampleSearches() async throws {
        guard let path = ProcessInfo.processInfo.environment["LEGADO_SOURCE_PROBE_FILE"] else { return }
        let sources = try BookSourceImporter().decode(Data(contentsOf: URL(fileURLWithPath: path)))
        let transport = ProbeTransport()
        let service = BookSearchService(transport: transport, networkPolicy: .init(), history: .init())
        let keyword = ProcessInfo.processInfo.environment["LEGADO_SOURCE_PROBE_KEYWORD"] ?? "斗罗大陆"
        let page = Int(ProcessInfo.processInfo.environment["LEGADO_SOURCE_PROBE_PAGE"] ?? "1") ?? 1
        var rows: [[String: JSONValue]] = []
        for await outcome in service.searchOutcomes(keyword: keyword, page: page, sources: sources, maximumConcurrentSources: 3, includeDisabled: true) {
            let source = try #require(sources.first { $0.id == outcome.sourceID })
            let row: [String: JSONValue] = [
                "name": .string(source.bookSourceName), "source": .string(source.id),
                "count": .number(Double(outcome.books.count)),
                "books": .array(outcome.books.prefix(3).map { .object([
                    "name": .string($0.name), "url": .string($0.bookURL), "author": .string($0.author),
                    "cover": .string($0.coverURL ?? ""), "wordCount": .string($0.wordCount ?? "")
                ]) }),
                "diagnostics": .array(outcome.diagnostics.map { .object(["code": .string($0.code), "message": .string($0.message), "rule": .string($0.rule)]) })
            ]
            rows.append(row)
            print("SOURCE_PROBE " + JSONValue.object(row).stringValue)
        }
        let report = JSONValue.object(["keyword": .string(keyword), "page": .number(Double(page)), "outcomes": .array(rows.map(JSONValue.object)), "requests": .array(await transport.records())])
        if let output = ProcessInfo.processInfo.environment["LEGADO_SOURCE_PROBE_OUTPUT"] {
            try JSONEncoder().encode(report).write(to: URL(fileURLWithPath: output))
        }
        #expect(rows.count == Set(sources.map(\.id)).count)
    }
}

private actor ProbeTransport: HTTPTransport {
    private var values: [JSONValue] = []
    private let transport = URLSessionHTTPTransport()

    func data(for request: URLRequest) async throws -> HTTPResponse {
        do {
            let response = try await transport.data(for: request)
            var record: [String: JSONValue] = [
                "url": .string(request.url?.absoluteString ?? ""),
                "finalURL": .string(response.finalURL.absoluteString),
                "status": .number(Double(response.statusCode)),
                "bytes": .number(Double(response.data.count)),
                "preview": .string(String(response.decodedText.prefix(240)))
            ]
            if let directory = ProcessInfo.processInfo.environment["LEGADO_SOURCE_PROBE_SNAPSHOT_DIR"] {
                let folder = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = folder.appendingPathComponent(UUID().uuidString + ".response")
                try response.data.write(to: file)
                record["snapshot"] = .string(file.path)
            }
            values.append(.object(record))
            return response
        } catch {
            values.append(.object(["url": .string(request.url?.absoluteString ?? ""), "error": .string(error.localizedDescription)]))
            throw error
        }
    }

    func records() -> [JSONValue] { values }
}

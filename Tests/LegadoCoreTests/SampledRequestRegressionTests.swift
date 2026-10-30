import Foundation
import Testing
@testable import LegadoCore

// The payloads and host below are synthetic and never use network access.
struct SampledRequestRegressionTests {
    @Test func equalsSeparatedSourceHeaderReachesSearchTransport() async throws {
        var source = source()
        source.header = #"{"type"="app"}"#
        source.searchUrl = #"/search,{"method":"POST","body":"keyword={{key}}&page={{page-1}}"}"#
        let transport = SampledRequestTransport()
        let result = await BookSearchService(transport: transport).search(keyword: "斗罗大陆", page: 1, source: source)
        #expect(result.diagnostics.isEmpty)
        #expect(result.books.count == 1)
        let request = try #require(await transport.requests().first)
        #expect(request.value(forHTTPHeaderField: "type") == "app")
        #expect(request.httpBody.map { String(decoding: $0, as: UTF8.self) } == "keyword=%E6%96%97%E7%BD%97%E5%A4%A7%E9%99%86&page=0")
    }

    @Test func stringEncodedLenientHeadersReachSearchTransport() async throws {
        var source = source()
        source.searchUrl = #"/search?word={{key}},{"headers":"{os:'pc'}"}"#
        let transport = SampledRequestTransport()
        let result = await BookSearchService(transport: transport).search(keyword: "斗罗大陆", page: 1, source: source)
        #expect(result.diagnostics.isEmpty)
        #expect(result.books.count == 1)
        let request = try #require(await transport.requests().first)
        #expect(request.value(forHTTPHeaderField: "os") == "pc")
    }

    @Test func unquotedKeywordInObjectBodyPreservesJSONValueTypes() async throws {
        var source = source()
        source.searchUrl = #"/search,{"method":"POST","body":{"keyword":{{key}},"page_index":{{page}},"page_size":20,"enabled":true,"cursor":null}}"#
        let transport = SampledRequestTransport()
        let result = await BookSearchService(transport: transport).search(keyword: "斗罗大陆", page: 1, source: source)
        #expect(result.diagnostics.isEmpty)
        #expect(result.books.count == 1)
        let request = try #require(await transport.requests().first)
        let body = try JSONValue.decode(data: #require(request.httpBody))
        #expect(body["keyword"] == .string("斗罗大陆"))
        #expect(body["page_index"] == .number(1))
        #expect(body["page_size"] == .number(20))
        #expect(body["enabled"] == .bool(true))
        #expect(body["cursor"] == .null)
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("application/json") == true)
    }

    @Test func lenientSeparatorsDoNotRewriteQuotedCookieOrURLValues() throws {
        let value = try LegadoURLBuilder.decodeLenientJSON(#"{type=>app, 'Cookie':'token=a=b; mode=pc', referer:'https://fixture.invalid/?a=b', retry:2, enabled:false, empty:null}"#)
        #expect(value["type"] == .string("app"))
        #expect(value["Cookie"] == .string("token=a=b; mode=pc"))
        #expect(value["referer"] == .string("https://fixture.invalid/?a=b"))
        #expect(value["retry"] == .number(2))
        #expect(value["enabled"] == .bool(false))
        #expect(value["empty"] == .null)
    }

    @Test func unquotedWebViewFlagUsedByAudioSourceParses() throws {
        let request = try LegadoURLBuilder().prepare("https://request.fixture.invalid/audio,{webView:“true”}")
        #expect(request.useWebView)
    }

    @Test func lenientValuesKeepCommentsAndPutRuleExpressionsWorking() throws {
        let options = try LegadoURLBuilder.decodeLenientJSON("{retry: 2 /* comment */, enabled: FALSE, word: 小说}")
        #expect(options["retry"] == .number(2))
        #expect(options["enabled"] == .bool(false))
        #expect(options["word"] == .string("小说"))
        let put = try LegadoURLBuilder.decodeLenientJSON("{id:$.books[0].id, name:name}", quoteUnquotedValues: true)
        #expect(put["id"] == .string("$.books[0].id"))
        #expect(put["name"] == .string("name"))
        #expect(throws: (any Error).self) { try LegadoURLBuilder.decodeLenientJSON("{broken:}") }
    }

    private func source() -> BookSource {
        var source = BookSource(bookSourceUrl: "https://request.fixture.invalid", bookSourceName: "请求兼容测试")
        source.ruleSearch = .init(bookList: "$.books", name: "$.name", bookUrl: "$.url")
        return source
    }
}

private actor SampledRequestTransport: HTTPTransport {
    private var values: [URLRequest] = []
    func data(for request: URLRequest) async throws -> HTTPResponse {
        values.append(request)
        return .init(data: Data(#"{"books":[{"name":"测试书","url":"/book/42"}]}"#.utf8),
                     statusCode: 200, headers: [:], finalURL: try #require(request.url))
    }
    func requests() -> [URLRequest] { values }
}

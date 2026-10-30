import Foundation
import Testing
@testable import LegadoCore

// All responses and hosts are synthetic; these tests never contact source websites.
struct SampledSourceRegressionTests {
    @Test func JavaScriptNumbersZeroAndOneRemainNumeric() throws {
        let evaluator = JavaScriptRuleEvaluator()
        let value = try evaluator.evaluate(script: "({zero: 0, one: 1, yes: true, no: false, list: [0, 1, true]})", result: .null, executionContext: .init()).value
        #expect(value["zero"] == .number(0))
        #expect(value["one"] == .number(1))
        #expect(value["yes"] == .bool(true))
        #expect(value["no"] == .bool(false))
        #expect(value["list"] == .array([.number(0), .number(1), .bool(true)]))
    }

    @Test func JavaScriptGetStringUsesTheSameJSONTemplateAndReplacementSemantics() async throws {
        let input = try JSONValue.decode(data: Data(#"{"id":42,"name":"测试小说","alternate":"备用小说"}"#.utf8))
        let value = await RuleEngine().evaluate("@js:java.getString('/book/{$.id}') + ':' + java.getString('$.name||$.alternate##小说')", in: input)
        #expect(value.diagnostics.isEmpty)
        #expect(value.strings == ["/book/42:测试"])
    }

    @Test func legacyJSONTemplatesKeepEachSearchBookURLDistinct() async throws {
        var source = BookSource(bookSourceUrl: "https://fixture.invalid", bookSourceName: "旧式 JSON 模板")
        source.searchUrl = "/search?word={{key}}"
        source.ruleSearch = .init(bookList: "data.bookList", name: "name", bookUrl: "/pc/book/{$.id}/catalog")
        let outcome = await BookSearchService(transport: SampledResponseTransport(body:
            #"{"data":{"bookList":[{"id":42,"name":"测试甲"},{"id":43,"name":"测试乙"}]}}"#
        )).search(keyword: "测试", page: 1, source: source)
        #expect(outcome.diagnostics.isEmpty)
        #expect(outcome.books.map(\.bookURL) == ["https://fixture.invalid/pc/book/42/catalog", "https://fixture.invalid/pc/book/43/catalog"])
    }

    @Test func legacyJSONRootWildcardAndRecursiveURLTemplate() async throws {
        var source = BookSource(bookSourceUrl: "https://fixture.invalid", bookSourceName: "旧式 JSON 列表")
        source.searchUrl = "/search?word={{key}}"
        source.ruleSearch = .init(bookList: "$.[*]", name: "$..name", bookUrl: "https://fixture.invalid{$..url}")
        let outcome = await BookSearchService(transport: SampledResponseTransport(body:
            #"[{"name":"测试甲","url":"/book/42"},{"name":"测试乙","url":"/book/43"}]"#
        )).search(keyword: "测试", page: 1, source: source)
        #expect(outcome.diagnostics.isEmpty)
        #expect(outcome.books.map(\.bookURL) == ["https://fixture.invalid/book/42", "https://fixture.invalid/book/43"])
    }

    @Test func legacyJSONTemplatesRespectQuotedBracesAndReplacement() async throws {
        let input = try JSONValue.decode(data: Data(#"{"id":42,"words":1200,"meta":{"label}":"玄幻"},"tags":["甲","乙"]}"#.utf8))
        let value = await RuleEngine().evaluate(#"{$.meta['label}']}/{$.words}字/{$.tags[*]}##1200##1.2千"#, in: input)
        #expect(value.diagnostics.isEmpty)
        #expect(value.strings == ["玄幻/1.2千字/甲\n乙"])
        let fromText = await RuleEngine().evaluate("/book/{$.id}", inText: input.stringValue)
        #expect(fromText.diagnostics.isEmpty)
        #expect(fromText.strings == ["/book/42"])
    }

    @Test func JSONFallbackSkipsEmptyArraysAndEmptyNames() async throws {
        let input = try JSONValue.decode(data: Data(#"{"empty":[],"books":[{"name":"备用书"}],"name":"","alternate":"备用书","zero":0}"#.utf8))
        for useText in [false, true] {
            let list = if useText {
                await RuleEngine().evaluate("$.empty||$.books", inText: input.stringValue, listMode: true)
            } else {
                await RuleEngine().evaluate("$.empty||$.books", in: input, listMode: true)
            }
            #expect(list.diagnostics.isEmpty)
            #expect(list.listItems(rule: "$.empty||$.books").count == 1)
            let name = await RuleEngine().evaluate("$.name||$.alternate", in: input)
            #expect(name.strings == ["备用书"])
            let zero = await RuleEngine().evaluate("$.zero||$.alternate", in: input)
            #expect(zero.strings == ["0"])
        }
    }

    @Test func replacementAppliesToTheCombinedSelectorResult() async throws {
        // Search names in the sampled fallback sources and multi-part metadata
        // use one trailing ## expression for the entire selector combination.
        let input = try JSONValue.decode(data: Data(#"{"name":"测试小说","fallback":"备用小说","a":"A1","b":"B2"}"#.utf8))
        let fallback = await RuleEngine().evaluate("$.name||$.fallback##小说", in: input)
        #expect(fallback.strings == ["测试"])
        let combined = await RuleEngine().evaluate("$.a&&$.b##[0-9]", in: input)
        #expect(combined.strings.joined(separator: "\n") == "A\nB")
        let anchored = await RuleEngine().evaluate(#"$.a&&$.b##^A1\nB2$##整段"#, in: input)
        #expect(anchored.strings == ["整段"])
        let list = await RuleEngine().evaluate("$.a&&$.b##[0-9]", in: input, listMode: true)
        #expect(list.strings == ["A", "B"])
        let html = await RuleEngine().evaluate("h1@text||h2@text##小说", inText: "<h1>测试小说</h1>")
        #expect(html.strings == ["测试"])
    }

    @Test func replacementTextIsNotParsedAsSelectorSyntax() async {
        let result = await RuleEngine().evaluate(#"h1@text##["']|[()]"#, inText: "<h1>书名(测试)'</h1>")
        #expect(result.diagnostics.isEmpty)
        #expect(result.strings == ["书名测试"])
        let replacement = await RuleEngine().evaluate("h1@text##书##A&&B", inText: "<h1>书</h1>")
        #expect(replacement.diagnostics.isEmpty)
        #expect(replacement.strings == ["A&&B"])
    }
}

private struct SampledResponseTransport: HTTPTransport {
    let body: String
    func data(for request: URLRequest) async throws -> HTTPResponse {
        .init(data: Data(body.utf8), statusCode: 200, headers: [:], finalURL: try #require(request.url))
    }
}

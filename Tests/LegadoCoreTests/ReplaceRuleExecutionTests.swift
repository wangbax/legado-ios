import Foundation
import Testing
@testable import LegadoCore

struct ReplaceRuleExecutionTests {
    private func process(_ content: String, rules: [ReplaceRule], title: String = "第十二章") -> ContentProcessingReport {
        let book = Book(bookUrl: "book", name: "测试书", origin: "https://source.test")
        let chapter = BookChapter(url: "chapter", title: title, bookUrl: book.bookUrl, index: 11)
        return ContentSanitizer().process(book: book, chapter: chapter, content: content, rules: rules,
            removeDuplicateTitle: false, resegment: false)
    }

    @Test func evaluatesJavaScriptForEveryMatchIncludingZeroWidthMatches() {
        let width = ReplaceRule(id: 1, name: "全角", pattern: "[Ａ-Ｚ０-９]",
            replacement: "@js:String.fromCharCode(result.charCodeAt(0) - 65248)")
        var punctuation = ReplaceRule(id: 2, name: "标点", pattern: #"(?<=说道)(?=“)|\.{3,}"#,
            replacement: #"@js:if (result === '') { '：' } else { '…' }"#)
        punctuation.sortOrder = 1
        let result = process("ＡＢＣ１２３\n他说道“等待...”", rules: [punctuation, width])
        #expect(result.content == "ABC123\n他说道：“等待…”")
        #expect(result.effectiveRuleIDs == [1, 2])
        #expect(result.diagnostics.isEmpty)
    }

    @Test func bindsBookAndChapterAndSharesOnlyJavaVariablesBetweenMatches() {
        let rule = ReplaceRule(id: 1, name: "上下文", pattern: "[ab]", replacement: """
            @js:n = typeof n === 'undefined' ? 1 : n + 1;
            java.put('count', String(Number(java.get('count') || 0) + 1));
            [book.name, book.getName(), chapter.title, chapter.getIndex(), result, n, java.get('count')].join(':')
            """)
        let report = process("a b", rules: [rule])
        #expect(report.content == "测试书:测试书:第十二章:11:a:1:1 测试书:测试书:第十二章:11:b:1:2")
        #expect(report.diagnostics.isEmpty)
        // A new application of the same rule must not inherit another chapter's variables.
        #expect(process("a", rules: [rule]).content == "测试书:测试书:第十二章:11:a:1:1")
    }

    @Test(arguments: [
        (#"'$1'"#, "x"),
        (#"String.fromCharCode(92) + 'n'"#, #"\n"#),
        ("null", "null"),
        ("undefined", "null"),
        ("['a', 'b']", "a,b"),
        ("123", "123.0"),
        ("false", "false")
    ])
    func convertsScriptCompletionAndPreservesReplacementEscaping(_ sample: (String, String)) {
        let rule = ReplaceRule(id: 1, name: "返回值", pattern: "(x)", replacement: "@js:" + sample.0)
        let report = process("x", rules: [rule])
        #expect(report.content == sample.1)
        #expect(report.diagnostics.isEmpty)
    }

    @Test func failedScriptDiscardsAllPartialReplacementsAndLaterRulesStillRun() {
        let failing = ReplaceRule(id: 1, name: "失败", pattern: "[ab]",
            replacement: "@js:if (result === 'b') { throw new Error('bad match') }; 'changed'")
        var following = ReplaceRule(id: 2, name: "后续", pattern: "tail", replacement: "后续成功")
        following.sortOrder = 1
        let report = process("ab tail", rules: [failing, following])
        #expect(report.content == "ab 后续成功")
        #expect(report.effectiveRuleIDs == [2])
        #expect(report.diagnostics.count == 1)
        #expect(report.diagnostics.first?.code == "rule.malformed")
    }

    @Test func skipsDisabledExcludedAndUnmatchedScriptsAndKeepsLiteralReplacementsLiteral() {
        var excluded = ReplaceRule(id: 1, name: "排除", pattern: "x", replacement: "@js:throw new Error('excluded')")
        excluded.excludeScope = "测试书"
        var disabled = excluded
        disabled.id = 2
        disabled.excludeScope = nil
        disabled.isEnabled = false
        let unmatched = ReplaceRule(id: 3, name: "未匹配", pattern: "z", replacement: "@js:throw new Error('unmatched')")
        var literal = ReplaceRule(id: 4, name: "普通文本", pattern: "x", replacement: "@js:'literal'")
        literal.isRegex = false
        let report = process("x", rules: [excluded, disabled, unmatched, literal])
        #expect(report.content == "@js:'literal'")
        #expect(report.diagnostics.isEmpty)
    }

    @Test func preservesLastNonblankTitleButAllowsDeletingBody() {
        var rename = ReplaceRule(id: 1, name: "标题", pattern: "十二", replacement: "12")
        rename.scopeTitle = true
        rename.scopeContent = false
        var erase = ReplaceRule(id: 2, name: "空白", pattern: "^.+$", replacement: "@js:' 　\\n'")
        erase.scopeTitle = true
        erase.sortOrder = 1
        let report = process("正文", rules: [erase, rename])
        #expect(report.title == "第12章")
        #expect(report.content == " 　\n")
        #expect(report.effectiveRuleIDs == [1, 2])
        erase.replacement = ""
        erase.scopeContent = false
        let titleOnly = process("正文", rules: [erase])
        #expect(titleOnly.title == "第十二章")
        #expect(titleOnly.effectiveRuleIDs.isEmpty)
    }

    @Test(arguments: [
        (#"(?:\n[^\n]+){0,15}$"#, "正文\nPS：说明\n感谢支持", "正文"),
        (#"^(?:[^\n\w]\w+){0,2}"#, "，第一章，开始\n正文", "\n正文"),
        (#"＂((?:[\w，。]|‘\w+’|\b[%\+\-])+)[＂]"#, "＂你好，世界。＂", "“你好，世界。”"),
        (#"(?:[+*]|\\)+"#, #"+*\"#, "")
    ])
    func acceptsBoundedDelimitedAndEscapedQuantifiers(_ sample: (String, String, String)) throws {
        let replacement = sample.0.hasPrefix("＂") ? "“$1”" : ""
        #expect(try RegexEvaluator().replacingStrict(pattern: sample.0, in: sample.1, with: replacement) == sample.2)
    }

    @Test(arguments: ["(a+)+$", #"(\w*)*"#, "(?:[ab]+){2,}"])
    func retainsChecksForClearlyNestedUnboundedRepetition(_ pattern: String) {
        #expect(throws: RuleEngineError.self) {
            try RegexEvaluator().replacingStrict(pattern: pattern, in: "aaa!", with: "changed")
        }
    }

    @Test func dynamicReplacementRespectsMatchOutputAndWholeOperationTimeLimits() throws {
        let limited = RegexEvaluator(limits: .init(maximumInputLength: 4, maximumMatches: 2))
        #expect(throws: RuleEngineError.self) {
            try limited.replacingStrict(pattern: "a", in: "aaa", replacement: { _ in "b" })
        }
        #expect(try limited.replacingStrict(pattern: "a", in: "aa", replacement: { _ in "b" }) == "bb")
        // Include untouched tail in the output limit, not only replaced spans.
        #expect(throws: RuleEngineError.self) {
            try limited.replacingStrict(pattern: "a", in: "abcd", replacement: { _ in "1234567" })
        }
        #expect(throws: RuleEngineError.self) {
            try limited.replacingStrict(pattern: "a", in: "a", timeoutMilliseconds: 1, replacement: { _ in
                Thread.sleep(forTimeInterval: 0.02)
                return "b"
            })
        }
    }

    @Test func rejectsKnownUnboundedJavaScriptAndReportsErrorWithoutChangingInput() {
        let rule = ReplaceRule(id: 1, name: "循环", pattern: "x", replacement: "@js:while(true){}")
        let report = process("x", rules: [rule])
        #expect(report.content == "x")
        #expect(report.diagnostics.first?.code == "rule.resource_limit")
    }
}

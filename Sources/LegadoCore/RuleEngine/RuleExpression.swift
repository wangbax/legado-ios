import Foundation

public enum RuleMode: String, Codable, Sendable {
    case css
    case xpath
    case jsonPath
    case regex
    case javaScript
    case webJavaScript
}

public enum RuleCombination: String, Codable, Sendable {
    case single
    case concatenate = "&&"
    case fallback = "||"
    case interleave = "%%"
}

public struct RuleBranch: Codable, Hashable, Sendable {
    public var mode: RuleMode
    public var expression: String
    public var replacePattern: String?
    public var replacement: String
    public var replaceFirst: Bool

    public init(
        mode: RuleMode,
        expression: String,
        replacePattern: String? = nil,
        replacement: String = "",
        replaceFirst: Bool = false
    ) {
        self.mode = mode
        self.expression = expression
        self.replacePattern = replacePattern
        self.replacement = replacement
        self.replaceFirst = replaceFirst
    }
}

public struct RulePlan: Codable, Hashable, Sendable {
    public var source: String
    public var combination: RuleCombination
    public var branches: [RuleBranch]
}

public struct RuleExpressionParser: Sendable {
    public init() {}

    public func parse(_ source: String, inputLooksLikeJSON: Bool = false) throws -> RulePlan {
        let normalized = source.trimmingCharacters(in: .newlines)
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuleEngineError.malformedRule(rule: source, detail: "规则不能为空")
        }
        // ## belongs to the whole selector stage. Regex/replacement text may
        // contain quotes, brackets and && that are not selector operators.
        let replacementStart = normalized.range(of: "##")?.lowerBound ?? normalized.endIndex
        let split = try splitAtTopLevel(String(normalized[..<replacementStart]))
        let suffix = String(normalized[replacementStart...])
        let branches = try split.parts.map { try parseBranch($0 + suffix, inputLooksLikeJSON: inputLooksLikeJSON) }
        return .init(source: source, combination: split.combination, branches: branches)
    }

    private func parseBranch(_ source: String, inputLooksLikeJSON: Bool) throws -> RuleBranch {
        var value = String(source.drop(while: { $0.isWhitespace }))
        var mode: RuleMode
        if value.lowercased().hasPrefix("@css:") {
            mode = .css
            value.removeFirst(5)
        } else if value.hasPrefix("@@") {
            mode = .css
            value.removeFirst(2)
        } else if value.lowercased().hasPrefix("@xpath:") {
            mode = .xpath
            value.removeFirst(7)
        } else if value.lowercased().hasPrefix("@json:") {
            mode = .jsonPath
            value.removeFirst(6)
        } else if value.lowercased().hasPrefix("@js:") {
            mode = .javaScript
            value.removeFirst(4)
        } else if value.lowercased().hasPrefix("<js>") && value.lowercased().hasSuffix("</js>") {
            mode = .javaScript
            value = String(value.dropFirst(4).dropLast(5))
        } else if value.lowercased().hasPrefix("<webjs>") && value.lowercased().hasSuffix("</webjs>") {
            mode = .webJavaScript
            value = String(value.dropFirst(7).dropLast(8))
        } else if value.hasPrefix(":") {
            mode = .regex
            value.removeFirst()
        } else if value.hasPrefix("$.") || value.hasPrefix("$[") || inputLooksLikeJSON {
            mode = .jsonPath
        } else if value.hasPrefix("/") || value.hasPrefix("./") {
            mode = .xpath
        } else {
            mode = .css
        }

        let replacement = value.components(separatedBy: "##")
        let expression = replacement[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty || replacement.count > 1 else {
            throw RuleEngineError.malformedRule(rule: source, detail: "规则主体不能为空")
        }
        return .init(
            mode: mode,
            expression: expression,
            replacePattern: replacement.count > 1 ? replacement[1] : nil,
            replacement: replacement.count > 2 ? replacement[2] : "",
            replaceFirst: replacement.count > 3
        )
    }

    private func splitAtTopLevel(_ source: String) throws -> (parts: [String], combination: RuleCombination) {
        var quote: Character?
        var escaped = false
        var roundDepth = 0
        var squareDepth = 0
        var curlyDepth = 0
        var found: RuleCombination?
        var parts: [String] = []
        var partStart = source.startIndex
        var index = source.startIndex

        while index < source.endIndex {
            let character = source[index]
            if escaped {
                escaped = false
                index = source.index(after: index)
                continue
            }
            if character == "\\" {
                escaped = true
                index = source.index(after: index)
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
                index = source.index(after: index)
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                index = source.index(after: index)
                continue
            }
            switch character {
            case "(": roundDepth += 1
            case ")": roundDepth -= 1
            case "[": squareDepth += 1
            case "]": squareDepth -= 1
            case "{": curlyDepth += 1
            case "}": curlyDepth -= 1
            default: break
            }
            if roundDepth < 0 || squareDepth < 0 || curlyDepth < 0 {
                throw RuleEngineError.malformedRule(rule: source, detail: "规则括号未平衡")
            }
            if roundDepth == 0, squareDepth == 0, curlyDepth == 0 {
                let remainder = source[index...]
                let candidate: RuleCombination? = if remainder.hasPrefix("&&") {
                    .concatenate
                } else if remainder.hasPrefix("||") {
                    .fallback
                } else if remainder.hasPrefix("%%") {
                    .interleave
                } else {
                    nil
                }
                if let candidate {
                    if found == nil { found = candidate }
                    if found == candidate {
                        parts.append(String(source[partStart..<index]))
                        index = source.index(index, offsetBy: 2)
                        partStart = index
                        continue
                    }
                }
            }
            index = source.index(after: index)
        }
        guard quote == nil, roundDepth == 0, squareDepth == 0, curlyDepth == 0 else {
            throw RuleEngineError.malformedRule(rule: source, detail: "规则引号或括号未闭合")
        }
        if let found {
            parts.append(String(source[partStart...]))
            guard parts.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw RuleEngineError.malformedRule(rule: source, detail: "组合规则存在空分支")
            }
            return (parts, found)
        }
        return ([source], .single)
    }
}

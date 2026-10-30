import Foundation

public struct JSONPathEvaluator: Sendable {
    private enum Selector: Equatable {
        case key(String)
        case index(Int)
        case wildcard
    }

    private enum Segment: Equatable {
        case child(Selector)
        case recursive(Selector)
        case union([Selector])
        case slice(start: Int?, end: Int?, step: Int)
        case filter(String)
    }

    public init() {}

    // Legado's JSON rules also allow literal templates such as /book/{$.id}.
    // Balance braces and quoted strings instead of stopping at the first }.
    func evaluateRule(_ rule: String, in root: JSONValue) throws -> [JSONValue] {
        var cursor = rule.startIndex
        var output = ""
        var foundTemplate = false
        while let opening = rule.range(of: "{$.", range: cursor..<rule.endIndex) {
            foundTemplate = true
            output += rule[cursor..<opening.lowerBound]
            let start = rule.index(after: opening.lowerBound)
            var end = start
            var depth = 1
            var quote: Character?
            var escaped = false
            while end < rule.endIndex {
                let character = rule[end]
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if let activeQuote = quote {
                    if character == activeQuote { quote = nil }
                } else if character == "\"" || character == "'" { quote = character }
                else if character == "{" { depth += 1 }
                else if character == "}" {
                    depth -= 1
                    if depth == 0 { break }
                }
                end = rule.index(after: end)
            }
            guard end < rule.endIndex else {
                throw RuleEngineError.malformedRule(rule: rule, detail: "JSONPath 模板大括号未闭合")
            }
            let values = try evaluate(path: String(rule[start..<end]), in: root)
            output += RuleEvaluation(values: values).strings.joined(separator: "\n")
            cursor = rule.index(after: end)
        }
        if foundTemplate {
            output += rule[cursor...]
            return [.string(output)]
        }
        return try evaluate(path: rule.hasPrefix("$") ? rule : "$." + rule, in: root)
    }

    public func evaluate(path: String, in root: JSONValue) throws -> [JSONValue] {
        let segments = try parse(path)
        var current = [root]
        for segment in segments {
            try Task.checkCancellation()
            switch segment {
            case .child(let selector):
                current = current.flatMap { select(selector, from: $0) }
            case .recursive(let selector):
                current = current.flatMap { recursivelySelect(selector, from: $0) }
            case .union(let selectors):
                current = current.flatMap { node in selectors.flatMap { select($0, from: node) } }
            case .slice(let start, let end, let step):
                current = current.flatMap { slice($0, start: start, end: end, step: step) }
            case .filter(let predicate):
                var filtered: [JSONValue] = []
                for node in current {
                    guard case .array(let values) = node else { continue }
                    for value in values where try matches(predicate, candidate: value, root: root) {
                        filtered.append(value)
                    }
                }
                current = filtered
            }
        }
        return current
    }

    private func parse(_ path: String) throws -> [Segment] {
        let rule = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rule.first == "$" else {
            throw RuleEngineError.malformedRule(rule: path, detail: "JSONPath 必须以 $ 开始")
        }
        var segments: [Segment] = []
        var index = rule.index(after: rule.startIndex)
        while index < rule.endIndex {
            let character = rule[index]
            if character == "." {
                let next = rule.index(after: index)
                guard next < rule.endIndex else {
                    throw RuleEngineError.malformedRule(rule: path, detail: "JSONPath 不能以点结尾")
                }
                if rule[next] == "[" {
                    // Legacy sources use $.[*] as well as $[*].
                    index = next
                } else if rule[next] == "." {
                    index = rule.index(after: next)
                    let parsed = try parseDotSelector(rule, from: index, original: path)
                    segments.append(.recursive(parsed.selector))
                    index = parsed.next
                } else {
                    index = next
                    let parsed = try parseDotSelector(rule, from: index, original: path)
                    segments.append(.child(parsed.selector))
                    index = parsed.next
                }
            } else if character == "[" {
                let parsed = try parseBracket(rule, from: index, original: path)
                segments.append(parsed.segment)
                index = parsed.next
            } else {
                throw RuleEngineError.malformedRule(
                    rule: path,
                    detail: "JSONPath 在 \(rule.distance(from: rule.startIndex, to: index)) 处包含意外字符"
                )
            }
        }
        return segments
    }

    private func parseDotSelector(
        _ rule: String,
        from start: String.Index,
        original: String
    ) throws -> (selector: Selector, next: String.Index) {
        if rule[start] == "*" {
            return (.wildcard, rule.index(after: start))
        }
        var end = start
        while end < rule.endIndex, rule[end] != ".", rule[end] != "[" {
            end = rule.index(after: end)
        }
        let key = String(rule[start..<end])
        guard !key.isEmpty else {
            throw RuleEngineError.malformedRule(rule: original, detail: "JSONPath 属性名不能为空")
        }
        return (.key(key), end)
    }

    private func parseBracket(
        _ rule: String,
        from open: String.Index,
        original: String
    ) throws -> (segment: Segment, next: String.Index) {
        var index = rule.index(after: open)
        var quote: Character?
        var escaped = false
        var depth = 1
        while index < rule.endIndex {
            let character = rule[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "[" {
                depth += 1
            } else if character == "]" {
                depth -= 1
                guard depth == 0 else {
                    index = rule.index(after: index)
                    continue
                }
                let content = String(rule[rule.index(after: open)..<index])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let segment = try parseBracketContent(content, original: original)
                return (segment, rule.index(after: index))
            }
            index = rule.index(after: index)
        }
        throw RuleEngineError.malformedRule(rule: original, detail: "JSONPath 方括号未闭合")
    }

    private func parseBracketContent(_ content: String, original: String) throws -> Segment {
        guard !content.isEmpty else {
            throw RuleEngineError.malformedRule(rule: original, detail: "JSONPath 方括号不能为空")
        }
        if content.hasPrefix("?(") && content.hasSuffix(")") {
            let predicate = String(content.dropFirst(2).dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !predicate.isEmpty else {
                throw RuleEngineError.malformedRule(rule: original, detail: "JSONPath filter 不能为空")
            }
            return .filter(predicate)
        }
        if content == "*" { return .child(.wildcard) }
        if content.contains(":") {
            let values = content.split(separator: ":", omittingEmptySubsequences: false)
            guard (2 ... 3).contains(values.count),
                  let step = values.count == 3 ? Int(values[2]) : 1,
                  step != 0 else {
                throw RuleEngineError.malformedRule(rule: original, detail: "JSONPath slice 格式无效")
            }
            return .slice(
                start: values[0].isEmpty ? nil : Int(values[0]),
                end: values[1].isEmpty ? nil : Int(values[1]),
                step: step
            )
        }
        let parts = splitCommaSeparated(content)
        let selectors = try parts.map { try parseSelector($0, original: original) }
        return selectors.count == 1 ? .child(selectors[0]) : .union(selectors)
    }

    private func splitCommaSeparated(_ content: String) -> [String] {
        var parts: [String] = []
        var quote: Character?
        var escaped = false
        var start = content.startIndex
        var index = start
        while index < content.endIndex {
            let character = content[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "," {
                parts.append(String(content[start..<index]).trimmingCharacters(in: .whitespaces))
                start = content.index(after: index)
            }
            index = content.index(after: index)
        }
        parts.append(String(content[start...]).trimmingCharacters(in: .whitespaces))
        return parts
    }

    private func parseSelector(_ source: String, original: String) throws -> Selector {
        if source == "*" { return .wildcard }
        if let index = Int(source) { return .index(index) }
        if source.count >= 2,
           let first = source.first,
           first == "\"" || first == "'",
           source.last == first {
            let key = String(source.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\(first)", with: String(first))
                .replacingOccurrences(of: "\\\\", with: "\\")
            return .key(key)
        }
        throw RuleEngineError.malformedRule(rule: original, detail: "不支持的 JSONPath 选择器：\(source)")
    }

    private func select(_ selector: Selector, from value: JSONValue) -> [JSONValue] {
        switch (selector, value) {
        case (.key(let key), .object(let object)):
            return object[key].map { [$0] } ?? []
        case (.index(let index), .array(let array)):
            let resolved = index >= 0 ? index : array.count + index
            return array.indices.contains(resolved) ? [array[resolved]] : []
        case (.wildcard, .object(let object)):
            return object.keys.sorted().compactMap { object[$0] }
        case (.wildcard, .array(let array)):
            return array
        default:
            return []
        }
    }

    private func recursivelySelect(_ selector: Selector, from value: JSONValue) -> [JSONValue] {
        var result = select(selector, from: value)
        switch value {
        case .object(let object):
            for key in object.keys.sorted() {
                if let child = object[key] { result += recursivelySelect(selector, from: child) }
            }
        case .array(let array):
            for child in array { result += recursivelySelect(selector, from: child) }
        default:
            break
        }
        return result
    }

    private func slice(_ value: JSONValue, start: Int?, end: Int?, step: Int) -> [JSONValue] {
        guard case .array(let array) = value, !array.isEmpty else { return [] }
        let count = array.count
        let defaultStart = step > 0 ? 0 : count - 1
        let defaultEnd = step > 0 ? count : -1
        var cursor = normalize(start ?? defaultStart, count: count, allowEnd: true)
        let boundary = end == nil && step < 0 ? -1 : normalize(end ?? defaultEnd, count: count, allowEnd: true)
        var result: [JSONValue] = []
        while step > 0 ? cursor < boundary : cursor > boundary {
            if array.indices.contains(cursor) { result.append(array[cursor]) }
            cursor += step
        }
        return result
    }

    private func normalize(_ index: Int, count: Int, allowEnd: Bool) -> Int {
        let value = index < 0 ? count + index : index
        return min(max(value, 0), allowEnd ? count : count - 1)
    }

    private func matches(_ source: String, candidate: JSONValue, root: JSONValue) throws -> Bool {
        let predicate = stripOuterParentheses(source.trimmingCharacters(in: .whitespacesAndNewlines))
        if let parts = splitLogical(predicate, operator: "||"), parts.count > 1 {
            for part in parts where try matches(part, candidate: candidate, root: root) { return true }
            return false
        }
        if let parts = splitLogical(predicate, operator: "&&"), parts.count > 1 {
            for part in parts where !(try matches(part, candidate: candidate, root: root)) { return false }
            return true
        }
        if predicate.hasPrefix("!") && !predicate.hasPrefix("!=") {
            return try !matches(String(predicate.dropFirst()), candidate: candidate, root: root)
        }
        if let comparison = findComparison(predicate) {
            let lhs = try resolveOperand(String(predicate[..<comparison.range.lowerBound]), candidate: candidate, root: root)
            let rhs = try resolveOperand(String(predicate[comparison.range.upperBound...]), candidate: candidate, root: root)
            guard !lhs.isEmpty, !rhs.isEmpty else { return false }
            return try lhs.contains { left in
                try rhs.contains { right in try compare(left, right, operation: comparison.operation) }
            }
        }
        let values = try resolveOperand(predicate, candidate: candidate, root: root)
        return values.contains(where: isTruthy)
    }

    private func splitLogical(_ source: String, operator operation: String) -> [String]? {
        var parts: [String] = []
        var quote: Character?
        var regex = false
        var escaped = false
        var roundDepth = 0
        var squareDepth = 0
        var start = source.startIndex
        var index = start
        while index < source.endIndex {
            let character = source[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "/" {
                regex.toggle()
            } else if !regex {
                if character == "(" { roundDepth += 1 }
                if character == ")" { roundDepth -= 1 }
                if character == "[" { squareDepth += 1 }
                if character == "]" { squareDepth -= 1 }
                if roundDepth == 0, squareDepth == 0, source[index...].hasPrefix(operation) {
                    parts.append(String(source[start..<index]).trimmingCharacters(in: .whitespaces))
                    index = source.index(index, offsetBy: operation.count)
                    start = index
                    continue
                }
            }
            index = source.index(after: index)
        }
        guard !parts.isEmpty else { return nil }
        parts.append(String(source[start...]).trimmingCharacters(in: .whitespaces))
        return parts
    }

    private func stripOuterParentheses(_ source: String) -> String {
        var value = source
        while value.first == "(", value.last == ")", outerParenthesesEncloseAll(value) {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    private func outerParenthesesEncloseAll(_ source: String) -> Bool {
        var depth = 0
        var quote: Character?
        var escaped = false
        for index in source.indices {
            let character = source[index]
            if escaped { escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
                continue
            }
            if character == "\"" || character == "'" { quote = character; continue }
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth == 0 && index != source.index(before: source.endIndex) { return false }
            }
        }
        return depth == 0
    }

    private func findComparison(_ source: String) -> (range: Range<String.Index>, operation: String)? {
        let operations = ["==", "!=", ">=", "<=", "=~", ">", "<"]
        var quote: Character?
        var escaped = false
        var roundDepth = 0
        var squareDepth = 0
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else {
                if character == "(" { roundDepth += 1 }
                if character == ")" { roundDepth -= 1 }
                if character == "[" { squareDepth += 1 }
                if character == "]" { squareDepth -= 1 }
                if roundDepth == 0, squareDepth == 0 {
                    for operation in operations where source[index...].hasPrefix(operation) {
                        return (index..<source.index(index, offsetBy: operation.count), operation)
                    }
                }
            }
            index = source.index(after: index)
        }
        return nil
    }

    private func resolveOperand(_ source: String, candidate: JSONValue, root: JSONValue) throws -> [JSONValue] {
        let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw RuleEngineError.malformedRule(rule: source, detail: "JSONPath filter 比较值不能为空")
        }
        if value.first == "@" || value.first == "$" {
            return try resolvePath(value, base: value.first == "@" ? candidate : root)
        }
        if value == "true" { return [.bool(true)] }
        if value == "false" { return [.bool(false)] }
        if value == "null" { return [.null] }
        if let number = Double(value) { return [.number(number)] }
        if let first = value.first, (first == "\"" || first == "'"), value.last == first {
            let inner = String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\(first)", with: String(first))
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\\\", with: "\\")
            return [.string(inner)]
        }
        if value.first == "/", value.dropFirst().lastIndex(of: "/") != nil {
            return [.string(value)]
        }
        throw RuleEngineError.malformedRule(rule: source, detail: "不支持的 JSONPath filter 操作数：\(value)")
    }

    private func resolvePath(_ path: String, base: JSONValue) throws -> [JSONValue] {
        var current = [base]
        var index = path.index(after: path.startIndex)
        while index < path.endIndex {
            if path[index] == "." {
                index = path.index(after: index)
                var end = index
                while end < path.endIndex, path[end] != ".", path[end] != "[" { end = path.index(after: end) }
                let key = String(path[index..<end])
                guard !key.isEmpty else { throw RuleEngineError.malformedRule(rule: path, detail: "filter 路径属性为空") }
                current = current.flatMap { select(.key(key), from: $0) }
                index = end
            } else if path[index] == "[" {
                guard let close = path[index...].firstIndex(of: "]") else {
                    throw RuleEngineError.malformedRule(rule: path, detail: "filter 路径方括号未闭合")
                }
                let token = String(path[path.index(after: index)..<close]).trimmingCharacters(in: .whitespaces)
                let selector = try parseSelector(token, original: path)
                current = current.flatMap { select(selector, from: $0) }
                index = path.index(after: close)
            } else {
                throw RuleEngineError.malformedRule(rule: path, detail: "filter 路径包含意外字符")
            }
        }
        return current
    }

    private func compare(_ lhs: JSONValue, _ rhs: JSONValue, operation: String) throws -> Bool {
        if operation == "=~" {
            let literal = rhs.stringValue
            guard literal.first == "/", let closing = literal.dropFirst().lastIndex(of: "/") else {
                throw RuleEngineError.malformedRule(rule: literal, detail: "filter 正则必须写成 /pattern/flags")
            }
            let pattern = String(literal[literal.index(after: literal.startIndex)..<closing])
            guard pattern.count <= 1_024 else {
                throw RuleEngineError.unsupportedRule(rule: literal, feature: "过长 JSONPath filter 正则")
            }
            let flags = literal[literal.index(after: closing)...]
            let options: NSRegularExpression.Options = flags.contains("i") ? .caseInsensitive : []
            let regex = try NSRegularExpression(pattern: pattern, options: options)
            let range = NSRange(lhs.stringValue.startIndex..., in: lhs.stringValue)
            return regex.firstMatch(in: lhs.stringValue, range: range) != nil
        }
        if operation == "==" || operation == "!=" {
            let equal: Bool
            switch (lhs, rhs) {
            case (.number(let left), .number(let right)): equal = left == right
            case (.bool(let left), .bool(let right)): equal = left == right
            case (.null, .null): equal = true
            default: equal = lhs.stringValue == rhs.stringValue
            }
            return operation == "==" ? equal : !equal
        }
        let ordering: ComparisonResult
        if case .number(let left) = lhs, case .number(let right) = rhs {
            ordering = left < right ? .orderedAscending : left > right ? .orderedDescending : .orderedSame
        } else {
            ordering = lhs.stringValue.compare(rhs.stringValue, options: .numeric)
        }
        return switch operation {
        case ">": ordering == .orderedDescending
        case ">=": ordering != .orderedAscending
        case "<": ordering == .orderedAscending
        case "<=": ordering != .orderedDescending
        default: false
        }
    }

    private func isTruthy(_ value: JSONValue) -> Bool {
        switch value {
        case .null: false
        case .bool(let value): value
        case .number(let value): value != 0
        case .string(let value): !value.isEmpty
        case .array(let value): !value.isEmpty
        case .object(let value): !value.isEmpty
        }
    }
}

import Foundation

/// Small NSRegularExpression helpers so the JavaScript regexes in v4 port
/// one-to-one (and keep working on every Foundation, without Swift Regex).
enum RX {
    private static var cache: [String: NSRegularExpression] = [:]
    private static let lock = NSLock()

    static func regex(_ pattern: String, ignoreCase: Bool = false) -> NSRegularExpression {
        let key = (ignoreCase ? "i:" : "s:") + pattern
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let options: NSRegularExpression.Options = ignoreCase ? [.caseInsensitive] : []
        // Patterns are compile-time constants in this module; a typo is a programmer error.
        let compiled = try! NSRegularExpression(pattern: pattern, options: options)
        cache[key] = compiled
        return compiled
    }

    /// `pattern.test(string)`
    static func test(_ pattern: String, _ string: String, ignoreCase: Bool = false) -> Bool {
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex(pattern, ignoreCase: ignoreCase).firstMatch(in: string, options: [], range: range) != nil
    }

    /// `string.match(pattern)`: the whole match followed by each capture group
    /// ("" for a group that did not participate), or nil when nothing matched.
    static func match(_ pattern: String, _ string: String, ignoreCase: Bool = false) -> [String]? {
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let result = regex(pattern, ignoreCase: ignoreCase).firstMatch(in: string, options: [], range: range) else {
            return nil
        }
        var groups: [String] = []
        for index in 0..<result.numberOfRanges {
            let groupRange = result.range(at: index)
            if groupRange.location != NSNotFound, let swiftRange = Range(groupRange, in: string) {
                groups.append(String(string[swiftRange]))
            } else {
                groups.append("")
            }
        }
        return groups
    }

    /// `string.replace(/pattern/g, template)`
    static func replaceAll(_ pattern: String, in string: String, with template: String, ignoreCase: Bool = false) -> String {
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex(pattern, ignoreCase: ignoreCase).stringByReplacingMatches(in: string, options: [], range: range, withTemplate: template)
    }
}

extension Array {
    /// A sort that keeps equal elements in their original order, like
    /// JavaScript's `Array.prototype.sort` (stable since ES2019).
    func stableSorted(by areInIncreasingOrder: (Element, Element) -> Bool) -> [Element] {
        enumerated()
            .sorted { lhs, rhs in
                if areInIncreasingOrder(lhs.element, rhs.element) { return true }
                if areInIncreasingOrder(rhs.element, lhs.element) { return false }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}

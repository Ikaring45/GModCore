import Foundation

struct LuaPatternMatch {
    let start: Int          // zero-based byte offset, inclusive
    let end: Int            // zero-based byte offset, exclusive
    let captures: [LuaValue]
}

private struct LuaPatternCapture {
    var start: Int
    var end: Int?
    var positionOnly: Bool
}

/// Byte-oriented implementation of the Lua 5.1 pattern language used by
/// string.find/match/gmatch/gsub. It deliberately implements Lua patterns,
/// not regular expressions.
final class LuaPatternMatcher {
    private let subject: [UInt8]
    private let pattern: [UInt8]
    private let anchored: Bool

    init(subject: LuaString, pattern: LuaString) {
        self.subject = subject.bytes
        if pattern.bytes.first == 94 { // ^
            self.anchored = true
            self.pattern = Array(pattern.bytes.dropFirst())
        } else {
            self.anchored = false
            self.pattern = pattern.bytes
        }
    }

    func firstMatch(from requestedStart: Int = 0) throws -> LuaPatternMatch? {
        guard requestedStart <= subject.count else { return nil }
        let start = max(0, requestedStart)
        if anchored {
            guard start == 0 else { return nil }
            return try attempt(at: 0)
        }

        var offset = start
        while offset <= subject.count {
            if let match = try attempt(at: offset) { return match }
            offset += 1
        }
        return nil
    }

    private func attempt(at start: Int) throws -> LuaPatternMatch? {
        if let result = try match(si: start, pi: 0, captures: []) {
            guard result.captures.allSatisfy({ $0.positionOnly || $0.end != nil }) else {
                throw LuaError.runtime("unfinished capture")
            }
            let values = materialize(result.captures)
            return LuaPatternMatch(start: start, end: result.si, captures: values)
        }
        return nil
    }

    private struct State {
        var si: Int
        var captures: [LuaPatternCapture]
    }

    private func match(si: Int, pi: Int, captures: [LuaPatternCapture]) throws -> State? {
        if pi >= pattern.count { return State(si: si, captures: captures) }

        // End anchor.
        if pattern[pi] == 36, pi + 1 == pattern.count { // $
            return si == subject.count ? State(si: si, captures: captures) : nil
        }

        // Capture start / position capture.
        if pattern[pi] == 40 { // (
            if pi + 1 < pattern.count, pattern[pi + 1] == 41 { // ()
                var next = captures
                next.append(LuaPatternCapture(start: si, end: si, positionOnly: true))
                return try match(si: si, pi: pi + 2, captures: next)
            }
            var next = captures
            next.append(LuaPatternCapture(start: si, end: nil, positionOnly: false))
            return try match(si: si, pi: pi + 1, captures: next)
        }

        // Capture end.
        if pattern[pi] == 41 { // )
            guard let index = captures.lastIndex(where: { $0.end == nil && !$0.positionOnly }) else {
                throw LuaError.runtime("invalid pattern capture")
            }
            var next = captures
            next[index].end = si
            return try match(si: si, pi: pi + 1, captures: next)
        }

        // Back reference %1 .. %9. Capture zero is only meaningful in a
        // gsub replacement template, never inside a Lua pattern.
        if pattern[pi] == 37, pi + 1 < pattern.count, pattern[pi + 1] == 48 {
            throw LuaError.runtime("invalid capture index")
        }
        if pattern[pi] == 37, pi + 1 < pattern.count,
           pattern[pi + 1] >= 49, pattern[pi + 1] <= 57 {
            let captureIndex = Int(pattern[pi + 1] - 49)
            guard captureIndex < captures.count,
                  let end = captures[captureIndex].end,
                  !captures[captureIndex].positionOnly else {
                throw LuaError.runtime("invalid capture index")
            }
            let bytes = subject[captures[captureIndex].start..<end]
            guard si + bytes.count <= subject.count else { return nil }
            if subject[si..<(si + bytes.count)].elementsEqual(bytes) {
                return try match(si: si + bytes.count, pi: pi + 2, captures: captures)
            }
            return nil
        }

        // Balanced pair %bxy.
        if pattern[pi] == 37, pi + 1 < pattern.count, pattern[pi + 1] == 98 { // %b
            guard pi + 3 < pattern.count else { throw LuaError.runtime("malformed pattern (missing arguments to %b)") }
            guard let end = matchBalance(si: si, open: pattern[pi + 2], close: pattern[pi + 3]) else { return nil }
            return try match(si: end, pi: pi + 4, captures: captures)
        }

        // Frontier %f[set].
        if pattern[pi] == 37, pi + 1 < pattern.count, pattern[pi + 1] == 102 { // %f
            guard pi + 2 < pattern.count, pattern[pi + 2] == 91 else {
                throw LuaError.runtime("missing '[' after '%f' in pattern")
            }
            let setEnd = try classEnd(from: pi + 2)
            let previous: UInt8 = si == 0 ? 0 : subject[si - 1]
            let current: UInt8 = si == subject.count ? 0 : subject[si]
            let prevIn = matchBracketClass(previous, start: pi + 2, end: setEnd)
            let curIn = matchBracketClass(current, start: pi + 2, end: setEnd)
            guard !prevIn && curIn else { return nil }
            return try match(si: si, pi: setEnd, captures: captures)
        }

        let itemEnd = try classEnd(from: pi)
        let suffix: UInt8? = itemEnd < pattern.count ? pattern[itemEnd] : nil
        let matches = si < subject.count && singleMatch(subject[si], start: pi, end: itemEnd)

        switch suffix {
        case 63: // ?
            if matches, let result = try match(si: si + 1, pi: itemEnd + 1, captures: captures) { return result }
            return try match(si: si, pi: itemEnd + 1, captures: captures)

        case 42: // * greedy
            var max = si
            while max < subject.count && singleMatch(subject[max], start: pi, end: itemEnd) { max += 1 }
            var candidate = max
            while candidate >= si {
                if let result = try match(si: candidate, pi: itemEnd + 1, captures: captures) { return result }
                if candidate == 0 { break }
                candidate -= 1
            }
            return nil

        case 43: // + greedy
            guard matches else { return nil }
            var max = si + 1
            while max < subject.count && singleMatch(subject[max], start: pi, end: itemEnd) { max += 1 }
            var candidate = max
            while candidate >= si + 1 {
                if let result = try match(si: candidate, pi: itemEnd + 1, captures: captures) { return result }
                candidate -= 1
            }
            return nil

        case 45: // - non-greedy
            var candidate = si
            while true {
                if let result = try match(si: candidate, pi: itemEnd + 1, captures: captures) { return result }
                guard candidate < subject.count,
                      singleMatch(subject[candidate], start: pi, end: itemEnd) else { return nil }
                candidate += 1
            }

        default:
            guard matches else { return nil }
            return try match(si: si + 1, pi: itemEnd, captures: captures)
        }
    }

    /// Returns the index just after one pattern class/item.
    private func classEnd(from start: Int) throws -> Int {
        guard start < pattern.count else { throw LuaError.runtime("malformed pattern") }
        if pattern[start] == 37 { // %x
            guard start + 1 < pattern.count else { throw LuaError.runtime("malformed pattern (ends with '%')") }
            return start + 2
        }
        if pattern[start] != 91 { return start + 1 } // [

        var i = start + 1
        if i < pattern.count, pattern[i] == 94 { i += 1 } // ^
        if i < pattern.count, pattern[i] == 93 { i += 1 } // ] literal first
        while i < pattern.count {
            if pattern[i] == 93 { return i + 1 }
            if pattern[i] == 37, i + 1 < pattern.count { i += 2 }
            else { i += 1 }
        }
        throw LuaError.runtime("malformed pattern (missing ']')")
    }

    private func singleMatch(_ byte: UInt8, start: Int, end: Int) -> Bool {
        let first = pattern[start]
        if first == 46 { return true } // .
        if first == 37, start + 1 < end { return matchClass(byte, pattern[start + 1]) }
        if first == 91 { return matchBracketClass(byte, start: start, end: end) }
        return byte == first
    }

    private func matchClass(_ c: UInt8, _ code: UInt8) -> Bool {
        let lower = code >= 65 && code <= 90 ? code + 32 : code
        let result: Bool
        switch lower {
        case 97: result = isAlpha(c)             // a
        case 99: result = c < 32 || c == 127     // c
        case 100: result = isDigit(c)            // d
        case 108: result = c >= 97 && c <= 122   // l
        case 112: result = isPunct(c)            // p
        case 115: result = isSpace(c)            // s
        case 117: result = c >= 65 && c <= 90    // u
        case 119: result = isAlpha(c) || isDigit(c) // w
        case 120: result = isHex(c)              // x
        case 122: result = c == 0                // z
        default: return c == code
        }
        return code >= 65 && code <= 90 ? !result : result
    }

    private func matchBracketClass(_ c: UInt8, start: Int, end: Int) -> Bool {
        var i = start + 1
        var inverted = false
        if i < end, pattern[i] == 94 { inverted = true; i += 1 }
        var matched = false

        while i < end - 1 {
            if pattern[i] == 37, i + 1 < end - 1 {
                if matchClass(c, pattern[i + 1]) { matched = true }
                i += 2
                continue
            }
            if i + 2 < end - 1, pattern[i + 1] == 45 { // range
                if c >= pattern[i] && c <= pattern[i + 2] { matched = true }
                i += 3
                continue
            }
            if c == pattern[i] { matched = true }
            i += 1
        }
        return inverted ? !matched : matched
    }

    private func matchBalance(si: Int, open: UInt8, close: UInt8) -> Int? {
        guard si < subject.count, subject[si] == open else { return nil }
        var depth = 1
        var i = si + 1
        while i < subject.count {
            if subject[i] == close {
                depth -= 1
                if depth == 0 { return i + 1 }
            } else if subject[i] == open {
                depth += 1
            }
            i += 1
        }
        return nil
    }

    private func materialize(_ captures: [LuaPatternCapture]) -> [LuaValue] {
        captures.compactMap { capture in
            if capture.positionOnly { return .number(Double(capture.start + 1)) }
            guard let end = capture.end else { return nil }
            return .string(LuaString(bytes: Array(subject[capture.start..<end])))
        }
    }

    private func isAlpha(_ c: UInt8) -> Bool { (65...90).contains(c) || (97...122).contains(c) }
    private func isDigit(_ c: UInt8) -> Bool { (48...57).contains(c) }
    private func isHex(_ c: UInt8) -> Bool { isDigit(c) || (65...70).contains(c) || (97...102).contains(c) }
    private func isSpace(_ c: UInt8) -> Bool { c == 32 || (9...13).contains(c) }
    private func isPunct(_ c: UInt8) -> Bool {
        c >= 33 && c <= 126 && !isAlpha(c) && !isDigit(c) && c != 32
    }
}

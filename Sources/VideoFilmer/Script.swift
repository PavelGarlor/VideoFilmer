import AppKit

enum PrompterStyle {
    static let upcoming = NSColor(white: 0.96, alpha: 1)
    static let spoken = NSColor(white: 0.33, alpha: 1)
    static let currentText = NSColor(white: 0.07, alpha: 1)
    static let currentBackground = NSColor(red: 1, green: 0.85, blue: 0.3, alpha: 1)
    static let anchor = NSColor(red: 0.49, green: 0.86, blue: 0.6, alpha: 1)
    static let cue = NSColor(red: 0.35, green: 0.66, blue: 1, alpha: 1)
}

struct ScriptWord {
    let range: NSRange
    let norm: String
    var weight: Double
}

struct ScriptAnchor {
    let wordIndex: Int
    let time: Double
}

/// One line of the script, as written and as shown.
struct ScriptLine: Equatable {
    /// Row in the script text (blank rows included).
    let sourceIndex: Int
    /// Bullet / timestamp text before `body` in the source row.
    let prefix: String
    /// The line without its timestamp.
    let body: String
    /// Where the line sits in the teleprompter text.
    let range: NSRange
    let firstWord: Int
    let wordCount: Int
    let anchor: Double?
}

/// How much time one line gets, and so how fast it has to be read.
struct PaceBlock {
    let line: ScriptLine
    var start: Double
    var end: Double
    var wpm: Double { Double(line.wordCount) / max(0.1, end - start) * 60 }
}

/// The script as shown in the teleprompter: styled text plus the readable words in it.
///
/// - `[0:12]` (or `0:12 -`, `[0:12 - 0:18]`) at the start of a line pins that line to the video time.
/// - `[notes]` and `(notes)` are shown small and skipped.
/// - `SPEAKER:` labels in capitals are shown small and skipped.
struct ParsedScript {
    var text = NSAttributedString()
    var words: [ScriptWord] = []
    var anchors: [ScriptAnchor] = []
    var lines: [ScriptLine] = []

    private static let timestamp = try! NSRegularExpression(
        pattern: #"^\s*[\[(]?(\d{1,2}):(\d{2})([.,]\d+)?(?:\s*[-–—]+\s*\d{1,2}:\d{2}(?:[.,]\d+)?)?[\])]?\s*[-–—:|]?\s*"#)
    private static let speaker = try! NSRegularExpression(pattern: #"^\s*([A-Z][A-Z0-9 .'’/()-]{0,24}):\s+"#)
    private static let bullet = try! NSRegularExpression(pattern: #"^\s*(#{1,6}|[-*•])\s+"#)
    private static let token = try! NSRegularExpression(pattern: #"\[[^\]]*\]|\([^)]*\)|\S+"#)

    static func parse(_ source: String, fontSize: Double) -> ParsedScript {
        let size = CGFloat(fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = size * 0.22
        paragraph.paragraphSpacing = size * 0.45
        let wordAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .semibold),
            .foregroundColor: PrompterStyle.upcoming,
            .paragraphStyle: paragraph,
        ]
        let dimAttrs = wordAttrs.merging([.foregroundColor: PrompterStyle.spoken]) { $1 }
        func tagAttrs(_ color: NSColor) -> [NSAttributedString.Key: Any] {
            [.font: NSFont.systemFont(ofSize: size * 0.45, weight: .medium), .foregroundColor: color,
             .paragraphStyle: paragraph, .baselineOffset: size * 0.12]
        }

        let out = NSMutableAttributedString()
        var result = ParsedScript()

        if source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append(NSAttributedString(string: "Paste your script in the sidebar…",
                                          attributes: tagAttrs(.secondaryLabelColor).merging([.font: NSFont.systemFont(ofSize: 20)]) { $1 }))
            result.text = out
            return result
        }

        for (sourceIndex, rawLine) in rows(of: source).enumerated() {
            var line = rawLine
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            line = replaceFirst(bullet, in: line)
            let lineStart = out.length
            var anchor: Double?

            if let m = firstMatch(timestamp, in: line) {
                let ns = line as NSString
                let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
                var seconds = Double(ns.substring(with: m.range(at: 2))) ?? 0
                if m.range(at: 3).location != NSNotFound {
                    seconds += Double("0." + ns.substring(with: m.range(at: 3)).dropFirst()) ?? 0
                }
                let time = minutes * 60 + seconds
                result.anchors.append(ScriptAnchor(wordIndex: result.words.count, time: time))
                anchor = time
                out.append(NSAttributedString(string: formatTime(time) + "  ", attributes: tagAttrs(PrompterStyle.anchor)))
                line = ns.substring(from: m.range.upperBound)
            }
            let body = line
            if let m = firstMatch(speaker, in: line) {
                let ns = line as NSString
                out.append(NSAttributedString(string: ns.substring(with: m.range(at: 1)) + "  ", attributes: tagAttrs(PrompterStyle.cue)))
                line = ns.substring(from: m.range.upperBound)
            }

            let wordsBefore = result.words.count
            let ns = line as NSString
            for match in token.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let tok = ns.substring(with: match.range)
                if tok.count > 1, (tok.hasPrefix("[") && tok.hasSuffix("]")) || (tok.hasPrefix("(") && tok.hasSuffix(")")) {
                    out.append(NSAttributedString(string: tok + " ", attributes: tagAttrs(PrompterStyle.cue)))
                    continue
                }
                let display = tok.replacingOccurrences(of: "*", with: "")
                let norm = ScriptMatcher.normalize(display)
                if norm.isEmpty {
                    out.append(NSAttributedString(string: display + " ", attributes: dimAttrs))
                    continue
                }
                var weight = 1.0 + (norm.count > 8 ? 0.3 : 0)
                if display.range(of: #"[.!?…]["'”’)\]]*$"#, options: .regularExpression) != nil {
                    weight += 1
                } else if display.range(of: #"[,;:—–]["'”’)\]]*$"#, options: .regularExpression) != nil {
                    weight += 0.4
                }
                let range = NSRange(location: out.length, length: (display as NSString).length)
                out.append(NSAttributedString(string: display, attributes: wordAttrs))
                out.append(NSAttributedString(string: " ", attributes: wordAttrs))
                result.words.append(ScriptWord(range: range, norm: norm, weight: weight))
            }
            if result.words.count > wordsBefore { result.words[result.words.count - 1].weight += 0.5 }
            out.append(NSAttributedString(string: "\n", attributes: wordAttrs))
            result.lines.append(ScriptLine(
                sourceIndex: sourceIndex, prefix: String(rawLine.dropLast(body.count)), body: body,
                range: NSRange(location: lineStart, length: out.length - lineStart),
                firstWord: wordsBefore, wordCount: result.words.count - wordsBefore, anchor: anchor))
        }
        // Room to scroll the last lines up to the reading position.
        out.append(NSAttributedString(string: String(repeating: "\n", count: 14), attributes: wordAttrs))
        result.text = out
        return result
    }

    /// When each word should be read, in seconds, plus when the script ends.
    /// With a video duration: spread over the video, honouring anchors. Otherwise: at `wpm`.
    func times(videoDuration: Double?, wpm: Double) -> (times: [Double], end: Double) {
        let n = words.count
        guard n > 0 else { return ([], 0) }
        var cum = [0.0]
        for w in words { cum.append(cum[cum.count - 1] + w.weight) }

        guard let duration = videoDuration, duration > 0 else {
            // One weight unit ≈ one word at the chosen speed.
            let perUnit = 60 / max(wpm, 30)
            return (cum.dropLast().map { $0 * perUnit }, cum[n] * perUnit)
        }

        var points: [ScriptAnchor] = []
        for a in anchors where a.time < duration {
            if let last = points.last {
                if a.wordIndex == last.wordIndex { points.removeLast() }
                else if a.time <= last.time { continue }
            }
            if let last = points.last, a.time <= last.time { continue }
            points.append(a)
        }
        if points.first.map({ $0.wordIndex > 0 }) ?? true { points.insert(ScriptAnchor(wordIndex: 0, time: 0), at: 0) }
        points.append(ScriptAnchor(wordIndex: n, time: duration))

        var times = [Double](repeating: 0, count: n)
        for (a, b) in zip(points, points.dropFirst()) where b.wordIndex > a.wordIndex {
            let span = cum[b.wordIndex] - cum[a.wordIndex]
            for i in a.wordIndex..<b.wordIndex {
                times[i] = a.time + (span > 0 ? (cum[i] - cum[a.wordIndex]) / span : 0) * (b.time - a.time)
            }
        }
        return (times, duration)
    }

    // MARK: - Lines and pace

    /// The script's rows, the way `parse` numbers them.
    static func rows(of source: String) -> [String] {
        source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    /// Time given to each line that has words. Without a video, lines run at `wpm`.
    func paceBlocks(videoDuration: Double?, wpm: Double) -> [PaceBlock] {
        let (t, end) = times(videoDuration: videoDuration, wpm: wpm)
        let spoken = lines.filter { $0.wordCount > 0 }
        return spoken.enumerated().map { i, line in
            PaceBlock(line: line, start: t[line.firstWord], end: i + 1 < spoken.count ? t[spoken[i + 1].firstWord] : end)
        }
    }

    /// The script with `body` in place of that line (an empty body removes the line).
    static func replacingBody(in source: String, line: ScriptLine, with body: String) -> String {
        var rows = rows(of: source)
        guard rows.indices.contains(line.sourceIndex) else { return source }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        if trimmed.isEmpty {
            rows.remove(at: line.sourceIndex)
        } else {
            rows[line.sourceIndex] = line.prefix + trimmed
        }
        return rows.joined(separator: "\n")
    }

    /// The script with each line in `starts` (keyed by source row) pinned to that time.
    static func applyingStarts(_ starts: [Int: Double], to source: String, lines: [ScriptLine]) -> String {
        var rows = rows(of: source)
        for line in lines {
            guard let t = starts[line.sourceIndex], rows.indices.contains(line.sourceIndex) else { continue }
            rows[line.sourceIndex] = stamp(t) + " " + line.body
        }
        return rows.joined(separator: "\n")
    }

    /// `[m:ss]`, or `[m:ss.s]` for fractions.
    static func stamp(_ time: Double) -> String {
        let t = (max(0, time) * 10).rounded() / 10
        let minutes = Int(t) / 60
        let seconds = t - Double(minutes * 60)
        return seconds == seconds.rounded()
            ? String(format: "[%d:%02d]", minutes, Int(seconds))
            : String(format: "[%d:%04.1f]", minutes, seconds)
    }

    private static func firstMatch(_ re: NSRegularExpression, in s: String) -> NSTextCheckingResult? {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length))
    }

    private static func replaceFirst(_ re: NSRegularExpression, in s: String) -> String {
        guard let m = firstMatch(re, in: s) else { return s }
        return (s as NSString).replacingCharacters(in: m.range, with: "")
    }
}

/// Matches recognized speech to the script.
enum ScriptMatcher {
    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        return String(String.UnicodeScalarView(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    static func words(in transcript: String) -> [String] {
        transcript.split(whereSeparator: { $0.isWhitespace }).map { normalize(String($0)) }.filter { !$0.isEmpty }
    }

    /// Moves `ptr` past `heard` if it matches one of the next few script words.
    static func advance(_ heard: String, from ptr: Int, in words: [ScriptWord]) -> Int {
        let lookahead = heard.count <= 3 ? 3 : 12
        var i = ptr
        while i < words.count, i < ptr + lookahead {
            if similar(heard, words[i].norm) { return i + 1 }
            i += 1
        }
        return ptr
    }

    static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if min(a.count, b.count) >= 4, a.hasPrefix(b) || b.hasPrefix(a) { return true }
        if max(a.count, b.count) >= 5 { return levenshtein(a, b) <= (max(a.count, b.count) >= 8 ? 2 : 1) }
        return false
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = prev
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}

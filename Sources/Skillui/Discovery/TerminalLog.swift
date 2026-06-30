import Foundation

/// Renders raw process output (with terminal control codes) into clean, readable log text.
///
/// `skills experimental_install` drives an interactive spinner: it repaints one line over and over
/// with `ESC[999D` (cursor to column 0) + `ESC[J` (erase) between frames. Captured without a TTY,
/// those escapes leak through as literal `[999D[J` and every frame stacks into its own line — turning
/// "Cloning repository…" into hundreds of garbled lines. This collapses each repainted line to its
/// final frame, strips the remaining ANSI (colors, cursor show/hide), and folds runs of identical
/// lines (e.g. the same install path echoed once per agent) into one.
///
/// Pure and idempotent: `clean(clean(x)) == clean(x)`, so it's safe to re-run on an accumulating log.
enum TerminalLog {
    static func clean(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        let normalized = normalizeControls(raw)
        var out: [String] = []
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            out.append(resolveCarriageReturns(String(rawLine)))
        }
        return collapse(out)
    }

    /// Pull a concise, human-readable failure reason out of `skills` CLI output, so a failed install
    /// surfaces "couldn't clone likec4.dev — repository does not exist" instead of a 200 KB dump (or,
    /// worse, a misleading silent success). Returns nil when no recognizable failure line is present.
    static func failureSummary(_ raw: String) -> String? {
        let lines = clean(raw)
            .split(separator: "\n")
            .map { stripGlyphs(String($0)) }
            .filter { !$0.isEmpty }
        // Most specific first: the line that names the unreachable source and why.
        if let l = lines.first(where: { $0.range(of: "failed to clone", options: .caseInsensitive) != nil && $0.contains(":") }) {
            return l
        }
        if let l = lines.first(where: { $0.range(of: "fatal:", options: .caseInsensitive) != nil }) {
            return l
        }
        if let l = lines.first(where: { $0.range(of: "failed", options: .caseInsensitive) != nil }) {
            return l
        }
        return nil
    }

    /// Leading box-drawing / spinner glyphs the CLI prints around messages; stripped so a reason reads
    /// as plain text.
    private static let glyphs: Set<Character> =
        Set("■│└┌┐┘├┤─╮╯╰╭◇◒◐◓◑●○◆✓ \t")

    private static func stripGlyphs(_ line: String) -> String {
        var s = Substring(line)
        while let f = s.first, glyphs.contains(f) { s = s.dropFirst() }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// Map line-repaint controls (cursor moves, erases, backspace) to `\r`; drop every other escape
    /// sequence (SGR colors, `?25l/h` cursor visibility, OSC). Leaves `\n` and printable text intact.
    private static func normalizeControls(_ raw: String) -> String {
        let chars = Array(raw)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\u{08}" {                       // backspace → treat as a line reset
                out.append("\r"); i += 1; continue
            }
            guard c == "\u{1B}" else {               // ordinary character
                out.append(c); i += 1; continue
            }
            // ESC sequence.
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            if next == "[" {                          // CSI: ESC [ params... final
                var j = i + 2
                while j < chars.count, "0123456789;?".contains(chars[j]) { j += 1 }
                let final = j < chars.count ? chars[j] : nil
                let isPrivate = (i + 2 < chars.count) && chars[i + 2] == "?"
                if let final, "ABCDEFGJKST".contains(final), !isPrivate {
                    out.append("\r")                 // cursor move / erase → line reset
                }                                    // else (colors `m`, `?25l/h`, …) → drop
                i = (final != nil) ? j + 1 : j
            } else if next == "]" {                   // OSC: ESC ] … (BEL | ESC \)
                var j = i + 2
                while j < chars.count, chars[j] != "\u{07}" {
                    if chars[j] == "\u{1B}", j + 1 < chars.count, chars[j + 1] == "\\" { j += 1; break }
                    j += 1
                }
                i = j + 1
            } else {                                  // lone ESC or two-char escape → drop
                i += next == nil ? 1 : 2
            }
        }
        return String(out)
    }

    /// A repainted line is a series of `\r`-separated frames; the final non-blank frame is what the
    /// terminal would actually show. Trailing whitespace is trimmed.
    private static func resolveCarriageReturns(_ line: String) -> String {
        guard line.contains("\r") else {
            return String(line.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed())
        }
        let frames = line.split(separator: "\r", omittingEmptySubsequences: false)
        let rendered = frames.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }).map(String.init) ?? ""
        return String(rendered.reversed().drop(while: { $0 == " " || $0 == "\t" }).reversed())
    }

    /// Fold consecutive identical lines (the per-agent path echo, leftover spinner frames) into one,
    /// and squeeze runs of blank lines down to a single blank line.
    private static func collapse(_ lines: [String]) -> String {
        var result: [String] = []
        for line in lines {
            if let last = result.last {
                if last == line { continue }
                if last.isEmpty && line.isEmpty { continue }
            }
            result.append(line)
        }
        return result.joined(separator: "\n")
    }
}

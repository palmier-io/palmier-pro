// Incremental caption re-alignment — when a caption's text is edited, keep the word timings that
// still apply instead of dropping the whole line's karaoke. Unchanged tokens keep their exact old
// spans; deleted tokens leave their time as a gap (neighbours never shift); inserted/replaced
// tokens interpolate within the space between anchored neighbours and are marked interpolated. A
// full rewrite with no surviving anchor returns nil so the caller clears as before. refs BUG-5
import Foundation

enum WordTimingRetimer {
    /// Re-aligns `old` (clip-relative frames) onto `newContent`. Returns nil when nothing anchors.
    static func retime(old: [WordTiming], newContent: String, duration: Int) -> [WordTiming]? {
        let newTokens = CaptionText.tokens(newContent)
        guard !newTokens.isEmpty, !old.isEmpty else { return nil }

        let oldKeys = old.map { CaptionText.matchKey($0.text) }
        let newKeys = newTokens.map(CaptionText.matchKey)
        let matched = longestCommonSubsequence(oldKeys, newKeys)
        guard !matched.isEmpty else { return nil }

        // Anchored new tokens inherit their old span (and aligned flag) exactly.
        var result = [WordTiming?](repeating: nil, count: newTokens.count)
        for (oldIndex, newIndex) in matched {
            let anchor = old[oldIndex]
            result[newIndex] = WordTiming(
                text: newTokens[newIndex], startFrame: anchor.startFrame, endFrame: anchor.endFrame,
                aligned: anchor.aligned)
        }

        // Interpolate each unmatched run within the gap its anchored neighbours leave open.
        var i = 0
        while i < newTokens.count {
            guard result[i] == nil else { i += 1; continue }
            var j = i
            while j < newTokens.count, result[j] == nil { j += 1 }
            let lower = i > 0 ? result[i - 1]!.endFrame : 0
            let upper = j < newTokens.count ? result[j]!.startFrame : duration
            let span = max(0, upper - lower)
            let count = j - i
            for k in i..<j {
                let start = lower + span * (k - i) / count
                let end = k == j - 1 ? upper : lower + span * (k - i + 1) / count
                result[k] = WordTiming(text: newTokens[k], startFrame: start, endFrame: max(start, end), aligned: false)
            }
            i = j
        }

        return result.map { timing in
            var t = timing!
            t.startFrame = min(max(0, t.startFrame), duration)
            t.endFrame = min(max(t.startFrame, t.endFrame), duration)
            return t
        }
    }

    /// LCS traceback → matched (oldIndex, newIndex) pairs in order. Empty keys (punctuation) never match.
    private static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [(old: Int, new: Int)] {
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [] }
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = (!a[i].isEmpty && a[i] == b[j])
                    ? dp[i + 1][j + 1] + 1
                    : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var matched: [(old: Int, new: Int)] = []
        var i = 0, j = 0
        while i < n, j < m {
            if !a[i].isEmpty, a[i] == b[j] {
                matched.append((i, j)); i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return matched
    }
}

// Auto-promotion classifier table (§6): which caption edits become glossary terms. refs feature/glossary

import Foundation
import Testing
@testable import PalmierPro

@Suite("GlossaryClassifier")
struct GlossaryClassifierTests {
    @Test func promotesCJKSingleSubstitution() {
        let p = GlossaryClassifier.classify(old: "李娘娘", new: "李嬢嬢")
        #expect(p != nil)
        #expect(p?.canonical == "嬢嬢")
        #expect(p?.variant == "娘娘")
    }

    @Test func promotesPhoneticallyDistantLatinSubstitution() {
        // Regression: phonetic distance (sushi vs sesame) must NOT block promotion.
        let p = GlossaryClassifier.classify(old: "I love black sushi", new: "I love black sesame")
        #expect(p != nil)
        #expect(p?.canonical == "sesame")
        #expect(p?.variant == "sushi")
    }

    @Test func doesNotPromotePureDeletion() {
        #expect(GlossaryClassifier.classify(old: "呃，我们住的酒店", new: "我们住的酒店") == nil)
    }

    @Test func doesNotPromoteCommonVocabRephrase() {
        // 太好吃了 → 非常好吃 is an ordinary rephrase, not a term correction.
        #expect(GlossaryClassifier.classify(old: "太好吃了", new: "非常好吃") == nil)
    }

    @Test func doesNotPromoteScatteredEdits() {
        #expect(GlossaryClassifier.classify(old: "我们住的酒店是", new: "我们的酒店") == nil)
    }

    @Test func doesNotPromotePunctuationOnly() {
        #expect(GlossaryClassifier.classify(old: "你好。", new: "你好，") == nil)
        #expect(GlossaryClassifier.classify(old: "Hello world.", new: "Hello world!") == nil)
    }

    @Test func doesNotPromoteWhitespaceOrCasingOnly() {
        #expect(GlossaryClassifier.classify(old: "hello world", new: "Hello World") == nil)
        #expect(GlossaryClassifier.classify(old: "hello  world", new: "hello world") == nil)
    }

    @Test func doesNotPromotePureInsertion() {
        #expect(GlossaryClassifier.classify(old: "我们住的酒店", new: "呃，我们住的酒店") == nil)
    }

    @Test func doesNotPromoteFillerReplacement() {
        // A replaced span that is only filler is a cleanup, not a term correction.
        #expect(GlossaryClassifier.classify(old: "um the plan", new: "uh the plan") == nil)
    }

    @Test func doesNotPromoteUnchanged() {
        #expect(GlossaryClassifier.classify(old: "李嬢嬢", new: "李嬢嬢") == nil)
    }

    // MARK: - Sub-threshold span widening (§6, B2)

    @Test func widensSubThresholdCJKSubstitution() {
        // 开→拍 is a single CJK char (below the 2-char floor); widen to the enclosing word so the
        // verb promotes as 开照片→拍照片 instead of being dropped and re-fixed every episode.
        let p = GlossaryClassifier.classify(old: "开照片", new: "拍照片")
        #expect(p?.variant == "开照片")
        #expect(p?.canonical == "拍照片")
    }

    @Test func widensSingleCharSubInsideLongerPhrase() {
        // The change sits mid-phrase; widening pulls in only the following word (视频), not 啊.
        let p = GlossaryClassifier.classify(old: "我要开照片啊", new: "我要拍照片啊")
        #expect(p?.variant == "开照片")
        #expect(p?.canonical == "拍照片")
    }

    @Test func widensShortVariantIntoNeighbourWord() {
        // 师 alone is too short; widening into the following char yields the safe 师父→狮父.
        let p = GlossaryClassifier.classify(old: "我的师父", new: "我的狮父")
        #expect(p?.variant == "师父")
        #expect(p?.canonical == "狮父")
    }

    @Test func doesNotWidenWhenNoContextClearsThreshold() {
        // A bare single-char caption has no neighbouring context to widen into — stays nil.
        #expect(GlossaryClassifier.classify(old: "师", new: "狮") == nil)
    }

    @Test func doesNotWidenCommonVocabMinimalSpan() {
        // Guard is on the MINIMAL span: 太好吃了→非常好吃 is an ordinary rephrase, never widened.
        #expect(GlossaryClassifier.classify(old: "太好吃了", new: "非常好吃") == nil)
    }

    @Test func doesNotPromoteWidenedAllCommonSpan() {
        // 在→再 widens to 在来→再来 — all common chars. Promoting it would silently corrupt 现在来.
        #expect(GlossaryClassifier.classify(old: "我在来", new: "我再来") == nil)
        // 他→她 widens to an all-common span too.
        #expect(GlossaryClassifier.classify(old: "他说的对", new: "她说的对") == nil)
    }

    @Test func stillPromotesWidenedSpanWithNonCommonChar() {
        // The widened-span guard must not block real term fixes: 视/频 and 师/狮 are non-common.
        #expect(GlossaryClassifier.classify(old: "开照片", new: "拍照片") != nil)
        #expect(GlossaryClassifier.classify(old: "我的师父", new: "我的狮父") != nil)
    }

    @Test func latinShortVariantNotWidened() {
        // Widening is CJK-only; a sub-threshold Latin substitution (Xe→Xen, 2 chars) stays nil.
        #expect(GlossaryClassifier.classify(old: "Xe", new: "Xen") == nil)
    }

    // MARK: - classifyWithReason (D3)

    /// classifyWithReason must agree with classify on whether every table case promotes.
    @Test func reasonWrapperAgreesWithClassify() {
        let pairs: [(String, String)] = [
            ("李娘娘", "李嬢嬢"),
            ("I love black sushi", "I love black sesame"),
            ("呃，我们住的酒店", "我们住的酒店"),
            ("太好吃了", "非常好吃"),
            ("我们住的酒店是", "我们的酒店"),
            ("你好。", "你好，"),
            ("hello world", "Hello World"),
            ("我们住的酒店", "呃，我们住的酒店"),
            ("um the plan", "uh the plan"),
            ("李嬢嬢", "李嬢嬢"),
            ("我的师父", "我的狮父"),
        ]
        for (old, new) in pairs {
            let classic = GlossaryClassifier.classify(old: old, new: new)
            switch GlossaryClassifier.classifyWithReason(old: old, new: new) {
            case .promote(let p): #expect(classic == p, "\(old)→\(new): wrapper promoted but classify differed")
            case .reject: #expect(classic == nil, "\(old)→\(new): wrapper rejected but classify promoted")
            }
        }
    }

    @Test func reasonNamesScatteredEdits() {
        #expect(GlossaryClassifier.classifyWithReason(old: "我们住的酒店是", new: "我们的酒店") == .reject(.scatteredEdits))
    }

    @Test func reasonNamesPureDeletion() {
        #expect(GlossaryClassifier.classifyWithReason(old: "呃我们住的酒店", new: "我们住的酒店") == .reject(.pureDeletion))
    }

    @Test func reasonNamesCommonVocabulary() {
        if case .reject(let r) = GlossaryClassifier.classifyWithReason(old: "太好吃了", new: "非常好吃") {
            #expect(r == .commonVocabulary || r == .scatteredEdits)
        } else {
            Issue.record("expected a rejection for a common-vocab rephrase")
        }
    }
}

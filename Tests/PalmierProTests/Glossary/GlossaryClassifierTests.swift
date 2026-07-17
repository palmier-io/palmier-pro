// Auto-promotion classifier table (§6): which caption edits become glossary terms. refs feature/glossary

import Foundation
import Testing
@testable import PalmierPro

@Suite("GlossaryClassifier")
struct GlossaryClassifierTests {
    @Test func promotesCJKSingleSubstitution() {
        let p = GlossaryClassifier.classify(old: "陈娘娘", new: "陈嬢嬢")
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
        #expect(GlossaryClassifier.classify(old: "陈嬢嬢", new: "陈嬢嬢") == nil)
    }

    @Test func doesNotPromoteUnsafeShortVariant() {
        // Old span 师 is a single CJK char — too short to safely find/replace.
        #expect(GlossaryClassifier.classify(old: "我的师父", new: "我的狮父") == nil)
    }
}

// Embedded high-frequency vocabulary + filler lists for the auto-promotion classifier's guards.
// Modest curated sets: if a caption edit's replaced span is common vocab or pure filler, it is a
// rephrase/cleanup, not a term correction, so it must not be promoted. refs feature/glossary

import Foundation

enum GlossaryCommonWords {
    /// Most-frequent Chinese characters. A CJK span made only of these reads as ordinary vocabulary.
    static let cjkChars: Set<Character> = Set(
        "的一是不了人我在有他这为之大来以个中上们到说国和地也子时道出而要于就下"
        + "得可你年生自会那后能对着事其里所去行过家十用发天如然作方成者多日都三小军"
        + "二无同么经法当起与好看学进种将还分此心前面又定见只主没公从想意力开高手知理"
        + "眼志点心思但现代总什两问被物身气老少什候太非常很更真最太吃喝住走坐买卖爱恨"
        + "喜欢谢感请让给做菜饭水酒店房间车路口门山河海风雨云天空阳月星光电话时间今明昨"
        + "早晚上下左右东西南北里外近远快慢新旧长短高低胖瘦冷热干湿甜苦香臭红黄蓝绿黑白"
        + "妈爸哥姐弟妹儿女爷奶叔姨伯婶朋友同事老师学生医生病人钱块元角分百千万亿元美"
    )

    /// Common English words. A Latin span made only of these reads as ordinary vocabulary.
    static let english: Set<String> = [
        "the", "a", "an", "and", "or", "but", "so", "too", "very", "really", "quite", "just",
        "is", "are", "was", "were", "be", "been", "am", "do", "did", "does", "have", "has", "had",
        "this", "that", "these", "those", "here", "there", "then", "now", "my", "your", "our",
        "their", "his", "her", "its", "we", "you", "they", "it", "he", "she", "i", "me", "us", "them",
        "to", "of", "in", "on", "for", "with", "at", "by", "from", "up", "out", "off", "over",
        "about", "into", "than", "as", "if", "when", "while", "because", "no", "not", "yes",
        "ok", "okay", "good", "great", "nice", "bad", "big", "small", "new", "old", "more", "most",
        "some", "any", "all", "much", "many", "few", "love", "like", "want", "need", "get", "got",
        "make", "made", "go", "going", "went", "come", "came", "see", "saw", "know", "knew", "think",
        "food", "nice", "cool", "fun", "one", "two", "three", "day", "time", "way", "thing", "things",
        "people", "guy", "guys", "place", "look", "looks", "feel", "feels", "pretty", "super",
    ]

    /// Filler tokens (Chinese + English). A span of only fillers is a cleanup, not a correction.
    static let fillers: Set<String> = [
        "呃", "啊", "嗯", "唉", "诶", "哦", "噢", "呐", "呗", "哈", "嘿", "哎", "唔", "呀", "嘛", "吧", "呢",
        "um", "uh", "uhh", "umm", "uhm", "er", "err", "erm", "ah", "oh", "hmm", "mm", "mhm", "eh",
    ]

    /// True when every non-empty token is a known filler.
    static func isAllFiller(_ tokens: [String]) -> Bool {
        let stripped = tokens.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
        guard !stripped.isEmpty else { return false }
        return stripped.allSatisfy { fillers.contains($0) }
    }

    /// True when the span reads as ordinary common vocabulary (so promoting it would be noise).
    static func isCommonVocabulary(_ span: String) -> Bool {
        let trimmed = span.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if GlossaryText.isCJKPhrase(trimmed) {
            // Every CJK character must be common; a single rare character makes it a candidate term.
            return trimmed.allSatisfy { !GlossaryText.isCJK($0) || cjkChars.contains($0) }
        }
        let words = trimmed.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return false }
        return words.allSatisfy { english.contains($0) }
    }
}

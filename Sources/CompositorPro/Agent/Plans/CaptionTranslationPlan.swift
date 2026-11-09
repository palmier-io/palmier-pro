import CoreMedia
import Foundation

/// Action to execute in the caption translation pipeline.
enum CaptionTranslationAction: String, Codable, Sendable {
    case translate
    case read
    case review
    case approveAll = "approve_all"
    case apply
}

/// Lifecycle status of a caption translation job.
enum CaptionTranslationStatus: String, Codable, Sendable {
    case translated
    case partiallyApproved = "partially_approved"
    case approved
    case applied
}

/// A target language specification for multilingual captions.
struct CaptionLanguage: Codable, Sendable, Equatable {
    let code: String
    let name: String
    let isRTL: Bool

    static let supported: [CaptionLanguage] = [
        CaptionLanguage(code: "es", name: "Spanish", isRTL: false),
        CaptionLanguage(code: "fr", name: "French", isRTL: false),
        CaptionLanguage(code: "de", name: "German", isRTL: false),
        CaptionLanguage(code: "it", name: "Italian", isRTL: false),
        CaptionLanguage(code: "pt", name: "Portuguese", isRTL: false),
        CaptionLanguage(code: "ja", name: "Japanese", isRTL: false),
        CaptionLanguage(code: "ko", name: "Korean", isRTL: false),
        CaptionLanguage(code: "zh", name: "Chinese", isRTL: false),
        CaptionLanguage(code: "zh-Hans", name: "Chinese (Simplified)", isRTL: false),
        CaptionLanguage(code: "zh-Hant", name: "Chinese (Traditional)", isRTL: false),
        CaptionLanguage(code: "hi", name: "Hindi", isRTL: false),
        CaptionLanguage(code: "ar", name: "Arabic", isRTL: true),
        CaptionLanguage(code: "ru", name: "Russian", isRTL: false),
        CaptionLanguage(code: "nl", name: "Dutch", isRTL: false),
        CaptionLanguage(code: "sv", name: "Swedish", isRTL: false),
        CaptionLanguage(code: "id", name: "Indonesian", isRTL: false),
        CaptionLanguage(code: "vi", name: "Vietnamese", isRTL: false),
        CaptionLanguage(code: "tr", name: "Turkish", isRTL: false),
        CaptionLanguage(code: "en", name: "English", isRTL: false),
    ]

    static func resolve(_ input: String) -> CaptionLanguage {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if let match = supported.first(where: { $0.code.lowercased() == lower || $0.name.lowercased() == lower }) {
            return match
        }
        let isRTL = lower == "ar" || lower == "he" || lower == "fa" || lower == "ur"
        return CaptionLanguage(code: lower, name: trimmed.capitalized, isRTL: isRTL)
    }
}

/// An input script beat or caption item provided directly for translation.
struct CaptionTranslationInputBeat: Codable, Sendable, Equatable {
    var beatId: String?
    var text: String
    var startFrame: Int?
    var endFrame: Int?
    var startSeconds: Double?
    var endSeconds: Double?

    init(
        beatId: String? = nil,
        text: String,
        startFrame: Int? = nil,
        endFrame: Int? = nil,
        startSeconds: Double? = nil,
        endSeconds: Double? = nil
    ) {
        self.beatId = beatId
        self.text = text
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }
}

/// An individual translated caption segment with narration timing bounds.
struct TranslatedCaptionSegment: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var beatId: String
    var sourceText: String
    var translatedText: String
    var targetLanguage: String
    var targetLanguageName: String
    var startFrame: Int
    var endFrame: Int
    var startSeconds: Double
    var endSeconds: Double
    var captionStyle: String
    var isApproved: Bool

    var durationFrames: Int { max(1, endFrame - startFrame) }
    var durationSeconds: Double { max(0.1, endSeconds - startSeconds) }
}

/// A complete caption translation job containing all translated segments and metadata.
struct CaptionTranslationJob: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var targetLanguage: String
    var targetLanguageName: String
    var captionStyle: String
    var status: CaptionTranslationStatus
    var segments: [TranslatedCaptionSegment]
    var totalSegments: Int
    var totalDurationSeconds: Double
    var timelineId: String
    var appliedClipIds: [String]?
    var trackId: String?

    var canApply: Bool {
        status == .approved || segments.contains { $0.isApproved }
    }
}

/// Structured receipt returned when translated captions are applied to the timeline.
struct CaptionTranslationReceipt: Codable, Sendable, Equatable {
    var jobId: String
    var targetLanguage: String
    var targetLanguageName: String
    var trackId: String
    var trackIndex: Int
    var captionClipIds: [String]
    var segmentCount: Int
    var totalDurationSeconds: Double
    var totalDurationFrames: Int
    var undoable: Bool
}

/// Errors raised during caption translation planning, review, or application.
enum CaptionTranslationError: Error, LocalizedError, Equatable {
    case jobNotFound(String)
    case segmentNotFound(String, jobId: String)
    case noScriptBeatsFound
    case noApprovedSegments(String)
    case alreadyApplied(String)
    case invalidTiming(startFrame: Int, endFrame: Int)
    case unknownCaptionStyle(String)

    var errorDescription: String? {
        switch self {
        case .jobNotFound(let id):
            return "Caption translation job '\(id)' not found."
        case .segmentNotFound(let segId, let jobId):
            return "Caption segment '\(segId)' not found in translation job '\(jobId)'."
        case .noScriptBeatsFound:
            return "No script beats or captions found to translate. Provide beats or link an edit plan with script beats."
        case .noApprovedSegments(let id):
            return "No approved caption segments in job '\(id)'. Review and approve at least one segment before applying."
        case .alreadyApplied(let id):
            return "Caption translation job '\(id)' has already been applied to the timeline."
        case .invalidTiming(let start, let end):
            return "Invalid caption timing: startFrame (\(start)) must be less than endFrame (\(end))."
        case .unknownCaptionStyle(let style):
            return "Unknown captionStyle '\(style)'. Available styles: \(CaptionStyles.availableIds)."
        }
    }
}

/// Built-in multilingual translator for script beats and captions.
enum CaptionTranslator {
    private static let phraseDictionary: [String: [String: String]] = [
        // Spanish
        "es": [
            "welcome": "bienvenidos",
            "welcome to the video": "bienvenidos al video",
            "in this video": "en este video",
            "let's begin": "comencemos",
            "step one": "paso uno",
            "key point": "punto clave",
            "for example": "por ejemplo",
            "follow and subscribe": "síguenos y suscríbete",
            "follow for more": "síguenos para más",
            "subscribe for more": "suscríbete para más",
            "thank you for watching": "gracias por ver",
            "thanks for watching": "gracias por ver",
            "see you next time": "hasta la próxima",
            "quick summary": "resumen rápido",
            "must watch": "no te lo pierdas",
            "highlights": "puntos destacados",
        ],
        // French
        "fr": [
            "welcome": "bienvenue",
            "welcome to the video": "bienvenue dans la vidéo",
            "in this video": "dans cette vidéo",
            "let's begin": "commençons",
            "step one": "première étape",
            "key point": "point clé",
            "for example": "par exemple",
            "follow and subscribe": "suivez et abonnez-vous",
            "follow for more": "suivez pour en savoir plus",
            "subscribe for more": "abonnez-vous pour plus",
            "thank you for watching": "merci d'avoir regardé",
            "thanks for watching": "merci d'avoir regardé",
            "see you next time": "à la prochaine",
            "quick summary": "résumé rapide",
            "must watch": "à ne pas manquer",
            "highlights": "points forts",
        ],
        // German
        "de": [
            "welcome": "willkommen",
            "welcome to the video": "willkommen zum Video",
            "in this video": "in diesem Video",
            "let's begin": "fangen wir an",
            "step one": "schritt eins",
            "key point": "kernpunkt",
            "for example": "zum Beispiel",
            "follow and subscribe": "folgen und abonnieren",
            "follow for more": "folgt für mehr",
            "subscribe for more": "abonnieren für mehr",
            "thank you for watching": "vielen Dank fürs Zuschauen",
            "thanks for watching": "danke fürs Zuschauen",
            "see you next time": "bis zum nächsten Mal",
            "quick summary": "kurze Zusammenfassung",
            "must watch": "unbedingt ansehen",
            "highlights": "Höhepunkte",
        ],
        // Italian
        "it": [
            "welcome": "benvenuti",
            "welcome to the video": "benvenuti nel video",
            "in this video": "in questo video",
            "let's begin": "iniziamo",
            "step one": "fase uno",
            "key point": "punto chiave",
            "for example": "per esempio",
            "follow and subscribe": "segui e iscriviti",
            "follow for more": "segui per altri contenuti",
            "subscribe for more": "iscriviti per altri contenuti",
            "thank you for watching": "grazie per la visione",
            "thanks for watching": "grazie per la visione",
            "see you next time": "alla prossima",
            "quick summary": "breve riassunto",
            "must watch": "da non perdere",
            "highlights": "punti salienti",
        ],
        // Portuguese
        "pt": [
            "welcome": "bem-vindos",
            "welcome to the video": "bem-vindos ao vídeo",
            "in this video": "neste vídeo",
            "let's begin": "vamos começar",
            "step one": "passo um",
            "key point": "ponto principal",
            "for example": "por exemplo",
            "follow and subscribe": "siga e inscreva-se",
            "follow for more": "siga para mais",
            "subscribe for more": "inscreva-se para mais",
            "thank you for watching": "obrigado por assistir",
            "thanks for watching": "obrigado por assistir",
            "see you next time": "até a próxima",
            "quick summary": "resumo rápido",
            "must watch": "imperdível",
            "highlights": "destaques",
        ],
        // Japanese
        "ja": [
            "welcome": "ようこそ",
            "welcome to the video": "動画へようこそ",
            "in this video": "この動画では",
            "let's begin": "始めましょう",
            "step one": "ステップ1",
            "key point": "重要なポイント",
            "for example": "例えば",
            "follow and subscribe": "フォローとチャンネル登録をお願いします",
            "follow for more": "フォローしてね",
            "subscribe for more": "チャンネル登録をお願いします",
            "thank you for watching": "ご視聴ありがとうございました",
            "thanks for watching": "ご視聴ありがとうございました",
            "see you next time": "また次回お会いしましょう",
            "quick summary": "クイック要約",
            "must watch": "必見",
            "highlights": "ハイライト",
        ],
        // Korean
        "ko": [
            "welcome": "환영합니다",
            "welcome to the video": "영상에 오신 것을 환영합니다",
            "in this video": "이번 영상에서는",
            "let's begin": "시작해 볼까요",
            "step one": "1단계",
            "key point": "핵심 포인트",
            "for example": "예를 들어",
            "follow and subscribe": "팔로우와 구독 부탁드립니다",
            "follow for more": "더 많은 콘텐츠를 위해 팔로우하세요",
            "subscribe for more": "구독하고 더 많은 영상을 만나보세요",
            "thank you for watching": "시청해 주셔서 감사합니다",
            "thanks for watching": "시청해 주셔서 감사합니다",
            "see you next time": "다음에 또 만나요",
            "quick summary": "빠른 요약",
            "must watch": "필수 시청",
            "highlights": "하이라이트",
        ],
        // Chinese
        "zh": [
            "welcome": "欢迎",
            "welcome to the video": "欢迎观看本视频",
            "in this video": "在这个视频中",
            "let's begin": "我们开始吧",
            "step one": "第一步",
            "key point": "关键点",
            "for example": "例如",
            "follow and subscribe": "关注并订阅",
            "follow for more": "关注获取更多内容",
            "subscribe for more": "订阅获取更多内容",
            "thank you for watching": "感谢观看",
            "thanks for watching": "感谢观看",
            "see you next time": "下次再见",
            "quick summary": "快速总结",
            "must watch": "必看内容",
            "highlights": "精选要点",
        ],
        // Hindi
        "hi": [
            "welcome": "स्वागत है",
            "welcome to the video": "वीडियो में आपका स्वागत है",
            "in this video": "इस वीडियो में",
            "let's begin": "चलिए शुरू करते हैं",
            "step one": "पहला कदम",
            "key point": "मुख्य बिंदु",
            "for example": "उदाहरण के लिए",
            "follow and subscribe": "फॉलो और सब्सक्राइब करें",
            "follow for more": "और जानने के लिए फॉलो करें",
            "subscribe for more": "अधिक के लिए सब्सक्राइब करें",
            "thank you for watching": "देखने के लिए धन्यवाद",
            "thanks for watching": "देखने के लिए धन्यवाद",
            "see you next time": "अगली बार मिलते हैं",
            "quick summary": "त्वरित सारांश",
            "must watch": "जरूर देखें",
            "highlights": "मुख्य अंश",
        ],
        // Arabic
        "ar": [
            "welcome": "أهلاً وسهلاً",
            "welcome to the video": "مرحباً بكم في الفيديو",
            "in this video": "في هذا الفيديو",
            "let's begin": "لنبدأ",
            "step one": "الخطوة الأولى",
            "key point": "نقطة رئيسية",
            "for example": "على سبيل المثال",
            "follow and subscribe": "تابع واشترك",
            "follow for more": "تابع للمزيد",
            "subscribe for more": "اشترك للمزيد",
            "thank you for watching": "شكراً للمشاهدة",
            "thanks for watching": "شكراً للمشاهدة",
            "see you next time": "إلى اللقاء في المرة القادمة",
            "quick summary": "ملخص سريع",
            "must watch": "يجب مشاهدته",
            "highlights": "أبرز النقاط",
        ],
    ]

    private static let wordDictionary: [String: [String: String]] = [
        "es": [
            "the": "el", "a": "un", "this": "este", "that": "ese", "video": "video",
            "summary": "resumen", "guide": "guía", "tutorial": "tutorial", "tips": "consejos",
            "best": "mejor", "new": "nuevo", "how": "cómo", "to": "a", "make": "hacer",
            "create": "crear", "edit": "editar", "music": "música", "audio": "audio",
            "story": "historia", "review": "revisión", "first": "primero", "second": "segundo",
            "final": "final", "now": "ahora", "here": "aquí", "we": "nosotros", "you": "tú",
            "with": "con", "and": "y", "for": "para", "in": "en", "on": "en",
        ],
        "fr": [
            "the": "le", "a": "un", "this": "cette", "that": "cela", "video": "vidéo",
            "summary": "résumé", "guide": "guide", "tutorial": "tutoriel", "tips": "astuces",
            "best": "meilleur", "new": "nouveau", "how": "comment", "to": "à", "make": "faire",
            "create": "créer", "edit": "éditer", "music": "musique", "audio": "audio",
            "story": "histoire", "review": "critique", "first": "premier", "second": "deuxième",
            "final": "final", "now": "maintenant", "here": "ici", "we": "nous", "you": "vous",
            "with": "avec", "and": "et", "for": "pour", "in": "dans", "on": "sur",
        ],
        "de": [
            "the": "das", "a": "ein", "this": "dieses", "that": "das", "video": "Video",
            "summary": "Zusammenfassung", "guide": "Leitfaden", "tutorial": "Anleitung", "tips": "Tipps",
            "best": "beste", "new": "neu", "how": "wie", "to": "zu", "make": "machen",
            "create": "erstellen", "edit": "bearbeiten", "music": "Musik", "audio": "Audio",
            "story": "Geschichte", "review": "Bewertung", "first": "erste", "second": "zweite",
            "final": "finale", "now": "jetzt", "here": "hier", "we": "wir", "you": "du",
            "with": "mit", "and": "und", "for": "für", "in": "in", "on": "auf",
        ],
        "it": [
            "the": "il", "a": "un", "this": "questo", "that": "quello", "video": "video",
            "summary": "riassunto", "guide": "guida", "tutorial": "tutorial", "tips": "consigli",
            "best": "migliore", "new": "nuovo", "how": "come", "to": "a", "make": "fare",
            "create": "creare", "edit": "modificare", "music": "musica", "audio": "audio",
            "story": "storia", "review": "recensione", "first": "primo", "second": "secondo",
            "final": "finale", "now": "ora", "here": "qui", "we": "noi", "you": "tu",
            "with": "con", "and": "e", "for": "per", "in": "in", "on": "su",
        ],
        "pt": [
            "the": "o", "a": "um", "this": "este", "that": "aquele", "video": "vídeo",
            "summary": "resumo", "guide": "guia", "tutorial": "tutorial", "tips": "dicas",
            "best": "melhor", "new": "novo", "how": "como", "to": "para", "make": "fazer",
            "create": "criar", "edit": "editar", "music": "música", "audio": "áudio",
            "story": "história", "review": "análise", "first": "primeiro", "second": "segundo",
            "final": "final", "now": "agora", "here": "aqui", "we": "nós", "you": "você",
            "with": "com", "and": "e", "for": "para", "in": "em", "on": "em",
        ],
        "ja": [
            "video": "動画", "summary": "まとめ", "guide": "ガイド", "tips": "ヒント",
            "best": "最高", "new": "新しい", "how": "方法", "music": "音楽",
            "audio": "音声", "story": "ストーリー", "first": "第1", "second": "第2",
            "final": "最後", "now": "今", "here": "ここ", "with": "と一緒に",
        ],
        "zh": [
            "video": "视频", "summary": "总结", "guide": "指南", "tips": "技巧",
            "best": "最佳", "new": "新", "how": "如何", "music": "音乐",
            "audio": "音频", "story": "故事", "first": "第一", "second": "第二",
            "final": "最终", "now": "现在", "here": "这里", "with": "与",
        ],
    ]

    /// Translates source text into the given target language.
    static func translate(text: String, targetLanguage: CaptionLanguage) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if targetLanguage.code == "en" { return trimmed }

        let normalizedLang = targetLanguage.code.hasPrefix("zh") ? "zh" : targetLanguage.code
        let lower = trimmed.lowercased()

        // 1. Direct phrase lookup
        if let phrases = phraseDictionary[normalizedLang], let match = phrases[lower] {
            return applyCasing(match, like: trimmed)
        }

        // 2. Partial phrase replacement
        var result = trimmed
        if let phrases = phraseDictionary[normalizedLang] {
            for (phrase, replacement) in phrases.sorted(by: { $0.key.count > $1.key.count }) {
                if let range = result.range(of: phrase, options: .caseInsensitive) {
                    let matchedOriginal = String(result[range])
                    let casedReplacement = applyCasing(replacement, like: matchedOriginal)
                    result.replaceSubrange(range, with: casedReplacement)
                }
            }
        }

        // 3. Word-level replacement for recognized terms
        if let words = wordDictionary[normalizedLang] {
            let tokens = result.components(separatedBy: " ")
            let mapped = tokens.map { token -> String in
                let cleanToken = token.trimmingCharacters(in: .punctuationCharacters).lowercased()
                if let translatedWord = words[cleanToken] {
                    var out = translatedWord
                    if token.first?.isUppercase == true {
                        out = out.capitalized
                    }
                    if let last = token.last, last.isPunctuation {
                        out.append(last)
                    }
                    return out
                }
                return token
            }
            result = mapped.joined(separator: " ")
        }

        return result
    }

    private static func applyCasing(_ translated: String, like original: String) -> String {
        if original == original.uppercased() && original.count > 1 {
            return translated.uppercased()
        }
        if original.first?.isUppercase == true {
            return translated.prefix(1).uppercased() + translated.dropFirst()
        }
        return translated
    }
}

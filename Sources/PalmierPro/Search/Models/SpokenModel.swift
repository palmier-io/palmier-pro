import Foundation
import NaturalLanguage

enum SpokenModel: String, CaseIterable, Sendable {
    case latin = "nlce-latin" // Latin-script languages (e.g., English, Spanish, French)
    case cjk = "nlce-cjk"     // Chinese, Japanese, Korean (CJK languages)

    var script: NLScript { self == .latin ? .latin : .simplifiedChinese }

    /// OS model revision (0 = no model on this platform); cached, hit per-asset when scheduling.
    private static let revisions: [SpokenModel: Int] = {
        var r: [SpokenModel: Int] = [:]
        for m in allCases { r[m] = NLContextualEmbedding(script: m.script)?.revision ?? 0 }
        return r
    }()
    var revision: Int { Self.revisions[self] ?? 0 }
    static var anyAvailable: Bool { allCases.contains { $0.revision > 0 } }

    static func family(forBCP47 tag: String?) -> SpokenModel? {
        guard let tag else { return nil }
        let code = (Locale(identifier: tag).language.languageCode?.identifier ?? String(tag.prefix(2))).lowercased()
        if ["zh", "ja", "ko", "yue", "wuu"].contains(code) { return cjk.revision > 0 ? .cjk : nil }
        if latin.revision > 0, let m = NLContextualEmbedding(script: .latin),
           m.languages.contains(NLLanguage(rawValue: code)) { return .latin }
        return nil
    }
}

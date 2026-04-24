import AppKit
import CoreText
import Foundation

/// Registers the `.ttf`/`.otf` files shipped under `Resources/Fonts/`
@MainActor
enum BundledFonts {
    private static var registered = false

    private(set) static var families: [String] = []

    static func register() {
        guard !registered else { return }
        registered = true

        // Avoid `Bundle.module` — its SwiftPM-generated accessor fatalErrors
        // when the resource bundle isn't on disk, taking the whole app down at
        // launch. Locate `Fonts/` manually and degrade to a warning instead.
        guard let fontsRoot = findFontsRoot() else {
            Log.app.warning("BundledFonts: Fonts/ not found in main bundle; skipping registration")
            return
        }

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: fontsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var urls: [URL] = []
        var familySet = Set<String>()
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard ext == "ttf" || ext == "otf" else { continue }
            urls.append(url)
            // Variable fonts export one descriptor per named instance; set dedups.
            if let ds = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] {
                for d in ds {
                    if let family = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String {
                        familySet.insert(family)
                    }
                }
            }
        }

        guard !urls.isEmpty else {
            Log.app.warning("BundledFonts: no TTF/OTF files under \(fontsRoot.path)")
            return
        }

        // URL-based; descriptor-based registration trips on variable fonts
        // (one descriptor per named instance, treated as duplicates).
        CTFontManagerRegisterFontURLs(
            urls as CFArray,
            .process,
            true
        ) { errors, done in
            if let cfErrors = errors as? [CFError] {
                for err in cfErrors {
                    Log.app.error("BundledFonts: \(CFErrorCopyDescription(err) as String? ?? "registration failed")")
                }
            }
            return true
        }

        families = familySet.sorted()
        Log.app.notice("BundledFonts: registered \(urls.count) files across \(families.count) families")
    }

    // MARK: - System fonts (for picker)

    private static var cachedSystemFamilies: [(name: String, previewable: Bool)]?

    /// Cached once — macOS doesn't install fonts mid-session.
    static var systemFamiliesForPicker: [(name: String, previewable: Bool)] {
        if let cached = cachedSystemFamilies { return cached }
        let bundled = Set(families)
        let result = NSFontManager.shared.availableFontFamilies
            .filter { !bundled.contains($0) }
            .map { (name: $0, previewable: canPreviewText(family: $0)) }
        cachedSystemFamilies = result
        return result
    }

    /// One path per environment — no cross-environment fallbacks.
    private static func findFontsRoot() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        #if DEBUG
        // `swift run`: SwiftPM writes the resource bundle beside the binary.
        let url = resourceURL.appendingPathComponent("PalmierPro_PalmierPro.bundle/Fonts")
        #else
        // .app release: bundle.sh flattens Fonts/ into Contents/Resources/.
        let url = resourceURL.appendingPathComponent("Fonts")
        #endif
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// False for symbol/emoji/dingbat fonts — they'd render the family name
    /// as glyphs instead of letters.
    private static func canPreviewText(family: String) -> Bool {
        guard let font = NSFont(name: family, size: 12) else { return false }
        let charset = font.coveredCharacterSet
        for scalar in "Aa1".unicodeScalars where !charset.contains(scalar) {
            return false
        }
        return true
    }
}

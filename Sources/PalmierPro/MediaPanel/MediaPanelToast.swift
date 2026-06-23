/// A transient banner shown at the bottom of the media panel
struct MediaPanelToast: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case warning, success }
    var message: String
    var kind: Kind = .warning

    init(message: String, kind: Kind = .warning) {
        self.message = message
        self.kind = kind
    }
}

// String-literal toasts default to `.warning`; construct explicitly for `.success`.
extension MediaPanelToast: ExpressibleByStringInterpolation {
    init(stringLiteral value: String) {
        self.init(message: value)
    }
    init(stringInterpolation: DefaultStringInterpolation) {
        self.init(message: String(stringInterpolation: stringInterpolation))
    }
}

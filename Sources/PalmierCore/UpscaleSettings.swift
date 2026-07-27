import Foundation

public struct UpscaleSettings: Codable, Sendable, Equatable {
    public var selections: [String: String] = [:]
    public var numbers: [String: Double] = [:]
    public var toggles: [String: Bool] = [:]

    public init(
        selections: [String: String] = [:],
        numbers: [String: Double] = [:],
        toggles: [String: Bool] = [:]
    ) {
        self.selections = selections
        self.numbers = numbers
        self.toggles = toggles
    }
}

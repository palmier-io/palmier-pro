import Foundation

func parseFillPatch(_ dict: [String: Any]?, path: String) throws -> ((inout TextStyle.Fill) -> Void)? {
    guard let dict else { return nil }
    try validateUnknownKeys(dict, allowed: ["enabled", "color"], path: path)
    let enabled = dict.bool("enabled")
    let color = try parseColorHex(dict.string("color"), path: "\(path).color")
    guard enabled != nil || color != nil else { return nil }
    return { fill in
        if let enabled { fill.enabled = enabled }
        if let color { fill.color = color }
    }
}

func parseShadowPatch(_ dict: [String: Any]?, path: String) throws -> ((inout TextStyle.Shadow) -> Void)? {
    guard let dict else { return nil }
    try validateUnknownKeys(dict, allowed: ["enabled", "color", "offsetX", "offsetY", "blur"], path: path)
    let enabled = dict.bool("enabled")
    let color = try parseColorHex(dict.string("color"), path: "\(path).color")
    let offsetX = dict.double("offsetX")
    let offsetY = dict.double("offsetY")
    let blur = dict.double("blur")
    if let b = blur, b < 0 { throw ToolError("\(path).blur must be >= 0 (got \(b))") }
    guard enabled != nil || color != nil || offsetX != nil || offsetY != nil || blur != nil else { return nil }
    return { shadow in
        if let enabled { shadow.enabled = enabled }
        if let color { shadow.color = color }
        if let offsetX { shadow.offsetX = offsetX }
        if let offsetY { shadow.offsetY = offsetY }
        if let blur { shadow.blur = blur }
    }
}

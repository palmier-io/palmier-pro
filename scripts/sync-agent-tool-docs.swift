#!/usr/bin/env swift
import Foundation

struct ToolDoc {
    let caseName: String
    let rawName: String
    let description: String
    let sourceLine: Int
    let availability: String
}

enum DocError: Error, CustomStringConvertible {
    case missingFile(String)
    case parse(String)

    var description: String {
        switch self {
        case .missingFile(let path): return "Missing file: \(path)"
        case .parse(let message): return "Parse error: \(message)"
        }
    }
}

let sourcePath = "Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift"
let docPath = "docs/agent-tools/agent-tool-contract.md"
let args = Set(CommandLine.arguments.dropFirst())
let shouldWrite = args.contains("--write")

func read(_ path: String) throws -> String {
    guard FileManager.default.fileExists(atPath: path) else { throw DocError.missingFile(path) }
    return try String(contentsOfFile: path, encoding: .utf8)
}

func lineNumber(in text: String, at offset: String.Index) -> Int {
    text[..<offset].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
}

func matchAll(_ pattern: String, in text: String) throws -> [(String, [String])] {
    let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
    let ns = NSRange(text.startIndex..<text.endIndex, in: text)
    return regex.matches(in: text, range: ns).compactMap { match in
        var groups: [String] = []
        for i in 1..<match.numberOfRanges {
            guard let range = Range(match.range(at: i), in: text) else { return nil }
            groups.append(String(text[range]))
        }
        guard let wholeRange = Range(match.range, in: text) else { return nil }
        return (String(text[wholeRange]), groups)
    }
}

func toolRawNames(from source: String) throws -> [String: String] {
    let matches = try matchAll(#"case\s+([A-Za-z0-9_]+)\s*=\s*"([^"]+)""#, in: source)
    var out: [String: String] = [:]
    for (_, groups) in matches { out[groups[0]] = groups[1] }
    return out
}

func decodeSwiftQuotedString(_ raw: String) throws -> String {
    let json = "\"\(raw)\""
    guard let data = json.data(using: .utf8),
          let decoded = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String else {
        throw DocError.parse("Could not decode quoted description near: \(raw.prefix(40))")
    }
    return decoded
}

func normalizeMultilineLiteral(_ raw: String, closingIndent: String) -> String {
    var text = raw
    if text.hasPrefix("\n") { text.removeFirst() }
    if text.hasSuffix("\n") { text.removeLast() }
    let lines = text.components(separatedBy: "\n").map { line -> String in
        line.hasPrefix(closingIndent) ? String(line.dropFirst(closingIndent.count)) : line
    }

    var joined: [String] = []
    var carry = ""
    for line in lines {
        let trimmedRight = line.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        if trimmedRight.hasSuffix("\\") {
            carry += trimmedRight.dropLast().trimmingCharacters(in: .whitespaces) + " "
        } else {
            joined.append(carry + line.trimmingCharacters(in: carry.isEmpty ? [] : .whitespaces))
            carry = ""
        }
    }
    if !carry.isEmpty { joined.append(carry.trimmingCharacters(in: .whitespaces)) }

    return joined
        .joined(separator: "\n")
        .replacingOccurrences(of: #"\(Self.effectCatalog())"#, with: "[generated from EffectRegistry at runtime]")
}

func parseDescription(in source: String, from start: String.Index) throws -> (String, String.Index) {
    var i = start
    while i < source.endIndex, source[i].isWhitespace { i = source.index(after: i) }

    if source[i...].hasPrefix(#""""#) {
        let bodyStart = source.index(i, offsetBy: 3)
        guard let endRange = source[bodyStart...].range(of: #""""#) else {
            throw DocError.parse("Unclosed multiline description")
        }
        let lineStart = source[..<endRange.lowerBound].lastIndex(of: "\n").map { source.index(after: $0) } ?? source.startIndex
        let indent = String(source[lineStart..<endRange.lowerBound])
        let raw = String(source[bodyStart..<endRange.lowerBound])
        return (normalizeMultilineLiteral(raw, closingIndent: indent), endRange.upperBound)
    }

    guard source[i] == "\"" else { throw DocError.parse("Expected string literal after description:") }
    i = source.index(after: i)
    var raw = ""
    var escaped = false
    while i < source.endIndex {
        let ch = source[i]
        if escaped {
            raw.append("\\")
            raw.append(ch)
            escaped = false
        } else if ch == "\\" {
            escaped = true
        } else if ch == "\"" {
            return (try decodeSwiftQuotedString(raw), source.index(after: i))
        } else {
            raw.append(ch)
        }
        i = source.index(after: i)
    }
    throw DocError.parse("Unclosed quoted description")
}

func parseTools(from source: String) throws -> [ToolDoc] {
    let rawNames = try toolRawNames(from: source)
    var docs: [ToolDoc] = []
    var searchStart = source.startIndex

    while let toolRange = source[searchStart...].range(of: "AgentTool(") {
        guard let nameLabel = source[toolRange.upperBound...].range(of: "name:") else { break }
        guard let dot = source[nameLabel.upperBound...].firstIndex(of: ".") else {
            throw DocError.parse("Missing tool case after name: at line \(lineNumber(in: source, at: nameLabel.lowerBound))")
        }
        var caseEnd = source.index(after: dot)
        while caseEnd < source.endIndex, source[caseEnd].isLetter || source[caseEnd].isNumber || source[caseEnd] == "_" {
            caseEnd = source.index(after: caseEnd)
        }
        let caseName = String(source[source.index(after: dot)..<caseEnd])
        guard let rawName = rawNames[caseName] else {
            throw DocError.parse("No raw value for ToolName.\(caseName)")
        }
        guard let descLabel = source[caseEnd...].range(of: "description:") else {
            throw DocError.parse("Missing description for \(rawName)")
        }
        let (description, descEnd) = try parseDescription(in: source, from: descLabel.upperBound)
        let availability = rawName == "read_skill" ? "In-app agent only" : "In-app agent and MCP"
        docs.append(ToolDoc(
            caseName: caseName,
            rawName: rawName,
            description: description,
            sourceLine: lineNumber(in: source, at: toolRange.lowerBound),
            availability: availability
        ))
        searchStart = descEnd
    }

    let duplicates = Dictionary(grouping: docs, by: \.rawName).filter { $0.value.count > 1 }.keys.sorted()
    if !duplicates.isEmpty { throw DocError.parse("Duplicate tool docs: \(duplicates.joined(separator: ", "))") }
    return docs
}

func markdown(_ text: String) -> String {
    text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func render(_ tools: [ToolDoc]) -> String {
    var out: [String] = []
    let mcpCount = tools.filter { $0.availability.contains("MCP") }.count
    out.append("# Agent Tool Contract")
    out.append("")
    out.append("This document is generated from `\(sourcePath)`.")
    out.append("Do not edit the tool list by hand. Run `swift scripts/sync-agent-tool-docs.swift --write` after changing agent tool definitions, and run `swift scripts/sync-agent-tool-docs.swift` before or after syncing upstream.")
    out.append("")
    out.append("Tool count: \(tools.count) in-app agent tools, \(mcpCount) MCP-exposed tools.")
    out.append("")
    out.append("## Maintenance Contract")
    out.append("")
    out.append("- `ToolDefinitions.swift` is the source of truth for names and descriptions.")
    out.append("- Any semantic change under `Sources/PalmierPro/Agent/Tools/` must update the corresponding tool description and regenerate this document.")
    out.append("- After syncing upstream, run `swift scripts/sync-agent-tool-docs.swift` to confirm the checked-in document still matches the current code.")
    out.append("- Install local hooks with `scripts/install-hooks.sh`; CI also runs the same check.")
    out.append("")
    out.append("## Tool Index")
    out.append("")
    for (index, tool) in tools.enumerated() {
        out.append("\(index + 1). `\(tool.rawName)` — \(tool.availability)")
    }
    out.append("")
    out.append("## Tool Descriptions")
    out.append("")
    for tool in tools {
        out.append("### `\(tool.rawName)`")
        out.append("")
        out.append("- Source case: `ToolName.\(tool.caseName)`")
        out.append("- Source line: `\(sourcePath):\(tool.sourceLine)`")
        out.append("- Availability: \(tool.availability)")
        out.append("")
        out.append(markdown(tool.description))
        out.append("")
    }
    return out.joined(separator: "\n") + "\n"
}

do {
    let source = try read(sourcePath)
    let tools = try parseTools(from: source)
    let generated = render(tools)

    if shouldWrite {
        try FileManager.default.createDirectory(
            atPath: (docPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try generated.write(toFile: docPath, atomically: true, encoding: .utf8)
        print("Wrote \(docPath) with \(tools.count) tools.")
    } else {
        let current = try read(docPath)
        guard current == generated else {
            fputs("""
            Agent tool documentation is out of sync.
            Run: swift scripts/sync-agent-tool-docs.swift --write
            Then review and commit \(docPath).

            """, stderr)
            exit(1)
        }
        print("Agent tool documentation is in sync (\(tools.count) tools).")
    }
} catch {
    fputs("\(error)\n", stderr)
    exit(1)
}

import Foundation

/// Bidirectional codec for HyperFrames-compatible `STORYBOARD.md` files and native `EditPlan` models.
enum StoryboardMarkdownCodec {

    // MARK: - Export

    static func export(plan: EditPlan) -> String {
        var lines: [String] = []
        lines.append("# Storyboard: \(plan.name)")
        lines.append("")
        lines.append("## Overview")
        if !plan.goal.isEmpty {
            lines.append("- **Goal:** \(plan.goal)")
        }
        let totalDurationSeconds = Double(plan.shots.map(\.endFrame).max() ?? 0) / Double(max(1, plan.fps))
        lines.append("- **Duration:** \(formatSeconds(totalDurationSeconds))")
        lines.append("- **FPS:** \(plan.fps)")
        lines.append("- **Resolution:** \(plan.width)x\(plan.height)")
        lines.append("- **Status:** \(plan.status.rawValue)")
        lines.append("")
        lines.append("---")
        lines.append("")

        let beatsById = Dictionary(uniqueKeysWithValues: (plan.scriptBeats ?? []).map { ($0.beatId, $0) })
        let cuesByBeatId = Dictionary(grouping: plan.soundCues ?? [], by: { $0.anchorBeatId ?? "" })

        for (index, shot) in plan.shots.enumerated() {
            let startSec = Double(shot.startFrame) / Double(max(1, plan.fps))
            let endSec = Double(shot.endFrame) / Double(max(1, plan.fps))
            lines.append("### Beat \(index + 1) — \(shot.title)")
            lines.append("- **Timecode:** \(formatTimecode(startSec)) – \(formatTimecode(endSec))")

            if let link = shot.narrationLink, let beat = beatsById[link.firstBeatId] {
                lines.append("- **Voiceover:** \"\(beat.text)\"")
                if let spoken = beat.spokenText, spoken != beat.text {
                    lines.append("- **Pronunciation:** \(spoken)")
                }
            }

            if !shot.notes.isEmpty {
                lines.append("- **Visual Concept:** \(shot.notes)")
            } else if let ref = shot.mediaRef {
                lines.append("- **Visual:** Media Asset \(ref)")
            } else if let url = shot.candidateURL {
                lines.append("- **Visual URL:** \(url)")
            }

            if let link = shot.narrationLink, let beat = beatsById[link.firstBeatId], !beat.purpose.isEmpty {
                lines.append("- **Purpose:** \(beat.purpose)")
            }

            if let link = shot.narrationLink, let cues = cuesByBeatId[link.firstBeatId], !cues.isEmpty {
                let cueDescriptions = cues.map(\.purpose).joined(separator: ", ")
                lines.append("- **SFX:** \(cueDescriptions)")
            }

            if let license = shot.license, let attribution = shot.attribution {
                lines.append("- **Rights:** License: \(license) | Attribution: \(attribution)")
            }

            lines.append("")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines) + "\n"
    }

    // MARK: - Import / Parsing

    static func parse(
        markdown: String,
        timelineId: String,
        fps: Int = 30,
        width: Int = 1920,
        height: Int = 1080,
        fallbackName: String = "Imported Storyboard"
    ) throws -> EditPlan {
        let lines = markdown.components(separatedBy: .newlines)
        var planName = fallbackName
        var goal = ""

        struct ParsedBeat {
            var title: String
            var startSeconds: Double?
            var endSeconds: Double?
            var durationSeconds: Double?
            var voiceover: String?
            var pronunciation: String?
            var visual: String?
            var purpose: String?
            var sfx: String?
            var mediaRef: String?
            var candidateURL: String?
            var license: String?
            var attribution: String?
        }

        var parsedBeats: [ParsedBeat] = []
        var currentBeat: ParsedBeat?

        func flushCurrent() {
            if let beat = currentBeat {
                parsedBeats.append(beat)
                currentBeat = nil
            }
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // Title detection
            if line.hasPrefix("# Storyboard:") {
                let title = line.dropFirst("# Storyboard:".count).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { planName = title }
                continue
            } else if line.hasPrefix("# ") && planName == fallbackName {
                let title = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { planName = title }
                continue
            }

            // Overview metadata
            if line.hasPrefix("- **Goal:**") || line.hasPrefix("**Goal:**") {
                goal = extractValue(line, key: "Goal")
                continue
            }

            // Heading detection: ### Beat 1 — Cold Open, ## Beat 2, ### Scene 1, etc.
            if isBeatHeading(line) {
                flushCurrent()
                let title = extractHeadingTitle(line)
                currentBeat = ParsedBeat(title: title)
                continue
            }

            // Key-value parsing inside current beat
            guard currentBeat != nil else { continue }

            if matchesKey(line, "Timecode") || matchesKey(line, "Time") || matchesKey(line, "Range") {
                let val = extractKeyValue(line)
                if let (start, end) = parseTimeRange(val) {
                    currentBeat?.startSeconds = start
                    currentBeat?.endSeconds = end
                }
            } else if matchesKey(line, "Duration") {
                let val = extractKeyValue(line)
                if let dur = parseSingleDuration(val) {
                    currentBeat?.durationSeconds = dur
                }
            } else if matchesKey(line, "Voiceover") || matchesKey(line, "VO") || matchesKey(line, "Narration") || matchesKey(line, "Script") {
                currentBeat?.voiceover = cleanQuotes(extractKeyValue(line))
            } else if matchesKey(line, "Pronunciation") {
                currentBeat?.pronunciation = cleanQuotes(extractKeyValue(line))
            } else if matchesKey(line, "Visual Concept") || matchesKey(line, "Visual") || matchesKey(line, "Visuals") {
                currentBeat?.visual = extractKeyValue(line)
            } else if matchesKey(line, "Visual URL") {
                currentBeat?.candidateURL = extractKeyValue(line)
            } else if matchesKey(line, "Purpose") {
                currentBeat?.purpose = extractKeyValue(line)
            } else if matchesKey(line, "SFX") || matchesKey(line, "Audio") || matchesKey(line, "Sound") {
                currentBeat?.sfx = extractKeyValue(line)
            } else if matchesKey(line, "Media Asset") || matchesKey(line, "MediaRef") {
                currentBeat?.mediaRef = extractKeyValue(line)
            } else if matchesKey(line, "Rights") {
                let val = extractKeyValue(line)
                let parts = val.components(separatedBy: "|")
                for part in parts {
                    let sub = part.trimmingCharacters(in: .whitespaces)
                    if sub.lowercased().hasPrefix("license:") {
                        currentBeat?.license = sub.dropFirst("license:".count).trimmingCharacters(in: .whitespaces)
                    } else if sub.lowercased().hasPrefix("attribution:") {
                        currentBeat?.attribution = sub.dropFirst("attribution:".count).trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        }
        flushCurrent()

        guard !parsedBeats.isEmpty else {
            throw EditPlanValidationError.invalidReference("No scene or beat headings found in Storyboard Markdown.")
        }

        // Build EditPlan Shots and ScriptBeats
        var shots: [EditPlanShot] = []
        var scriptBeats: [ScriptBeat] = []
        var soundCues: [PlanSoundCue] = []
        var currentFrame = 0

        for (index, beat) in parsedBeats.enumerated() {
            let beatNumber = index + 1
            let shotId = "shot-\(beatNumber)"
            let beatId = "beat-\(beatNumber)"

            let startFrame: Int
            let endFrame: Int

            if let s = beat.startSeconds, let e = beat.endSeconds, e > s {
                startFrame = max(currentFrame, Int(round(s * Double(fps))))
                endFrame = max(startFrame + 1, Int(round(e * Double(fps))))
            } else if let dur = beat.durationSeconds, dur > 0 {
                startFrame = currentFrame
                endFrame = startFrame + max(1, Int(round(dur * Double(fps))))
            } else {
                // Default pacing: 3.5 seconds
                startFrame = currentFrame
                endFrame = startFrame + Int(round(3.5 * Double(fps)))
            }
            currentFrame = endFrame

            let beatTitle = beat.title.isEmpty ? "Scene \(beatNumber)" : beat.title
            let purpose = beat.purpose ?? beatTitle

            var narrationLink: SceneNarrationLink? = nil
            if let vo = beat.voiceover, !vo.isEmpty {
                let scriptBeat = ScriptBeat(
                    beatId: beatId,
                    text: vo,
                    spokenText: beat.pronunciation,
                    purpose: purpose
                )
                scriptBeats.append(scriptBeat)
                narrationLink = SceneNarrationLink(firstBeatId: beatId, lastBeatId: beatId)
            }

            if let sfxText = beat.sfx, !sfxText.isEmpty {
                let cue = PlanSoundCue(
                    cueId: "cue-\(beatNumber)",
                    role: .sfx,
                    purpose: sfxText,
                    anchorBeatId: narrationLink != nil ? beatId : nil,
                    anchorFrame: narrationLink == nil ? startFrame : nil
                )
                soundCues.append(cue)
            }

            var shot = EditPlanShot(
                id: shotId,
                title: beatTitle,
                startFrame: startFrame,
                endFrame: endFrame,
                notes: beat.visual ?? ""
            )
            shot.mediaRef = beat.mediaRef
            shot.candidateURL = beat.candidateURL
            shot.license = beat.license
            shot.attribution = beat.attribution
            shot.narrationLink = narrationLink
            shots.append(shot)
        }

        let plan = EditPlan(
            name: planName,
            goal: goal,
            timelineId: timelineId,
            fps: fps,
            width: width,
            height: height,
            status: .proposed,
            shots: shots,
            scriptBeats: scriptBeats.isEmpty ? nil : scriptBeats,
            soundCues: soundCues.isEmpty ? nil : soundCues
        )
        return plan
    }

    // MARK: - Internal Helpers

    private static func isBeatHeading(_ line: String) -> Bool {
        guard line.hasPrefix("#") else { return false }
        let stripped = line.trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)
        let lower = stripped.lowercased()
        return lower.hasPrefix("beat ") || lower.hasPrefix("scene ") || lower.hasPrefix("shot ")
            || (line.hasPrefix("### ") && !lower.hasPrefix("overview"))
    }

    private static func extractHeadingTitle(_ line: String) -> String {
        let stripped = line.trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)
        // Check for separator "—" or "-" or ":"
        for sep in ["—", "–", ":", "-"] {
            if let range = stripped.range(of: sep) {
                let title = stripped[range.upperBound...].trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { return title }
            }
        }
        return stripped
    }

    private static func matchesKey(_ line: String, _ key: String) -> Bool {
        let lower = line.lowercased()
        let target = key.lowercased()
        return lower.hasPrefix("- **\(target):**")
            || lower.hasPrefix("**\(target):**")
            || lower.hasPrefix("- *\(target):*")
            || lower.hasPrefix("*\(target):*")
            || lower.hasPrefix("- \(target):")
            || lower.hasPrefix("\(target):")
    }

    private static func extractKeyValue(_ line: String) -> String {
        guard let colon = line.firstIndex(of: ":") else { return "" }
        var rest = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("**") { rest = String(rest.dropFirst(2)) }
        if rest.hasPrefix("*") { rest = String(rest.dropFirst(1)) }
        return rest.trimmingCharacters(in: .whitespaces)
    }

    private static func extractValue(_ line: String, key: String) -> String {
        extractKeyValue(line)
    }

    private static func cleanQuotes(_ s: String) -> String {
        var str = s.trimmingCharacters(in: .whitespaces)
        if (str.hasPrefix("\"") && str.hasSuffix("\"")) || (str.hasPrefix("“") && str.hasSuffix("”")) {
            str = String(str.dropFirst().dropLast())
        }
        return str.trimmingCharacters(in: .whitespaces)
    }

    private static func parseTimeRange(_ s: String) -> (Double, Double)? {
        let separators = ["–", "—", " - ", "-"]
        for sep in separators {
            if let range = s.range(of: sep) {
                let startStr = String(s[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                let endStr = String(s[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                if let start = parseSingleDuration(startStr), let end = parseSingleDuration(endStr), end > start {
                    return (start, end)
                }
            }
        }
        return nil
    }

    private static func parseSingleDuration(_ s: String) -> Double? {
        var trimmed = s.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.hasSuffix("s") { trimmed = String(trimmed.dropLast()) }

        // Format mm:ss or hh:mm:ss
        if trimmed.contains(":") {
            let parts = trimmed.components(separatedBy: ":")
            if parts.count == 2, let m = Double(parts[0]), let sec = Double(parts[1]) {
                return m * 60.0 + sec
            } else if parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) {
                return h * 3600.0 + m * 60.0 + sec
            }
        }
        return Double(trimmed)
    }

    private static func formatTimecode(_ seconds: Double) -> String {
        let total = Int(floor(seconds))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }

    private static func formatSeconds(_ seconds: Double) -> String {
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return "\(m)m \(s)s"
    }
}


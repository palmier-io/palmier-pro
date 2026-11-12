import CryptoKit
import Foundation

enum EvidenceGraphicKind: String, Codable, Sendable, CaseIterable {
    case numericComparison = "numeric_comparison"
    case sourceCard = "source_card"
    case comparisonChart = "comparison_chart"
    case policyTimeline = "policy_timeline"
}

enum EvidenceGraphicError: LocalizedError, Equatable {
    case malformedData(String)
    case incompatibleUnits(String)
    case unsupportedCombination(String)
    case fabricatedAttribution(String)
    case chronologyViolation(String)
    case nonFiniteNumber(String)
    case narrationDisagreement(String)
    case invalidBounds(String)

    var errorDescription: String? {
        switch self {
        case .malformedData(let detail): "Malformed graphic data: \(detail)"
        case .incompatibleUnits(let detail): "Incompatible units: \(detail)"
        case .unsupportedCombination(let detail): "Unsupported combination: \(detail)"
        case .fabricatedAttribution(let detail): "Fabricated attribution: \(detail)"
        case .chronologyViolation(let detail): "Chronology violation: \(detail)"
        case .nonFiniteNumber(let detail): "Non-finite numeric value: \(detail)"
        case .narrationDisagreement(let detail): "Display and narration disagree: \(detail)"
        case .invalidBounds(let detail): "Invalid bounds: \(detail)"
        }
    }
}

// MARK: - Numeric Comparison Data

struct NumericComparisonItem: Codable, Sendable, Equatable {
    var label: String
    var value: Double
    var unit: String
    var claimIds: [String]?
    var baseline: Bool?
    var note: String?
}

struct NumericComparisonData: Codable, Sendable, Equatable {
    var items: [NumericComparisonItem]
    var comparisonType: String?
    var deltaLabel: String?
    var showDelta: Bool?

    func validated() throws -> Self {
        guard (2...6).contains(items.count) else {
            throw EvidenceGraphicError.malformedData("Numeric comparison requires between 2 and 6 items to compare.")
        }
        var cleanedItems: [NumericComparisonItem] = []
        var seenLabels = Set<String>()
        var baseUnit: String?

        for item in items {
            let label = item.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else {
                throw EvidenceGraphicError.malformedData("Comparison item label must not be empty.")
            }
            guard seenLabels.insert(label.lowercased()).inserted else {
                throw EvidenceGraphicError.malformedData("Duplicate comparison item label '\(label)'.")
            }
            guard item.value.isFinite else {
                throw EvidenceGraphicError.nonFiniteNumber("Value for '\(label)' must be a finite number.")
            }
            let unit = item.unit.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !unit.isEmpty else {
                throw EvidenceGraphicError.malformedData("Unit for '\(label)' must not be empty.")
            }

            if let base = baseUnit {
                if !Self.areUnitsCompatible(base, unit) {
                    throw EvidenceGraphicError.incompatibleUnits("Cannot compare '\(base)' with '\(unit)' in a numeric comparison.")
                }
            } else {
                baseUnit = unit
            }

            let claimIds = (item.claimIds ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            cleanedItems.append(NumericComparisonItem(
                label: label,
                value: item.value,
                unit: unit,
                claimIds: claimIds.isEmpty ? nil : claimIds,
                baseline: item.baseline,
                note: item.note?.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }

        let cType = comparisonType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let cType, !cType.isEmpty {
            let supportedTypes = ["standard", "nominal_vs_adjusted", "announced_vs_realized", "per_capita_vs_total", "year_over_year"]
            guard supportedTypes.contains(cType) else {
                throw EvidenceGraphicError.unsupportedCombination("Comparison type '\(cType)' is unsupported. Choose from: \(supportedTypes.joined(separator: ", ")).")
            }
        }

        return NumericComparisonData(
            items: cleanedItems,
            comparisonType: cType,
            deltaLabel: deltaLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
            showDelta: showDelta ?? true
        )
    }

    static func areUnitsCompatible(_ u1: String, _ u2: String) -> Bool {
        let n1 = u1.lowercased()
        let n2 = u2.lowercased()
        if n1 == n2 { return true }
        // Currency variations
        let currencies: Set<String> = ["usd", "$", "myr", "rm", "eur", "€", "gbp", "£", "jpy", "¥", "sgd"]
        if currencies.contains(n1) && currencies.contains(n2) { return true }
        // Percentage / rates
        let percents: Set<String> = ["%", "percent", "percentage", "pct"]
        if percents.contains(n1) && percents.contains(n2) { return true }
        // Per capita
        let perCapita: Set<String> = ["usd/capita", "$/capita", "usd per capita", "$ per capita"]
        if perCapita.contains(n1) && perCapita.contains(n2) { return true }
        return false
    }

    var delta: (absolute: Double, percent: Double)? {
        guard items.count >= 2 else { return nil }
        let base = items[0].value
        let target = items[1].value
        let absDelta = target - base
        guard base != 0 else { return (absolute: absDelta, percent: 0) }
        let pct = (absDelta / abs(base)) * 100.0
        return (absolute: absDelta, percent: pct)
    }
}

// MARK: - Source Card Data

struct SourceCardData: Codable, Sendable, Equatable {
    var sourceId: String?
    var title: String
    var author: String
    var publicationDate: String?
    var accessedDate: String
    var url: String?
    var documentReference: String?
    var quotation: String?
    var paraphrase: String?
    var claimIds: [String]

    func validated() throws -> Self {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw EvidenceGraphicError.malformedData("Source card title must not be empty.") }
        let author = author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !author.isEmpty else { throw EvidenceGraphicError.fabricatedAttribution("Source card requires a verified author or publishing organization.") }

        let cleanUrl = url?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDoc = documentReference?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasUrl = cleanUrl != nil && !cleanUrl!.isEmpty
        let hasDoc = cleanDoc != nil && !cleanDoc!.isEmpty

        guard hasUrl != hasDoc else {
            throw EvidenceGraphicError.fabricatedAttribution("Source card requires exactly one of 'url' or 'documentReference' for verifiable provenance.")
        }

        let access = accessedDate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !access.isEmpty else { throw EvidenceGraphicError.fabricatedAttribution("Source card requires accessedDate.") }
        try Self.validateDate(access, field: "accessedDate")

        var pubDateClean: String?
        if let pub = publicationDate?.trimmingCharacters(in: .whitespacesAndNewlines), !pub.isEmpty {
            try Self.validateDate(pub, field: "publicationDate")
            pubDateClean = pub
        }

        let quote = quotation?.trimmingCharacters(in: .whitespacesAndNewlines)
        let para = paraphrase?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (quote != nil && !quote!.isEmpty) || (para != nil && !para!.isEmpty) else {
            throw EvidenceGraphicError.fabricatedAttribution("Source card requires either an exact quotation or a marked paraphrase.")
        }

        let cleanedClaimIds = claimIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !cleanedClaimIds.isEmpty else {
            throw EvidenceGraphicError.fabricatedAttribution("Source card must cite at least one claimId from the ledger.")
        }

        return SourceCardData(
            sourceId: sourceId?.trimmingCharacters(in: .whitespacesAndNewlines),
            title: title,
            author: author,
            publicationDate: pubDateClean,
            accessedDate: access,
            url: hasUrl ? cleanUrl : nil,
            documentReference: hasDoc ? cleanDoc : nil,
            quotation: quote,
            paraphrase: para,
            claimIds: cleanedClaimIds
        )
    }

    static func validateDate(_ dateStr: String, field: String) throws {
        // Support YYYY or YYYY-MM-DD
        if dateStr.count == 4, let year = Int(dateStr), (1000...9999).contains(year) {
            return
        }
        let pieces = dateStr.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              pieces.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
              let year = Int(pieces[0]), (1000...9999).contains(year),
              let month = Int(pieces[1]), (1...12).contains(month),
              let day = Int(pieces[2]), (1...31).contains(day) else {
            throw EvidenceGraphicError.malformedData("\(field) '\(dateStr)' must be a valid YYYY or YYYY-MM-DD date.")
        }
    }
}

// MARK: - Comparison Chart Data

struct ChartPoint: Codable, Sendable, Equatable {
    var label: String
    var value: Double
    var claimIds: [String]?
}

struct ChartSeries: Codable, Sendable, Equatable {
    var name: String
    var points: [ChartPoint]
    var unit: String?
    var colorHex: String?
}

struct AxisScale: Sendable, Equatable {
    var min: Double
    var max: Double
    var step: Double
    var ticks: [Double]
}

struct ComparisonChartData: Codable, Sendable, Equatable {
    var series: [ChartSeries]
    var unit: String
    var xAxisLabel: String?
    var yAxisLabel: String?
    var chartType: String? // "line" or "bar"
    var timeScale: Bool?

    func validated() throws -> Self {
        let cleanUnit = unit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUnit.isEmpty else { throw EvidenceGraphicError.malformedData("Chart requires a non-empty unit.") }
        guard (1...4).contains(series.count) else {
            throw EvidenceGraphicError.malformedData("Comparison chart requires between 1 and 4 series.")
        }

        let isLine = (chartType?.lowercased() ?? "line") == "line"
        let minPoints = isLine ? 2 : 1
        var cleanedSeries: [ChartSeries] = []
        var seenSeriesNames = Set<String>()

        for s in series {
            let name = s.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw EvidenceGraphicError.malformedData("Chart series name must not be empty.") }
            guard seenSeriesNames.insert(name.lowercased()).inserted else {
                throw EvidenceGraphicError.malformedData("Duplicate chart series name '\(name)'.")
            }
            guard (minPoints...32).contains(s.points.count) else {
                throw EvidenceGraphicError.malformedData("Series '\(name)' must have between \(minPoints) and 32 points.")
            }
            if let sUnit = s.unit?.trimmingCharacters(in: .whitespacesAndNewlines), !sUnit.isEmpty {
                guard NumericComparisonData.areUnitsCompatible(cleanUnit, sUnit) else {
                    throw EvidenceGraphicError.incompatibleUnits("Series '\(name)' unit '\(sUnit)' does not match chart unit '\(cleanUnit)'.")
                }
            }

            var cleanedPoints: [ChartPoint] = []
            for pt in s.points {
                let label = pt.label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !label.isEmpty else { throw EvidenceGraphicError.malformedData("Data point label in '\(name)' cannot be empty.") }
                guard pt.value.isFinite else {
                    throw EvidenceGraphicError.nonFiniteNumber("Data point value for '\(label)' in '\(name)' must be finite.")
                }
                let claims = (pt.claimIds ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                cleanedPoints.append(ChartPoint(label: label, value: pt.value, claimIds: claims.isEmpty ? nil : claims))
            }
            cleanedSeries.append(ChartSeries(name: name, points: cleanedPoints, unit: s.unit, colorHex: s.colorHex))
        }

        let typeStr = isLine ? "line" : "bar"
        return ComparisonChartData(
            series: cleanedSeries,
            unit: cleanUnit,
            xAxisLabel: xAxisLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
            yAxisLabel: yAxisLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
            chartType: typeStr,
            timeScale: timeScale ?? true
        )
    }

    func computeScale() -> AxisScale {
        let allValues = series.flatMap(\.points).map(\.value)
        guard !allValues.isEmpty else {
            return AxisScale(min: 0, max: 100, step: 25, ticks: [0, 25, 50, 75, 100])
        }
        var rawMin = allValues.min() ?? 0
        var rawMax = allValues.max() ?? 100
        if rawMin == rawMax {
            rawMin = rawMin > 0 ? 0 : rawMin - 10
            rawMax = rawMax + 10
        }
        if rawMin > 0 && rawMin / rawMax < 0.25 {
            rawMin = 0 // Anchor to zero for bar/percentage readability
        }

        let range = rawMax - rawMin
        let roughStep = range / 4.0
        let magnitude = pow(10, floor(log10(roughStep)))
        let normalizedStep = roughStep / magnitude
        let cleanStep: Double
        if normalizedStep < 1.5 { cleanStep = 1.0 * magnitude }
        else if normalizedStep < 3.0 { cleanStep = 2.0 * magnitude }
        else if normalizedStep < 7.0 { cleanStep = 5.0 * magnitude }
        else { cleanStep = 10.0 * magnitude }

        let niceMin = floor(rawMin / cleanStep) * cleanStep
        let niceMax = ceil(rawMax / cleanStep) * cleanStep
        var ticks: [Double] = []
        var current = niceMin
        while current <= niceMax + (cleanStep * 0.001) {
            ticks.append(current)
            current += cleanStep
        }
        return AxisScale(min: niceMin, max: niceMax, step: cleanStep, ticks: ticks)
    }
}

// MARK: - Policy Timeline Data

struct PolicyTimelineEvent: Codable, Sendable, Equatable {
    var date: String
    var title: String
    var description: String?
    var claimIds: [String]
    var tag: String?
}

struct PolicyTimelineData: Codable, Sendable, Equatable {
    var events: [PolicyTimelineEvent]

    func validated() throws -> Self {
        guard (2...12).contains(events.count) else {
            throw EvidenceGraphicError.malformedData("Policy timeline requires between 2 and 12 events.")
        }
        var cleanedEvents: [PolicyTimelineEvent] = []
        var previousYear = -10000

        for event in events {
            let dateStr = event.date.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !dateStr.isEmpty else { throw EvidenceGraphicError.malformedData("Event date must not be empty.") }
            try SourceCardData.validateDate(dateStr, field: "event date")

            let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw EvidenceGraphicError.malformedData("Event title must not be empty.") }

            let claims = event.claimIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !claims.isEmpty else {
                throw EvidenceGraphicError.fabricatedAttribution("Timeline event '\(title)' must cite at least one claimId.")
            }

            let yearStr = String(dateStr.prefix(4))
            guard let year = Int(yearStr) else {
                throw EvidenceGraphicError.malformedData("Event date '\(dateStr)' does not contain a 4-digit year.")
            }

            guard year >= previousYear else {
                throw EvidenceGraphicError.chronologyViolation("Event '\(title)' (\(dateStr)) appears after an event from year \(previousYear). Events must be chronological.")
            }
            previousYear = year

            cleanedEvents.append(PolicyTimelineEvent(
                date: dateStr,
                title: title,
                description: event.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                claimIds: claims,
                tag: event.tag?.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }

        return PolicyTimelineData(events: cleanedEvents)
    }
}

// MARK: - Graphic Style

struct EvidenceGraphicStyle: Codable, Sendable, Equatable {
    var backgroundColor: (r: Double, g: Double, b: Double) = (0.07, 0.09, 0.13)
    var cardBackgroundColor: (r: Double, g: Double, b: Double) = (0.12, 0.15, 0.22)
    var primaryColor: (r: Double, g: Double, b: Double) = (0.24, 0.58, 0.98)
    var secondaryColor: (r: Double, g: Double, b: Double) = (0.95, 0.55, 0.22)
    var textColor: (r: Double, g: Double, b: Double) = (0.96, 0.97, 0.99)
    var mutedTextColor: (r: Double, g: Double, b: Double) = (0.62, 0.67, 0.76)
    var gridColor: (r: Double, g: Double, b: Double) = (0.20, 0.25, 0.35)
    var accentColor: (r: Double, g: Double, b: Double) = (0.20, 0.78, 0.55)

    enum CodingKeys: String, CodingKey {
        case backgroundColor, cardBackgroundColor, primaryColor, secondaryColor
        case textColor, mutedTextColor, gridColor, accentColor
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let c = try container.decodeIfPresent([Double].self, forKey: .backgroundColor), c.count == 3 {
            backgroundColor = (c[0], c[1], c[2])
        }
        if let c = try container.decodeIfPresent([Double].self, forKey: .cardBackgroundColor), c.count == 3 {
            cardBackgroundColor = (c[0], c[1], c[2])
        }
        if let c = try container.decodeIfPresent([Double].self, forKey: .primaryColor), c.count == 3 {
            primaryColor = (c[0], c[1], c[2])
        }
        if let c = try container.decodeIfPresent([Double].self, forKey: .secondaryColor), c.count == 3 {
            secondaryColor = (c[0], c[1], c[2])
        }
        if let c = try container.decodeIfPresent([Double].self, forKey: .textColor), c.count == 3 {
            textColor = (c[0], c[1], c[2])
        }
        if let c = try container.decodeIfPresent([Double].self, forKey: .mutedTextColor), c.count == 3 {
            mutedTextColor = (c[0], c[1], c[2])
        }
        if let c = try container.decodeIfPresent([Double].self, forKey: .gridColor), c.count == 3 {
            gridColor = (c[0], c[1], c[2])
        }
        if let c = try container.decodeIfPresent([Double].self, forKey: .accentColor), c.count == 3 {
            accentColor = (c[0], c[1], c[2])
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode([backgroundColor.r, backgroundColor.g, backgroundColor.b], forKey: .backgroundColor)
        try container.encode([cardBackgroundColor.r, cardBackgroundColor.g, cardBackgroundColor.b], forKey: .cardBackgroundColor)
        try container.encode([primaryColor.r, primaryColor.g, primaryColor.b], forKey: .primaryColor)
        try container.encode([secondaryColor.r, secondaryColor.g, secondaryColor.b], forKey: .secondaryColor)
        try container.encode([textColor.r, textColor.g, textColor.b], forKey: .textColor)
        try container.encode([mutedTextColor.r, mutedTextColor.g, mutedTextColor.b], forKey: .mutedTextColor)
        try container.encode([gridColor.r, gridColor.g, gridColor.b], forKey: .gridColor)
        try container.encode([accentColor.r, accentColor.g, accentColor.b], forKey: .accentColor)
    }

    static func == (lhs: EvidenceGraphicStyle, rhs: EvidenceGraphicStyle) -> Bool {
        lhs.backgroundColor == rhs.backgroundColor &&
        lhs.cardBackgroundColor == rhs.cardBackgroundColor &&
        lhs.primaryColor == rhs.primaryColor &&
        lhs.secondaryColor == rhs.secondaryColor &&
        lhs.textColor == rhs.textColor &&
        lhs.mutedTextColor == rhs.mutedTextColor &&
        lhs.gridColor == rhs.gridColor &&
        lhs.accentColor == rhs.accentColor
    }
}

// MARK: - Evidence Graphic Specification

enum GraphicData: Sendable, Equatable {
    case numericComparison(NumericComparisonData)
    case sourceCard(SourceCardData)
    case comparisonChart(ComparisonChartData)
    case policyTimeline(PolicyTimelineData)
}

struct EvidenceGraphicSpec: Sendable, Equatable {
    var kind: EvidenceGraphicKind
    var title: String
    var subtitle: String?
    var data: GraphicData
    var durationFrames: Int
    var width: Int
    var height: Int
    var revealFrame: Int
    var holdFrame: Int
    var style: EvidenceGraphicStyle
    var digest: String
    var claimIds: [String]

    static func validated(
        kind: EvidenceGraphicKind,
        title: String,
        subtitle: String? = nil,
        numericData: NumericComparisonData? = nil,
        sourceCardData: SourceCardData? = nil,
        chartData: ComparisonChartData? = nil,
        timelineData: PolicyTimelineData? = nil,
        durationFrames: Int? = 180,
        width: Int? = 1920,
        height: Int? = 1080,
        revealFrame: Int? = 0,
        style: EvidenceGraphicStyle = EvidenceGraphicStyle()
    ) throws -> EvidenceGraphicSpec {
        let duration = durationFrames ?? 180
        guard (30...3600).contains(duration) else {
            throw EvidenceGraphicError.invalidBounds("durationFrames must be between 30 and 3600 (1s–2m at 30fps).")
        }
        let w = width ?? 1920
        let h = height ?? 1080
        guard (320...3840).contains(w), (240...2160).contains(h) else {
            throw EvidenceGraphicError.invalidBounds("width must be 320–3840 and height 240–2160.")
        }
        let reveal = revealFrame ?? 0
        guard (0..<duration).contains(reveal) else {
            throw EvidenceGraphicError.invalidBounds("revealFrame must be within the duration (0..<\(duration)).")
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            throw EvidenceGraphicError.malformedData("Graphic title must not be empty.")
        }
        let cleanSubtitle = subtitle?.trimmingCharacters(in: .whitespacesAndNewlines)

        let resolvedData: GraphicData
        var referencedClaims: [String] = []

        switch kind {
        case .numericComparison:
            guard let numericData else {
                throw EvidenceGraphicError.malformedData("kind 'numeric_comparison' requires numericData.")
            }
            let valid = try numericData.validated()
            resolvedData = .numericComparison(valid)
            referencedClaims = valid.items.flatMap { $0.claimIds ?? [] }

        case .sourceCard:
            guard let sourceCardData else {
                throw EvidenceGraphicError.malformedData("kind 'source_card' requires sourceCardData.")
            }
            let valid = try sourceCardData.validated()
            resolvedData = .sourceCard(valid)
            referencedClaims = valid.claimIds

        case .comparisonChart:
            guard let chartData else {
                throw EvidenceGraphicError.malformedData("kind 'comparison_chart' requires chartData.")
            }
            let valid = try chartData.validated()
            resolvedData = .comparisonChart(valid)
            referencedClaims = valid.series.flatMap { $0.points.flatMap { $0.claimIds ?? [] } }

        case .policyTimeline:
            guard let timelineData else {
                throw EvidenceGraphicError.malformedData("kind 'policy_timeline' requires timelineData.")
            }
            let valid = try timelineData.validated()
            resolvedData = .policyTimeline(valid)
            referencedClaims = valid.events.flatMap(\.claimIds)
        }

        let uniqueClaims = Array(Set(referencedClaims)).sorted()

        var digestInput = "\(kind.rawValue):\(cleanTitle):\(cleanSubtitle ?? ""):\(duration):\(w)x\(h)"
        switch resolvedData {
        case .numericComparison(let d):
            digestInput += ":numeric:" + d.items.map { "\($0.label)=\($0.value)\($0.unit)" }.joined(separator: ",")
        case .sourceCard(let d):
            digestInput += ":source:\(d.title):\(d.author):\(d.accessedDate):\(d.url ?? d.documentReference ?? "")"
        case .comparisonChart(let d):
            digestInput += ":chart:\(d.unit):" + d.series.map { s in
                "\(s.name)=" + s.points.map { "\($0.label):\($0.value)" }.joined(separator: ",")
            }.joined(separator: ";")
        case .policyTimeline(let d):
            digestInput += ":timeline:" + d.events.map { "\($0.date):\($0.title)" }.joined(separator: ";")
        }
        let digest = SHA256.hash(data: Data(digestInput.utf8)).compactMap { String(format: "%02x", $0) }.joined()

        return EvidenceGraphicSpec(
            kind: kind,
            title: cleanTitle,
            subtitle: cleanSubtitle,
            data: resolvedData,
            durationFrames: duration,
            width: w,
            height: h,
            revealFrame: reveal,
            holdFrame: duration,
            style: style,
            digest: digest,
            claimIds: uniqueClaims
        )
    }

    var receipt: [String: Any] {
        var row: [String: Any] = [
            "kind": kind.rawValue,
            "title": title,
            "durationFrames": durationFrames,
            "width": width,
            "height": height,
            "revealFrame": revealFrame,
            "digest": digest,
            "claimIds": claimIds,
        ]
        if let subtitle { row["subtitle"] = subtitle }
        switch data {
        case .numericComparison(let num):
            row["items"] = num.items.map { item in
                var r: [String: Any] = ["label": item.label, "value": item.value, "unit": item.unit]
                if let claims = item.claimIds { r["claimIds"] = claims }
                if let baseline = item.baseline { r["baseline"] = baseline }
                if let note = item.note { r["note"] = note }
                return r
            }
            if let type = num.comparisonType { row["comparisonType"] = type }
            if let delta = num.delta {
                row["computedDelta"] = ["absolute": delta.absolute, "percent": delta.percent]
            }
        case .sourceCard(let card):
            var c: [String: Any] = [
                "title": card.title,
                "author": card.author,
                "accessedDate": card.accessedDate,
                "claimIds": card.claimIds,
            ]
            if let pub = card.publicationDate { c["publicationDate"] = pub }
            if let url = card.url { c["url"] = url }
            if let doc = card.documentReference { c["documentReference"] = doc }
            if let quote = card.quotation { c["quotation"] = quote }
            if let para = card.paraphrase { c["paraphrase"] = para }
            row["sourceCard"] = c
        case .comparisonChart(let chart):
            row["unit"] = chart.unit
            row["chartType"] = chart.chartType ?? "line"
            row["series"] = chart.series.map { s in
                [
                    "name": s.name,
                    "points": s.points.map { ["label": $0.label, "value": $0.value] },
                ] as [String: Any]
            }
            let scale = chart.computeScale()
            row["scale"] = ["min": scale.min, "max": scale.max, "step": scale.step, "ticks": scale.ticks]
        case .policyTimeline(let timeline):
            row["events"] = timeline.events.map { e in
                var ev: [String: Any] = ["date": e.date, "title": e.title, "claimIds": e.claimIds]
                if let desc = e.description { ev["description"] = desc }
                if let tag = e.tag { ev["tag"] = tag }
                return ev
            }
        }
        return row
    }
}


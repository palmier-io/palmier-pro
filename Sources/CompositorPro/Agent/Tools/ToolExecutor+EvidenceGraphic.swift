import Foundation

extension ToolExecutor {
    private struct BuildGraphicSceneInput: DecodableToolArgs {
        var kind: String
        var title: String
        var subtitle: String?
        var items: [NumericComparisonItem]?
        var comparisonType: String?
        var deltaLabel: String?
        var showDelta: Bool?
        var sourceCard: SourceCardData?
        var author: String?
        var publicationDate: String?
        var accessedDate: String?
        var url: String?
        var documentReference: String?
        var quotation: String?
        var paraphrase: String?
        var series: [ChartSeries]?
        var unit: String?
        var xAxisLabel: String?
        var yAxisLabel: String?
        var chartType: String?
        var events: [PolicyTimelineEvent]?
        var durationFrames: Int?
        var width: Int?
        var height: Int?
        var name: String?
        var addToTimeline: Bool?
        var startFrame: Int?
        var planId: String?
        var narrationText: String?
        var claimIds: [String]?

        static let allowedKeys: Set<String> = [
            "kind", "title", "subtitle", "items", "comparisonType", "deltaLabel", "showDelta",
            "sourceCard", "author", "publicationDate", "accessedDate", "url", "documentReference",
            "quotation", "paraphrase", "series", "unit", "xAxisLabel", "yAxisLabel", "chartType",
            "events", "durationFrames", "width", "height", "name", "addToTimeline", "startFrame",
            "planId", "narrationText", "claimIds",
        ]
    }

    /// Builds a typed graphic family scene (numeric comparison, source card, comparison chart,
    /// or dated policy timeline) from real structured inputs, bakes a ProRes 4444 video,
    /// and adds it to the media library / timeline.
    func buildGraphicScene(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: BuildGraphicSceneInput = try decodeToolArgs(args, path: "build_graphic_scene")

        guard let graphicKind = EvidenceGraphicKind(rawValue: input.kind.lowercased()) else {
            let validKinds = EvidenceGraphicKind.allCases.map(\.rawValue).joined(separator: ", ")
            throw ToolError("build_graphic_scene: kind must be one of: \(validKinds).")
        }

        var numData: NumericComparisonData?
        var cardData: SourceCardData?
        var chartData: ComparisonChartData?
        var timelineData: PolicyTimelineData?

        switch graphicKind {
        case .numericComparison:
            guard let items = input.items, !items.isEmpty else {
                throw ToolError("build_graphic_scene: numeric_comparison requires 'items'.")
            }
            numData = NumericComparisonData(
                items: items,
                comparisonType: input.comparisonType,
                deltaLabel: input.deltaLabel,
                showDelta: input.showDelta
            )

        case .sourceCard:
            if let sc = input.sourceCard {
                cardData = sc
            } else {
                guard let author = input.author, let access = input.accessedDate else {
                    throw ToolError("build_graphic_scene: source_card requires 'author' and 'accessedDate'.")
                }
                let claims = input.claimIds ?? []
                cardData = SourceCardData(
                    sourceId: nil,
                    title: input.title,
                    author: author,
                    publicationDate: input.publicationDate,
                    accessedDate: access,
                    url: input.url,
                    documentReference: input.documentReference,
                    quotation: input.quotation,
                    paraphrase: input.paraphrase,
                    claimIds: claims
                )
            }

        case .comparisonChart:
            guard let series = input.series, !series.isEmpty, let unit = input.unit else {
                throw ToolError("build_graphic_scene: comparison_chart requires 'series' and 'unit'.")
            }
            chartData = ComparisonChartData(
                series: series,
                unit: unit,
                xAxisLabel: input.xAxisLabel,
                yAxisLabel: input.yAxisLabel,
                chartType: input.chartType
            )

        case .policyTimeline:
            guard let events = input.events, !events.isEmpty else {
                throw ToolError("build_graphic_scene: policy_timeline requires 'events'.")
            }
            timelineData = PolicyTimelineData(events: events)
        }

        let spec: EvidenceGraphicSpec
        do {
            spec = try EvidenceGraphicSpec.validated(
                kind: graphicKind,
                title: input.title,
                subtitle: input.subtitle,
                numericData: numData,
                sourceCardData: cardData,
                chartData: chartData,
                timelineData: timelineData,
                durationFrames: input.durationFrames,
                width: input.width ?? editor.timeline.width,
                height: input.height ?? editor.timeline.height
            )
        } catch let error as EvidenceGraphicError {
            throw ToolError("build_graphic_scene: \(error.localizedDescription ?? error.errorDescription ?? "invalid spec")")
        }

        let addToTimeline = input.addToTimeline ?? false
        let startFrame = input.startFrame ?? 0
        guard (0...1_099_511_627_776).contains(startFrame) else {
            throw ToolError("build_graphic_scene: startFrame is out of range.")
        }

        let plan = try await editor.prepareGraphicScene(
            spec,
            name: input.name,
            addToTimeline: addToTimeline,
            startFrame: startFrame,
            planId: input.planId,
            narrationText: input.narrationText
        )

        var payload: [String: Any] = [
            "mediaRef": plan.asset.id,
            "name": plan.asset.name,
            "path": plan.asset.url.path,
            "type": plan.asset.type.rawValue,
            "kind": spec.kind.rawValue,
            "width": spec.width,
            "height": spec.height,
            "durationFrames": spec.durationFrames,
            "digest": plan.digest,
            "claimIds": spec.claimIds,
            "spec": spec.receipt,
        ]
        if let clipId = plan.clipId {
            payload["clipId"] = clipId
            payload["startFrame"] = startFrame
        }
        if !plan.warnings.isEmpty { payload["warnings"] = plan.warnings }
        return .ok(Self.jsonString(payload) ?? "{}")
    }
}


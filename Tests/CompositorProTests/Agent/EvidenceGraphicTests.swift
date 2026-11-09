import AppKit
import Foundation
import Testing
@testable import CompositorPro

@Suite("Evidence graphic validation")
struct EvidenceGraphicValidationTests {
    @Test func numericComparisonValidatesBoundsAndCompatibleUnits() throws {
        // Valid comparison
        let valid = try NumericComparisonData(
            items: [
                .init(label: "Announced", value: 25.0, unit: "USD Billion", claimIds: ["c1"], baseline: true, note: nil),
                .init(label: "Realized", value: 18.5, unit: "USD Billion", claimIds: ["c2"], baseline: false, note: nil),
            ],
            comparisonType: "announced_vs_realized",
            deltaLabel: nil,
            showDelta: true
        ).validated()
        #expect(valid.items.count == 2)
        let delta = try #require(valid.delta)
        #expect(abs(delta.absolute - (-6.5)) < 0.001)
        #expect(abs(delta.percent - (-26.0)) < 0.1)

        // Incompatible units rejected
        #expect(throws: EvidenceGraphicError.incompatibleUnits("Cannot compare 'USD' with '%' in a numeric comparison.")) {
            try NumericComparisonData(
                items: [
                    .init(label: "Exports", value: 100, unit: "USD"),
                    .init(label: "Share", value: 15, unit: "%"),
                ]
            ).validated()
        }

        // Non-finite value rejected
        #expect(throws: EvidenceGraphicError.nonFiniteNumber("Value for 'Infinity' must be a finite number.")) {
            try NumericComparisonData(
                items: [
                    .init(label: "Valid", value: 10, unit: "RM"),
                    .init(label: "Infinity", value: .infinity, unit: "RM"),
                ]
            ).validated()
        }

        // Less than 2 items rejected
        #expect(throws: EvidenceGraphicError.malformedData("Numeric comparison requires between 2 and 6 items to compare.")) {
            try NumericComparisonData(items: [.init(label: "Solo", value: 10, unit: "USD")]).validated()
        }
    }

    @Test func sourceCardRequiresAuthenticProvenance() throws {
        // Valid source card with URL
        let validURL = try SourceCardData(
            sourceId: "s1",
            title: "Malaysia Semiconductor Strategy",
            author: "Ministry of Investment, Trade and Industry (MITI)",
            publicationDate: "2024-05-28",
            accessedDate: "2026-11-01",
            url: "https://miti.gov.my/report2024.pdf",
            documentReference: nil,
            quotation: "Targeting 500 billion MYR in semiconductor investments.",
            paraphrase: nil,
            claimIds: ["c-semi-1"]
        ).validated()
        #expect(validURL.author.contains("MITI"))

        // Missing both URL and documentReference rejected
        #expect(throws: EvidenceGraphicError.fabricatedAttribution("Source card requires exactly one of 'url' or 'documentReference' for verifiable provenance.")) {
            try SourceCardData(
                sourceId: nil,
                title: "Fabricated Source",
                author: "Anonymous",
                publicationDate: "2024",
                accessedDate: "2026-11-01",
                url: nil,
                documentReference: nil,
                quotation: "Unverifiable assertion.",
                paraphrase: nil,
                claimIds: ["c1"]
            ).validated()
        }

        // Having both URL and documentReference rejected
        #expect(throws: EvidenceGraphicError.fabricatedAttribution("Source card requires exactly one of 'url' or 'documentReference' for verifiable provenance.")) {
            try SourceCardData(
                sourceId: nil,
                title: "Confused Source",
                author: "Author",
                publicationDate: "2024",
                accessedDate: "2026-11-01",
                url: "https://example.com",
                documentReference: "Doc ref",
                quotation: "Double reference.",
                paraphrase: nil,
                claimIds: ["c1"]
            ).validated()
        }

        // Missing claimIds rejected
        #expect(throws: EvidenceGraphicError.fabricatedAttribution("Source card must cite at least one claimId from the ledger.")) {
            try SourceCardData(
                sourceId: nil,
                title: "Unlinked Source",
                author: "Author",
                publicationDate: "2024",
                accessedDate: "2026-11-01",
                url: "https://example.com",
                documentReference: nil,
                quotation: "No claims.",
                paraphrase: nil,
                claimIds: []
            ).validated()
        }
    }

    @Test func comparisonChartComputesDeterministicScales() throws {
        let chart = try ComparisonChartData(
            series: [
                .init(name: "Malaysia", points: [
                    .init(label: "1990", value: 2400),
                    .init(label: "2000", value: 4000),
                    .init(label: "2010", value: 9000),
                    .init(label: "2020", value: 10400),
                ]),
                .init(name: "South Korea", points: [
                    .init(label: "1990", value: 6500),
                    .init(label: "2000", value: 12000),
                    .init(label: "2010", value: 23000),
                    .init(label: "2020", value: 32000),
                ]),
            ],
            unit: "USD / capita"
        ).validated()

        let scale = chart.computeScale()
        #expect(scale.min == 0)
        #expect(scale.max >= 32000)
        #expect(scale.step > 0)
        #expect(!scale.ticks.isEmpty)
        #expect(scale.ticks.contains(0))
    }

    @Test func policyTimelineEnforcesChronologicalOrdering() throws {
        // Chronological events pass
        let valid = try PolicyTimelineData(
            events: [
                .init(date: "1972", title: "Penang Free Trade Zone", description: "Establishment of Bayan Lepas FTZ.", claimIds: ["c1"]),
                .init(date: "1985", title: "National Industrial Policy", description: "Heavy industrialization push.", claimIds: ["c2"]),
                .init(date: "2024-05-28", title: "National Semiconductor Strategy", description: "500B MYR investment target.", claimIds: ["c3"]),
            ]
        ).validated()
        #expect(valid.events.count == 3)

        // Out-of-order events rejected
        #expect(throws: EvidenceGraphicError.chronologyViolation("Event 'Bayan Lepas' (1972) appears after an event from year 1995. Events must be chronological.")) {
            try PolicyTimelineData(
                events: [
                    .init(date: "1995", title: "Kulim Hi-Tech Park", claimIds: ["c1"]),
                    .init(date: "1972", title: "Bayan Lepas", claimIds: ["c2"]),
                ]
            ).validated()
        }
    }
}

@Suite("Display and narration agreement")
struct EvidenceGraphicNarrationAgreementTests {
    @Test func detectsGDPVersusGDPPerCapitaDisagreement() throws {
        let spec = try EvidenceGraphicSpec.validated(
            kind: .numericComparison,
            title: "Malaysia vs South Korea GDP per capita",
            numericData: .init(items: [
                .init(label: "Malaysia", value: 13000, unit: "USD / capita", claimIds: ["c1"]),
                .init(label: "South Korea", value: 33000, unit: "USD / capita", claimIds: ["c2"]),
            ])
        )

        // Narration asserts total GDP instead of per capita -> rejected
        let mismatchedNarration = "Malaysia's gross domestic product reached 400 billion dollars while South Korea reached 1.7 trillion."
        #expect(throws: EvidenceGraphicError.narrationDisagreement("Graphic displays 'GDP per capita', but narration describes total 'GDP' without 'per capita'. Display and narration must agree.")) {
            try EvidenceGraphicNarrationValidator.validate(spec: spec, narration: mismatchedNarration)
        }

        // Narration correctly asserts per capita -> passes
        let matchingNarration = "Malaysia's GDP per capita stands at 13,000 dollars, while South Korea's per capita income surged past 33,000."
        try EvidenceGraphicNarrationValidator.validate(spec: spec, narration: matchingNarration)
    }

    @Test func detectsNominalVersusAdjustedDisagreement() throws {
        let spec = try EvidenceGraphicSpec.validated(
            kind: .numericComparison,
            title: "Nominal Semiconductor Output",
            numericData: .init(
                items: [
                    .init(label: "2015 Output", value: 100, unit: "Billion MYR"),
                    .init(label: "2024 Output", value: 180, unit: "Billion MYR"),
                ],
                comparisonType: "nominal_vs_adjusted"
            )
        )

        // Narration asserts real/inflation-adjusted output -> rejected
        let mismatchedNarration = "In real terms adjusted for inflation, semiconductor output grew significantly."
        #expect(throws: EvidenceGraphicError.narrationDisagreement("Graphic displays 'Nominal' values, but narration asserts inflation-'Adjusted' or 'Real' values.")) {
            try EvidenceGraphicNarrationValidator.validate(spec: spec, narration: mismatchedNarration)
        }

        // Matching narration -> passes
        let matchingNarration = "In nominal figures at current prices, output grew from 100 billion to 180 billion ringgit."
        try EvidenceGraphicNarrationValidator.validate(spec: spec, narration: matchingNarration)
    }

    @Test func detectsAnnouncedVersusRealizedDisagreement() throws {
        let spec = try EvidenceGraphicSpec.validated(
            kind: .numericComparison,
            title: "Foreign Direct Investment",
            numericData: .init(
                items: [
                    .init(label: "Announced Pledges", value: 50, unit: "Billion USD"),
                    .init(label: "Pipeline Target", value: 60, unit: "Billion USD"),
                ],
                comparisonType: "announced_vs_realized"
            )
        )

        // Narration claims realized / disbursed investment -> rejected
        let mismatchedNarration = "Malaysia has realized 50 billion dollars in actual disbursed foreign investment."
        #expect(throws: EvidenceGraphicError.narrationDisagreement("Graphic displays 'Announced' investment, but narration asserts 'Realized' or 'Actual' investment.")) {
            try EvidenceGraphicNarrationValidator.validate(spec: spec, narration: mismatchedNarration)
        }

        // Matching narration -> passes
        let matchingNarration = "The government announced 50 billion dollars in pledged commitments."
        try EvidenceGraphicNarrationValidator.validate(spec: spec, narration: matchingNarration)
    }

    @Test func detectsQuantitativeClaimValueDisagreement() throws {
        let claim = SourceClaimLedger.Claim(
            claimId: "claim-val-1",
            kind: .quantity,
            statement: "Penang wafer fab capacity expansion",
            value: 25.0,
            unit: "Billion USD",
            evidence: [.init(sourceId: "src-1", passage: "25 billion USD committed")],
            status: .reviewed
        )

        let spec = try EvidenceGraphicSpec.validated(
            kind: .numericComparison,
            title: "Wafer Fab Investment",
            numericData: .init(items: [
                .init(label: "Penang Fab", value: 40.0, unit: "Billion USD", claimIds: ["claim-val-1"]),
                .init(label: "Baseline", value: 20.0, unit: "Billion USD", claimIds: nil),
            ])
        )

        #expect(throws: EvidenceGraphicError.narrationDisagreement("Graphic item 'Penang Fab' value (40.0) disagrees with claim 'claim-val-1' value (25.0).")) {
            try EvidenceGraphicNarrationValidator.validate(spec: spec, narration: "Investment was 25 billion.", claims: [claim])
        }
    }
}

@Suite("Evidence graphic Lottie rendering")
struct EvidenceGraphicLottieTests {
    @Test func lottieCarriesBodymovinSignatureForAllGraphicKinds() throws {
        let numericSpec = try EvidenceGraphicSpec.validated(
            kind: .numericComparison,
            title: "Investment Comparison",
            numericData: .init(items: [
                .init(label: "A", value: 10, unit: "USD"),
                .init(label: "B", value: 20, unit: "USD"),
            ]),
            durationFrames: 60, width: 960, height: 540
        )
        let numData = try EvidenceGraphicLottie.data(for: numericSpec)
        let numURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-num-\(UUID().uuidString).json")
        try numData.write(to: numURL)
        defer { try? FileManager.default.removeItem(at: numURL) }
        #expect(LottieVideoGenerator.isLottie(at: numURL))

        let sourceSpec = try EvidenceGraphicSpec.validated(
            kind: .sourceCard,
            title: "MIDA Semiconductor Report",
            sourceCardData: .init(
                title: "MIDA Report",
                author: "MIDA",
                accessedDate: "2026-11-01",
                url: "https://mida.gov.my",
                quotation: "Growing at 10% annually.",
                claimIds: ["c1"]
            ),
            durationFrames: 60, width: 960, height: 540
        )
        let srcData = try EvidenceGraphicLottie.data(for: sourceSpec)
        let srcURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-src-\(UUID().uuidString).json")
        try srcData.write(to: srcURL)
        defer { try? FileManager.default.removeItem(at: srcURL) }
        #expect(LottieVideoGenerator.isLottie(at: srcURL))

        let chartSpec = try EvidenceGraphicSpec.validated(
            kind: .comparisonChart,
            title: "Growth Comparison",
            chartData: .init(
                series: [.init(name: "Series 1", points: [.init(label: "2020", value: 50), .init(label: "2024", value: 100)])],
                unit: "MYR"
            ),
            durationFrames: 60, width: 960, height: 540
        )
        let chartData = try EvidenceGraphicLottie.data(for: chartSpec)
        let chartURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-chart-\(UUID().uuidString).json")
        try chartData.write(to: chartURL)
        defer { try? FileManager.default.removeItem(at: chartURL) }
        #expect(LottieVideoGenerator.isLottie(at: chartURL))

        let timelineSpec = try EvidenceGraphicSpec.validated(
            kind: .policyTimeline,
            title: "Industrial Timeline",
            timelineData: .init(events: [
                .init(date: "1972", title: "Free Trade Zone", claimIds: ["c1"]),
                .init(date: "2024", title: "New Industrial Master Plan", claimIds: ["c2"]),
            ]),
            durationFrames: 60, width: 960, height: 540
        )
        let timelineData = try EvidenceGraphicLottie.data(for: timelineSpec)
        let timeURL = FileManager.default.temporaryDirectory.appendingPathComponent("test-time-\(UUID().uuidString).json")
        try timelineData.write(to: timeURL)
        defer { try? FileManager.default.removeItem(at: timeURL) }
        #expect(LottieVideoGenerator.isLottie(at: timeURL))
    }
}

@Suite("Evidence graphic MCP tool integration")
@MainActor
struct EvidenceGraphicMCPTests {
    @Test func buildGraphicSceneRegistersLibraryAssetAndPlacesOnTimeline() async throws {
        try await withSavedMediaPackageTestFixture { fixture, document in
            let editor = document.editorViewModel
            editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack()])
            let undo = UndoManager()
            undo.groupsByEvent = false
            editor.undo.attach(undo)

            let executor = ToolExecutor(editor: editor)
            let result = await executor.execute(name: "build_graphic_scene", args: [
                "kind": "numeric_comparison",
                "title": "Malaysia vs Vietnam Chip Assembly",
                "items": [
                    ["label": "Malaysia", "value": 13.0, "unit": "Percent global packaging"],
                    ["label": "Vietnam", "value": 4.5, "unit": "Percent global packaging"],
                ],
                "durationFrames": 60,
                "width": 480,
                "height": 270,
                "addToTimeline": true,
                "startFrame": 0,
            ])

            #expect(!result.isError, "\(ToolHarness.textOf(result))")
            let receipt = try #require(JSONSerialization.jsonObject(with: Data(ToolHarness.textOf(result).utf8)) as? [String: Any])
            let mediaRef = try #require(receipt["mediaRef"] as? String)
            let asset = try #require(editor.mediaAssets.first { $0.id.hasPrefix(mediaRef) || mediaRef.hasPrefix($0.id) })
            #expect(asset.type == .video)
            #expect(receipt["kind"] as? String == "numeric_comparison")

            let placedClips = editor.timeline.tracks.flatMap(\.clips).filter { $0.mediaRef == asset.id }
            #expect(placedClips.count == 1)
            #expect(placedClips.first?.durationFrames == 60)

            undo.undo()
            #expect(editor.timeline.tracks.flatMap(\.clips).filter { $0.mediaRef == asset.id }.isEmpty)
        }
    }

    @Test func correctingClaimValueSynchronizesDependentsWithoutLeavingStaleData() throws {
        var plan = EditPlan(
            id: "plan-claims-1",
            name: "Penang Chip Explainer",
            timelineId: "tl-1",
            fps: 30,
            width: 1920,
            height: 1080,
            sections: [],
            shots: [
                .init(id: "shot-1", title: "Intro Stat", startFrame: 0, endFrame: 60, claimIds: ["c-stat-1"]),
            ],
            sourceLedger: .init(
                sources: [
                    .init(sourceId: "s1", title: "MIDA", url: "https://mida.gov.my", author: "MIDA", accessedDate: "2026-11-01")
                ],
                claims: [
                    .init(
                        claimId: "c-stat-1",
                        kind: .quantity,
                        statement: "Announced investment volume",
                        value: 20.0,
                        unit: "Billion USD",
                        evidence: [.init(sourceId: "s1", passage: "20 billion USD announced")],
                        status: .reviewed
                    )
                ]
            ),
            scriptBeats: [
                .init(beatId: "beat-1", text: "Malaysia announced 20 Billion USD in new projects.", purpose: "Establish volume", claimIds: ["c-stat-1"])
            ]
        )

        // Update the claim from 20.0 to 25.0, and synchronize narration
        let report = try plan.updateClaimAndSyncDependents(
            claimId: "c-stat-1",
            newValue: 25.0,
            newUnit: "Billion USD",
            narrationUpdates: ["beat-1": "Malaysia announced 25 Billion USD in new projects."]
        )

        #expect(report["claimId"] as? String == "c-stat-1")
        let updatedClaim = try #require(plan.sourceLedger?.claims.first { $0.claimId == "c-stat-1" })
        #expect(updatedClaim.value == 25.0)
        #expect(updatedClaim.status == SourceClaimLedger.Claim.Status.unresolved) // must be re-reviewed

        let updatedBeat = try #require(plan.scriptBeats?.first { $0.beatId == "beat-1" })
        #expect(updatedBeat.text == "Malaysia announced 25 Billion USD in new projects.")
        #expect(!updatedBeat.text.contains("20 Billion")) // old value is not left behind!

        let dependents = try #require(report["dependents"] as? [String: [String]])
        #expect(dependents["shotIds"] == ["shot-1"])
        #expect(dependents["beatIds"] == ["beat-1"])
    }
}

import Foundation

enum EvidenceGraphicNarrationValidator {
    /// Validates display/narration agreement against text or script beats.
    /// Rejects semantic traps: GDP vs GDP per capita, nominal vs adjusted values,
    /// announced vs realized investment, and mismatched numbers.
    static func validate(
        spec: EvidenceGraphicSpec,
        narration: String,
        claims: [SourceClaimLedger.Claim] = []
    ) throws {
        let text = narration.lowercased()
        guard !text.isEmpty else { return }

        // 1. GDP vs GDP per capita
        let specMentionsPerCapita = specTextContains(spec, terms: ["per capita", "/capita", "per person", "per head"])
        let specMentionsGDP = specTextContains(spec, terms: ["gdp", "gross domestic product"])
        let narrationMentionsPerCapita = text.contains("per capita") || text.contains("per person") || text.contains("per head")
        let narrationMentionsGDP = text.contains("gdp") || text.contains("gross domestic product")

        if specMentionsGDP && specMentionsPerCapita {
            if narrationMentionsGDP && !narrationMentionsPerCapita {
                throw EvidenceGraphicError.narrationDisagreement(
                    "Graphic displays 'GDP per capita', but narration describes total 'GDP' without 'per capita'. Display and narration must agree."
                )
            }
        } else if specMentionsGDP && !specMentionsPerCapita {
            if narrationMentionsGDP && narrationMentionsPerCapita {
                throw EvidenceGraphicError.narrationDisagreement(
                    "Graphic displays total 'GDP', but narration describes 'GDP per capita'. Display and narration must agree."
                )
            }
        }

        // 2. Nominal vs Adjusted values
        let specMentionsNominal = specTextContains(spec, terms: ["nominal", "current prices", "current dollars"])
        let specMentionsAdjusted = specTextContains(spec, terms: ["adjusted", "real gdp", "constant prices", "constant dollars", "inflation-adjusted", "real"])
        let narrationMentionsNominal = text.contains("nominal") || text.contains("current prices") || text.contains("current dollars")
        let narrationMentionsAdjusted = text.contains("adjusted") || text.contains("inflation-adjusted") || text.contains("constant prices") || text.contains("real terms") || text.contains("real gdp")

        if specMentionsNominal && !specMentionsAdjusted {
            if narrationMentionsAdjusted && !narrationMentionsNominal {
                throw EvidenceGraphicError.narrationDisagreement(
                    "Graphic displays 'Nominal' values, but narration asserts inflation-'Adjusted' or 'Real' values."
                )
            }
        } else if specMentionsAdjusted && !specMentionsNominal {
            if narrationMentionsNominal && !narrationMentionsAdjusted {
                throw EvidenceGraphicError.narrationDisagreement(
                    "Graphic displays 'Adjusted' / 'Real' values, but narration asserts 'Nominal' values."
                )
            }
        }

        // 3. Announced vs Realized investment
        let specMentionsAnnounced = specTextContains(spec, terms: ["announced", "pledged", "proposed", "committed investment", "pipeline"])
        let specMentionsRealized = specTextContains(spec, terms: ["realized", "actual investment", "disbursed", "invested to date", "completed investment"])
        let narrationMentionsAnnounced = text.contains("announced") || text.contains("pledged") || text.contains("committed")
        let narrationMentionsRealized = text.contains("realized") || text.contains("actual") || text.contains("disbursed") || text.contains("spent to date") || text.contains("invested to date")

        if specMentionsAnnounced && !specMentionsRealized {
            if narrationMentionsRealized && !narrationMentionsAnnounced {
                throw EvidenceGraphicError.narrationDisagreement(
                    "Graphic displays 'Announced' investment, but narration asserts 'Realized' or 'Actual' investment."
                )
            }
        } else if specMentionsRealized && !specMentionsAnnounced {
            if narrationMentionsAnnounced && !narrationMentionsRealized {
                throw EvidenceGraphicError.narrationDisagreement(
                    "Graphic displays 'Realized' investment, but narration asserts 'Announced' investment."
                )
            }
        }

        // 4. Validate quantitative values against cited claims
        let claimMap = Dictionary(uniqueKeysWithValues: claims.map { ($0.claimId, $0) })
        for claimId in spec.claimIds {
            guard let claim = claimMap[claimId], claim.kind == .quantity, let claimVal = claim.value, let claimUnit = claim.unit else {
                continue
            }
            switch spec.data {
            case .numericComparison(let num):
                for item in num.items where (item.claimIds ?? []).contains(claimId) {
                    if abs(item.value - claimVal) > 0.001 {
                        throw EvidenceGraphicError.narrationDisagreement(
                            "Graphic item '\(item.label)' value (\(item.value)) disagrees with claim '\(claimId)' value (\(claimVal))."
                        )
                    }
                    if !NumericComparisonData.areUnitsCompatible(item.unit, claimUnit) {
                        throw EvidenceGraphicError.narrationDisagreement(
                            "Graphic item '\(item.label)' unit '\(item.unit)' disagrees with claim '\(claimId)' unit '\(claimUnit)'."
                        )
                    }
                }
            case .comparisonChart(let chart):
                for series in chart.series {
                    for pt in series.points where (pt.claimIds ?? []).contains(claimId) {
                        if abs(pt.value - claimVal) > 0.001 {
                            throw EvidenceGraphicError.narrationDisagreement(
                                "Chart point '\(pt.label)' value (\(pt.value)) in series '\(series.name)' disagrees with claim '\(claimId)' value (\(claimVal))."
                            )
                        }
                    }
                }
            default:
                break
            }
        }
    }

    private static func specTextContains(_ spec: EvidenceGraphicSpec, terms: [String]) -> Bool {
        var texts: [String] = [spec.title, spec.subtitle ?? ""]
        switch spec.data {
        case .numericComparison(let d):
            texts.append(contentsOf: d.items.map(\.label))
            texts.append(contentsOf: d.items.map(\.unit))
            texts.append(contentsOf: d.items.compactMap(\.note))
        case .sourceCard(let d):
            texts.append(d.title)
            if let q = d.quotation { texts.append(q) }
            if let p = d.paraphrase { texts.append(p) }
        case .comparisonChart(let d):
            texts.append(d.unit)
            if let x = d.xAxisLabel { texts.append(x) }
            if let y = d.yAxisLabel { texts.append(y) }
            texts.append(contentsOf: d.series.map(\.name))
        case .policyTimeline(let d):
            texts.append(contentsOf: d.events.map(\.title))
            texts.append(contentsOf: d.events.compactMap(\.description))
        }
        let full = texts.joined(separator: " ").lowercased()
        return terms.contains { full.contains($0) }
    }
}

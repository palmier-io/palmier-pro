import Foundation

enum EvidenceGraphicLottie {
    static let fps = 30

    static func json(for spec: EvidenceGraphicSpec) -> [String: Any] {
        let duration = spec.durationFrames
        let w = spec.width
        let h = spec.height
        let style = spec.style

        var layers: [[String: Any]] = []
        var layerIndex = 1

        func hex(_ c: (r: Double, g: Double, b: Double)) -> String {
            String(format: "%02X%02X%02X", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
        }

        func opacityKeys(start: Int, end: Int) -> [String: Any] {
            guard start < end, start >= 0 else { return ["a": 0, "k": 100] }
            return ["a": 1, "k": [
                ["i": ["x": [0.833], "y": [0.833]], "o": ["x": [0.167], "y": [0.167]], "t": start, "s": [0]],
                ["i": ["x": [0.833], "y": [0.833]], "o": ["x": [0.167], "y": [0.167]], "t": end, "s": [100]],
            ]]
        }

        func makeTextLayer(
            name: String,
            text: String,
            fontSize: Double,
            fontName: String = "Helvetica-Bold",
            color: (r: Double, g: Double, b: Double),
            position: [Double],
            justification: Int = 0, // 0: left, 1: right, 2: center
            revealStart: Int = 0,
            revealEnd: Int = 0
        ) -> [String: Any] {
            let ind = layerIndex
            layerIndex += 1
            return [
                "ddd": 0, "ind": ind, "ty": 5, "nm": name, "sr": 1,
                "ks": [
                    "o": revealStart < revealEnd ? opacityKeys(start: revealStart, end: revealEnd) : ["a": 0, "k": 100],
                    "r": ["a": 0, "k": 0],
                    "p": ["a": 0, "k": [position[0], position[1], 0]],
                    "a": ["a": 0, "k": [0, 0, 0]],
                    "s": ["a": 0, "k": [100, 100, 100]],
                ],
                "ao": 0, "ip": 0, "op": duration, "st": 0, "bm": 0,
                "t": [
                    "d": ["k": [[
                        "s": [
                            "s": fontSize, "f": fontName, "t": text, "j": justification,
                            "tr": 0, "lh": fontSize * 1.25, "ls": 0, "a": fontSize * 0.8,
                            "fc": [color.r, color.g, color.b, 1],
                        ],
                        "t": 0,
                    ]]],
                    "f": [["fName": fontName, "fFamily": "Helvetica", "fStyle": fontName.contains("Bold") ? "Bold" : "Regular", "ascent": fontSize * 0.8]],
                    "p": ["a": 0, "k": [0, 0, 0]],
                    "m": ["g": 1, "a": ["a": 0, "k": [0, 0]]],
                    "a": [],
                ],
            ]
        }

        // Header layers
        let titleLayer = makeTextLayer(
            name: "title",
            text: spec.title,
            fontSize: Double(min(w, h)) * 0.045,
            color: style.textColor,
            position: [Double(w) * 0.08, Double(h) * 0.12],
            revealStart: spec.revealFrame,
            revealEnd: spec.revealFrame + 12
        )
        layers.append(titleLayer)

        if let sub = spec.subtitle, !sub.isEmpty {
            let subLayer = makeTextLayer(
                name: "subtitle",
                text: sub,
                fontSize: Double(min(w, h)) * 0.024,
                fontName: "Helvetica",
                color: style.mutedTextColor,
                position: [Double(w) * 0.08, Double(h) * 0.17],
                revealStart: spec.revealFrame + 4,
                revealEnd: spec.revealFrame + 16
            )
            layers.append(subLayer)
        }

        // Content layers by kind
        switch spec.data {
        case .numericComparison(let comp):
            let count = comp.items.count
            let startX = Double(w) * 0.08
            let availW = Double(w) * 0.84
            let gap = Double(w) * 0.03
            let cardW = (availW - (gap * Double(count - 1))) / Double(count)
            let cardH = Double(h) * 0.55
            let cardY = Double(h) * 0.25

            for (idx, item) in comp.items.enumerated() {
                let x = startX + Double(idx) * (cardW + gap)
                let cardReveal = spec.revealFrame + (idx * 8)

                // Item label
                layers.append(makeTextLayer(
                    name: "item_label_\(idx)",
                    text: item.label.uppercased(),
                    fontSize: 22,
                    color: style.mutedTextColor,
                    position: [x + 30, cardY + 60],
                    revealStart: cardReveal,
                    revealEnd: cardReveal + 14
                ))

                // Value text
                let valStr = String(format: item.value.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.1f", item.value)
                layers.append(makeTextLayer(
                    name: "item_val_\(idx)",
                    text: "\(valStr) \(item.unit)",
                    fontSize: min(52, cardW * 0.15),
                    color: idx == 0 ? style.primaryColor : style.secondaryColor,
                    position: [x + 30, cardY + 140],
                    revealStart: cardReveal + 4,
                    revealEnd: cardReveal + 18
                ))

                // Note or delta pill
                if let note = item.note, !note.isEmpty {
                    layers.append(makeTextLayer(
                        name: "item_note_\(idx)",
                        text: note,
                        fontSize: 18,
                        fontName: "Helvetica",
                        color: style.mutedTextColor,
                        position: [x + 30, cardY + 210],
                        revealStart: cardReveal + 8,
                        revealEnd: cardReveal + 22
                    ))
                } else if idx > 0, let delta = comp.delta {
                    let sign = delta.percent >= 0 ? "+" : ""
                    let deltaStr = String(format: "%@%.1f%% (%@%.1f %@)", sign, delta.percent, sign, delta.absolute, item.unit)
                    layers.append(makeTextLayer(
                        name: "item_delta_\(idx)",
                        text: deltaStr,
                        fontSize: 20,
                        color: delta.percent >= 0 ? style.accentColor : style.secondaryColor,
                        position: [x + 30, cardY + 210],
                        revealStart: cardReveal + 8,
                        revealEnd: cardReveal + 22
                    ))
                }

                // Card background shape
                let rectShape: [String: Any] = [
                    "ty": "rc",
                    "p": ["a": 0, "k": [x + (cardW / 2), cardY + (cardH / 2)]],
                    "s": ["a": 0, "k": [cardW, cardH]],
                    "r": ["a": 0, "k": 16],
                ]
                let fillShape: [String: Any] = [
                    "ty": "fl",
                    "c": ["a": 0, "k": [style.cardBackgroundColor.r, style.cardBackgroundColor.g, style.cardBackgroundColor.b, 1]],
                    "o": ["a": 0, "k": 90],
                    "r": ["a": 0, "k": 1], "bm": 0,
                ]
                let strokeShape: [String: Any] = [
                    "ty": "st",
                    "c": ["a": 0, "k": [style.gridColor.r, style.gridColor.g, style.gridColor.b, 1]],
                    "o": ["a": 0, "k": 100], "w": ["a": 0, "k": 2], "lc": 1, "lj": 1, "ml": 4,
                ]
                var grpTr: [String: Any] = [
                    "ty": "tr", "p": ["a": 0, "k": [0, 0]], "a": ["a": 0, "k": [0, 0]],
                    "s": ["a": 0, "k": [100, 100]], "r": ["a": 0, "k": 0], "sk": ["a": 0, "k": 0], "sa": ["a": 0, "k": 0],
                ]
                grpTr["o"] = opacityKeys(start: cardReveal, end: cardReveal + 14)
                let cardGroup: [String: Any] = [
                    "ty": "gr", "nm": "card_\(idx)", "np": 4, "mn": "AD Group", "hd": false,
                    "it": [rectShape, fillShape, strokeShape, grpTr],
                ]
                let shapeLayer: [String: Any] = [
                    "ddd": 0, "ind": layerIndex, "ty": 4, "nm": "card_bg_\(idx)", "sr": 1,
                    "ks": ["o": ["a": 0, "k": 100], "r": ["a": 0, "k": 0], "p": ["a": 0, "k": [0, 0, 0]], "a": ["a": 0, "k": [0, 0, 0]], "s": ["a": 0, "k": [100, 100, 100]]],
                    "ao": 0, "shapes": [cardGroup], "ip": 0, "op": duration, "st": 0, "bm": 0,
                ]
                layerIndex += 1
                layers.append(shapeLayer)
            }

        case .sourceCard(let card):
            let cardX = Double(w) * 0.10
            let cardY = Double(h) * 0.24
            let cardW = Double(w) * 0.80
            let cardH = Double(h) * 0.60
            let reveal = spec.revealFrame

            // Badge
            layers.append(makeTextLayer(
                name: "source_badge",
                text: "OFFICIAL SOURCED CITATION",
                fontSize: 18,
                color: style.accentColor,
                position: [cardX + 40, cardY + 50],
                revealStart: reveal,
                revealEnd: reveal + 12
            ))

            // Source Title
            layers.append(makeTextLayer(
                name: "source_title",
                text: card.title,
                fontSize: 34,
                color: style.textColor,
                position: [cardX + 40, cardY + 105],
                revealStart: reveal + 4,
                revealEnd: reveal + 16
            ))

            // Author & Date
            let pubStr = card.publicationDate != nil ? " • Pub: \(card.publicationDate!)" : ""
            let citationText = "\(card.author)\(pubStr) • Accessed: \(card.accessedDate)"
            layers.append(makeTextLayer(
                name: "source_citation",
                text: citationText,
                fontSize: 20,
                fontName: "Helvetica",
                color: style.mutedTextColor,
                position: [cardX + 40, cardY + 150],
                revealStart: reveal + 6,
                revealEnd: reveal + 18
            ))

            // Quotation or paraphrase
            let quoteText = card.quotation ?? card.paraphrase ?? ""
            let displayQuote = quoteText.count > 160 ? String(quoteText.prefix(157)) + "..." : quoteText
            layers.append(makeTextLayer(
                name: "source_quote",
                text: "\"\(displayQuote)\"",
                fontSize: 26,
                fontName: "Helvetica-Bold",
                color: style.primaryColor,
                position: [cardX + 40, cardY + 230],
                revealStart: reveal + 10,
                revealEnd: reveal + 24
            ))

            // Provenance link
            let provText = card.url != nil ? "URL: \(card.url!)" : "Reference: \(card.documentReference ?? "")"
            layers.append(makeTextLayer(
                name: "source_provenance",
                text: provText,
                fontSize: 18,
                fontName: "Helvetica",
                color: style.mutedTextColor,
                position: [cardX + 40, cardY + cardH - 50],
                revealStart: reveal + 12,
                revealEnd: reveal + 26
            ))

            // Card Shape
            let rectShape: [String: Any] = [
                "ty": "rc",
                "p": ["a": 0, "k": [cardX + (cardW / 2), cardY + (cardH / 2)]],
                "s": ["a": 0, "k": [cardW, cardH]],
                "r": ["a": 0, "k": 18],
            ]
            let fillShape: [String: Any] = [
                "ty": "fl",
                "c": ["a": 0, "k": [style.cardBackgroundColor.r, style.cardBackgroundColor.g, style.cardBackgroundColor.b, 1]],
                "o": ["a": 0, "k": 95], "r": ["a": 0, "k": 1], "bm": 0,
            ]
            let strokeShape: [String: Any] = [
                "ty": "st",
                "c": ["a": 0, "k": [style.primaryColor.r, style.primaryColor.g, style.primaryColor.b, 1]],
                "o": ["a": 0, "k": 70], "w": ["a": 0, "k": 2.5], "lc": 1, "lj": 1, "ml": 4,
            ]
            var grpTr: [String: Any] = [
                "ty": "tr", "p": ["a": 0, "k": [0, 0]], "a": ["a": 0, "k": [0, 0]],
                "s": ["a": 0, "k": [100, 100]], "r": ["a": 0, "k": 0], "sk": ["a": 0, "k": 0], "sa": ["a": 0, "k": 0],
            ]
            grpTr["o"] = opacityKeys(start: reveal, end: reveal + 14)
            let cardGroup: [String: Any] = [
                "ty": "gr", "nm": "source_card_bg", "np": 4, "mn": "AD Group", "hd": false,
                "it": [rectShape, fillShape, strokeShape, grpTr],
            ]
            layers.append([
                "ddd": 0, "ind": layerIndex, "ty": 4, "nm": "source_card_bg_layer", "sr": 1,
                "ks": ["o": ["a": 0, "k": 100], "r": ["a": 0, "k": 0], "p": ["a": 0, "k": [0, 0, 0]], "a": ["a": 0, "k": [0, 0, 0]], "s": ["a": 0, "k": [100, 100, 100]]],
                "ao": 0, "shapes": [cardGroup], "ip": 0, "op": duration, "st": 0, "bm": 0,
            ])
            layerIndex += 1

        case .comparisonChart(let chart):
            let scale = chart.computeScale()
            let graphLeft = Double(w) * 0.12
            let graphRight = Double(w) * 0.88
            let graphTop = Double(h) * 0.28
            let graphBottom = Double(h) * 0.78
            let graphW = graphRight - graphLeft
            let graphH = graphBottom - graphTop
            let reveal = spec.revealFrame

            var gridShapes: [[String: Any]] = []

            // Ticks and grid lines
            for tick in scale.ticks {
                let norm = (tick - scale.min) / max(1.0, scale.max - scale.min)
                let y = graphBottom - (norm * graphH)

                // Grid line
                let linePath: [String: Any] = [
                    "ty": "sh",
                    "ks": ["a": 0, "k": ["i": [[0, 0], [0, 0]], "o": [[0, 0], [0, 0]],
                                         "v": [[graphLeft, y], [graphRight, y]], "c": false]],
                ]
                let stroke: [String: Any] = [
                    "ty": "st",
                    "c": ["a": 0, "k": [style.gridColor.r, style.gridColor.g, style.gridColor.b, 1]],
                    "o": ["a": 0, "k": 40], "w": ["a": 0, "k": 1], "lc": 1, "lj": 1, "ml": 4,
                ]
                gridShapes.append([
                    "ty": "gr", "nm": "grid_\(tick)", "np": 2, "mn": "AD Group", "hd": false,
                    "it": [linePath, stroke],
                ])

                // Y-axis tick label
                let tickStr = String(format: tick.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.1f", tick)
                layers.append(makeTextLayer(
                    name: "y_tick_\(tick)",
                    text: tickStr,
                    fontSize: 16,
                    fontName: "Helvetica",
                    color: style.mutedTextColor,
                    position: [graphLeft - 20, y + 6],
                    justification: 1, // right-aligned
                    revealStart: reveal,
                    revealEnd: reveal + 10
                ))
            }

            // Series lines and points
            let colors: [(r: Double, g: Double, b: Double)] = [style.primaryColor, style.secondaryColor, style.accentColor]
            for (sIdx, series) in chart.series.enumerated() {
                let color = colors[sIdx % colors.count]
                let ptCount = series.points.count
                var vertices: [[Double]] = []

                for (pIdx, pt) in series.points.enumerated() {
                    let normX = ptCount > 1 ? Double(pIdx) / Double(ptCount - 1) : 0.5
                    let x = graphLeft + (normX * graphW)
                    let normY = (pt.value - scale.min) / max(1.0, scale.max - scale.min)
                    let y = graphBottom - (normY * graphH)
                    vertices.append([x, y])

                    // X-axis label (only for first series to avoid overlap)
                    if sIdx == 0 {
                        layers.append(makeTextLayer(
                            name: "x_label_\(pIdx)",
                            text: pt.label,
                            fontSize: 18,
                            fontName: "Helvetica",
                            color: style.mutedTextColor,
                            position: [x, graphBottom + 35],
                            justification: 2, // centered
                            revealStart: reveal + 4,
                            revealEnd: reveal + 14
                        ))
                    }

                    // Point dot shape
                    let dotShape: [String: Any] = [
                        "ty": "el",
                        "p": ["a": 0, "k": [x, y]],
                        "s": ["a": 0, "k": [12, 12]],
                    ]
                    let dotFill: [String: Any] = [
                        "ty": "fl",
                        "c": ["a": 0, "k": [color.r, color.g, color.b, 1]],
                        "o": ["a": 0, "k": 100], "r": ["a": 0, "k": 1], "bm": 0,
                    ]
                    gridShapes.append([
                        "ty": "gr", "nm": "pt_\(sIdx)_\(pIdx)", "np": 2, "mn": "AD Group", "hd": false,
                        "it": [dotShape, dotFill],
                    ])
                }

                // Series line
                if vertices.count >= 2 {
                    let linePath: [String: Any] = [
                        "ty": "sh",
                        "ks": ["a": 0, "k": [
                            "i": Array(repeating: [0, 0], count: vertices.count),
                            "o": Array(repeating: [0, 0], count: vertices.count),
                            "v": vertices,
                            "c": false,
                        ]],
                    ]
                    let lineStroke: [String: Any] = [
                        "ty": "st",
                        "c": ["a": 0, "k": [color.r, color.g, color.b, 1]],
                        "o": ["a": 0, "k": 100], "w": ["a": 0, "k": 4], "lc": 2, "lj": 2, "ml": 4,
                    ]
                    gridShapes.append([
                        "ty": "gr", "nm": "line_\(sIdx)", "np": 2, "mn": "AD Group", "hd": false,
                        "it": [linePath, lineStroke],
                    ])
                }

                // Legend item
                let legendX = graphRight - Double(chart.series.count - sIdx) * 180.0
                layers.append(makeTextLayer(
                    name: "legend_\(sIdx)",
                    text: series.name,
                    fontSize: 18,
                    color: color,
                    position: [legendX, graphTop - 30],
                    revealStart: reveal,
                    revealEnd: reveal + 10
                ))
            }

            // Grid & lines shape layer
            var grpTr: [String: Any] = [
                "ty": "tr", "p": ["a": 0, "k": [0, 0]], "a": ["a": 0, "k": [0, 0]],
                "s": ["a": 0, "k": [100, 100]], "r": ["a": 0, "k": 0], "sk": ["a": 0, "k": 0], "sa": ["a": 0, "k": 0],
            ]
            grpTr["o"] = opacityKeys(start: reveal, end: reveal + 16)
            layers.append([
                "ddd": 0, "ind": layerIndex, "ty": 4, "nm": "chart_elements", "sr": 1,
                "ks": ["o": ["a": 0, "k": 100], "r": ["a": 0, "k": 0], "p": ["a": 0, "k": [0, 0, 0]], "a": ["a": 0, "k": [0, 0, 0]], "s": ["a": 0, "k": [100, 100, 100]]],
                "ao": 0, "shapes": gridShapes + [[
                    "ty": "gr", "nm": "chart_group_tr", "np": 1, "mn": "AD Group", "hd": false,
                    "it": [grpTr],
                ]], "ip": 0, "op": duration, "st": 0, "bm": 0,
            ])
            layerIndex += 1

        case .policyTimeline(let timeline):
            let evCount = timeline.events.count
            let startX = Double(w) * 0.10
            let availW = Double(w) * 0.80
            let spineY = Double(h) * 0.52
            let stepX = availW / max(1.0, Double(evCount - 1))
            let reveal = spec.revealFrame

            var spineShapes: [[String: Any]] = []

            // Main spine line
            let spinePath: [String: Any] = [
                "ty": "sh",
                "ks": ["a": 0, "k": ["i": [[0, 0], [0, 0]], "o": [[0, 0], [0, 0]],
                                     "v": [[startX, spineY], [startX + availW, spineY]], "c": false]],
            ]
            let spineStroke: [String: Any] = [
                "ty": "st",
                "c": ["a": 0, "k": [style.primaryColor.r, style.primaryColor.g, style.primaryColor.b, 1]],
                "o": ["a": 0, "k": 80], "w": ["a": 0, "k": 4], "lc": 2, "lj": 2, "ml": 4,
            ]
            spineShapes.append([
                "ty": "gr", "nm": "spine_line", "np": 2, "mn": "AD Group", "hd": false,
                "it": [spinePath, spineStroke],
            ])

            for (idx, event) in timeline.events.enumerated() {
                let x = startX + (Double(idx) * stepX)
                let evReveal = reveal + (idx * 10)
                let isAbove = idx % 2 == 0
                let cardY = isAbove ? spineY - 140 : spineY + 60

                // Node circle on spine
                let nodeDot: [String: Any] = [
                    "ty": "el", "p": ["a": 0, "k": [x, spineY]], "s": ["a": 0, "k": [16, 16]],
                ]
                let nodeFill: [String: Any] = [
                    "ty": "fl",
                    "c": ["a": 0, "k": [style.accentColor.r, style.accentColor.g, style.accentColor.b, 1]],
                    "o": ["a": 0, "k": 100], "r": ["a": 0, "k": 1], "bm": 0,
                ]
                spineShapes.append([
                    "ty": "gr", "nm": "node_\(idx)", "np": 2, "mn": "AD Group", "hd": false,
                    "it": [nodeDot, nodeFill],
                ])

                // Date label
                layers.append(makeTextLayer(
                    name: "event_date_\(idx)",
                    text: event.date,
                    fontSize: 22,
                    color: style.accentColor,
                    position: [x, isAbove ? spineY - 30 : spineY + 35],
                    justification: 2,
                    revealStart: evReveal,
                    revealEnd: evReveal + 12
                ))

                // Title
                layers.append(makeTextLayer(
                    name: "event_title_\(idx)",
                    text: event.title,
                    fontSize: 20,
                    color: style.textColor,
                    position: [x, cardY],
                    justification: 2,
                    revealStart: evReveal + 4,
                    revealEnd: evReveal + 16
                ))

                // Description
                if let desc = event.description, !desc.isEmpty {
                    let shortDesc = desc.count > 50 ? String(desc.prefix(47)) + "..." : desc
                    layers.append(makeTextLayer(
                        name: "event_desc_\(idx)",
                        text: shortDesc,
                        fontSize: 15,
                        fontName: "Helvetica",
                        color: style.mutedTextColor,
                        position: [x, cardY + 28],
                        justification: 2,
                        revealStart: evReveal + 6,
                        revealEnd: evReveal + 18
                    ))
                }
            }

            layers.append([
                "ddd": 0, "ind": layerIndex, "ty": 4, "nm": "timeline_spine", "sr": 1,
                "ks": ["o": ["a": 0, "k": 100], "r": ["a": 0, "k": 0], "p": ["a": 0, "k": [0, 0, 0]], "a": ["a": 0, "k": [0, 0, 0]], "s": ["a": 0, "k": [100, 100, 100]]],
                "ao": 0, "shapes": spineShapes, "ip": 0, "op": duration, "st": 0, "bm": 0,
            ])
            layerIndex += 1
        }

        // Background solid layer (bottom)
        let bgLayer: [String: Any] = [
            "ddd": 0, "ind": 0, "ty": 1, "nm": "background", "sr": 1,
            "sw": w, "sh": h, "sc": "#\(hex(style.backgroundColor))",
            "ks": [
                "o": ["a": 0, "k": 100], "r": ["a": 0, "k": 0],
                "p": ["a": 0, "k": [0, 0, 0]], "a": ["a": 0, "k": [0, 0, 0]],
                "s": ["a": 0, "k": [100, 100, 100]],
            ],
            "ao": 0, "ip": 0, "op": duration, "st": 0, "bm": 0,
        ]
        layers.append(bgLayer)

        return [
            "v": "5.7.0",
            "fr": fps,
            "ip": 0,
            "op": duration,
            "w": w,
            "h": h,
            "nm": "evidence_graphic",
            "ddd": 0,
            "assets": [],
            "fonts": [
                ["fName": "Helvetica-Bold", "fFamily": "Helvetica", "fStyle": "Bold", "ascent": 24],
                ["fName": "Helvetica", "fFamily": "Helvetica", "fStyle": "Regular", "ascent": 24],
            ],
            "layers": layers,
        ]
    }

    static func data(for spec: EvidenceGraphicSpec) throws -> Data {
        try JSONSerialization.data(withJSONObject: json(for: spec), options: [.sortedKeys])
    }
}


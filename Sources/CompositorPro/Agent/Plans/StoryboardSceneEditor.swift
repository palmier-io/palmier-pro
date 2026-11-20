import SwiftUI

struct StoryboardSceneEditor: View {
    let card: StoryboardCard
    let visualAssets: [MediaAsset]
    let canEdit: Bool
    let onRevise: ([StoryboardBeatEdit], StoryboardVisualEdit?) -> Void
    @State private var edits: [StoryboardBeatEdit]
    @State private var mediaRef: String
    @State private var license: String
    @State private var attribution: String
    @State private var useSpan: Bool
    @State private var sourceStart: String
    @State private var sourceEnd: String

    init(card: StoryboardCard, visualAssets: [MediaAsset], canEdit: Bool,
         onRevise: @escaping ([StoryboardBeatEdit], StoryboardVisualEdit?) -> Void) {
        self.card = card
        self.visualAssets = visualAssets
        self.canEdit = canEdit
        self.onRevise = onRevise
        _edits = State(initialValue: card.beats.map { .init(beatId: $0.beatId, text: $0.text, spokenText: $0.spokenText) })
        _mediaRef = State(initialValue: card.shot.mediaRef ?? "")
        _license = State(initialValue: card.shot.license ?? "")
        _attribution = State(initialValue: card.shot.attribution ?? "")
        _useSpan = State(initialValue: card.shot.sourceStartSeconds != nil)
        _sourceStart = State(initialValue: String(card.shot.sourceStartSeconds ?? 0))
        _sourceEnd = State(initialValue: String(card.shot.sourceEndSeconds ?? visualAssets.first { $0.id == card.shot.mediaRef }?.duration ?? 0))
    }

    var body: some View {
        DisclosureGroup(L10n.string("Revise Scene")) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                ForEach(edits.indices, id: \.self) { index in
                    Text(verbatim: edits[index].beatId).foregroundStyle(AppTheme.Text.secondaryColor)
                    TextEditor(text: $edits[index].text).frame(height: AppTheme.Storyboard.evidenceHeight)
                        .accessibilityLabel(L10n.string("Narration"))
                    TextField(L10n.string("Pronunciation wording (optional)"), text: Binding(
                        get: { edits[index].spokenText ?? "" },
                        set: { edits[index].spokenText = $0.isEmpty ? nil : $0 }
                    ))
                }
                Picker(L10n.string("Visual"), selection: $mediaRef) {
                    Text(L10n.string("No Visual Selected")).tag("")
                    ForEach(visualAssets) { asset in Text(verbatim: asset.name).tag(asset.id) }
                }
                TextField(L10n.string("License"), text: $license)
                TextField(L10n.string("Attribution"), text: $attribution)
                Toggle(L10n.string("Use Selected Source Span"), isOn: $useSpan)
                if useSpan {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        TextField(L10n.string("Source Start (seconds)"), text: $sourceStart)
                        TextField(L10n.string("Source End (seconds)"), text: $sourceEnd)
                    }
                    if parsedSpan == nil { Text(L10n.string("Enter finite source times with the end after the start.")) }
                }
                Text(L10n.string("Narration changes affect every scene linked to that beat. Material changes require storyboard approval again."))
                    .font(.system(size: AppTheme.FontSize.xs)).foregroundStyle(AppTheme.Text.secondaryColor)
                Button(L10n.string("Save Scene Changes")) {
                    onRevise(changedBeats, changedVisual)
                }.disabled(changedBeats.isEmpty && changedVisual == nil || useSpan && parsedSpan == nil)
            }.disabled(!canEdit)
        }
        .onChange(of: card.beats) {
            edits = card.beats.map { .init(beatId: $0.beatId, text: $0.text, spokenText: $0.spokenText) }
        }
        .onChange(of: mediaRef) {
            guard mediaRef != card.shot.mediaRef else {
                license = card.shot.license ?? ""
                attribution = card.shot.attribution ?? ""
                useSpan = card.shot.sourceStartSeconds != nil
                sourceStart = String(card.shot.sourceStartSeconds ?? 0)
                sourceEnd = String(card.shot.sourceEndSeconds ?? visualAssets.first { $0.id == mediaRef }?.duration ?? 0)
                return
            }
            license = ""
            attribution = ""
            useSpan = false
            sourceStart = "0"
            sourceEnd = String(visualAssets.first { $0.id == mediaRef }?.duration ?? 0)
        }
    }

    private var changedBeats: [StoryboardBeatEdit] {
        let original = card.beats.map { StoryboardBeatEdit(beatId: $0.beatId, text: $0.text, spokenText: $0.spokenText) }
        return edits.filter { !original.contains($0) }
    }

    private var changedVisual: StoryboardVisualEdit? {
        guard !mediaRef.isEmpty else { return nil }
        let visual = StoryboardVisualEdit(mediaRef: mediaRef, license: license, attribution: attribution,
            sourceStartSeconds: useSpan ? parsedSpan?.0 : nil, sourceEndSeconds: useSpan ? parsedSpan?.1 : nil)
        guard mediaRef != (card.shot.mediaRef ?? "") || license != (card.shot.license ?? "")
            || attribution != (card.shot.attribution ?? "") || visual.sourceStartSeconds != card.shot.sourceStartSeconds
            || visual.sourceEndSeconds != card.shot.sourceEndSeconds else { return nil }
        return visual
    }

    private var parsedSpan: (Double, Double)? {
        guard let start = Double(sourceStart), let end = Double(sourceEnd),
              start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
        return (start, end)
    }
}

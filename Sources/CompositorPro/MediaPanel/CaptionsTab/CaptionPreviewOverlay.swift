import AppKit
import SwiftUI

struct CaptionPreviewConfiguration: Equatable {
    let text: String
    let style: TextStyle
    let center: CGPoint
    let preset: TextAnimation.Preset
    let highlight: TextStyle.RGBA?
}

enum CaptionPreviewPlacement {
    static func snappedCoordinate(_ value: Double) -> CGFloat {
        guard value.isFinite else { return AppTheme.Caption.centerSnapValue }
        let center = Double(AppTheme.Caption.centerSnapValue)
        return CGFloat(abs(value - center) < AppTheme.Caption.centerSnapThreshold ? center : value)
    }

    static func movedCenter(from start: CGPoint, by translation: CGSize, in size: CGSize) -> CGPoint {
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              translation.width.isFinite, translation.height.isFinite else { return start }
        return CGPoint(
            x: snappedCoordinate(Double(start.x + translation.width / size.width)),
            y: snappedCoordinate(Double(start.y + translation.height / size.height))
        )
    }

    static func viewOffset(for center: CGPoint, in size: CGSize) -> CGSize {
        guard center.x.isFinite, center.y.isFinite,
              size.width.isFinite, size.height.isFinite else { return .zero }
        let origin = AppTheme.Caption.centerSnapValue
        return CGSize(
            width: (center.x - origin) * size.width,
            height: (center.y - origin) * size.height
        )
    }
}

struct CaptionPreviewOverlay: View {
    let configuration: CaptionPreviewConfiguration
    let canvas: CGSize
    let size: CGSize
    let onCenterChange: (CGPoint) -> Void

    @State private var dragStart: CGPoint?

    var body: some View {
        ZStack(alignment: .topLeading) {
            previewContent
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    @ViewBuilder
    private var previewContent: some View {
        let naturalSize = TextLayout.naturalSize(
            content: configuration.text,
            style: configuration.style,
            maxWidth: canvas.width * AppTheme.ComponentSize.captionPreviewMaxTextWidthRatio,
            canvasHeight: canvas.height
        )
        let clip = makePreviewClip(naturalSize: naturalSize)
        let offset = CaptionPreviewPlacement.viewOffset(for: configuration.center, in: size)

        centerGuides
        CaptionAnimatedPreview(clip: clip, size: size)
            .offset(x: offset.width, y: offset.height)
            .allowsHitTesting(false)
        dragTarget(naturalSize: naturalSize)
        previewTag
    }

    private func dragTarget(naturalSize: CGSize) -> some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .frame(
                width: max(
                    AppTheme.IconSize.xl,
                    naturalSize.width / canvas.width * size.width
                ),
                height: max(
                    AppTheme.IconSize.xl,
                    naturalSize.height / canvas.height * size.height
                )
            )
            .position(
                x: configuration.center.x * size.width,
                y: configuration.center.y * size.height
            )
            .pointerStyle(dragStart == nil ? .grabIdle : .grabActive)
            .gesture(centerDragGesture)
    }

    private var centerDragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == nil { dragStart = configuration.center }
                guard let dragStart else { return }
                onCenterChange(CaptionPreviewPlacement.movedCenter(
                    from: dragStart,
                    by: value.translation,
                    in: size
                ))
            }
            .onEnded { value in
                guard let dragStart else { return }
                self.dragStart = nil
                onCenterChange(CaptionPreviewPlacement.movedCenter(
                    from: dragStart,
                    by: value.translation,
                    in: size
                ))
            }
    }

    private func makePreviewClip(naturalSize: CGSize) -> Clip {
        let transform = Transform(
            centerX: AppTheme.Caption.centerSnapValue,
            centerY: AppTheme.Caption.centerSnapValue,
            width: naturalSize.width / canvas.width,
            height: naturalSize.height / canvas.height
        )
        return CaptionPreviewRender.clip(
            content: configuration.text,
            style: configuration.style,
            transform: transform,
            preset: configuration.preset,
            highlight: configuration.highlight
        )
    }

    private var previewTag: some View {
        Label {
            Text(L10n.string("Preview"))
        } icon: {
            Image(systemName: "captions.bubble")
        }
        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
        .foregroundStyle(AppTheme.Text.primaryColor)
        .padding(.horizontal, AppTheme.Spacing.sm)
        .frame(height: AppTheme.IconSize.mdLg)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(AppTheme.Background.surfaceColor.opacity(AppTheme.Opacity.prominent))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.hairline)
        )
        .padding(AppTheme.Spacing.sm)
        .allowsHitTesting(false)
    }

    private var centerGuides: some View {
        let color = AppTheme.Accent.timecodeColor.opacity(AppTheme.Opacity.prominent)
        return ZStack {
            if configuration.center.x == AppTheme.Caption.centerSnapValue {
                Rectangle()
                    .fill(color)
                    .frame(width: AppTheme.BorderWidth.hairline, height: size.height)
            }
            if configuration.center.y == AppTheme.Caption.centerSnapValue {
                Rectangle()
                    .fill(color)
                    .frame(width: size.width, height: AppTheme.BorderWidth.hairline)
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}

private struct CaptionPreviewRenderRequest: Equatable, Sendable {
    let clip: Clip
    let frame: Int
    let size: CGSize
    let scale: CGFloat
}

private struct CaptionAnimatedPreview: View {
    let clip: Clip
    let size: CGSize

    @State private var start = Date()
    @State private var image: NSImage?
    @Environment(\.displayScale) private var displayScale

    private static let fps = 30
    private var preset: TextAnimation.Preset { clip.textAnimation?.preset ?? .none }

    var body: some View {
        if preset == .none {
            frameView(at: 0)
        } else {
            SwiftUI.TimelineView(.periodic(from: start, by: 1.0 / Double(Self.fps))) { ctx in
                frameView(
                    at: Int(ctx.date.timeIntervalSince(start) * Double(Self.fps))
                        % CaptionPreviewRender.loopFrames(preset)
                )
            }
        }
    }

    private func frameView(at frame: Int) -> some View {
        let request = CaptionPreviewRenderRequest(
            clip: clip,
            frame: frame,
            size: size,
            scale: max(1, displayScale)
        )
        return Group {
            if let image {
                Image(nsImage: image)
                    .interpolation(.high)
            } else {
                Color.clear
            }
        }
        .frame(width: size.width, height: size.height)
        .task(id: request) {
            let cgImage = await CaptionPreviewRasterizer.shared.image(
                clip: request.clip,
                frame: request.frame,
                size: request.size,
                scale: request.scale
            )
            guard !Task.isCancelled else { return }
            image = cgImage.map { NSImage(cgImage: $0, size: request.size) }
        }
    }
}

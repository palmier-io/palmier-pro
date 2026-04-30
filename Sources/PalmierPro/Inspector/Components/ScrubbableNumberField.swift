import AppKit
import SwiftUI

/// Scrubbable number: drag the value horizontally to change it,
/// click to type. Blue text marks it as draggable.
struct ScrubbableNumberField: View {
    let value: Double?
    let range: ClosedRange<Double>
    var displayMultiplier: Double = 1
    var format: String = "%.0f"
    var valueSuffix: String = ""
    /// Display units changed per pixel of horizontal drag.
    var dragSensitivity: Double = 1
    var fieldWidth: CGFloat = 50
    var trailingLabel: String? = nil
    var displayTextOverride: ((Double) -> String?)? = nil
    var onChanged: ((Double) -> Void)? = nil
    let onCommit: (Double) -> Void

    @State private var isEditing = false
    @State private var editText = ""
    @FocusState private var editFocused: Bool

    @State private var isDragging = false
    @State private var dragStartValue: Double = 0
    @State private var liveValue: Double = 0

    private var isMixed: Bool { value == nil && !isDragging }
    private var sourceValue: Double { isDragging ? liveValue : (value ?? liveValue) }
    private var displayValue: Double { sourceValue * displayMultiplier }

    private var displayText: String {
        if isMixed { return "—" }
        if let s = displayTextOverride?(sourceValue) { return s }
        return String(format: format, displayValue) + valueSuffix
    }
    private var editingText: String {
        isMixed ? "" : String(format: format, displayValue)
    }

    var body: some View {
        HStack(spacing: 4) {
            ZStack {
                if isEditing {
                    TextField("", text: $editText)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .font(.system(size: AppTheme.FontSize.sm, weight: .medium).monospacedDigit())
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .focused($editFocused)
                        .onAppear { editFocused = true }
                        .onSubmit { editFocused = false }
                        .onExitCommand {
                            isEditing = false
                            editFocused = false
                        }
                } else {
                    Text(displayText)
                        .font(.system(size: AppTheme.FontSize.sm, weight: .medium).monospacedDigit())
                        .foregroundStyle(isMixed ? AppTheme.Text.tertiaryColor : ScrubbableTheme.accent)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .lineLimit(1)
                }
            }
            .frame(width: fieldWidth, alignment: .trailing)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(scrubOverlay)

            if let trailingLabel {
                Text(trailingLabel)
                    .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize()
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .onAppear { liveValue = value ?? range.lowerBound }
        .onChange(of: value) { _, new in
            if !isDragging { liveValue = new ?? liveValue }
        }
        .onChange(of: editFocused) { _, focused in
            if !focused && isEditing {
                commitEdit()
                isEditing = false
            }
        }
    }

    @ViewBuilder
    private var scrubOverlay: some View {
        if isEditing {
            EmptyView()
        } else {
            ScrubMouseArea(
                canScrub: !isMixed,
                onDragStart: {
                    dragStartValue = value ?? liveValue
                    isDragging = true
                },
                onDragChanged: { totalDx, modifiers in
                    var sens = dragSensitivity
                    if modifiers.contains(.shift) { sens *= 10 }
                    if modifiers.contains(.command) { sens *= 0.1 }
                    let mult = displayMultiplier == 0 ? 1 : displayMultiplier
                    let next = (dragStartValue + Double(totalDx) * sens / mult).clamped(to: range)
                    if next != liveValue {
                        liveValue = next
                        onChanged?(next)
                    }
                },
                onDragEnd: {
                    if isDragging {
                        onCommit(liveValue)
                        isDragging = false
                    }
                },
                onClick: {
                    editText = editingText
                    isEditing = true
                }
            )
        }
    }

    private func commitEdit() {
        let trimmed = editText.trimmingCharacters(in: .whitespaces)
        let withoutSuffix: String = {
            guard !valueSuffix.isEmpty, trimmed.hasSuffix(valueSuffix) else { return trimmed }
            return String(trimmed.dropLast(valueSuffix.count))
        }()
        let cleaned = withoutSuffix
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        guard let parsed = Double(cleaned) else { return }
        let mult = displayMultiplier == 0 ? 1 : displayMultiplier
        let raw = (parsed / mult).clamped(to: range)
        liveValue = raw
        onCommit(raw)
    }
}

enum ScrubbableTheme {
    static let accent = Color(red: 0.42, green: 0.66, blue: 0.95)
}

/// AppKit mouse-tracking area for the scrubbable field.
private struct ScrubMouseArea: NSViewRepresentable {
    var canScrub: Bool
    var onDragStart: () -> Void
    var onDragChanged: (CGFloat, NSEvent.ModifierFlags) -> Void
    var onDragEnd: () -> Void
    var onClick: () -> Void

    func makeNSView(context: Context) -> ScrubArea {
        let v = ScrubArea()
        apply(to: v)
        return v
    }

    func updateNSView(_ nsView: ScrubArea, context: Context) {
        apply(to: nsView)
    }

    private func apply(to v: ScrubArea) {
        v.canScrub = canScrub
        v.onDragStart = onDragStart
        v.onDragChanged = onDragChanged
        v.onDragEnd = onDragEnd
        v.onClick = onClick
    }

    final class ScrubArea: NSView {
        var canScrub: Bool = true
        var onDragStart: (() -> Void)?
        var onDragChanged: ((CGFloat, NSEvent.ModifierFlags) -> Void)?
        var onDragEnd: (() -> Void)?
        var onClick: (() -> Void)?

        private var dragStartWindowX: CGFloat = 0
        private var isDragging = false

        override var acceptsFirstResponder: Bool { false }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func mouseDown(with event: NSEvent) {
            dragStartWindowX = event.locationInWindow.x
            isDragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard canScrub else { return }
            let dx = event.locationInWindow.x - dragStartWindowX
            if !isDragging && abs(dx) > 3 {
                isDragging = true
                onDragStart?()
            }
            if isDragging {
                onDragChanged?(dx, event.modifierFlags)
            }
        }

        override func mouseUp(with event: NSEvent) {
            if isDragging {
                onDragEnd?()
            } else {
                onClick?()
            }
            isDragging = false
        }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

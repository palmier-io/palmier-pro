import CoreGraphics
import Testing
@testable import PalmierPro

@MainActor
@Suite struct CaptionLayoutTests {
    private func editor(width: Int = 1920, height: Int = 1080) -> EditorViewModel {
        let e = EditorViewModel()
        e.timeline.width = width
        e.timeline.height = height
        return e
    }

    @Test func shortCaptionsKeepRequestedScale() {
        let e = editor()
        var style = TextStyle()
        style.fontSize = AppTheme.Caption.defaultFontSize

        let fitted = e.captionStyleFitting(["短字幕"], base: style)

        #expect(fitted.fontScale == style.fontScale)
    }

    @Test func largeCaptionsShrinkAndStayInsideSafeArea() {
        let e = editor(width: 1080, height: 1920)
        var style = TextStyle()
        style.fontSize = AppTheme.Caption.maxFontSize
        let text = Array(repeating: "字幕裁切测试", count: 30).joined()

        let fitted = e.captionStyleFitting([text], base: style)
        let transform = e.captionTransform(for: text, style: fitted, center: CGPoint(x: 0.01, y: 0.99))
        let topLeft = transform.topLeft
        let right = topLeft.x + transform.width
        let bottom = topLeft.y + transform.height
        let minX = AppTheme.Caption.minPosition + Double(AppTheme.Caption.horizontalSafeInsetRatio)
        let maxX = AppTheme.Caption.maxPosition - Double(AppTheme.Caption.horizontalSafeInsetRatio)
        let minY = AppTheme.Caption.minPosition + Double(AppTheme.Caption.verticalSafeInsetRatio)
        let maxY = AppTheme.Caption.maxPosition - Double(AppTheme.Caption.verticalSafeInsetRatio)
        let tolerance = Double.ulpOfOne * Double(AppTheme.Caption.maxFontSize)

        #expect(fitted.fontScale < style.fontScale)
        #expect(topLeft.x >= minX - tolerance)
        #expect(right <= maxX + tolerance)
        #expect(topLeft.y >= minY - tolerance)
        #expect(bottom <= maxY + tolerance)
    }
}

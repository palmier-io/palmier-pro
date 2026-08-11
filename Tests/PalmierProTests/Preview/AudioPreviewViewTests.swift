import Testing
@testable import PalmierPro

@Test func barLevelsStretchContrastAcrossDynamicRange() {
    // Samples are dB-normalized quietness: 0 = loudest, 1 = silence.
    let levels = AudioPreviewView.barLevels(samples: [0.1, 0.1, 0.6, 0.6], barCount: 2)
    #expect(levels.count == 2)
    #expect(levels[0] == 1.0)
    #expect(abs(levels[1] - 0.08) < 0.0001)
}

@Test func barLevelsLeaveNearConstantAudioUnstretched() {
    let levels = AudioPreviewView.barLevels(samples: [0.5, 0.52, 0.51, 0.5], barCount: 2)
    #expect(levels.allSatisfy { abs($0 - 0.49) < 0.02 })
}

@Test func barLevelsHandleEmptyAndTinyInput() {
    #expect(AudioPreviewView.barLevels(samples: [], barCount: 4).isEmpty)
    #expect(AudioPreviewView.barLevels(samples: [0.5], barCount: 0).isEmpty)
    #expect(AudioPreviewView.barLevels(samples: [0.5], barCount: 4).count == 4)
}

@Test func activeTranscriptLineUsesSegmentBounds() {
    let lines = [
        TranscriptionSegment(text: "One", start: 0, end: 1),
        TranscriptionSegment(text: "Two", start: 2, end: 3),
    ]
    #expect(AudioPreviewView.activeLineIndex(at: 0.5, in: lines) == 0)
    #expect(AudioPreviewView.activeLineIndex(at: 2.5, in: lines) == 1)
    #expect(AudioPreviewView.activeLineIndex(at: -0.1, in: lines) == nil)
    #expect(AudioPreviewView.activeLineIndex(at: 1.5, in: lines) == nil)
    #expect(AudioPreviewView.activeLineIndex(at: 1, in: lines) == nil)
    #expect(AudioPreviewView.activeLineIndex(at: 3, in: lines) == nil)
}

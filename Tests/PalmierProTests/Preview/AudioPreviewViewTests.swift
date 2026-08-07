import Testing
@testable import PalmierPro

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

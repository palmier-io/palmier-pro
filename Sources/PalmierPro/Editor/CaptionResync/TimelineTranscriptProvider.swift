// TimelineTranscriptProvider — cache-only CaptionWordSource for reactive resync. Reads transcripts
// already on disk and maps their words to project frames; never triggers ASR and never writes,
// which is the L1/L2 read-only guarantee the resync engine depends on.

import Foundation

final class TimelineTranscriptProvider: CaptionWordSource {
    private struct Fragment { let clip: Clip; let url: URL; let mediaRef: String }
    private let fragments: [Fragment]
    private let fps: Int
    private var transcripts: [URL: TranscriptionResult?] = [:]  // memoized disk reads; stored nil = no cache

    /// Snapshots the editor's audible source clips (the same set get_transcript uses) on the main actor.
    @MainActor
    init(editor: EditorViewModel) {
        var frags: [Fragment] = []
        for clip in editor.captionTargets(ids: []) {
            guard let url = editor.mediaResolver.resolveURL(for: clip.mediaRef) else { continue }
            frags.append(Fragment(clip: clip, url: url, mediaRef: clip.mediaRef))
        }
        self.fragments = frags
        self.fps = editor.timeline.fps
    }

    func audibleWords(in range: Range<Int>) -> [WordTiming] {
        var out: [WordTiming] = []
        for frag in fragmentsIntersecting(range) {
            guard let transcript = transcript(for: frag.url) else { continue }
            for w in CaptionTranscriptMapper.timelineWords(from: transcript, clip: frag.clip, fps: fps)
            where w.startFrame < range.upperBound && w.endFrame > range.lowerBound {
                out.append(w)
            }
        }
        return out.sorted { ($0.startFrame, $0.endFrame) < ($1.startFrame, $1.endFrame) }
    }

    func uncachedRefs(in range: Range<Int>) -> [String] {
        var refs: [String] = []
        var seen = Set<String>()
        for frag in fragmentsIntersecting(range) where transcript(for: frag.url) == nil {
            if seen.insert(frag.mediaRef).inserted { refs.append(frag.mediaRef) }
        }
        return refs
    }

    private func fragmentsIntersecting(_ range: Range<Int>) -> [Fragment] {
        fragments.filter { $0.clip.startFrame < range.upperBound && $0.clip.endFrame > range.lowerBound }
    }

    private func transcript(for url: URL) -> TranscriptionResult? {
        if let memo = transcripts[url] { return memo }
        let loaded = TranscriptCache.cachedOnDisk(for: url)
        transcripts[url] = loaded
        return loaded
    }
}

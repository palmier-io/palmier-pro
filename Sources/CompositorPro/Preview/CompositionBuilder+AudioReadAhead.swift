import AVFoundation

extension CompositionBuilder {
    static func addAudioReadAhead(
        to composition: AVMutableComposition, audioMix: AVMutableAudioMix,
        source: AVMutableCompositionTrack, at end: CMTime
    ) async throws {
        let segments = try await source.load(.segments)
        guard end.isNumeric, end >= .zero,
              let segment = segments.first(where: { !$0.isEmpty }),
              segment.timeMapping.target.isValid, segment.timeMapping.target.start.isNumeric,
              segment.timeMapping.target.duration.isNumeric, segment.timeMapping.target.duration > .zero else {
            throw InvalidTimelineError(reason: "unavailable audio decoding read-ahead source")
        }
        let range = segment.timeMapping.target
        let copies = ceil(AudioTrackReader.mixReadAhead.seconds / range.duration.seconds)
        guard copies.isFinite, copies > 0, copies <= 128 else {
            throw InvalidTimelineError(reason: "audio segment is too short for decoding read-ahead")
        }
        guard let tail = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw InvalidTimelineError(reason: "could not prepare audio decoding read-ahead")
        }
        var cursor = CMTime.zero
        for _ in 0..<Int(copies) {
            try Task.checkCancellation()
            let duration = CMTimeMinimum(range.duration, AudioTrackReader.mixReadAhead - cursor)
            try tail.insertTimeRange(CMTimeRange(start: range.start, duration: duration), of: source, at: end + cursor)
            cursor = cursor + duration
        }
        // Empty trailing edits are ignored; muted media keeps the resampler fed through the cut.
        let parameters = AVMutableAudioMixInputParameters(track: tail)
        parameters.setVolume(0, at: .zero)
        audioMix.inputParameters.append(parameters)
    }
}

import AVFoundation
import Foundation
import Testing
@testable import CompositorPro

@MainActor
struct AudioEnhancementJobTests {
    @Test func cancellationAbortsOwnedTaskAndPreventsCommit() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let source = directory.appendingPathComponent("tone.wav")
        let editor = EditorViewModel()
        let clip = Fixtures.clip(id: "c1", mediaRef: "tone", mediaType: .audio, start: 0, duration: 60)
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])
        editor.mediaManifest.entries = [MediaManifestEntry(id: "tone", name: "Tone", type: .audio,
                                                          source: .external(absolutePath: source.path), duration: 3)]

        let (jobId, isNew) = try await editor.startEnhancementJob(
            clipIds: [clip.id], type: .loudness, params: .loudness(targetLUFS: -16), actionName: "Match"
        )
        #expect(isNew)
        editor.cancelEnhancementJob(jobId)

        let status = try #require(editor.getEnhancementJobStatus(jobId))
        #expect(status.status == "cancelled")
        #expect(status.stage == "cancelled")
        #expect(editor.clipFor(id: clip.id)?.effects == nil)

        await #expect(throws: CancellationError.self) {
            try await editor.awaitEnhancementJob(jobId)
        }
        try await AudioFinishingFixtures.remove(directory)
    }

    @Test func sourceModificationDuringJobRejectsLateCommit() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let source = directory.appendingPathComponent("tone.wav")
        let editor = EditorViewModel()
        let clip = Fixtures.clip(id: "c1", mediaRef: "tone", mediaType: .audio, start: 0, duration: 60)
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])
        editor.mediaManifest.entries = [MediaManifestEntry(id: "tone", name: "Tone", type: .audio,
                                                          source: .external(absolutePath: source.path), duration: 3)]
        let undo = UndoManager()
        editor.undo.attach(undo)

        let entered = AsyncSemaphore(value: 0)
        let resume = AsyncSemaphore(value: 0)
        let (jobId, _) = try await editor.startEnhancementJob(
            clipIds: [clip.id], type: .loudness, params: .loudness(targetLUFS: -16), actionName: "Match",
            analyze: { _, _, _ in
                await entered.signal()
                try await resume.wait()
                return LoudnessMeasurement(status: .measured, integratedLUFS: -25, truePeakDBFS: nil,
                                           analyzedFrames: 96_000, sampleRate: 48_000)
            }
        )
        try await entered.wait()

        // Modify source on disk
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        let modified = (attributes[.modificationDate] as! Date).addingTimeInterval(5)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: source.path)

        await resume.signal()
        await #expect(throws: AudioFinishingError.self) {
            try await editor.awaitEnhancementJob(jobId)
        }

        #expect(editor.clipFor(id: clip.id)?.effects == nil)
        #expect(!undo.canUndo)
        let status = try #require(editor.getEnhancementJobStatus(jobId))
        #expect(status.status == "failed")
        #expect(status.errors.contains { $0.contains("modified during audio finishing") })
        try await AudioFinishingFixtures.remove(directory)
    }

    @Test func clipTimingChangeDuringJobRejectsLateCommit() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let source = directory.appendingPathComponent("tone.wav")
        let editor = EditorViewModel()
        let clip = Fixtures.clip(id: "c1", mediaRef: "tone", mediaType: .audio, start: 0, duration: 60)
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])
        editor.mediaManifest.entries = [MediaManifestEntry(id: "tone", name: "Tone", type: .audio,
                                                          source: .external(absolutePath: source.path), duration: 3)]
        let undo = UndoManager()
        editor.undo.attach(undo)

        let entered = AsyncSemaphore(value: 0)
        let resume = AsyncSemaphore(value: 0)
        let (jobId, _) = try await editor.startEnhancementJob(
            clipIds: [clip.id], type: .loudness, params: .loudness(targetLUFS: -16), actionName: "Match",
            analyze: { _, _, _ in
                await entered.signal()
                try await resume.wait()
                return LoudnessMeasurement(status: .measured, integratedLUFS: -25, truePeakDBFS: nil,
                                           analyzedFrames: 96_000, sampleRate: 48_000)
            }
        )
        try await entered.wait()

        // Change clip trim while analysis was running
        editor.timeline.tracks[0].clips[0].trimStartFrame = 15

        await resume.signal()
        await #expect(throws: AudioFinishingError.self) {
            try await editor.awaitEnhancementJob(jobId)
        }

        #expect(editor.clipFor(id: clip.id)?.effects == nil)
        #expect(!undo.canUndo)
        let status = try #require(editor.getEnhancementJobStatus(jobId))
        #expect(status.status == "failed")
        #expect(status.errors.contains { $0.contains("timing or source range changed") })
        try await AudioFinishingFixtures.remove(directory)
    }

    @Test func identicalJobCoalescesAndChangedParamsReplace() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let source = directory.appendingPathComponent("tone.wav")
        let editor = EditorViewModel()
        let clip = Fixtures.clip(id: "c1", mediaRef: "tone", mediaType: .audio, start: 0, duration: 60)
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])
        editor.mediaManifest.entries = [MediaManifestEntry(id: "tone", name: "Tone", type: .audio,
                                                          source: .external(absolutePath: source.path), duration: 3)]

        let entered = AsyncSemaphore(value: 0)
        let resume = AsyncSemaphore(value: 0)
        let (job1, isNew1) = try await editor.startEnhancementJob(
            clipIds: [clip.id], type: .loudness, params: .loudness(targetLUFS: -16), actionName: "Match",
            analyze: { _, _, _ in
                await entered.signal()
                try await resume.wait()
                return LoudnessMeasurement(status: .measured, integratedLUFS: -25, truePeakDBFS: nil,
                                           analyzedFrames: 96_000, sampleRate: 48_000)
            }
        )
        #expect(isNew1)
        try await entered.wait()

        // Same params -> coalesces to same job
        let (job2, isNew2) = try await editor.startEnhancementJob(
            clipIds: [clip.id], type: .loudness, params: .loudness(targetLUFS: -16), actionName: "Match"
        )
        #expect(!isNew2)
        #expect(job1 == job2)

        // Different params -> cancels old job and starts new
        let (job3, isNew3) = try await editor.startEnhancementJob(
            clipIds: [clip.id], type: .loudness, params: .loudness(targetLUFS: -14), actionName: "Match 2"
        )
        #expect(isNew3)
        #expect(job3 != job1)
        #expect(editor.enhancementJobs[job1]?.status == .cancelled)

        await resume.signal()
        try await editor.awaitEnhancementJob(job3)
        #expect(editor.clipFor(id: clip.id)?.effects != nil)
        try await AudioFinishingFixtures.remove(directory)
    }

    @Test func successfulFinishingCreatesOneAtomicUndoAction() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let source = directory.appendingPathComponent("tone.wav")
        let editor = EditorViewModel()
        let clip = Fixtures.clip(id: "c1", mediaRef: "tone", mediaType: .audio, start: 0, duration: 60)
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])
        editor.mediaManifest.entries = [MediaManifestEntry(id: "tone", name: "Tone", type: .audio,
                                                          source: .external(absolutePath: source.path), duration: 3)]
        let baseline = editor.timeline
        let undo = UndoManager()
        editor.undo.attach(undo)

        let (jobId, _) = try await editor.startEnhancementJob(
            clipIds: [clip.id], type: .loudness, params: .loudness(targetLUFS: -16), actionName: "Match Loudness"
        )
        let completed = try await editor.awaitEnhancementJob(jobId)
        #expect(completed.status == .completed)
        #expect(completed.changedClipIds == [clip.id])
        #expect(undo.canUndo)
        #expect(undo.undoActionName == "Match Loudness")

        undo.undo()
        #expect(editor.timeline == baseline)
        #expect(undo.canRedo)
        undo.redo()
        #expect(editor.timeline != baseline)
        #expect(editor.clipFor(id: clip.id)?.effects != nil)
        try await AudioFinishingFixtures.remove(directory)
    }

    @Test func timelineSwitchDuringJobRejectsLateCommit() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let source = directory.appendingPathComponent("tone.wav")
        let editor = EditorViewModel()
        let clip = Fixtures.clip(id: "c1", mediaRef: "tone", mediaType: .audio, start: 0, duration: 60)
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])
        editor.mediaManifest.entries = [MediaManifestEntry(id: "tone", name: "Tone", type: .audio,
                                                          source: .external(absolutePath: source.path), duration: 3)]
        let undo = UndoManager()
        editor.undo.attach(undo)

        let entered = AsyncSemaphore(value: 0)
        let resume = AsyncSemaphore(value: 0)
        let (jobId, _) = try await editor.startEnhancementJob(
            clipIds: [clip.id], type: .loudness, params: .loudness(targetLUFS: -16), actionName: "Match",
            analyze: { _, _, _ in
                await entered.signal()
                try await resume.wait()
                return LoudnessMeasurement(status: .measured, integratedLUFS: -25, truePeakDBFS: nil,
                                           analyzedFrames: 96_000, sampleRate: 48_000)
            }
        )
        try await entered.wait()

        // Switch active timeline while job was running
        let otherTimeline = Fixtures.timeline(tracks: [])
        editor.timeline = otherTimeline

        await resume.signal()
        await #expect(throws: AudioFinishingError.self) {
            try await editor.awaitEnhancementJob(jobId)
        }

        #expect(!undo.canUndo)
        let status = try #require(editor.getEnhancementJobStatus(jobId))
        #expect(status.status == "failed")
        #expect(status.errors.contains { $0.contains("Timeline switched during audio finishing") })
        try await AudioFinishingFixtures.remove(directory)
    }

    @Test func missingModelRefusesJobAndLeavesCleanState() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let source = directory.appendingPathComponent("tone.wav")
        let editor = EditorViewModel()
        let clip = Fixtures.clip(id: "c1", mediaRef: "tone", mediaType: .audio, start: 0, duration: 60)
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [clip])])
        editor.mediaManifest.entries = [MediaManifestEntry(id: "tone", name: "Tone", type: .audio,
                                                          source: .external(absolutePath: source.path), duration: 3)]

        if !AudioEnhancer.availability.canStart {
            await #expect(throws: RuntimeCapabilityError.self) {
                try await editor.startEnhancementJob(
                    clipIds: [clip.id], type: .denoise, params: .denoise(amount: 1.0), actionName: "Denoise"
                )
            }
            #expect(editor.enhancementJobs.isEmpty)
            #expect(editor.enhancementJobTasks.isEmpty)
            #expect(editor.clipFor(id: clip.id)?.effects == nil)
        }
        try await AudioFinishingFixtures.remove(directory)
    }

    @Test func exportAwaitsInFlightEnhancementJob() async throws {
        let directory = try await AudioFinishingFixtures.makeDirectory()
        let source = directory.appendingPathComponent("tone.wav")
        let editor = EditorViewModel()
        let clip = Fixtures.clip(id: "c1", mediaRef: "tone", mediaType: .audio, start: 0, duration: 60)
        var title = Fixtures.clip(mediaType: .text, start: 0, duration: 60)
        title.textContent = "Test"
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [title]), Fixtures.audioTrack(clips: [clip])])
        editor.mediaManifest.entries = [MediaManifestEntry(id: "tone", name: "Tone", type: .audio,
                                                          source: .external(absolutePath: source.path), duration: 3)]

        // Start enhancement job in flight
        let (jobId, _) = try await editor.startEnhancementJob(
            clipIds: [clip.id], type: .loudness, params: .loudness(targetLUFS: -16), actionName: "Match"
        )
        let output = directory.appendingPathComponent("output.mp4")
        let queue = ExportQueue()
        let submission = try queue.enqueueVideo(
            timeline: editor.timeline,
            resolver: editor.mediaResolver,
            resolveTimeline: editor.timelineResolver(),
            format: .h264,
            resolution: .matchTimeline,
            missingMediaRefs: [],
            outputURL: output,
            source: .manual,
            projectID: "test",
            analyticsProjectID: nil,
            prepareProcessing: { [weak editor] in
                try await editor?.awaitEnhancementJobsForTimeline(editor!.timeline)
            }
        )

        let finished = try await queue.waitForCompletion(submission.jobID)
        #expect(finished.status == .completed)
        #expect(editor.enhancementJobs[jobId]?.status == .completed)
        try await AudioFinishingFixtures.remove(directory)
    }
}

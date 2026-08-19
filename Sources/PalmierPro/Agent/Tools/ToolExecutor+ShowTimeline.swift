import AppKit
import Foundation

struct TimelinePreviewJob {
    var id: String
    var timelineId: String
    var timelineName: String
    var startFrame: Int
    var endFrame: Int
    var fps: Int
    var width: Int
    var height: Int
    var windowed: Bool
    var groupMembers: [String]
    var status: String
    var error: String?
    var fileURL: URL?
}

extension ToolExecutor {
    static let timelinePreviewMaxSeconds = 20
    static let timelinePreviewMaxCount = 6
    static let timelinePreviewShortSide = 720
    private static let timelinePreviewJobCap = 24

    struct TimelinePreviewWindow: Equatable {
        var startFrame: Int
        var endFrame: Int
        var windowed: Bool
    }

    static func timelinePreviewWindow(
        totalFrames: Int,
        fps: Int,
        startFrame: Int?,
        endFrame: Int?
    ) throws -> TimelinePreviewWindow {
        guard totalFrames > 0 else {
            throw ToolError("Timeline is empty.")
        }
        let start = startFrame ?? 0
        guard start >= 0 else {
            throw ToolError("startFrame must be >= 0.")
        }
        guard start < totalFrames else {
            throw ToolError("startFrame \(start) is past the end of the timeline (\(totalFrames) frames).")
        }
        let requestedEnd = endFrame ?? totalFrames
        guard requestedEnd > start else {
            throw ToolError("endFrame must be greater than startFrame.")
        }
        let clampedEnd = min(requestedEnd, totalFrames)
        let maxFrames = max(1, fps) * timelinePreviewMaxSeconds
        if clampedEnd - start > maxFrames {
            return TimelinePreviewWindow(startFrame: start, endFrame: start + maxFrames, windowed: true)
        }
        return TimelinePreviewWindow(startFrame: start, endFrame: clampedEnd, windowed: false)
    }

    static func aspectRatioLabel(width: Int, height: Int) -> String {
        let d = gcd(max(width, 1), max(height, 1))
        return "\(width / d):\(height / d)"
    }

    func showTimeline(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(
            args,
            allowed: ["timelineIds", "timelineId", "startFrame", "endFrame"],
            path: "show_timeline"
        )
        let ids = try resolvedShowTimelineIds(args, editor: editor)
        let requestedStart = args.int("startFrame")
        let requestedEnd = args.int("endFrame")

        var jobs: [TimelinePreviewJob] = []
        var warnings: [String] = []
        for timelineId in ids {
            guard let timeline = editor.timeline(for: timelineId) else {
                throw ToolError("No timeline with id '\(timelineId)'. get_media lists the project's timelines.")
            }
            let window: TimelinePreviewWindow
            do {
                window = try Self.timelinePreviewWindow(
                    totalFrames: timeline.totalFrames,
                    fps: timeline.fps,
                    startFrame: requestedStart,
                    endFrame: requestedEnd
                )
            } catch let error as ToolError {
                throw ToolError("\"\(timeline.name)\": \(error.message)")
            }
            if window.windowed {
                warnings.append(
                    "\"\(timeline.name)\" previewed frames [\(window.startFrame), \(window.endFrame)) (max \(Self.timelinePreviewMaxSeconds)s). Pass a smaller range to choose a different span."
                )
            }
            jobs.append(
                TimelinePreviewJob(
                    id: UUID().uuidString,
                    timelineId: timeline.id,
                    timelineName: timeline.name,
                    startFrame: window.startFrame,
                    endFrame: window.endFrame,
                    fps: max(1, timeline.fps),
                    width: timeline.width,
                    height: timeline.height,
                    windowed: window.windowed,
                    groupMembers: [],
                    status: "generating",
                    error: nil,
                    fileURL: nil
                )
            )
        }
        let members = jobs.map(\.id)
        for i in jobs.indices {
            jobs[i].groupMembers = members
            rememberTimelinePreview(jobs[i])
        }
        startTimelinePreviewRenders(jobs, editor: editor)

        let host = jobs[0]
        var payload = timelinePreviewPayload(host)
        payload["message"] = jobs.count == 1
            ? "Rendering \"\(host.timelineName)\"."
            : "Rendering \(jobs.count) timelines."
        payload["previews"] = jobs.map { timelinePreviewPayload($0) }
        if !warnings.isEmpty { payload["warnings"] = warnings }
        let json = Self.jsonString(payload) ?? "{}"
        return .ok(json)
    }

    func revealTimeline(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["timelineId"], path: "reveal_timeline")
        let timelineId = try args.requireString("timelineId")
        guard editor.timeline(for: timelineId) != nil else {
            throw ToolError("No timeline with id '\(timelineId)'.")
        }
        if editor.activeTimelineId != timelineId {
            editor.activateTimeline(timelineId)
        }
        if let project = project(for: editor) {
            AppState.shared.showEditor(for: project)
            project.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        return .ok(#"{"activated":true}"#)
    }

    func timelinePreviewJSON(mediaRef: String, includeMedia: Bool) async -> String? {
        guard let job = timelinePreviewJobs[mediaRef] else { return nil }
        var payload = timelinePreviewPayload(job)
        if includeMedia, job.status == "ready", let url = job.fileURL {
            let media = await Task.detached(priority: .userInitiated) {
                Self.inlinePlayableFile(url: url, mimeType: "video/mp4")
            }.value
            if let media { payload["media"] = media }
        }
        return Self.jsonString(payload)
    }

    private func resolvedShowTimelineIds(_ args: [String: Any], editor: EditorViewModel) throws -> [String] {
        var ids = args.stringArray("timelineIds")
        if let one = args.string("timelineId") { ids.insert(one, at: 0) }
        if ids.isEmpty { ids = [editor.activeTimelineId] }
        var seen = Set<String>()
        ids = ids.filter { seen.insert($0).inserted }
        guard !ids.isEmpty else {
            throw ToolError("No timeline to show.")
        }
        if ids.count > Self.timelinePreviewMaxCount {
            throw ToolError("show_timeline accepts at most \(Self.timelinePreviewMaxCount) timelines.")
        }
        return ids
    }

    private func rememberTimelinePreview(_ job: TimelinePreviewJob) {
        timelinePreviewJobs[job.id] = job
        timelinePreviewOrder.append(job.id)
        while timelinePreviewOrder.count > Self.timelinePreviewJobCap {
            let evicted = timelinePreviewOrder.removeFirst()
            if let url = timelinePreviewJobs[evicted]?.fileURL {
                let stale = url
                Task.detached { try? FileManager.default.removeItem(at: stale) }
            }
            timelinePreviewJobs.removeValue(forKey: evicted)
        }
    }

    private func startTimelinePreviewRenders(_ jobs: [TimelinePreviewJob], editor: EditorViewModel) {
        let requests: [(job: TimelinePreviewJob, timeline: Timeline)] = jobs.compactMap { job in
            guard let timeline = editor.timeline(for: job.timelineId) else { return nil }
            return (job, timeline)
        }
        let resolver = editor.mediaResolver
        let resolveTimeline = editor.timelineResolver()
        let missing = editor.missingMediaRefs
        timelinePreviewRenderTask = Task { @MainActor [weak self] in
            for request in requests {
                guard let self, !Task.isCancelled else { return }
                do {
                    let url = try await TimelineRenderer.render(
                        timeline: request.timeline,
                        resolver: resolver,
                        resolveTimeline: resolveTimeline,
                        missingMediaRefs: missing,
                        startFrame: request.job.startFrame,
                        frameCount: request.job.endFrame - request.job.startFrame,
                        shortSide: Self.timelinePreviewShortSide
                    )
                    guard !Task.isCancelled else {
                        try? FileManager.default.removeItem(at: url)
                        return
                    }
                    self.completeTimelinePreview(id: request.job.id, url: url)
                } catch is CancellationError {
                    self.failTimelinePreview(id: request.job.id, message: "Cancelled")
                } catch {
                    self.failTimelinePreview(id: request.job.id, message: error.localizedDescription)
                }
                NotificationCenter.default.post(name: .generationAssetDidChange, object: request.job.id)
            }
        }
    }

    private func completeTimelinePreview(id: String, url: URL) {
        guard var job = timelinePreviewJobs[id] else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        if let previous = job.fileURL, previous != url {
            let stale = previous
            Task.detached { try? FileManager.default.removeItem(at: stale) }
        }
        job.status = "ready"
        job.error = nil
        job.fileURL = url
        timelinePreviewJobs[id] = job
    }

    private func failTimelinePreview(id: String, message: String) {
        guard var job = timelinePreviewJobs[id] else { return }
        job.status = "failed"
        job.error = message
        timelinePreviewJobs[id] = job
    }

    private func timelinePreviewPayload(_ job: TimelinePreviewJob) -> [String: Any] {
        let duration = Double(job.endFrame - job.startFrame) / Double(max(1, job.fps))
        var payload: [String: Any] = [
            "kind": "timeline",
            "mediaRef": job.id,
            "timelineId": job.timelineId,
            "timelineName": job.timelineName,
            "name": job.timelineName,
            "status": job.status,
            "phase": job.status == "generating" ? "rendering" : job.status,
            "startFrame": job.startFrame,
            "endFrame": job.endFrame,
            "duration": duration,
            "aspectRatio": Self.aspectRatioLabel(width: job.width, height: job.height),
            "previewUri": MCPPreviewApp.previewResourceURI(mediaRef: job.id),
            "groupRole": job.id == job.groupMembers.first ? "host" : "member",
            "groupMembers": job.groupMembers,
            "mimeType": "video/mp4",
        ]
        if job.windowed { payload["windowed"] = true }
        if let error = job.error { payload["error"] = error }
        return payload
    }

    private func project(for editor: EditorViewModel) -> VideoProject? {
        if let sessionProject, sessionProject.editorViewModel === editor {
            return sessionProject
        }
        return AppState.shared.openProjects.first { $0.editorViewModel === editor }
    }

    private nonisolated static func inlinePlayableFile(url: URL, mimeType: String) -> [String: String]? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size > 0,
              size <= MCPPreviewApp.maxInlineMediaBytes,
              let data = try? Data(contentsOf: url)
        else { return nil }
        return ["mimeType": mimeType, "data": data.base64EncodedString()]
    }
}

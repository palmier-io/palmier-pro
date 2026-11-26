import Foundation

extension ToolExecutor {
    fileprivate struct DenoiseAudioInput: DecodableToolArgs {
        let clipIds: [String]
        let strength: Double?
        let enabled: Bool?
        static let allowedKeys: Set<String> = ["clipIds", "strength", "enabled"]
    }

    func denoiseAudio(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: DenoiseAudioInput = try decodeToolArgs(args, path: "denoise_audio")
        guard !input.clipIds.isEmpty else { throw ToolError("clipIds is empty.") }
        if let s = input.strength, !(0...1).contains(s) {
            throw ToolError("strength must be 0–1 (got \(s))")
        }
        for id in input.clipIds {
            guard let clip = editor.clipFor(id: id) else { throw ToolError("Clip not found: \(id)") }
            guard clip.mediaType == .audio else {
                throw ToolError("Clip \(id) is a \(clip.mediaType.rawValue) clip; denoise_audio needs an audio clip.")
            }
        }

        let enabled = input.enabled ?? true
        if enabled { try AudioEnhancer.availability.requireAvailable() }
        let snapshot = timelineSnapshot(editor)
        let actionName = enabled ? "Denoise Audio (Agent)" : "Disable Denoise (Agent)"
        if !enabled {
            let before = editor.timeline
            try editor.undo.perform(actionName) {
                try editor.setDenoise(clipIds: Set(input.clipIds), enabled: false, amount: nil, actionName: actionName)
            }
            let notes = ["Denoise disabled."]
            return mutationResult(editor, since: snapshot, touched: before == editor.timeline ? [] : input.clipIds,
                                  extra: ["noOp": before == editor.timeline], notes: notes)
        }
        let (jobId, isNew) = try await editor.startEnhancementJob(
            clipIds: Set(input.clipIds),
            type: .denoise,
            params: .denoise(amount: input.strength),
            actionName: actionName
        )
        let notes = ["Denoise job started: \(jobId.uuidString). \(isNew ? "New job." : "Reusing existing job.") Check status with get_enhancement_job_status."]
        return mutationResult(editor, since: snapshot, touched: [], extra: ["jobId": jobId.uuidString, "isNew": isNew], notes: notes)
    }

    fileprivate struct GetEnhancementJobStatusInput: DecodableToolArgs {
        let jobId: String
        static let allowedKeys: Set<String> = ["jobId"]
    }

    func getEnhancementJobStatus(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: GetEnhancementJobStatusInput = try decodeToolArgs(args, path: "get_enhancement_job_status")
        guard let uuid = UUID(uuidString: input.jobId) else { throw ToolError("Invalid jobId format.") }
        guard let status = editor.getEnhancementJobStatus(uuid) else { throw ToolError("Job not found: \(input.jobId)") }
        var result: [String: Any] = [
            "jobId": input.jobId,
            "status": status.status,
            "stage": status.stage,
            "progress": status.progress,
            "errors": status.errors,
            "warnings": status.warnings,
            "changedClipIds": status.changed,
        ]
        guard let json = Self.jsonString(result) else { return .error("Failed to encode status.") }
        return .ok(json)
    }

    fileprivate struct CancelEnhancementJobInput: DecodableToolArgs {
        let jobId: String
        static let allowedKeys: Set<String> = ["jobId"]
    }

    func cancelEnhancementJob(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: CancelEnhancementJobInput = try decodeToolArgs(args, path: "cancel_enhancement_job")
        guard let uuid = UUID(uuidString: input.jobId) else { throw ToolError("Invalid jobId format.") }
        editor.cancelEnhancementJob(uuid)
        guard let status = editor.getEnhancementJobStatus(uuid) else { throw ToolError("Job not found: \(input.jobId)") }
        var result: [String: Any] = [
            "jobId": input.jobId,
            "status": status.status,
            "stage": status.stage,
            "message": "Job cancelled.",
        ]
        guard let json = Self.jsonString(result) else { return .error("Failed to encode result.") }
        return .ok(json)
    }

    fileprivate struct ListEnhancementJobsInput: DecodableToolArgs {
        let status: String?
        static let allowedKeys: Set<String> = ["status"]
    }

    func listEnhancementJobs(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: ListEnhancementJobsInput = try decodeToolArgs(args, path: "list_enhancement_jobs")
        let jobs = editor.getAllEnhancementJobs()
        let filtered = input.status.map { s in jobs.filter { $0.2 == s } } ?? jobs
        var result: [[String: Any]] = filtered.map { job in
            [
                "jobId": job.0.uuidString,
                "type": job.1,
                "status": job.2,
                "clipCount": job.3,
                "progress": job.4,
            ]
        }
        guard let json = Self.jsonString(result) else { return .error("Failed to encode jobs.") }
        return .ok(json)
    }
}

import Foundation

enum ExportJobSource: String, Sendable {
    case manual
    case agent
}

enum ExportJobStatus: String, Sendable {
    case waiting = "queued"
    case preparing
    case exporting = "rendering"
    case canceling
    case completed
    case failed
    case canceled

    var isRunning: Bool {
        switch self {
        case .preparing, .exporting, .canceling: true
        default: false
        }
    }

    var isFinished: Bool {
        switch self {
        case .completed, .failed, .canceled: true
        default: false
        }
    }

    var isPending: Bool { self == .waiting || isRunning }
}

struct ExportJob: Identifiable, Sendable {
    let id: UUID
    let projectID: String
    let filename: String
    let source: ExportJobSource
    let outputURL: URL
    let createdAt: Date
    var status: ExportJobStatus
    var progress: Double
    var error: String?
    var warnings: [String]
    var palmierReport: CompositorProjectExporter.Report?
    /// Canonical source identities of the media the resolver used to render this job.
    var sourceIds: Set<String> = []
}

struct ExportQueueSubmission: Sendable {
    let jobID: UUID
    let started: Bool
    let queuePosition: Int
}

enum ExportQueueError: LocalizedError {
    case destinationInUse(String)
    case unknownJob

    var errorDescription: String? {
        switch self {
        case .unknownJob: "Export job not found."
        case .destinationInUse(let filename):
            "An export to \(filename) is already waiting or in progress."
        }
    }
}

@Observable
@MainActor
final class ExportQueue {
    static let shared = ExportQueue()

    typealias Operation = @MainActor (ExportService) async -> Void
    private(set) var jobs: [ExportJob] = []
    private var operations: [UUID: Operation] = [:]
    private var activeID: UUID?
    private var activeTask: Task<Void, Never>?
    private var activeService: ExportService?
    private var completionWaiters: [UUID: [UUID: CheckedContinuation<ExportJob, Error>]] = [:]

    var hasActivity: Bool { jobs.contains { $0.status.isPending } }
    var isExportActive: Bool { activeID != nil }

    func waitWhileExportActive() async throws {
        while let id = activeID {
            _ = try await waitForCompletion(id)
        }
    }

    func waitForCompletion(_ id: UUID) async throws -> ExportJob {
        try Task.checkCancellation()
        guard let job = job(id) else { throw ExportQueueError.unknownJob }
        if job.status.isFinished { return job }
        let token = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    completionWaiters[id, default: [:]][token] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.completionWaiters[id]?.removeValue(forKey: token)?.resume(throwing: CancellationError())
                if self.completionWaiters[id]?.isEmpty == true { self.completionWaiters[id] = nil }
            }
        }
    }

    private func notifyCompletion(_ job: ExportJob) {
        let waiters = completionWaiters.removeValue(forKey: job.id) ?? [:]
        for waiter in waiters.values { waiter.resume(returning: job) }
    }

    func jobs(for projectID: String) -> [ExportJob] {
        jobs.filter { $0.projectID == projectID }
    }

    func isDestinationReserved(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return jobs.contains { $0.status.isPending && $0.outputURL.standardizedFileURL.path == path }
    }

    @discardableResult
    func enqueueVideo(
        timeline: Timeline,
        resolver: MediaResolver,
        resolveTimeline: @escaping @Sendable (String) -> Timeline?,
        format: ExportFormat,
        resolution: ExportResolution,
        fcpxmlVersion: FCPXMLVersion = .default,
        fcpxmlTarget: FCPXMLTarget = .default,
        missingMediaRefs: Set<String>,
        outputURL: URL,
        source: ExportJobSource,
        projectID: String,
        analyticsProjectID: String?,
        warnings: [String] = []
    ) throws -> ExportQueueSubmission {
        let resolver = resolver.snapshot()
        let manifest = resolver.manifestSnapshot()
        let analyticsInput = ExportTimelineAnalyticsInput(
            scope: .exportedTimeline(root: timeline, resolveTimeline: resolveTimeline),
            manifest: manifest,
            exportFilename: outputURL.lastPathComponent
        )
        return try enqueue(outputURL: outputURL, projectID: projectID, source: source, warnings: warnings,
                           sourceIds: StockDeliveryHistory.sourceIds(manifest: manifest)) { service in
            await service.export(
                timeline: timeline,
                resolver: resolver,
                resolveTimeline: resolveTimeline,
                format: format,
                resolution: resolution,
                fcpxmlVersion: fcpxmlVersion,
                fcpxmlTarget: fcpxmlTarget,
                missingMediaRefs: missingMediaRefs,
                outputURL: outputURL,
                analyticsContext: ExportAnalyticsContext(
                    source: source.rawValue,
                    projectId: analyticsProjectID,
                    timelineInput: analyticsInput
                )
            )
        }
    }

    @discardableResult
    func enqueueCompositorProject(
        projectFile: ProjectFile,
        manifest: MediaManifest,
        sourceProjectURL: URL?,
        outputURL: URL,
        source: ExportJobSource,
        projectID: String,
        analyticsProjectID: String?
    ) throws -> ExportQueueSubmission {
        let analyticsInput = ExportTimelineAnalyticsInput(
            scope: .project(
                timelines: projectFile.timelines,
                rootTimelineId: projectFile.activeTimelineId
            ),
            manifest: manifest,
            exportFilename: outputURL.lastPathComponent
        )
        return try enqueue(outputURL: outputURL, projectID: projectID, source: source,
                           sourceIds: StockDeliveryHistory.sourceIds(manifest: manifest)) { service in
            await service.exportCompositorProject(
                projectFile: projectFile,
                manifest: manifest,
                sourceProjectURL: sourceProjectURL,
                outputURL: outputURL,
                analyticsContext: ExportAnalyticsContext(
                    source: source.rawValue,
                    projectId: analyticsProjectID,
                    timelineInput: analyticsInput
                )
            )
        }
    }

    @discardableResult
    func cancel(_ id: UUID) -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return false }
        switch jobs[index].status {
        case .waiting:
            operations[id] = nil
            jobs[index].status = .canceled
            notifyCompletion(jobs[index])
            return true
        case .preparing, .exporting:
            if let activeService, !activeService.cancel() { return false }
            jobs[index].status = .canceling
            activeTask?.cancel()
            return true
        case .canceling:
            return true
        default:
            return false
        }
    }

    func remove(_ id: UUID) {
        guard jobs.first(where: { $0.id == id })?.status.isFinished == true else { return }
        jobs.removeAll { $0.id == id }
    }

    func clearFinished(for projectID: String) {
        jobs.removeAll { $0.projectID == projectID && $0.status.isFinished }
    }

#if DEBUG
    @discardableResult
    func enqueueForTesting(
        outputURL: URL,
        projectID: String = "test-project",
        operation: @escaping Operation
    ) throws -> ExportQueueSubmission {
        try enqueue(outputURL: outputURL, projectID: projectID, source: .manual, operation: operation)
    }
#endif

    private func enqueue(
        outputURL: URL,
        projectID: String,
        source: ExportJobSource,
        warnings: [String] = [],
        sourceIds: Set<String> = [],
        operation: @escaping Operation
    ) throws -> ExportQueueSubmission {
        guard !isDestinationReserved(outputURL) else {
            throw ExportQueueError.destinationInUse(outputURL.lastPathComponent)
        }

        let id = UUID()
        jobs.append(ExportJob(
            id: id,
            projectID: projectID,
            filename: outputURL.lastPathComponent,
            source: source,
            outputURL: outputURL,
            createdAt: .now,
            status: .waiting,
            progress: 0,
            warnings: warnings,
            palmierReport: nil,
            sourceIds: sourceIds
        ))
        operations[id] = operation
        startNext()

        let waiting = jobs.filter { $0.status == .waiting }
        return ExportQueueSubmission(
            jobID: id,
            started: activeID == id,
            queuePosition: waiting.firstIndex(where: { $0.id == id }).map { $0 + 1 } ?? 0
        )
    }

    private func startNext() {
        guard activeID == nil,
              let index = jobs.firstIndex(where: { $0.status == .waiting && operations[$0.id] != nil }) else { return }
        let id = jobs[index].id
        activeID = id
        jobs[index].status = .preparing
        activeTask = Task { @MainActor [weak self] in await self?.run(id) }
    }

    private func run(_ id: UUID) async {
        guard activeID == id, let operation = operations[id] else { return }
        let service = ExportService()
        activeService = service
        guard !Task.isCancelled else {
            finish(id, status: .canceled, service: service)
            return
        }
        service.onPhaseChange = { [weak self] phase in self?.update(phase, for: id) }
        service.onProgressChange = { [weak self] progress in self?.update(progress, for: id) }

        await operation(service)

        let status: ExportJobStatus
        if service.didCommitOutput {
            status = .completed
        } else if service.wasCancelled || job(id)?.status == .canceling {
            status = .canceled
        } else if service.error != nil {
            status = .failed
        } else {
            service.error = "Export produced no output."
            status = .failed
        }
        let source = job(id)?.source
        let filename = job(id)?.filename
        let outputURL = job(id)?.outputURL
        let deliverySourceIds = job(id)?.sourceIds ?? []
        finish(id, status: status, service: service)

        if status == .completed, !deliverySourceIds.isEmpty, let filename {
            recordDelivery(sourceIds: deliverySourceIds, filename: filename)
        }

        guard source == .agent, let filename, let outputURL else { return }
        if status == .completed {
            AppNotifications.exportComplete(
                name: filename,
                outputURL: outputURL,
                size: service.lastReport?.outputSize,
                warningCount: job(id)?.warningCount(service.lastReport) ?? 0
            )
        } else if status == .failed {
            AppNotifications.exportFailed(name: filename, reason: service.error ?? "Export failed")
        }
    }

    /// Records a successful delivery in the bounded local usage history.
    ///
    /// Failed and canceled exports never pollute the history, so a retry does not
    /// deprioritize sources it did not actually deliver.
    private func recordDelivery(sourceIds: Set<String>, filename: String) {
        var history = StockDeliveryHistory.load()
        history.add(sourceIds: sourceIds, outputFilename: filename)
        history.save()
    }

    private func finish(_ id: UUID, status: ExportJobStatus, service: ExportService) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].status = status
        jobs[index].progress = status == .completed ? 1 : service.progress
        jobs[index].error = service.error
        if let report = service.lastCompositorReport {
            jobs[index].palmierReport = report
            jobs[index].warnings = report.warnings
        }
        operations[id] = nil
        notifyCompletion(jobs[index])
        activeID = nil
        activeTask = nil
        activeService = nil
        startNext()
    }

    private func update(_ phase: ExportService.Phase, for id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].status != .canceling else { return }
        jobs[index].status = phase == .preparing ? .preparing : .exporting
    }

    private func update(_ progress: Double, for id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].status.isPending
        else { return }
        jobs[index].progress = min(1, max(0, progress))
    }

    private func job(_ id: UUID) -> ExportJob? {
        jobs.first { $0.id == id }
    }

}

private extension ExportJob {
    func warningCount(_ mediaReport: ExportRunReport?) -> Int {
        if let palmierReport { return palmierReport.missing.count }
        if let mediaReport {
            return mediaReport.offlineMediaRefs.count + mediaReport.unprocessableMediaRefs.count
        }
        return warnings.count
    }
}

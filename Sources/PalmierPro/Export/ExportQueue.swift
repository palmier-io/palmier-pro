import Foundation

enum ExportJobSource: String, Sendable {
    case manual
    case agent
}

enum ExportJobStatus: Sendable {
    case waiting
    case preparing
    case exporting
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
}

struct ExportQueueSubmission: Sendable {
    let jobID: UUID
    let started: Bool
    let queuePosition: Int
}

enum ExportQueueError: LocalizedError {
    case destinationInUse(String)

    var errorDescription: String? {
        switch self {
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

    var hasActivity: Bool { jobs.contains { $0.status.isPending } }
    var isExportActive: Bool { activeID != nil }

    func waitWhileExportActive() async throws {
        while isExportActive {
            try await Task.sleep(for: .seconds(2))
        }
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
        analyticsProjectID: String?
    ) throws -> ExportQueueSubmission {
        let resolver = resolver.snapshot()
        return try enqueue(outputURL: outputURL, projectID: projectID, source: source) { service in
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
                analyticsContext: ExportAnalyticsContext(source: source.rawValue, projectId: analyticsProjectID)
            )
        }
    }

    @discardableResult
    func enqueuePalmierProject(
        projectFile: ProjectFile,
        manifest: MediaManifest,
        generationLog: GenerationLog,
        sourceProjectURL: URL?,
        outputURL: URL,
        source: ExportJobSource,
        projectID: String,
        analyticsProjectID: String?
    ) throws -> ExportQueueSubmission {
        try enqueue(outputURL: outputURL, projectID: projectID, source: source) { service in
            await service.exportPalmierProject(
                projectFile: projectFile,
                manifest: manifest,
                generationLog: generationLog,
                sourceProjectURL: sourceProjectURL,
                outputURL: outputURL,
                analyticsContext: ExportAnalyticsContext(source: source.rawValue, projectId: analyticsProjectID)
            )
        }
    }

    func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        switch jobs[index].status {
        case .waiting:
            operations[id] = nil
            jobs[index].status = .canceled
        case .preparing, .exporting:
            jobs[index].status = .canceling
            activeService?.cancel()
            activeTask?.cancel()
        default:
            break
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
            progress: 0
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
        service.onPhaseChange = { [weak self] phase in self?.update(phase, for: id) }
        service.onProgressChange = { [weak self] progress in self?.update(progress, for: id) }

        await operation(service)

        let status: ExportJobStatus
        if service.wasCancelled || Task.isCancelled || job(id)?.status == .canceling {
            status = .canceled
        } else if service.error != nil {
            status = .failed
        } else {
            status = .completed
        }
        let source = job(id)?.source
        let filename = job(id)?.filename
        let outputURL = job(id)?.outputURL
        finish(id, status: status, service: service)

        guard source == .agent, let filename, let outputURL else { return }
        if status == .completed {
            let report = service.lastReport
            AppNotifications.exportComplete(
                name: filename,
                outputURL: outputURL,
                size: report?.outputSize,
                warningCount: (report?.offlineMediaRefs.count ?? 0) + (report?.unprocessableMediaRefs.count ?? 0)
            )
        } else if status == .failed {
            AppNotifications.exportFailed(name: filename, reason: service.error ?? "Export failed")
        }
    }

    private func finish(_ id: UUID, status: ExportJobStatus, service: ExportService) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].status = status
        jobs[index].progress = status == .completed ? 1 : service.progress
        jobs[index].error = service.error
        operations[id] = nil
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
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].progress = min(1, max(0, progress))
    }

    private func job(_ id: UUID) -> ExportJob? {
        jobs.first { $0.id == id }
    }

}

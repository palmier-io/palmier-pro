#if canImport(AWSS3) && canImport(AWSLambda)
import Foundation
import AWSSDKCore
import AWSS3
import AWSS3Types
import AWSSDKIdentity
import AWSLambda

/// Optional AWS Lambda remote rendering backend for offloading heavy export batches.
/// Requires AWS credentials and a deployed Lambda function for rendering.
@MainActor
final class AWSLambdaRenderer {
    static let shared = AWSLambdaRenderer()

    private var lambdaClient: LambdaClient?
    private var s3Client: S3Client?
    private var configuration: LambdaRendererConfiguration?

    private init() {}

    /// Configures the renderer with AWS credentials and function details.
    func configure(_ config: LambdaRendererConfiguration) async {
        self.configuration = config

        let credentialsProvider = try? await DefaultCredentialProvider()
        let region = config.region

        self.lambdaClient = try? LambdaClient(
            region: region,
            credentialsProvider: credentialsProvider
        )
        self.s3Client = try? S3Client(
            region: region,
            credentialsProvider: credentialsProvider
        )
    }

    /// Exports a timeline using AWS Lambda.
    /// - Parameters:
    ///   - timeline: The timeline to render
    ///   - resolver: Media resolver for local assets
    ///   - format: Export format
    ///   - resolution: Export resolution
    ///   - outputURL: Local destination URL
    ///   - progressHandler: Optional progress callback
    /// - Returns: ExportRunReport with output info
    func export(
        timeline: Timeline,
        resolver: MediaResolver,
        format: ExportFormat,
        resolution: ExportResolution,
        outputURL: URL,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws -> ExportRunReport {
        guard let config = configuration,
              let lambdaClient = lambdaClient,
              let s3Client = s3Client else {
            throw LambdaRendererError.notConfigured
        }

        // Stage 1: Upload project and media to S3
        progressHandler?(0.1)
        let projectKey = "projects/\(UUID().uuidString)/project.json"
        let mediaPrefix = "projects/\(projectKey.split(separator: "/")[1])/media/"

        let projectData = try encodeProjectForLambda(timeline: timeline, resolver: resolver, format: format, resolution: resolution)
        try await uploadToS3(client: s3Client, bucket: config.bucket, key: projectKey, data: projectData)

        progressHandler?(0.2)
        let mediaUploadResult = try await uploadMediaAssets(resolver: resolver, s3Client: s3Client, bucket: config.bucket, prefix: mediaPrefix, progress: { p in
            progressHandler?(0.2 + p * 0.3)
        })

        // Stage 2: Invoke Lambda function
        progressHandler?(0.5)
        let invokeRequest = LambdaInvokeRequest(
            functionName: config.functionName,
            payload: try JSONEncoder().encode(LambdaRenderPayload(
                projectKey: projectKey,
                mediaKeys: mediaUploadResult,
                outputKey: "renders/\(UUID().uuidString).\(format.fileExtension)",
                format: format.rawValue,
                resolution: resolution.rawValue,
                fps: timeline.fps,
                width: timeline.width,
                height: timeline.height
            )),
            invocationType: .requestResponse
        )

        let invokeResponse = try await lambdaClient.invoke(input: invokeRequest)

        progressHandler?(0.7)

        // Stage 3: Download result from S3
        guard let payload = invokeResponse.payload,
              let result = try? JSONDecoder().decode(LambdaRenderResult.self, from: payload) else {
            throw LambdaRendererError.invalidLambdaResponse
        }

        if let error = result.error {
            throw LambdaRendererError.lambdaError(error)
        }

        progressHandler?(0.8)
        let outputKey = result.outputKey
        let outputData = try await downloadFromS3(client: s3Client, bucket: config.bucket, key: outputKey)
        try outputData.write(to: outputURL)

        progressHandler?(1.0)

        return ExportRunReport(
            outputSize: CGSize(width: resolution.renderSize(for: CGSize(width: timeline.width, height: timeline.height)).width,
                               height: resolution.renderSize(for: CGSize(width: timeline.width, height: timeline.height)).height),
            offlineMediaRefs: [],
            unprocessableMediaRefs: []
        )
    }

    /// Encodes timeline and media references for Lambda payload
    private func encodeProjectForLambda(
        timeline: Timeline,
        resolver: MediaResolver,
        format: ExportFormat,
        resolution: ExportResolution
    ) throws -> Data {
        let manifest = resolver.manifestSnapshot()
        let mediaRefs = resolver.expectedURLMap()

        struct LambdaProject: Codable {
            let timeline: Timeline
            let manifest: MediaManifest
            let format: String
            let resolution: String
        }

        return try JSONEncoder().encode(LambdaProject(
            timeline: timeline,
            manifest: manifest,
            format: format.rawValue,
            resolution: resolution.rawValue
        ))
    }

    private func uploadMediaAssets(
        resolver: MediaResolver,
        s3Client: S3Client,
        bucket: String,
        prefix: String,
        progress: @escaping (Double) -> Void
    ) async throws -> [String: String] {
        let mediaMap = resolver.expectedURLMap()
        var result: [String: String] = [:]

        for (index, (ref, url)) in mediaMap.enumerated() {
            let key = "\(prefix)\(ref)\(url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)")"
            let data = try Data(contentsOf: url)
            try await uploadToS3(client: s3Client, bucket: bucket, key: key, data: data)
            result[ref] = key
            progress(Double(index + 1) / Double(mediaMap.count))
        }

        return result
    }

    private func uploadToS3(client: S3Client, bucket: String, key: String, data: Data) async throws {
        let putInput = PutObjectInput(
            bucket: bucket,
            key: key,
            body: .data(data)
        )
        _ = try await client.putObject(input: putInput)
    }

    private func downloadFromS3(client: S3Client, bucket: String, key: String) async throws -> Data {
        let getInput = GetObjectInput(bucket: bucket, key: key)
        let output = try await client.getObject(input: getInput)
        guard let body = output.body else {
            throw LambdaRendererError.s3DownloadFailed
        }
        return try await Data(collecting: body, upTo: 1024 * 1024 * 1024) // 1GB max
    }
}

/// Configuration for Lambda renderer
struct LambdaRendererConfiguration: Codable, Sendable, Equatable {
    let region: String
    let bucket: String
    let functionName: String
    let timeoutSeconds: Int

    init(region: String = "us-east-1", bucket: String, functionName: String, timeoutSeconds: Int = 900) {
        self.region = region
        self.bucket = bucket
        self.functionName = functionName
        self.timeoutSeconds = timeoutSeconds
    }
}

/// Payload sent to Lambda function
struct LambdaRenderPayload: Codable, Sendable, Equatable {
    let projectKey: String
    let mediaKeys: [String: String]
    let outputKey: String
    let format: String
    let resolution: String
    let fps: Int
    let width: Int
    let height: Int
}

/// Result returned from Lambda function
struct LambdaRenderResult: Codable, Sendable, Equatable {
    let outputKey: String
    let error: String?
    let durationSeconds: Double
    let outputSize: CGSize?
}

enum LambdaRendererError: LocalizedError {
    case notConfigured
    case invalidLambdaResponse
    case lambdaError(String)
    case s3UploadFailed
    case s3DownloadFailed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "AWS Lambda renderer not configured. Call configure() first."
        case .invalidLambdaResponse: return "Invalid response from Lambda function"
        case .lambdaError(let msg): return "Lambda error: \(msg)"
        case .s3UploadFailed: return "Failed to upload to S3"
        case .s3DownloadFailed: return "Failed to download from S3"
        case .encodingFailed: return "Failed to encode project data"
        }
    }
}

/// Extension to ExportService for Lambda integration
extension ExportService {
    /// Exports using AWS Lambda if configured, otherwise falls back to local export.
    func exportWithLambdaFallback(
        timeline: Timeline,
        resolver: MediaResolver,
        format: ExportFormat,
        resolution: ExportResolution,
        outputURL: URL,
        analyticsContext: ExportAnalyticsContext = .init(),
        onProgress: ((Double) -> Void)? = nil
    ) async {
        if await AWSLambdaRenderer.shared.configuration != nil {
            do {
                let report = try await AWSLambdaRenderer.shared.export(
                    timeline: timeline,
                    resolver: resolver,
                    format: format,
                    resolution: resolution,
                    outputURL: outputURL,
                    progressHandler: onProgress
                )
                lastReport = report
                didCommitOutput = true
                setProgress(1)
                return
            } catch {
                Log.export.warning("Lambda export failed, falling back to local: \(error.localizedDescription)")
            }
        }
        // Fallback to local export
        await export(
            timeline: timeline,
            resolver: resolver,
            format: format,
            resolution: resolution,
            outputURL: outputURL,
            analyticsContext: analyticsContext
        )
    }
}
#endif

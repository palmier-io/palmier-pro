import AVFoundation
import CryptoKit
import Foundation

extension AgentDiagnostics {
    public enum FailureCategory: String, Codable, Sendable, CaseIterable {
        case transport
        case retrieval
        case planning
        case execution
        case audioProcessing = "audio_processing"
        case review
    }

    public struct FailureAttribution: Codable, Sendable, Equatable {
        public let category: FailureCategory
        public let reason: String
        public let details: String?

        public init(category: FailureCategory, reason: String, details: String? = nil) {
            self.category = category
            self.reason = DiagnosticLog.redact(reason)
            self.details = details.map { DiagnosticLog.redact($0) }
        }
    }

    public enum AgentMode: String, Codable, Sendable {
        case inApp = "in_app"
        case externalMCP = "external_mcp"
    }

    public struct CandidateSelection: Codable, Sendable, Equatable {
        public let shotIndex: Int
        public let query: String
        public let candidatesConsidered: Int
        public let selectedMediaRef: String
        public let selectionReason: String
        public let inspectionFramesReceived: Int

        public init(
            shotIndex: Int,
            query: String,
            candidatesConsidered: Int,
            selectedMediaRef: String,
            selectionReason: String,
            inspectionFramesReceived: Int
        ) {
            self.shotIndex = shotIndex
            self.query = DiagnosticLog.redact(query)
            self.candidatesConsidered = candidatesConsidered
            self.selectedMediaRef = selectedMediaRef
            self.selectionReason = DiagnosticLog.redact(selectionReason)
            self.inspectionFramesReceived = inspectionFramesReceived
        }
    }

    public struct InspectionRecord: Codable, Sendable, Equatable {
        public let toolName: String
        public let mediaRef: String
        public let framesReturned: Int
        public let imagesIncluded: Bool
        public let textMetadataKeys: [String]

        public init(
            toolName: String,
            mediaRef: String,
            framesReturned: Int,
            imagesIncluded: Bool,
            textMetadataKeys: [String]
        ) {
            self.toolName = toolName
            self.mediaRef = mediaRef
            self.framesReturned = framesReturned
            self.imagesIncluded = imagesIncluded
            self.textMetadataKeys = textMetadataKeys
        }
    }

    public struct TerminalJobState: Codable, Sendable, Equatable {
        public let toolName: String
        public let status: String
        public let durationMs: Int64
        public let error: String?

        public init(
            toolName: String,
            status: String,
            durationMs: Int64,
            error: String? = nil
        ) {
            self.toolName = toolName
            self.status = status
            self.durationMs = durationMs
            self.error = error.map { DiagnosticLog.redact($0) }
        }
    }

    public struct ExportMeasurements: Codable, Sendable, Equatable {
        public let durationSeconds: Double
        public let integratedLUFS: Double?
        public let truePeakDBFS: Double?
        public let clippedSamples: Int
        public let fileSizeBytes: Int64
        public let codec: String
        public let resolution: String
        public let shotCount: Int

        public init(
            durationSeconds: Double,
            integratedLUFS: Double?,
            truePeakDBFS: Double?,
            clippedSamples: Int,
            fileSizeBytes: Int64,
            codec: String,
            resolution: String,
            shotCount: Int
        ) {
            self.durationSeconds = durationSeconds
            self.integratedLUFS = integratedLUFS
            self.truePeakDBFS = truePeakDBFS
            self.clippedSamples = clippedSamples
            self.fileSizeBytes = fileSizeBytes
            self.codec = codec
            self.resolution = resolution
            self.shotCount = shotCount
        }

        @concurrent
        public static func measure(url: URL, timelineShotCount: Int = 0) async throws -> ExportMeasurements {
            let asset = AVURLAsset(url: url)
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            var codec = "unknown"
            var resolution = "unknown"
            let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            if let videoTrack = videoTracks.first {
                if let size = try? await videoTrack.load(.naturalSize) {
                    resolution = "\(Int(size.width))x\(Int(size.height))"
                }
                if let descriptions = try? await videoTrack.load(.formatDescriptions), let desc = descriptions.first {
                    let subType = CMFormatDescriptionGetMediaSubType(desc)
                    codec = fourCCToString(subType)
                }
            }
            let fileSizeBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

            var lufs: Double?
            var truePeak: Double?
            var clipped = 0
            let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            if !audioTracks.isEmpty {
                if let measurement = try? await LoudnessAnalyzer.integratedLoudness(for: url, mediaRef: url.lastPathComponent) {
                    lufs = measurement.integratedLUFS
                    truePeak = measurement.truePeakDBFS
                }
                let monoFloats = (try? await AudioTrackReader.readMonoFloats(from: url, sampleRate: 48_000)) ?? []
                for sample in monoFloats {
                    if abs(sample) >= 1.0 { clipped += 1 }
                }
            }
            return ExportMeasurements(
                durationSeconds: duration,
                integratedLUFS: lufs,
                truePeakDBFS: truePeak,
                clippedSamples: clipped,
                fileSizeBytes: fileSizeBytes,
                codec: codec,
                resolution: resolution,
                shotCount: timelineShotCount
            )
        }

        private static func fourCCToString(_ code: FourCharCode) -> String {
            let bytes: [UInt8] = [
                UInt8((code >> 24) & 0xff),
                UInt8((code >> 16) & 0xff),
                UInt8((code >> 8) & 0xff),
                UInt8(code & 0xff),
            ]
            return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        }
    }

    public struct QualityScores: Codable, Sendable, Equatable {
        public let visualRelevance: Double
        public let humanEditQuality: Double
        public let toolSuccessRate: Double

        public init(visualRelevance: Double, humanEditQuality: Double, toolSuccessRate: Double) {
            self.visualRelevance = visualRelevance
            self.humanEditQuality = humanEditQuality
            self.toolSuccessRate = toolSuccessRate
        }
    }

    public struct BaselineRunRecord: Codable, Sendable {
        public let id: String
        public let fixtureName: String
        public let agentMode: AgentMode
        public let timestamp: Date
        public let wireModelID: String
        public let endpointProtocol: String
        public let reasoningSetting: String
        public let instructionVersion: String
        public let skillVersions: [String: String]
        public let enabledCapabilities: [String: Bool]
        public let assetIDs: [String]
        public let outputTimelineRevision: Int
        public let extraTools: [String]
        public let extraContext: [String: String]
        public let candidateSelections: [CandidateSelection]
        public let rejectionReasons: [String]
        public let inspectionDelivery: [InspectionRecord]
        public let terminalJobStates: [TerminalJobState]
        public let exportedOutputMeasurements: ExportMeasurements?
        public let qualityScores: QualityScores?
        public var failure: FailureAttribution?

        public init(
            id: String = UUID().uuidString,
            fixtureName: String,
            agentMode: AgentMode,
            timestamp: Date = Date(),
            wireModelID: String,
            endpointProtocol: String,
            reasoningSetting: String,
            instructionVersion: String,
            skillVersions: [String: String],
            enabledCapabilities: [String: Bool],
            assetIDs: [String],
            outputTimelineRevision: Int,
            extraTools: [String] = [],
            extraContext: [String: String] = [:],
            candidateSelections: [CandidateSelection] = [],
            rejectionReasons: [String] = [],
            inspectionDelivery: [InspectionRecord] = [],
            terminalJobStates: [TerminalJobState] = [],
            exportedOutputMeasurements: ExportMeasurements? = nil,
            qualityScores: QualityScores? = nil,
            failure: FailureAttribution? = nil
        ) {
            self.id = id
            self.fixtureName = fixtureName
            self.agentMode = agentMode
            self.timestamp = timestamp
            self.wireModelID = DiagnosticLog.redact(wireModelID)
            self.endpointProtocol = endpointProtocol
            self.reasoningSetting = reasoningSetting
            self.instructionVersion = instructionVersion
            self.skillVersions = skillVersions
            self.enabledCapabilities = enabledCapabilities
            self.assetIDs = assetIDs
            self.outputTimelineRevision = outputTimelineRevision
            self.extraTools = extraTools
            self.extraContext = extraContext.mapValues { DiagnosticLog.redact($0) }
            self.candidateSelections = candidateSelections
            self.rejectionReasons = rejectionReasons.map { DiagnosticLog.redact($0) }
            self.inspectionDelivery = inspectionDelivery
            self.terminalJobStates = terminalJobStates
            self.exportedOutputMeasurements = exportedOutputMeasurements
            self.qualityScores = qualityScores
            self.failure = failure
        }

        public func sanitized() -> BaselineRunRecord {
            BaselineRunRecord(
                id: id,
                fixtureName: fixtureName,
                agentMode: agentMode,
                timestamp: timestamp,
                wireModelID: DiagnosticLog.redact(wireModelID),
                endpointProtocol: endpointProtocol,
                reasoningSetting: reasoningSetting,
                instructionVersion: instructionVersion,
                skillVersions: skillVersions,
                enabledCapabilities: enabledCapabilities,
                assetIDs: assetIDs,
                outputTimelineRevision: outputTimelineRevision,
                extraTools: extraTools,
                extraContext: extraContext.mapValues { DiagnosticLog.redact($0) },
                candidateSelections: candidateSelections,
                rejectionReasons: rejectionReasons.map { DiagnosticLog.redact($0) },
                inspectionDelivery: inspectionDelivery,
                terminalJobStates: terminalJobStates,
                exportedOutputMeasurements: exportedOutputMeasurements,
                qualityScores: qualityScores,
                failure: failure
            )
        }

        public func encodeArtifact() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(sanitized())
        }

        public static func decodeArtifact(from data: Data) throws -> BaselineRunRecord {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(BaselineRunRecord.self, from: data)
        }

        public func writeArtifact(to url: URL) throws {
            let data = try encodeArtifact()
            try data.write(to: url, options: .atomic)
        }

        public static func loadArtifact(from url: URL) throws -> BaselineRunRecord {
            let data = try Data(contentsOf: url)
            return try decodeArtifact(from: data)
        }
    }

    public static func assignFailure(
        to record: BaselineRunRecord,
        category: FailureCategory,
        reason: String,
        details: String? = nil
    ) -> BaselineRunRecord {
        var updated = record
        updated.failure = FailureAttribution(category: category, reason: reason, details: details)
        return updated
    }

    public static func computeInstructionVersion() -> String {
        let hash = SHA256.hash(data: Data(AgentInstructions.serverInstructions.utf8))
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    @MainActor
    public static func computeSkillVersions(from skillStore: SkillStore = .shared) -> [String: String] {
        var versions: [String: String] = [:]
        for skill in skillStore.skills {
            versions[skill.id] = skillStore.contentSHA(for: skill.id)
        }
        return versions
    }
}

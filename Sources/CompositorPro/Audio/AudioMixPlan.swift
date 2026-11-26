import Foundation

enum AudioRole: String, Codable, Sendable, CaseIterable {
    case voice, music, ambience, effects
}

struct AudioRoleAssignment: Codable, Sendable, Equatable {
    var clipId: String
    var role: AudioRole
    var targetLUFS: Double?
    var peakDBFS: Double?

    func level(for target: AudioDeliveryTarget) -> Double {
        switch role {
        case .voice: targetLUFS ?? target.integratedLUFS - 1
        case .music: targetLUFS ?? target.integratedLUFS - 12
        case .ambience: targetLUFS ?? target.integratedLUFS - 18
        case .effects: peakDBFS ?? min(-12, target.truePeakDBTP - 6)
        }
    }
}

struct AudioDeliveryTarget: Codable, Sendable, Equatable {
    var integratedLUFS: Double
    var truePeakDBTP: Double
    var toleranceLU: Double = 1

    func validate() throws {
        guard integratedLUFS.isFinite, (-60 ... -5).contains(integratedLUFS),
              truePeakDBTP.isFinite, (-20 ... 0).contains(truePeakDBTP),
              toleranceLU.isFinite, (0.1 ... 2).contains(toleranceLU) else {
            throw AudioFinishingError(reason: "Delivery requires -60…-5 LUFS, -20…0 dBTP, and 0.1…2 LU tolerance.")
        }
    }

    func accepts(_ measurement: AudioMeasurement) -> Bool {
        guard measurement.loudness.status == .measured,
              let loudness = measurement.loudness.integratedLUFS, loudness.isFinite,
              let peak = measurement.loudness.truePeakDBFS, peak.isFinite else { return false }
        return abs(loudness - integratedLUFS) <= toleranceLU
            && peak <= truePeakDBTP && measurement.clippedSamples == 0
    }

    var receipt: [String: Any] {
        ["integratedLUFS": integratedLUFS, "truePeakDBTP": truePeakDBTP, "toleranceLU": toleranceLU]
    }
}

struct AudioMixRequest: Codable, Sendable, Equatable {
    var roles: [AudioRoleAssignment]
    var target: AudioDeliveryTarget
    var ducking: DuckingPlan.Parameters
    var bedFadeFrames: Int
    var voiceDenoiseAmount: Double?

    func validated() throws -> Self {
        try target.validate()
        guard !roles.isEmpty, roles.count <= 256,
              Set(roles.map(\.clipId)).count == roles.count,
              roles.allSatisfy({ !$0.clipId.isEmpty && $0.clipId.count <= 128 }) else {
            throw AudioFinishingError(reason: "Assign 1…256 unique, nonempty audio clip IDs to roles.")
        }
        for assignment in roles {
            if let loudness = assignment.targetLUFS {
                guard assignment.role != .effects, loudness.isFinite, (-65 ... -5).contains(loudness) else {
                    throw AudioFinishingError(reason: "Role targetLUFS requires -65…-5 LUFS on voice, music, or ambience.")
                }
            }
            if let peak = assignment.peakDBFS {
                guard assignment.role == .effects, peak.isFinite, (-60 ... 0).contains(peak) else {
                    throw AudioFinishingError(reason: "Role peakDBFS requires -60…0 dBFS on effects.")
                }
            }
        }
        guard bedFadeFrames >= 0, bedFadeFrames < maxFrameArg,
              voiceDenoiseAmount.map({ $0.isFinite && (0 ... 1).contains($0) }) ?? true else {
            throw AudioFinishingError(reason: "Bed fades require nonnegative bounded frames; voice denoise requires 0…1.")
        }
        _ = try DuckingPlan.plan(bedStartFrame: 0, bedDurationFrames: 1, speechSpans: [], parameters: ducking)
        guard ducking.attackFrames < maxFrameArg, ducking.holdFrames < maxFrameArg,
              ducking.releaseFrames < maxFrameArg, ducking.mergeGapFrames < maxFrameArg,
              ducking.duckDb > VolumeScale.floorDb else {
            throw AudioFinishingError(reason: "Ducking must stay above the volume envelope's -60 dB mute floor.")
        }
        var value = self
        value.roles.sort { $0.clipId < $1.clipId }
        return value
    }
}

struct AudioMixState: Codable, Sendable, Equatable {
    var request: AudioMixRequest
    var ownedVolumeTracks: [String: KeyframeTrack<Double>]
    var outputRevision: String
    var sourceVersions: [String: LoudnessAnalyzer.SourceVersion]
    var measurement: AudioMeasurement
    var speechDetection: [String: String]
    var speechRanges: [String: [Range<Int>]]
    var speechBalance: AudioSpeechBalance
    var warnings: [String]
}

struct AudioMixReceipt: Sendable, Equatable {
    var timelineId: String
    var changedClipIds: [String]
    var changed: Bool
    var state: AudioMixState

    var receipt: [String: Any] {
        ["timelineId": timelineId, "changed": changed, "noOp": !changed,
         "changedClipIds": changedClipIds, "outputRevision": state.outputRevision,
         "target": state.request.target.receipt, "measurement": state.measurement.receipt,
         "roles": state.request.roles.map { assignment in
             var row: [String: Any] = ["clipId": assignment.clipId, "role": assignment.role.rawValue]
             row[assignment.role == .effects ? "peakDBFS" : "targetLUFS"] = assignment.level(for: state.request.target)
             return row
          }, "speechDetection": state.speechDetection, "speechBalance": state.speechBalance.receipt,
          "warnings": state.warnings]
    }
}

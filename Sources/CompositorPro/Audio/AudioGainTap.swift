import AVFoundation
import MediaToolbox
import Synchronization

enum AudioGainTap {
    struct Failure: LocalizedError {
        let code: Int32
        var errorDescription: String? { "Audio gain processing failed (\(code))." }
    }

    private final class Storage {
        let gain: Float
        let failure = Atomic<Int32>(0)

        init(gain: Float) { self.gain = gain }
    }

    static func make(gain: Float) throws -> MTAudioProcessingTap {
        guard gain.isFinite, gain >= 1 else { throw Failure(code: kAudio_ParamError) }
        let storage = Unmanaged.passRetained(Storage(gain: gain))
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: storage.toOpaque(),
            init: { _, info, output in output.pointee = info },
            finalize: { tap in
                Unmanaged<Storage>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                let state = Unmanaged<Storage>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let format = format.pointee
                guard format.mFormatID == kAudioFormatLinearPCM,
                      format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                      format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
                      format.mBitsPerChannel == 32 else {
                    state.failure.store(kAudioFormatUnsupportedDataFormatError, ordering: .relaxed)
                    return
                }
            },
            unprepare: nil,
            process: { tap, count, _, buffers, frames, flags in
                let state = Unmanaged<Storage>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let status = MTAudioProcessingTapGetSourceAudio(tap, count, buffers, flags, nil, frames)
                guard status == noErr else {
                    state.failure.store(status, ordering: .relaxed)
                    frames.pointee = 0
                    return
                }
                guard state.failure.load(ordering: .relaxed) == noErr,
                      AudioGainTap.amplify(buffers, frames: frames.pointee, gain: state.gain) else {
                    state.failure.store(kAudioFormatUnsupportedDataFormatError, ordering: .relaxed)
                    frames.pointee = 0
                    return
                }
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap
        )
        guard status == noErr, let tap else {
            storage.release()
            throw Failure(code: status)
        }
        return tap
    }

    static func validate(_ mix: AVAudioMix) throws {
        for parameters in mix.inputParameters {
            guard let tap = parameters.audioTapProcessor else { continue }
            let state = Unmanaged<Storage>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
            let code = state.failure.load(ordering: .relaxed)
            guard code == noErr else { throw Failure(code: code) }
        }
    }

    private static func amplify(_ list: UnsafeMutablePointer<AudioBufferList>, frames: CMItemCount, gain: Float) -> Bool {
        guard frames >= 0 else { return false }
        for buffer in UnsafeMutableAudioBufferListPointer(list) {
            if frames == 0 { continue }
            let count = frames.multipliedReportingOverflow(by: Int(buffer.mNumberChannels))
            guard !count.overflow, count.partialValue <= Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride,
                  let data = buffer.mData else { return false }
            let samples = data.assumingMemoryBound(to: Float.self)
            for i in 0..<count.partialValue { samples[i] *= gain }
        }
        return true
    }
}

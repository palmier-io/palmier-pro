import type { PreviewAudio } from './model'

export function decodePreviewAudio(payload: PreviewAudio): AudioBuffer | null {
  if (typeof AudioContext === 'undefined') return null
  const bytes = Uint8Array.from(atob(payload.samplesBase64), (char) =>
    char.charCodeAt(0),
  )
  if (bytes.byteLength < 4 || bytes.byteLength % 4 !== 0) return null
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  const totalSamples = bytes.byteLength / 4
  const channels = Math.max(1, payload.channels)
  if (totalSamples % channels !== 0) return null
  const frames = totalSamples / channels
  const context = sharedAudioContext()
  if (!context) return null
  const buffer = context.createBuffer(channels, frames, payload.sampleRate)
  for (let channel = 0; channel < channels; channel += 1) {
    const channelData = buffer.getChannelData(channel)
    for (let frame = 0; frame < frames; frame += 1) {
      channelData[frame] = view.getFloat32((frame * channels + channel) * 4, true)
    }
  }
  return buffer
}

let audioContext: AudioContext | null = null

export function sharedAudioContext(): AudioContext | null {
  if (typeof AudioContext === 'undefined') return null
  audioContext ??= new AudioContext()
  return audioContext
}

export async function resumeAudioContext(): Promise<AudioContext | null> {
  const context = sharedAudioContext()
  if (!context) return null
  if (context.state === 'suspended') {
    await context.resume()
  }
  return context
}

export function playAudioBuffer(
  buffer: AudioBuffer,
): AudioBufferSourceNode | null {
  const context = sharedAudioContext()
  if (!context) return null
  const source = context.createBufferSource()
  source.buffer = buffer
  source.connect(context.destination)
  source.start()
  return source
}

export function stopAudioSource(source: AudioBufferSourceNode | null): void {
  if (!source) return
  try {
    source.stop()
  } catch {
    // Already stopped.
  }
  try {
    source.disconnect()
  } catch {
    // Already disconnected.
  }
}

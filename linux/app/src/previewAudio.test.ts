import { describe, expect, test, vi } from 'vitest'
import { decodePreviewAudio } from './previewAudio'
import type { PreviewAudio } from './model'

class FakeAudioBuffer {
  numberOfChannels: number
  length: number
  sampleRate: number
  private readonly channels: Float32Array[]

  constructor(channels: number, length: number, sampleRate: number) {
    this.numberOfChannels = channels
    this.length = length
    this.sampleRate = sampleRate
    this.channels = Array.from(
      { length: channels },
      () => new Float32Array(length),
    )
  }

  getChannelData(channel: number) {
    return this.channels[channel] ?? new Float32Array(this.length)
  }
}

class FakeAudioContext {
  state = 'running'
  destination = {}
  createBuffer(channels: number, length: number, sampleRate: number) {
    return new FakeAudioBuffer(channels, length, sampleRate)
  }
  resume() {
    return Promise.resolve()
  }
  createBufferSource() {
    return {
      buffer: null,
      connect() {},
      start() {},
      stop() {},
      disconnect() {},
    }
  }
}

vi.stubGlobal('AudioContext', FakeAudioContext)

describe('preview audio', () => {
  test('decodes interleaved little-endian f32 samples', () => {
    const samples = new Float32Array([0.5, -0.5, 0.25, -0.25])
    const payload: PreviewAudio = {
      sampleRate: 48000,
      channels: 2,
      samplesBase64: btoa(String.fromCharCode(...new Uint8Array(samples.buffer))),
    }
    const buffer = decodePreviewAudio(payload)
    expect(buffer).not.toBeNull()
    expect(buffer?.numberOfChannels).toBe(2)
    expect(buffer?.length).toBe(2)
    expect(buffer?.getChannelData(0)[0]).toBeCloseTo(0.5)
    expect(buffer?.getChannelData(1)[0]).toBeCloseTo(-0.5)
  })
})

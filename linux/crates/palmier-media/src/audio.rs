//! Preview audio mixing helpers. Optional `playback` feature enables cpal output.

use crate::error::{MediaError, Result};

#[derive(Clone, Debug, PartialEq)]
pub struct MixedAudioBuffer {
    pub sample_rate: u32,
    pub channels: u16,
    pub samples: Vec<f32>,
}

pub fn mix_mono_to_interleaved(
    sources: &[(f32, &[f32])],
    sample_rate: u32,
    channels: u16,
    frames: usize,
) -> Result<MixedAudioBuffer> {
    if sample_rate == 0 || channels == 0 {
        return Err(MediaError::InvalidRequest(
            "audio mix requires nonzero sample rate and channels".into(),
        ));
    }
    let mut samples = vec![0.0_f32; frames * channels as usize];
    for (gain, mono) in sources {
        let gain = if gain.is_finite() { *gain } else { 0.0 };
        for (index, sample) in mono.iter().take(frames).enumerate() {
            let value = sample * gain;
            for channel in 0..channels as usize {
                samples[index * channels as usize + channel] += value;
            }
        }
    }
    for sample in &mut samples {
        *sample = sample.clamp(-1.0, 1.0);
    }
    Ok(MixedAudioBuffer {
        sample_rate,
        channels,
        samples,
    })
}

#[cfg(feature = "playback")]
pub mod output {
    use std::sync::{Arc, Mutex};

    use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
    use cpal::{SampleFormat, StreamConfig};

    use super::MixedAudioBuffer;
    use crate::error::{MediaError, Result};

    pub struct PreviewAudioPlayer {
        _stream: cpal::Stream,
        queue: Arc<Mutex<Vec<f32>>>,
    }

    impl PreviewAudioPlayer {
        pub fn open_default() -> Result<Self> {
            let host = cpal::default_host();
            let device = host
                .default_output_device()
                .ok_or_else(|| MediaError::InvalidRequest("no default audio output".into()))?;
            let config = device
                .default_output_config()
                .map_err(|error| MediaError::InvalidRequest(error.to_string()))?;
            if config.sample_format() != SampleFormat::F32 {
                return Err(MediaError::InvalidRequest(
                    "preview audio requires f32 output".into(),
                ));
            }
            let queue = Arc::new(Mutex::new(Vec::new()));
            let queue_callback = Arc::clone(&queue);
            let stream_config: StreamConfig = config.into();
            let stream = device
                .build_output_stream(
                    &stream_config,
                    move |data: &mut [f32], _| {
                        let mut queue = queue_callback
                            .lock()
                            .unwrap_or_else(|error| error.into_inner());
                        for sample in data.iter_mut() {
                            *sample = if queue.is_empty() {
                                0.0
                            } else {
                                queue.remove(0)
                            };
                        }
                    },
                    |error| eprintln!("preview audio stream error: {error}"),
                    None,
                )
                .map_err(|error| MediaError::InvalidRequest(error.to_string()))?;
            stream
                .play()
                .map_err(|error| MediaError::InvalidRequest(error.to_string()))?;
            Ok(Self {
                _stream: stream,
                queue,
            })
        }

        pub fn enqueue(&self, buffer: &MixedAudioBuffer) {
            if let Ok(mut queue) = self.queue.lock() {
                queue.extend_from_slice(&buffer.samples);
            }
        }

        pub fn clear(&self) {
            if let Ok(mut queue) = self.queue.lock() {
                queue.clear();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mixes_and_clamps() {
        let a = vec![0.8_f32; 4];
        let b = vec![0.8_f32; 4];
        let mixed = mix_mono_to_interleaved(&[(1.0, &a), (1.0, &b)], 48_000, 2, 4).unwrap();
        assert_eq!(mixed.samples.len(), 8);
        assert!(
            mixed
                .samples
                .iter()
                .all(|sample| (*sample - 1.0).abs() < f32::EPSILON)
        );
    }
}

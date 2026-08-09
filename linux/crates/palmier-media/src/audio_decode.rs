//! Decode a contiguous PCM range from a media file for export mixing.

use std::path::Path;

use ffmpeg_next as ffmpeg;

use crate::error::{MediaError, Result};
use crate::ffmpeg::initialize_ffmpeg_blocking;

#[derive(Clone, Debug, PartialEq)]
pub struct PcmRange {
    pub sample_rate: u32,
    pub channels: u16,
    pub samples: Vec<f32>,
}

pub fn decode_pcm_range(
    path: &Path,
    start_seconds: f64,
    duration_seconds: f64,
    output_sample_rate: u32,
    output_channels: u16,
) -> Result<PcmRange> {
    if !start_seconds.is_finite() || start_seconds < 0.0 {
        return Err(MediaError::InvalidRequest(
            "audio start time must be finite and non-negative".into(),
        ));
    }
    if !duration_seconds.is_finite() || duration_seconds <= 0.0 {
        return Err(MediaError::InvalidRequest(
            "audio duration must be finite and positive".into(),
        ));
    }
    if output_sample_rate == 0 || output_channels == 0 {
        return Err(MediaError::InvalidRequest(
            "audio output rate and channels must be nonzero".into(),
        ));
    }

    initialize_ffmpeg_blocking()?;
    let mut input = ffmpeg::format::input(&path)?;
    let stream = input
        .streams()
        .best(ffmpeg::media::Type::Audio)
        .ok_or(MediaError::StreamNotFound("audio"))?;
    let stream_index = stream.index();
    let time_base = stream.time_base();
    if time_base.numerator() <= 0 || time_base.denominator() <= 0 {
        return Err(MediaError::UnsupportedMedia(
            "audio stream has an invalid time base".into(),
        ));
    }
    let stream_start = if stream.start_time() == ffmpeg::ffi::AV_NOPTS_VALUE {
        0
    } else {
        stream.start_time()
    };
    let mut decoder = ffmpeg::codec::context::Context::from_parameters(stream.parameters())?
        .decoder()
        .audio()?;
    let decoder_rate = u32::try_from(decoder.rate()).unwrap_or(0);
    let decoder_channels = u16::try_from(decoder.channels()).unwrap_or(0);
    if decoder_rate == 0 || decoder_channels == 0 {
        return Err(MediaError::UnsupportedMedia(
            "audio decoder reported invalid layout".into(),
        ));
    }
    let layout = decoder.channel_layout();
    let format = decoder.format();
    let mut resampler = ffmpeg::software::resampling::Context::get(
        format,
        layout,
        decoder_rate,
        ffmpeg::format::Sample::F32(ffmpeg::format::sample::Type::Packed),
        ffmpeg::ChannelLayout::default(i32::from(output_channels)),
        output_sample_rate,
    )?;

    let seek_micros = (start_seconds * 1_000_000.0).floor() as i64;
    if seek_micros > 0 {
        input.seek(seek_micros, ..seek_micros)?;
        decoder.flush();
    }

    let target_samples = ((duration_seconds * f64::from(output_sample_rate)).ceil() as usize)
        .saturating_mul(usize::from(output_channels));
    let mut samples = Vec::with_capacity(target_samples);
    let end_seconds = start_seconds + duration_seconds;

    for (packet_stream, packet) in input.packets() {
        if packet_stream.index() != stream_index {
            continue;
        }
        decoder.send_packet(&packet)?;
        drain_audio(
            &mut decoder,
            &mut resampler,
            stream_start,
            time_base,
            start_seconds,
            end_seconds,
            output_channels,
            &mut samples,
            target_samples,
        )?;
        if samples.len() >= target_samples {
            break;
        }
    }
    decoder.send_eof()?;
    drain_audio(
        &mut decoder,
        &mut resampler,
        stream_start,
        time_base,
        start_seconds,
        end_seconds,
        output_channels,
        &mut samples,
        target_samples,
    )?;

    if samples.len() < target_samples {
        samples.resize(target_samples, 0.0);
    } else {
        samples.truncate(target_samples);
    }

    Ok(PcmRange {
        sample_rate: output_sample_rate,
        channels: output_channels,
        samples,
    })
}

fn drain_audio(
    decoder: &mut ffmpeg::decoder::Audio,
    resampler: &mut ffmpeg::software::resampling::Context,
    stream_start: i64,
    time_base: ffmpeg::Rational,
    start_seconds: f64,
    end_seconds: f64,
    output_channels: u16,
    samples: &mut Vec<f32>,
    target_samples: usize,
) -> Result<()> {
    let mut decoded = ffmpeg::frame::Audio::empty();
    while decoder.receive_frame(&mut decoded).is_ok() {
        let pts = decoded.pts().unwrap_or(stream_start);
        let seconds = (pts - stream_start) as f64 * f64::from(time_base.numerator())
            / f64::from(time_base.denominator());
        if seconds + 0.05 < start_seconds {
            continue;
        }
        if seconds >= end_seconds {
            return Ok(());
        }
        let mut converted = ffmpeg::frame::Audio::empty();
        resampler.run(&decoded, &mut converted)?;
        let plane = converted.data(0);
        let values = unsafe {
            std::slice::from_raw_parts(
                plane.as_ptr().cast::<f32>(),
                plane.len() / std::mem::size_of::<f32>(),
            )
        };
        let channels = usize::from(output_channels.max(1));
        let frame_offset = if seconds < start_seconds {
            let skip =
                ((start_seconds - seconds) * f64::from(converted.rate())).floor() as usize * channels;
            skip.min(values.len())
        } else {
            0
        };
        let remaining = target_samples.saturating_sub(samples.len());
        let take = values.len().saturating_sub(frame_offset).min(remaining);
        samples.extend_from_slice(&values[frame_offset..frame_offset + take]);
        if samples.len() >= target_samples {
            return Ok(());
        }
    }
    Ok(())
}

use std::cmp::Ordering;
use std::path::PathBuf;

use ffmpeg_next as ffmpeg;
use serde::{Deserialize, Serialize};
use tokio_util::sync::CancellationToken;

use crate::cache::CacheCost;
use crate::error::{MediaError, Result};
use crate::ffmpeg::initialize_ffmpeg_blocking;
use crate::probe::display_transform;
use crate::time::{ExactRational, MediaTime};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FrameOutput {
    Rgba,
    Jpeg { quality: u8 },
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct PausedFrameRequest {
    pub path: PathBuf,
    pub stream_index: Option<usize>,
    pub time: MediaTime,
    pub max_width: u32,
    pub max_height: u32,
    pub allow_upscale: bool,
    pub output: FrameOutput,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "format", rename_all = "snake_case")]
pub enum DecodedFrameData {
    Rgba { bytes: Vec<u8> },
    Jpeg { bytes: Vec<u8>, quality: u8 },
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct DecodedFrame {
    pub width: u32,
    pub height: u32,
    pub presentation_time: MediaTime,
    pub data: DecodedFrameData,
}

impl DecodedFrame {
    pub fn bytes(&self) -> &[u8] {
        match &self.data {
            DecodedFrameData::Rgba { bytes } | DecodedFrameData::Jpeg { bytes, .. } => bytes,
        }
    }
}

impl CacheCost for DecodedFrame {
    fn cost_bytes(&self) -> usize {
        let bytes = match &self.data {
            DecodedFrameData::Rgba { bytes } | DecodedFrameData::Jpeg { bytes, .. } => {
                bytes.capacity()
            }
        };
        bytes.saturating_add(std::mem::size_of::<Self>())
    }
}

pub async fn decode_paused_frame(request: PausedFrameRequest) -> Result<DecodedFrame> {
    decode_paused_frame_cancellable(request, CancellationToken::new()).await
}

pub fn decode_paused_frame_sync(request: PausedFrameRequest) -> Result<DecodedFrame> {
    decode_paused_frame_blocking(request, CancellationToken::new())
}

pub async fn decode_paused_frame_cancellable(
    request: PausedFrameRequest,
    cancellation: CancellationToken,
) -> Result<DecodedFrame> {
    tokio::task::spawn_blocking(move || decode_paused_frame_blocking(request, cancellation))
        .await
        .map_err(|error| MediaError::BlockingTask(error.to_string()))?
}

fn decode_paused_frame_blocking(
    request: PausedFrameRequest,
    cancellation: CancellationToken,
) -> Result<DecodedFrame> {
    validate_request(&request)?;
    check_cancelled(&cancellation)?;
    initialize_ffmpeg_blocking()?;

    let mut input = ffmpeg::format::input(&request.path)?;
    let stream = match request.stream_index {
        Some(index) => input
            .stream(index)
            .filter(|stream| stream.parameters().medium() == ffmpeg::media::Type::Video),
        None => input.streams().best(ffmpeg::media::Type::Video),
    }
    .ok_or(MediaError::StreamNotFound("video"))?;

    let stream_index = stream.index();
    let stream_time_base = stream.time_base();
    if stream_time_base.numerator() <= 0 || stream_time_base.denominator() <= 0 {
        return Err(MediaError::UnsupportedMedia(
            "video stream has an invalid time base".into(),
        ));
    }
    let stream_start = if stream.start_time() == ffmpeg::ffi::AV_NOPTS_VALUE {
        0
    } else {
        stream.start_time()
    };
    let display_transform = display_transform(&stream)?;
    if display_transform.mirrored {
        return Err(MediaError::UnsupportedMedia(
            "mirrored display matrices are not supported by paused-frame decode".into(),
        ));
    }
    let rotation = orthogonal_rotation(display_transform.clockwise_degrees)?;
    let mut decoder = ffmpeg::codec::context::Context::from_parameters(stream.parameters())?
        .decoder()
        .video()?;
    let _ = stream;

    let time_base = ExactRational::new(
        i128::from(stream_time_base.numerator()),
        i128::from(stream_time_base.denominator()),
    )?;
    let target_timestamp = request
        .time
        .seconds()
        .checked_div(time_base)?
        .checked_add(ExactRational::from_integer(i128::from(stream_start)))?;
    let seek_time = target_timestamp
        .checked_mul(time_base)?
        .checked_mul_integer(1_000_000)?
        .floor_i64()?;
    if seek_time > 0 {
        input.seek(seek_time, ..seek_time)?;
        decoder.flush();
    }

    let mut selected: Option<(ffmpeg::frame::Video, Option<i64>)> = None;
    let mut done = false;
    for (packet_stream, packet) in input.packets() {
        check_cancelled(&cancellation)?;
        if packet_stream.index() != stream_index {
            continue;
        }
        decoder.send_packet(&packet)?;
        drain_decoder(
            &mut decoder,
            target_timestamp,
            &mut selected,
            &mut done,
            &cancellation,
        )?;
        if done {
            break;
        }
    }
    if !done {
        decoder.send_eof()?;
        drain_decoder(
            &mut decoder,
            target_timestamp,
            &mut selected,
            &mut done,
            &cancellation,
        )?;
    }

    let (decoded, timestamp) = selected.ok_or(MediaError::FrameNotFound)?;
    check_cancelled(&cancellation)?;
    let presentation_time = timestamp
        .map(|timestamp| {
            ExactRational::from_integer(
                i128::from(timestamp)
                    .checked_sub(i128::from(stream_start))
                    .ok_or(MediaError::ArithmeticOverflow("frame presentation time"))?,
            )
            .checked_mul(time_base)
            .map(MediaTime::from_seconds)
        })
        .transpose()?
        .unwrap_or(request.time);
    convert_frame(decoded, rotation, &request, presentation_time)
}

fn drain_decoder(
    decoder: &mut ffmpeg::decoder::Video,
    target_timestamp: ExactRational,
    selected: &mut Option<(ffmpeg::frame::Video, Option<i64>)>,
    done: &mut bool,
    cancellation: &CancellationToken,
) -> Result<()> {
    loop {
        check_cancelled(cancellation)?;
        let mut frame = ffmpeg::frame::Video::empty();
        match decoder.receive_frame(&mut frame) {
            Ok(()) => {}
            Err(ffmpeg::Error::Eof)
            | Err(ffmpeg::Error::Other {
                errno: ffmpeg::util::error::EAGAIN,
            }) => return Ok(()),
            Err(error) => return Err(error.into()),
        }

        let timestamp = frame.timestamp();
        match timestamp {
            Some(timestamp) => {
                let ordering = ExactRational::from_integer(i128::from(timestamp))
                    .checked_cmp(target_timestamp)?;
                if ordering != Ordering::Greater {
                    *selected = Some((frame, Some(timestamp)));
                } else {
                    if selected.is_none() {
                        *selected = Some((frame, Some(timestamp)));
                    }
                    *done = true;
                    return Ok(());
                }
            }
            None => {
                *selected = Some((frame, None));
                *done = true;
                return Ok(());
            }
        }
    }
}

fn convert_frame(
    decoded: ffmpeg::frame::Video,
    rotation: u16,
    request: &PausedFrameRequest,
    presentation_time: MediaTime,
) -> Result<DecodedFrame> {
    let source_width = decoded.width();
    let source_height = decoded.height();
    if source_width == 0 || source_height == 0 {
        return Err(MediaError::UnsupportedMedia(
            "decoded frame has zero dimensions".into(),
        ));
    }
    let swaps_dimensions = rotation == 90 || rotation == 270;
    let (display_width, display_height) = if swaps_dimensions {
        (source_height, source_width)
    } else {
        (source_width, source_height)
    };
    let (output_width, output_height) = bounded_dimensions(
        display_width,
        display_height,
        request.max_width,
        request.max_height,
        request.allow_upscale,
    );
    let (scaled_width, scaled_height) = if swaps_dimensions {
        (output_height, output_width)
    } else {
        (output_width, output_height)
    };

    let mut scaler = ffmpeg::software::scaling::Context::get(
        decoded.format(),
        source_width,
        source_height,
        ffmpeg::format::Pixel::RGBA,
        scaled_width,
        scaled_height,
        ffmpeg::software::scaling::flag::Flags::BILINEAR,
    )?;
    let mut rgba = ffmpeg::frame::Video::empty();
    scaler.run(&decoded, &mut rgba)?;
    let packed = packed_rgba(&rgba)?;
    let rotated = rotate_rgba(&packed, scaled_width, scaled_height, rotation)?;

    let data = match request.output {
        FrameOutput::Rgba => DecodedFrameData::Rgba { bytes: rotated },
        FrameOutput::Jpeg { quality } => {
            let width = u16::try_from(output_width).map_err(|_| {
                MediaError::UnsupportedMedia("JPEG width exceeds 65535 pixels".into())
            })?;
            let height = u16::try_from(output_height).map_err(|_| {
                MediaError::UnsupportedMedia("JPEG height exceeds 65535 pixels".into())
            })?;
            let rgb_size = usize::try_from(output_width)
                .ok()
                .and_then(|width| {
                    usize::try_from(output_height)
                        .ok()
                        .and_then(|height| width.checked_mul(height))
                })
                .and_then(|pixels| pixels.checked_mul(3))
                .ok_or(MediaError::ArithmeticOverflow("JPEG RGB frame"))?;
            let mut rgb = Vec::with_capacity(rgb_size);
            for pixel in rotated.chunks_exact(4) {
                rgb.extend_from_slice(&pixel[..3]);
            }
            let mut bytes = Vec::new();
            jpeg_encoder::Encoder::new(&mut bytes, quality)
                .encode(&rgb, width, height, jpeg_encoder::ColorType::Rgb)
                .map_err(|error| {
                    MediaError::UnsupportedMedia(format!("JPEG encoding failed: {error}"))
                })?;
            DecodedFrameData::Jpeg { bytes, quality }
        }
    };

    Ok(DecodedFrame {
        width: output_width,
        height: output_height,
        presentation_time,
        data,
    })
}

fn packed_rgba(frame: &ffmpeg::frame::Video) -> Result<Vec<u8>> {
    let row_bytes = usize::try_from(frame.width())
        .map_err(|_| MediaError::ArithmeticOverflow("RGBA row size"))?
        .checked_mul(4)
        .ok_or(MediaError::ArithmeticOverflow("RGBA row size"))?;
    let height = usize::try_from(frame.height())
        .map_err(|_| MediaError::ArithmeticOverflow("RGBA frame size"))?;
    let mut packed = Vec::with_capacity(
        row_bytes
            .checked_mul(height)
            .ok_or(MediaError::ArithmeticOverflow("RGBA frame size"))?,
    );
    let data = frame.data(0);
    let stride = frame.stride(0);
    if stride < row_bytes {
        return Err(MediaError::UnsupportedMedia(
            "decoded RGBA stride is shorter than one row".into(),
        ));
    }
    for row in 0..height {
        let start = row
            .checked_mul(stride)
            .ok_or(MediaError::ArithmeticOverflow("RGBA row offset"))?;
        let end = start
            .checked_add(row_bytes)
            .ok_or(MediaError::ArithmeticOverflow("RGBA row offset"))?;
        if end > data.len() {
            return Err(MediaError::UnsupportedMedia(
                "decoded RGBA plane is shorter than expected".into(),
            ));
        }
        packed.extend_from_slice(&data[start..end]);
    }
    Ok(packed)
}

fn bounded_dimensions(
    width: u32,
    height: u32,
    max_width: u32,
    max_height: u32,
    allow_upscale: bool,
) -> (u32, u32) {
    if !allow_upscale && width <= max_width && height <= max_height {
        return (width, height);
    }
    let width_limited =
        u64::from(max_width) * u64::from(height) <= u64::from(max_height) * u64::from(width);
    if width_limited {
        let scaled_height =
            (u64::from(height) * u64::from(max_width) / u64::from(width)).max(1) as u32;
        (max_width, scaled_height)
    } else {
        let scaled_width =
            (u64::from(width) * u64::from(max_height) / u64::from(height)).max(1) as u32;
        (scaled_width, max_height)
    }
}

fn rotate_rgba(bytes: &[u8], width: u32, height: u32, rotation: u16) -> Result<Vec<u8>> {
    if rotation == 0 {
        return Ok(bytes.to_vec());
    }
    let width =
        usize::try_from(width).map_err(|_| MediaError::ArithmeticOverflow("rotated RGBA width"))?;
    let height = usize::try_from(height)
        .map_err(|_| MediaError::ArithmeticOverflow("rotated RGBA height"))?;
    let (output_width, output_height) = if rotation == 90 || rotation == 270 {
        (height, width)
    } else {
        (width, height)
    };
    let output_size = output_width
        .checked_mul(output_height)
        .and_then(|pixels| pixels.checked_mul(4))
        .ok_or(MediaError::ArithmeticOverflow("rotated RGBA frame"))?;
    if bytes.len() != output_size {
        return Err(MediaError::UnsupportedMedia(
            "RGBA frame size does not match its dimensions".into(),
        ));
    }
    let mut output = vec![0; output_size];
    for y in 0..height {
        for x in 0..width {
            let (output_x, output_y) = match rotation {
                90 => (height - 1 - y, x),
                180 => (width - 1 - x, height - 1 - y),
                270 => (y, width - 1 - x),
                _ => unreachable!(),
            };
            let source = (y * width + x) * 4;
            let destination = (output_y * output_width + output_x) * 4;
            output[destination..destination + 4].copy_from_slice(&bytes[source..source + 4]);
        }
    }
    Ok(output)
}

fn orthogonal_rotation(value: f64) -> Result<u16> {
    let normalized = value.rem_euclid(360.0);
    for candidate in [0_u16, 90, 180, 270] {
        let difference = (normalized - f64::from(candidate)).abs();
        if difference.min(360.0 - difference) <= 0.01 {
            return Ok(candidate);
        }
    }
    Err(MediaError::UnsupportedMedia(format!(
        "non-orthogonal display rotation {value}"
    )))
}

fn validate_request(request: &PausedFrameRequest) -> Result<()> {
    if request.path.as_os_str().is_empty()
        || request
            .path
            .to_str()
            .is_none_or(|value| value.contains('\0'))
    {
        return Err(MediaError::InvalidRequest(
            "FFmpeg decode path must be nonempty UTF-8".into(),
        ));
    }
    if request.time.seconds().is_negative() {
        return Err(MediaError::InvalidRequest(
            "decode time cannot be negative".into(),
        ));
    }
    if request.max_width == 0 || request.max_height == 0 {
        return Err(MediaError::InvalidRequest(
            "decode dimensions must be greater than zero".into(),
        ));
    }
    if request.max_width > i32::MAX as u32 || request.max_height > i32::MAX as u32 {
        return Err(MediaError::InvalidRequest(
            "decode dimensions exceed FFmpeg limits".into(),
        ));
    }
    if let FrameOutput::Jpeg { quality } = request.output
        && !(1..=100).contains(&quality)
    {
        return Err(MediaError::InvalidRequest(
            "JPEG quality must be from 1 through 100".into(),
        ));
    }
    Ok(())
}

fn check_cancelled(cancellation: &CancellationToken) -> Result<()> {
    if cancellation.is_cancelled() {
        Err(MediaError::Cancelled)
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dimensions_preserve_aspect_ratio_without_upscaling() {
        assert_eq!(bounded_dimensions(1920, 1080, 320, 320, false), (320, 180));
        assert_eq!(bounded_dimensions(100, 50, 320, 320, false), (100, 50));
    }

    #[test]
    fn rgba_rotation_moves_pixels_clockwise() {
        let pixels = vec![1, 0, 0, 255, 2, 0, 0, 255, 3, 0, 0, 255, 4, 0, 0, 255];

        let rotated = rotate_rgba(&pixels, 2, 2, 90).unwrap();

        assert_eq!(rotated[0], 3);
        assert_eq!(rotated[4], 1);
        assert_eq!(rotated[8], 4);
        assert_eq!(rotated[12], 2);
    }
}

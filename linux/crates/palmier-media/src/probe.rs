use std::cmp::Ordering;
use std::path::{Path, PathBuf};

use ffmpeg_next as ffmpeg;
use serde::{Deserialize, Serialize};

use crate::error::{MediaError, Result};
use crate::ffmpeg::initialize_ffmpeg_blocking;
use crate::time::{ExactRational, FrameRate, MediaTime};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MediaKind {
    Video,
    Audio,
    AudioVideo,
    Image,
    Unknown,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct VideoProbe {
    pub stream_index: usize,
    pub codec_id: String,
    pub decoder_name: Option<String>,
    pub width: u32,
    pub height: u32,
    pub display_width: u32,
    pub display_height: u32,
    pub display_rotation_degrees: f64,
    pub display_mirrored: bool,
    pub source_frame_rate: Option<FrameRate>,
    pub frame_count: Option<u64>,
    pub pixel_format: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct AudioProbe {
    pub stream_index: usize,
    pub codec_id: String,
    pub decoder_name: Option<String>,
    pub sample_rate: Option<u32>,
    pub channels: Option<u16>,
    pub channel_layout: Option<String>,
    pub sample_format: Option<String>,
    pub bit_rate: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct MediaProbe {
    pub path: PathBuf,
    pub kind: MediaKind,
    pub container: String,
    pub duration: Option<MediaTime>,
    pub bit_rate: Option<u64>,
    pub video: Option<VideoProbe>,
    pub audio_streams: Vec<AudioProbe>,
}

impl MediaProbe {
    pub fn has_audio(&self) -> bool {
        !self.audio_streams.is_empty()
    }
}

pub async fn probe_media(path: impl Into<PathBuf>) -> Result<MediaProbe> {
    let path = path.into();
    tokio::task::spawn_blocking(move || probe_media_blocking(&path))
        .await
        .map_err(|error| MediaError::BlockingTask(error.to_string()))?
}

fn probe_media_blocking(path: &Path) -> Result<MediaProbe> {
    if path.as_os_str().is_empty() || path.to_str().is_none_or(|value| value.contains('\0')) {
        return Err(MediaError::InvalidRequest(
            "FFmpeg input path must be nonempty UTF-8".into(),
        ));
    }
    initialize_ffmpeg_blocking()?;
    let input = ffmpeg::format::input(path)?;
    let container = input.format().name().to_owned();
    let duration = probe_duration(&input)?;
    let bit_rate = positive_u64(input.bit_rate());

    let video = input
        .streams()
        .best(ffmpeg::media::Type::Video)
        .map(|stream| probe_video_stream(&stream))
        .transpose()?;

    let mut audio_streams = Vec::new();
    for stream in input
        .streams()
        .filter(|stream| stream.parameters().medium() == ffmpeg::media::Type::Audio)
    {
        audio_streams.push(probe_audio_stream(&stream));
    }

    let kind = match (video.as_ref(), audio_streams.is_empty()) {
        (Some(video), true) if is_still_image(video, &input) => MediaKind::Image,
        (Some(_), true) => MediaKind::Video,
        (Some(_), false) => MediaKind::AudioVideo,
        (None, false) => MediaKind::Audio,
        (None, true) => MediaKind::Unknown,
    };

    Ok(MediaProbe {
        path: path.to_owned(),
        kind,
        container,
        duration,
        bit_rate,
        video,
        audio_streams,
    })
}

fn probe_video_stream(stream: &ffmpeg::format::stream::Stream<'_>) -> Result<VideoProbe> {
    let parameters = stream.parameters();
    let codec_id = format!("{:?}", parameters.id()).to_ascii_lowercase();
    let decoder_name = ffmpeg::decoder::find(parameters.id()).map(|codec| codec.name().to_owned());
    let source_frame_rate =
        frame_rate(stream.avg_frame_rate()).or_else(|| frame_rate(stream.rate()));
    let frame_count = positive_u64(stream.frames());
    let display_transform = display_transform(stream)?;
    let rotation = display_transform.clockwise_degrees;

    let decoded = ffmpeg::codec::context::Context::from_parameters(parameters)
        .and_then(|context| context.decoder().video());
    let (width, height, pixel_format) = match decoded {
        Ok(decoder) => (
            decoder.width(),
            decoder.height(),
            Some(format!("{:?}", decoder.format()).to_ascii_lowercase()),
        ),
        Err(_) => (0, 0, None),
    };
    let swaps_dimensions = {
        let normalized = rotation.round().rem_euclid(360.0) as i32;
        normalized == 90 || normalized == 270
    };
    let (display_width, display_height) = if swaps_dimensions {
        (height, width)
    } else {
        (width, height)
    };

    Ok(VideoProbe {
        stream_index: stream.index(),
        codec_id,
        decoder_name,
        width,
        height,
        display_width,
        display_height,
        display_rotation_degrees: rotation,
        display_mirrored: display_transform.mirrored,
        source_frame_rate,
        frame_count,
        pixel_format,
    })
}

fn probe_audio_stream(stream: &ffmpeg::format::stream::Stream<'_>) -> AudioProbe {
    let parameters = stream.parameters();
    let codec_id = format!("{:?}", parameters.id()).to_ascii_lowercase();
    let decoder_name = ffmpeg::decoder::find(parameters.id()).map(|codec| codec.name().to_owned());
    let decoded = ffmpeg::codec::context::Context::from_parameters(parameters)
        .and_then(|context| context.decoder().audio());

    match decoded {
        Ok(decoder) => AudioProbe {
            stream_index: stream.index(),
            codec_id,
            decoder_name,
            sample_rate: nonzero(decoder.rate()),
            channels: nonzero(decoder.channels()),
            channel_layout: Some(format!("{:?}", decoder.channel_layout())),
            sample_format: Some(decoder.format().name().to_owned()),
            bit_rate: nonzero(decoder.bit_rate() as u64),
        },
        Err(_) => AudioProbe {
            stream_index: stream.index(),
            codec_id,
            decoder_name,
            sample_rate: None,
            channels: None,
            channel_layout: None,
            sample_format: None,
            bit_rate: None,
        },
    }
}

fn probe_duration(input: &ffmpeg::format::context::Input) -> Result<Option<MediaTime>> {
    if input.duration() > 0 {
        return Ok(Some(MediaTime::from_micros(input.duration())?));
    }

    let mut longest: Option<ExactRational> = None;
    for stream in input.streams() {
        let duration = match positive_u64(stream.duration()) {
            Some(duration) => i128::from(duration),
            None => continue,
        };
        let time_base = stream.time_base();
        if time_base.numerator() <= 0 || time_base.denominator() <= 0 {
            continue;
        }
        let seconds = ExactRational::new(
            duration
                .checked_mul(i128::from(time_base.numerator()))
                .ok_or(MediaError::ArithmeticOverflow("stream duration"))?,
            i128::from(time_base.denominator()),
        )?;
        if longest
            .map(|current| seconds.checked_cmp(current))
            .transpose()?
            .is_none_or(|ordering| ordering == Ordering::Greater)
        {
            longest = Some(seconds);
        }
    }
    Ok(longest.map(MediaTime::from_seconds))
}

fn frame_rate(value: ffmpeg::Rational) -> Option<FrameRate> {
    let numerator = u32::try_from(value.numerator()).ok()?;
    let denominator = u32::try_from(value.denominator()).ok()?;
    FrameRate::new(numerator, denominator).ok()
}

#[derive(Clone, Copy)]
pub(crate) struct DisplayTransform {
    pub clockwise_degrees: f64,
    pub mirrored: bool,
}

pub(crate) fn display_transform(
    stream: &ffmpeg::format::stream::Stream<'_>,
) -> Result<DisplayTransform> {
    for side_data in stream.side_data() {
        if side_data.kind() != ffmpeg::codec::packet::side_data::Type::DisplayMatrix {
            continue;
        }
        let data = side_data.data();
        if data.len() < std::mem::size_of::<[i32; 9]>() {
            return Err(MediaError::UnsupportedMedia(
                "display matrix side data is truncated".into(),
            ));
        }
        let mut matrix = [0_i32; 9];
        unsafe {
            std::ptr::copy_nonoverlapping(
                data.as_ptr(),
                matrix.as_mut_ptr().cast::<u8>(),
                std::mem::size_of::<[i32; 9]>(),
            );
        }
        let rotation = unsafe { ffmpeg::ffi::av_display_rotation_get(matrix.as_ptr()) };
        if !rotation.is_finite() {
            return Err(MediaError::UnsupportedMedia(
                "display matrix is singular".into(),
            ));
        }
        let determinant = i128::from(matrix[0]) * i128::from(matrix[4])
            - i128::from(matrix[1]) * i128::from(matrix[3]);
        return Ok(DisplayTransform {
            clockwise_degrees: normalize_rotation(-rotation),
            mirrored: determinant < 0,
        });
    }

    let clockwise_degrees = match stream.metadata().get("rotate") {
        Some(value) => {
            let value = value.parse::<f64>().map_err(|_| {
                MediaError::UnsupportedMedia(format!("invalid display rotation metadata {value:?}"))
            })?;
            if !value.is_finite() {
                return Err(MediaError::UnsupportedMedia(
                    "display rotation metadata is not finite".into(),
                ));
            }
            normalize_rotation(value)
        }
        None => 0.0,
    };
    Ok(DisplayTransform {
        clockwise_degrees,
        mirrored: false,
    })
}

fn normalize_rotation(value: f64) -> f64 {
    let normalized = value.rem_euclid(360.0);
    if normalized.abs() < f64::EPSILON || (360.0 - normalized).abs() < f64::EPSILON {
        0.0
    } else {
        normalized
    }
}

fn is_still_image(video: &VideoProbe, input: &ffmpeg::format::context::Input) -> bool {
    if video.frame_count == Some(1) {
        return true;
    }
    if video.frame_count.is_some_and(|count| count > 1) {
        return false;
    }
    matches!(
        input
            .stream(video.stream_index)
            .map(|stream| stream.parameters().id()),
        Some(
            ffmpeg::codec::Id::MJPEG
                | ffmpeg::codec::Id::PNG
                | ffmpeg::codec::Id::BMP
                | ffmpeg::codec::Id::TIFF
                | ffmpeg::codec::Id::GIF
                | ffmpeg::codec::Id::APNG
                | ffmpeg::codec::Id::WEBP
                | ffmpeg::codec::Id::JPEG2000
        )
    )
}

fn positive_u64(value: i64) -> Option<u64> {
    u64::try_from(value).ok().filter(|value| *value > 0)
}

fn nonzero<T>(value: T) -> Option<T>
where
    T: Copy + Default + PartialEq,
{
    (value != T::default()).then_some(value)
}

#[cfg(test)]
mod tests {
    use std::io::Write;

    use super::*;

    #[tokio::test(flavor = "current_thread")]
    async fn probes_pcm_wave_when_ffmpeg_is_available() {
        let path = std::env::temp_dir().join(format!("palmier-probe-{}.wav", uuid::Uuid::new_v4()));
        write_pcm_wave(&path);

        let result = probe_media(path.clone()).await;
        let _ = std::fs::remove_file(&path);
        let probe = result.unwrap();

        assert_eq!(probe.kind, MediaKind::Audio);
        assert_eq!(probe.audio_streams[0].sample_rate, Some(8_000));
        assert_eq!(probe.audio_streams[0].channels, Some(1));
        assert!(probe.duration.is_some());
    }

    fn write_pcm_wave(path: &Path) {
        let sample_count = 800_u32;
        let data_size = sample_count * 2;
        let mut file = std::fs::File::create(path).unwrap();
        file.write_all(b"RIFF").unwrap();
        file.write_all(&(36 + data_size).to_le_bytes()).unwrap();
        file.write_all(b"WAVEfmt ").unwrap();
        file.write_all(&16_u32.to_le_bytes()).unwrap();
        file.write_all(&1_u16.to_le_bytes()).unwrap();
        file.write_all(&1_u16.to_le_bytes()).unwrap();
        file.write_all(&8_000_u32.to_le_bytes()).unwrap();
        file.write_all(&16_000_u32.to_le_bytes()).unwrap();
        file.write_all(&2_u16.to_le_bytes()).unwrap();
        file.write_all(&16_u16.to_le_bytes()).unwrap();
        file.write_all(b"data").unwrap();
        file.write_all(&data_size.to_le_bytes()).unwrap();
        file.write_all(&vec![0; data_size as usize]).unwrap();
    }
}

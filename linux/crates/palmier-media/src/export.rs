use std::collections::HashMap;
use std::ffi::{CString, OsString};
use std::os::unix::ffi::OsStrExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use ffmpeg_next as ffmpeg;
use serde::{Deserialize, Serialize};
use tokio::sync::{Semaphore, watch};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::error::{IoResultExt, MediaError, Result};
use crate::ffmpeg::initialize_ffmpeg_blocking;
use crate::plan::CompositionPlan;
use crate::probe::MediaProbe;
use crate::renderer::{RendererCapabilities, preflight_render};
use crate::time::{ExactRational, FrameRate};

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct AudioExportSettings {
    pub sample_rate: u32,
    pub channels: u16,
    pub bit_rate: u64,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ExportSettings {
    pub video_bit_rate: u64,
    pub video_encoder: Option<String>,
    pub audio: Option<AudioExportSettings>,
}

impl Default for ExportSettings {
    fn default() -> Self {
        Self {
            video_bit_rate: 12_000_000,
            video_encoder: None,
            audio: Some(AudioExportSettings {
                sample_rate: 48_000,
                channels: 2,
                bit_rate: 192_000,
            }),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ExportRequest {
    pub destination: PathBuf,
    pub overwrite: bool,
    pub plan: CompositionPlan,
    pub media: HashMap<String, MediaProbe>,
    pub settings: ExportSettings,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RgbaFrame {
    pub width: u32,
    pub height: u32,
    pub bytes: Vec<u8>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct InterleavedAudio {
    pub channels: u16,
    pub samples: Vec<f32>,
}

pub trait ExportFrameSource: Send + Sync {
    fn capabilities(&self) -> RendererCapabilities;

    fn render_video_frame(&self, frame_index: u64, width: u32, height: u32) -> Result<RgbaFrame>;

    fn render_audio(
        &self,
        start_sample: u64,
        sample_count: usize,
        sample_rate: u32,
        channels: u16,
    ) -> Result<InterleavedAudio>;
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
pub struct ExportJobId(Uuid);

impl ExportJobId {
    pub fn new() -> Self {
        Self(Uuid::new_v4())
    }

    pub const fn as_uuid(self) -> Uuid {
        self.0
    }
}

impl Default for ExportJobId {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ExportPhase {
    Preflight,
    Encoding,
    Finalizing,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ExportProgress {
    pub phase: ExportPhase,
    pub completed_video_frames: u64,
    pub total_video_frames: u64,
    pub completed_audio_samples: u64,
    pub total_audio_samples: u64,
    pub fraction: f32,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct ExportReceipt {
    pub destination: PathBuf,
    pub video_frames: u64,
    pub audio_samples: u64,
    pub bytes_written: u64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum ExportState {
    Queued,
    Running { progress: ExportProgress },
    Completed { receipt: ExportReceipt },
    Failed { message: String },
    Cancelled,
}

impl ExportState {
    pub fn is_terminal(&self) -> bool {
        matches!(
            self,
            Self::Completed { .. } | Self::Failed { .. } | Self::Cancelled
        )
    }
}

// Queue backends run only inside a blocking worker.
pub trait ExportBackend: Send + Sync {
    fn export(
        &self,
        request: &ExportRequest,
        source: &dyn ExportFrameSource,
        cancellation: &CancellationToken,
        progress: &(dyn Fn(ExportProgress) + Send + Sync),
    ) -> Result<ExportReceipt>;
}

#[derive(Default)]
struct FfmpegExportBackend;

impl ExportBackend for FfmpegExportBackend {
    fn export(
        &self,
        request: &ExportRequest,
        source: &dyn ExportFrameSource,
        cancellation: &CancellationToken,
        progress: &(dyn Fn(ExportProgress) + Send + Sync),
    ) -> Result<ExportReceipt> {
        export_with_ffmpeg(request, source, cancellation, progress)
    }
}

pub async fn export_media(
    request: ExportRequest,
    source: Arc<dyn ExportFrameSource>,
) -> Result<ExportReceipt> {
    export_media_cancellable(request, source, CancellationToken::new()).await
}

pub async fn export_media_cancellable(
    request: ExportRequest,
    source: Arc<dyn ExportFrameSource>,
    cancellation: CancellationToken,
) -> Result<ExportReceipt> {
    tokio::task::spawn_blocking(move || {
        FfmpegExportBackend.export(&request, source.as_ref(), &cancellation, &|_| {})
    })
    .await
    .map_err(|error| MediaError::BlockingTask(error.to_string()))?
}

pub struct ExportQueue {
    backend: Arc<dyn ExportBackend>,
    semaphore: Arc<Semaphore>,
    max_pending: usize,
    pending: Arc<AtomicUsize>,
    lifetime: CancellationToken,
}

impl ExportQueue {
    pub fn ffmpeg(max_pending: usize, max_concurrent: usize) -> Result<Self> {
        Self::new(max_pending, max_concurrent, Arc::new(FfmpegExportBackend))
    }

    pub fn new(
        max_pending: usize,
        max_concurrent: usize,
        backend: Arc<dyn ExportBackend>,
    ) -> Result<Self> {
        if max_pending == 0 || max_concurrent == 0 {
            return Err(MediaError::InvalidRequest(
                "export queue limits must be greater than zero".into(),
            ));
        }
        if tokio::runtime::Handle::try_current().is_err() {
            return Err(MediaError::InvalidRequest(
                "export queue requires an active Tokio runtime".into(),
            ));
        }
        Ok(Self {
            backend,
            semaphore: Arc::new(Semaphore::new(max_concurrent)),
            max_pending,
            pending: Arc::new(AtomicUsize::new(0)),
            lifetime: CancellationToken::new(),
        })
    }

    pub fn submit(
        &self,
        request: ExportRequest,
        source: Arc<dyn ExportFrameSource>,
    ) -> Result<ExportJobHandle> {
        reserve_pending(&self.pending, self.max_pending)?;

        let id = ExportJobId::new();
        let cancellation = self.lifetime.child_token();
        let (state_sender, state_receiver) = watch::channel(ExportState::Queued);
        let semaphore = Arc::clone(&self.semaphore);
        let pending = Arc::clone(&self.pending);
        let backend = Arc::clone(&self.backend);
        let task_cancellation = cancellation.clone();

        tokio::spawn(async move {
            let permit = tokio::select! {
                _ = task_cancellation.cancelled() => {
                    pending.fetch_sub(1, Ordering::AcqRel);
                    state_sender.send_replace(ExportState::Cancelled);
                    return;
                }
                permit = semaphore.acquire_owned() => permit,
            };
            pending.fetch_sub(1, Ordering::AcqRel);
            let Ok(_permit) = permit else {
                state_sender.send_replace(ExportState::Failed {
                    message: "export queue stopped".into(),
                });
                return;
            };
            if task_cancellation.is_cancelled() {
                state_sender.send_replace(ExportState::Cancelled);
                return;
            }

            let progress_sender = state_sender.clone();
            let progress_callback = move |progress| {
                progress_sender.send_replace(ExportState::Running { progress });
            };
            let blocking_cancellation = task_cancellation.clone();
            let result = tokio::task::spawn_blocking(move || {
                backend.export(
                    &request,
                    source.as_ref(),
                    &blocking_cancellation,
                    &progress_callback,
                )
            })
            .await;

            match result {
                Ok(Ok(receipt)) => {
                    state_sender.send_replace(ExportState::Completed { receipt });
                }
                Ok(Err(MediaError::Cancelled)) => {
                    state_sender.send_replace(ExportState::Cancelled);
                }
                Ok(Err(error)) => {
                    state_sender.send_replace(ExportState::Failed {
                        message: error.to_string(),
                    });
                }
                Err(error) => {
                    state_sender.send_replace(ExportState::Failed {
                        message: format!("blocking export task failed: {error}"),
                    });
                }
            }
        });

        Ok(ExportJobHandle {
            id,
            cancellation,
            state: state_receiver,
        })
    }
}

impl Drop for ExportQueue {
    fn drop(&mut self) {
        self.lifetime.cancel();
    }
}

pub struct ExportJobHandle {
    id: ExportJobId,
    cancellation: CancellationToken,
    state: watch::Receiver<ExportState>,
}

impl ExportJobHandle {
    pub const fn id(&self) -> ExportJobId {
        self.id
    }

    pub fn cancel(&self) {
        self.cancellation.cancel();
    }

    pub fn state(&self) -> ExportState {
        self.state.borrow().clone()
    }

    pub async fn changed(&mut self) -> Option<ExportState> {
        self.state.changed().await.ok()?;
        Some(self.state.borrow().clone())
    }

    pub async fn wait(mut self) -> ExportState {
        loop {
            let current = self.state.borrow().clone();
            if current.is_terminal() {
                return current;
            }
            if self.state.changed().await.is_err() {
                return self.state.borrow().clone();
            }
        }
    }
}

fn reserve_pending(pending: &AtomicUsize, maximum: usize) -> Result<()> {
    pending
        .fetch_update(Ordering::AcqRel, Ordering::Acquire, |value| {
            (value < maximum).then_some(value + 1)
        })
        .map(|_| ())
        .map_err(|_| MediaError::QueueFull)
}

fn export_with_ffmpeg(
    request: &ExportRequest,
    source: &dyn ExportFrameSource,
    cancellation: &CancellationToken,
    progress: &(dyn Fn(ExportProgress) + Send + Sync),
) -> Result<ExportReceipt> {
    validate_export_request(request)?;
    check_cancelled(cancellation)?;
    initialize_ffmpeg_blocking()?;

    progress(ExportProgress {
        phase: ExportPhase::Preflight,
        completed_video_frames: 0,
        total_video_frames: request.plan.duration_frames,
        completed_audio_samples: 0,
        total_audio_samples: 0,
        fraction: 0.0,
    });
    preflight_render(&request.plan, &source.capabilities(), &request.media)?.require_supported()?;
    check_cancelled(cancellation)?;

    if !request.overwrite && path_exists(&request.destination)? {
        return Err(MediaError::DestinationExists(request.destination.clone()));
    }
    let stage_path = staging_path(&request.destination)?;
    let mut staged_file = StagedFile::new(stage_path.clone());

    let mut output = ffmpeg::format::output(&stage_path)?;
    let mut video = configure_video_encoder(
        &mut output,
        request.plan.width,
        request.plan.height,
        request.plan.frame_rate,
        &request.settings,
    )?;
    let mut audio = request
        .settings
        .audio
        .as_ref()
        .map(|settings| configure_audio_encoder(&mut output, settings))
        .transpose()?;
    output.write_header()?;
    video.output_time_base = output
        .stream(video.stream_index)
        .ok_or(MediaError::StreamNotFound("output video"))?
        .time_base();
    if let Some(audio) = &mut audio {
        audio.output_time_base = output
            .stream(audio.stream_index)
            .ok_or(MediaError::StreamNotFound("output audio"))?
            .time_base();
    }

    let total_audio_samples = request
        .settings
        .audio
        .as_ref()
        .map(|settings| {
            total_audio_samples(
                request.plan.duration_frames,
                request.plan.frame_rate,
                settings.sample_rate,
            )
        })
        .transpose()?
        .unwrap_or(0);
    let mut audio_cursor = 0_u64;
    let mut scaler = ffmpeg::software::scaling::Context::get(
        ffmpeg::format::Pixel::RGBA,
        request.plan.width,
        request.plan.height,
        video.pixel_format,
        request.plan.width,
        request.plan.height,
        ffmpeg::software::scaling::flag::Flags::BILINEAR,
    )?;

    for frame_index in 0..request.plan.duration_frames {
        check_cancelled(cancellation)?;
        let rendered =
            source.render_video_frame(frame_index, request.plan.width, request.plan.height)?;
        let mut rgba = rgba_frame(rendered, request.plan.width, request.plan.height)?;
        rgba.set_pts(Some(i64::try_from(frame_index).map_err(|_| {
            MediaError::ArithmeticOverflow("video frame timestamp")
        })?));
        let mut yuv = ffmpeg::frame::Video::empty();
        scaler.run(&rgba, &mut yuv)?;
        yuv.set_pts(rgba.pts());
        video.encoder.send_frame(&yuv)?;
        drain_video_packets(&mut video, &mut output)?;

        if let (Some(audio), Some(settings)) = (&mut audio, &request.settings.audio) {
            let due = audio_due_after_frame(
                frame_index,
                request.plan.frame_rate,
                settings.sample_rate,
                total_audio_samples,
            )?;
            while audio_cursor < due {
                audio_cursor = encode_audio_chunk(
                    audio,
                    &mut output,
                    source,
                    audio_cursor,
                    total_audio_samples,
                    settings,
                )?;
            }
        }
        report_encoding_progress(
            progress,
            frame_index + 1,
            request.plan.duration_frames,
            audio_cursor,
            total_audio_samples,
        );
    }

    if let (Some(audio), Some(settings)) = (&mut audio, &request.settings.audio) {
        while audio_cursor < total_audio_samples {
            check_cancelled(cancellation)?;
            audio_cursor = encode_audio_chunk(
                audio,
                &mut output,
                source,
                audio_cursor,
                total_audio_samples,
                settings,
            )?;
            report_encoding_progress(
                progress,
                request.plan.duration_frames,
                request.plan.duration_frames,
                audio_cursor,
                total_audio_samples,
            );
        }
    }

    check_cancelled(cancellation)?;
    video.encoder.send_eof()?;
    drain_video_packets(&mut video, &mut output)?;
    if let Some(audio) = &mut audio {
        audio.encoder.send_eof()?;
        drain_audio_packets(audio, &mut output)?;
    }
    progress(ExportProgress {
        phase: ExportPhase::Finalizing,
        completed_video_frames: request.plan.duration_frames,
        total_video_frames: request.plan.duration_frames,
        completed_audio_samples: audio_cursor,
        total_audio_samples,
        fraction: 0.99,
    });
    output.write_trailer()?;
    drop(output);

    check_cancelled(cancellation)?;
    commit_staged_file(&stage_path, &request.destination, request.overwrite)?;
    staged_file.committed = true;
    let bytes_written = std::fs::metadata(&request.destination)
        .at_path(&request.destination)?
        .len();
    Ok(ExportReceipt {
        destination: request.destination.clone(),
        video_frames: request.plan.duration_frames,
        audio_samples: audio_cursor,
        bytes_written,
    })
}

struct VideoEncoder {
    encoder: ffmpeg::encoder::video::Encoder,
    stream_index: usize,
    input_time_base: ffmpeg::Rational,
    output_time_base: ffmpeg::Rational,
    pixel_format: ffmpeg::format::Pixel,
}

fn configure_video_encoder(
    output: &mut ffmpeg::format::context::Output,
    width: u32,
    height: u32,
    frame_rate: FrameRate,
    settings: &ExportSettings,
) -> Result<VideoEncoder> {
    let codec = match &settings.video_encoder {
        Some(name) => ffmpeg::encoder::find_by_name(name)
            .ok_or_else(|| MediaError::CodecUnavailable(name.clone()))?,
        None => ffmpeg::encoder::find_by_name("libx264")
            .or_else(|| ffmpeg::encoder::find(ffmpeg::codec::Id::H264))
            .ok_or_else(|| MediaError::CodecUnavailable("H.264 encoder".into()))?,
    };
    if !matches!(
        codec.id(),
        ffmpeg::codec::Id::H264 | ffmpeg::codec::Id::HEVC | ffmpeg::codec::Id::PRORES
    ) {
        return Err(MediaError::InvalidRequest(format!(
            "video encoder {} is not H.264, H.265, or ProRes",
            codec.name()
        )));
    }
    let preferred_format = if codec.id() == ffmpeg::codec::Id::PRORES {
        ffmpeg::format::Pixel::YUV422P10LE
    } else {
        ffmpeg::format::Pixel::YUV420P
    };
    let pixel_format = codec
        .video()?
        .formats()
        .and_then(|formats| {
            let supported = formats.collect::<Vec<_>>();
            supported
                .contains(&preferred_format)
                .then_some(preferred_format)
                .or_else(|| supported.first().copied())
        })
        .unwrap_or(preferred_format);

    let numerator = i32::try_from(frame_rate.numerator())
        .map_err(|_| MediaError::ArithmeticOverflow("FFmpeg frame rate"))?;
    let denominator = i32::try_from(frame_rate.denominator())
        .map_err(|_| MediaError::ArithmeticOverflow("FFmpeg frame rate"))?;
    let time_base = ffmpeg::Rational(denominator, numerator);
    let global_header = output
        .format()
        .flags()
        .contains(ffmpeg::format::Flags::GLOBAL_HEADER);
    let mut stream = output.add_stream(codec)?;
    let stream_index = stream.index();
    stream.set_time_base(time_base);
    stream.set_rate((numerator, denominator));
    stream.set_avg_frame_rate((numerator, denominator));

    let mut encoder = ffmpeg::codec::context::Context::new_with_codec(codec)
        .encoder()
        .video()?;
    encoder.set_width(width);
    encoder.set_height(height);
    encoder.set_format(pixel_format);
    encoder.set_time_base(time_base);
    encoder.set_frame_rate(Some((numerator, denominator)));
    encoder.set_bit_rate(
        usize::try_from(settings.video_bit_rate)
            .map_err(|_| MediaError::ArithmeticOverflow("video bit rate"))?,
    );
    if matches!(codec.id(), ffmpeg::codec::Id::H264 | ffmpeg::codec::Id::HEVC) {
        let gop = frame_rate
            .numerator()
            .div_ceil(frame_rate.denominator())
            .max(1)
            .checked_mul(2)
            .ok_or(MediaError::ArithmeticOverflow("video GOP size"))?;
        encoder.set_gop(gop);
        encoder.set_max_b_frames(0);
    }
    if global_header {
        encoder.set_flags(ffmpeg::codec::Flags::GLOBAL_HEADER);
    }
    let encoder = encoder.open_as(codec)?;
    stream.set_parameters(&encoder);

    Ok(VideoEncoder {
        encoder,
        stream_index,
        input_time_base: time_base,
        output_time_base: time_base,
        pixel_format,
    })
}

struct AudioEncoder {
    encoder: ffmpeg::encoder::audio::Encoder,
    stream_index: usize,
    input_time_base: ffmpeg::Rational,
    output_time_base: ffmpeg::Rational,
    frame_size: usize,
    layout: ffmpeg::ChannelLayout,
    input_format: ffmpeg::format::Sample,
    resampler: ffmpeg::software::resampling::Context,
}

fn configure_audio_encoder(
    output: &mut ffmpeg::format::context::Output,
    settings: &AudioExportSettings,
) -> Result<AudioEncoder> {
    let codec = ffmpeg::encoder::find(ffmpeg::codec::Id::AAC)
        .ok_or_else(|| MediaError::CodecUnavailable("AAC encoder".into()))?;
    let audio_codec = codec.audio()?;
    let rate = i32::try_from(settings.sample_rate)
        .map_err(|_| MediaError::ArithmeticOverflow("audio sample rate"))?;
    if let Some(rates) = audio_codec.rates()
        && !rates.into_iter().any(|candidate| candidate == rate)
    {
        return Err(MediaError::UnsupportedMedia(format!(
            "AAC encoder does not support {} Hz",
            settings.sample_rate
        )));
    }
    let layout = match settings.channels {
        1 => ffmpeg::ChannelLayout::MONO,
        2 => ffmpeg::ChannelLayout::STEREO,
        channels => {
            return Err(MediaError::UnsupportedMedia(format!(
                "AAC export supports one or two channels, requested {channels}"
            )));
        }
    };
    if let Some(layouts) = audio_codec.channel_layouts()
        && !layouts.into_iter().any(|candidate| candidate == layout)
    {
        return Err(MediaError::UnsupportedMedia(format!(
            "AAC encoder does not support {} channels",
            settings.channels
        )));
    }
    let format = audio_codec
        .formats()
        .and_then(|mut formats| formats.next())
        .ok_or_else(|| {
            MediaError::UnsupportedMedia("AAC encoder reports no sample formats".into())
        })?;
    let time_base = ffmpeg::Rational(1, rate);
    let global_header = output
        .format()
        .flags()
        .contains(ffmpeg::format::Flags::GLOBAL_HEADER);
    let mut stream = output.add_stream(codec)?;
    let stream_index = stream.index();
    stream.set_time_base(time_base);

    let mut encoder = ffmpeg::codec::context::Context::new_with_codec(codec)
        .encoder()
        .audio()?;
    encoder.set_rate(rate);
    encoder.set_channel_layout(layout);
    encoder.set_format(format);
    encoder.set_time_base(time_base);
    encoder.set_bit_rate(
        usize::try_from(settings.bit_rate)
            .map_err(|_| MediaError::ArithmeticOverflow("audio bit rate"))?,
    );
    if global_header {
        encoder.set_flags(ffmpeg::codec::Flags::GLOBAL_HEADER);
    }
    let encoder = encoder.open_as(codec)?;
    stream.set_parameters(&encoder);
    let frame_size = usize::try_from(encoder.frame_size())
        .map_err(|_| MediaError::ArithmeticOverflow("AAC frame size"))?
        .max(1);
    let input_format = ffmpeg::format::Sample::F32(ffmpeg::format::sample::Type::Packed);
    let resampler = ffmpeg::software::resampling::Context::get(
        input_format,
        layout,
        settings.sample_rate,
        encoder.format(),
        layout,
        settings.sample_rate,
    )?;

    Ok(AudioEncoder {
        encoder,
        stream_index,
        input_time_base: time_base,
        output_time_base: time_base,
        frame_size,
        layout,
        input_format,
        resampler,
    })
}

fn rgba_frame(rendered: RgbaFrame, width: u32, height: u32) -> Result<ffmpeg::frame::Video> {
    if rendered.width != width || rendered.height != height {
        return Err(MediaError::InvalidRequest(format!(
            "renderer returned {}x{} for a {}x{} export",
            rendered.width, rendered.height, width, height
        )));
    }
    let row_bytes = usize::try_from(width)
        .map_err(|_| MediaError::ArithmeticOverflow("export RGBA row"))?
        .checked_mul(4)
        .ok_or(MediaError::ArithmeticOverflow("export RGBA row"))?;
    let expected = row_bytes
        .checked_mul(
            usize::try_from(height)
                .map_err(|_| MediaError::ArithmeticOverflow("export RGBA frame"))?,
        )
        .ok_or(MediaError::ArithmeticOverflow("export RGBA frame"))?;
    if rendered.bytes.len() != expected {
        return Err(MediaError::InvalidRequest(format!(
            "renderer returned {} RGBA bytes, expected {expected}",
            rendered.bytes.len()
        )));
    }

    let mut frame = ffmpeg::frame::Video::new(ffmpeg::format::Pixel::RGBA, width, height);
    let stride = frame.stride(0);
    if stride < row_bytes {
        return Err(MediaError::UnsupportedMedia(
            "FFmpeg allocated an invalid RGBA stride".into(),
        ));
    }
    let destination = frame.data_mut(0);
    let height =
        usize::try_from(height).map_err(|_| MediaError::ArithmeticOverflow("export RGBA frame"))?;
    for row in 0..height {
        let source_start = row
            .checked_mul(row_bytes)
            .ok_or(MediaError::ArithmeticOverflow("export RGBA row offset"))?;
        let destination_start = row
            .checked_mul(stride)
            .ok_or(MediaError::ArithmeticOverflow("export RGBA row offset"))?;
        let source_end = source_start
            .checked_add(row_bytes)
            .ok_or(MediaError::ArithmeticOverflow("export RGBA row offset"))?;
        let destination_end = destination_start
            .checked_add(row_bytes)
            .ok_or(MediaError::ArithmeticOverflow("export RGBA row offset"))?;
        if destination_end > destination.len() {
            return Err(MediaError::UnsupportedMedia(
                "FFmpeg allocated a short RGBA frame".into(),
            ));
        }
        destination[destination_start..destination_end]
            .copy_from_slice(&rendered.bytes[source_start..source_end]);
    }
    Ok(frame)
}

fn encode_audio_chunk(
    audio: &mut AudioEncoder,
    output: &mut ffmpeg::format::context::Output,
    source: &dyn ExportFrameSource,
    cursor: u64,
    total: u64,
    settings: &AudioExportSettings,
) -> Result<u64> {
    let remaining = usize::try_from(
        total
            .checked_sub(cursor)
            .ok_or(MediaError::ArithmeticOverflow("audio sample remainder"))?,
    )
    .unwrap_or(usize::MAX);
    let requested = remaining.min(audio.frame_size);
    let rendered =
        source.render_audio(cursor, requested, settings.sample_rate, settings.channels)?;
    if rendered.channels != settings.channels {
        return Err(MediaError::InvalidRequest(format!(
            "renderer returned {} audio channels, expected {}",
            rendered.channels, settings.channels
        )));
    }
    let expected_samples = requested
        .checked_mul(usize::from(settings.channels))
        .ok_or(MediaError::ArithmeticOverflow("rendered audio size"))?;
    if rendered.samples.len() != expected_samples
        || rendered.samples.iter().any(|sample| !sample.is_finite())
    {
        return Err(MediaError::InvalidRequest(format!(
            "renderer returned invalid audio at sample {cursor}"
        )));
    }

    let mut input = ffmpeg::frame::Audio::new(audio.input_format, audio.frame_size, audio.layout);
    input.set_rate(settings.sample_rate);
    input.set_pts(Some(
        i64::try_from(cursor).map_err(|_| MediaError::ArithmeticOverflow("audio timestamp"))?,
    ));
    let destination = input.data_mut(0);
    let rendered_bytes = rendered
        .samples
        .len()
        .checked_mul(std::mem::size_of::<f32>())
        .ok_or(MediaError::ArithmeticOverflow("rendered audio bytes"))?;
    if rendered_bytes > destination.len() {
        return Err(MediaError::UnsupportedMedia(
            "FFmpeg allocated a short audio frame".into(),
        ));
    }
    destination.fill(0);
    for (index, sample) in rendered.samples.iter().enumerate() {
        let start = index
            .checked_mul(std::mem::size_of::<f32>())
            .ok_or(MediaError::ArithmeticOverflow("audio byte offset"))?;
        destination[start..start + std::mem::size_of::<f32>()]
            .copy_from_slice(&sample.to_ne_bytes());
    }

    let mut converted = ffmpeg::frame::Audio::empty();
    audio.resampler.run(&input, &mut converted)?;
    converted.set_pts(input.pts());
    audio.encoder.send_frame(&converted)?;
    drain_audio_packets(audio, output)?;
    let requested = u64::try_from(requested)
        .map_err(|_| MediaError::ArithmeticOverflow("audio sample cursor"))?;
    cursor
        .checked_add(requested)
        .ok_or(MediaError::ArithmeticOverflow("audio sample cursor"))
}

fn drain_video_packets(
    video: &mut VideoEncoder,
    output: &mut ffmpeg::format::context::Output,
) -> Result<()> {
    loop {
        let mut packet = ffmpeg::Packet::empty();
        match video.encoder.receive_packet(&mut packet) {
            Ok(()) => {
                packet.set_stream(video.stream_index);
                packet.rescale_ts(video.input_time_base, video.output_time_base);
                packet.write_interleaved(output)?;
            }
            Err(ffmpeg::Error::Eof)
            | Err(ffmpeg::Error::Other {
                errno: ffmpeg::util::error::EAGAIN,
            }) => return Ok(()),
            Err(error) => return Err(error.into()),
        }
    }
}

fn drain_audio_packets(
    audio: &mut AudioEncoder,
    output: &mut ffmpeg::format::context::Output,
) -> Result<()> {
    loop {
        let mut packet = ffmpeg::Packet::empty();
        match audio.encoder.receive_packet(&mut packet) {
            Ok(()) => {
                packet.set_stream(audio.stream_index);
                packet.rescale_ts(audio.input_time_base, audio.output_time_base);
                packet.write_interleaved(output)?;
            }
            Err(ffmpeg::Error::Eof)
            | Err(ffmpeg::Error::Other {
                errno: ffmpeg::util::error::EAGAIN,
            }) => return Ok(()),
            Err(error) => return Err(error.into()),
        }
    }
}

fn total_audio_samples(frames: u64, frame_rate: FrameRate, sample_rate: u32) -> Result<u64> {
    let value = ExactRational::from_integer(i128::from(frames))
        .checked_div(frame_rate.as_rational())?
        .checked_mul_integer(i128::from(sample_rate))?
        .ceil_i64()?;
    u64::try_from(value).map_err(|_| MediaError::ArithmeticOverflow("audio duration"))
}

fn audio_due_after_frame(
    frame_index: u64,
    frame_rate: FrameRate,
    sample_rate: u32,
    total: u64,
) -> Result<u64> {
    let completed_frames = frame_index
        .checked_add(1)
        .ok_or(MediaError::ArithmeticOverflow("completed video frames"))?;
    let due = ExactRational::from_integer(i128::from(completed_frames))
        .checked_div(frame_rate.as_rational())?
        .checked_mul_integer(i128::from(sample_rate))?
        .floor_i64()?;
    Ok(u64::try_from(due)
        .map_err(|_| MediaError::ArithmeticOverflow("audio interleave position"))?
        .min(total))
}

fn report_encoding_progress(
    progress: &(dyn Fn(ExportProgress) + Send + Sync),
    video_frames: u64,
    total_video_frames: u64,
    audio_samples: u64,
    total_audio_samples: u64,
) {
    let video_fraction = video_frames as f64 / total_video_frames as f64;
    let audio_fraction = if total_audio_samples == 0 {
        1.0
    } else {
        audio_samples as f64 / total_audio_samples as f64
    };
    progress(ExportProgress {
        phase: ExportPhase::Encoding,
        completed_video_frames: video_frames,
        total_video_frames,
        completed_audio_samples: audio_samples,
        total_audio_samples,
        fraction: (0.85 * video_fraction + 0.14 * audio_fraction).min(0.99) as f32,
    });
}

fn validate_export_request(request: &ExportRequest) -> Result<()> {
    request.plan.validate()?;
    if request.destination.as_os_str().is_empty()
        || request
            .destination
            .to_str()
            .is_none_or(|value| value.contains('\0'))
    {
        return Err(MediaError::InvalidRequest(
            "FFmpeg export destination must be nonempty UTF-8".into(),
        ));
    }
    let extension = request
        .destination
        .extension()
        .and_then(|extension| extension.to_str());
    if extension.is_none_or(|extension| {
        !extension.eq_ignore_ascii_case("mp4") && !extension.eq_ignore_ascii_case("mov")
    }) {
        return Err(MediaError::InvalidRequest(
            "video export destination must use .mp4 or .mov".into(),
        ));
    }
    if request.plan.width % 2 != 0 || request.plan.height % 2 != 0 {
        return Err(MediaError::InvalidRequest(
            "H.264 YUV420 export dimensions must be even".into(),
        ));
    }
    if request.plan.width > i32::MAX as u32 || request.plan.height > i32::MAX as u32 {
        return Err(MediaError::InvalidRequest(
            "export dimensions exceed FFmpeg limits".into(),
        ));
    }
    if request.plan.duration_frames > i64::MAX as u64 {
        return Err(MediaError::InvalidRequest(
            "export duration exceeds FFmpeg timestamp limits".into(),
        ));
    }
    if request.plan.frame_rate.numerator() > i32::MAX as u32
        || request.plan.frame_rate.denominator() > i32::MAX as u32
    {
        return Err(MediaError::InvalidRequest(
            "export frame rate exceeds FFmpeg limits".into(),
        ));
    }
    if request.settings.video_bit_rate == 0 || request.settings.video_bit_rate > i64::MAX as u64 {
        return Err(MediaError::InvalidRequest(
            "video bit rate is outside FFmpeg limits".into(),
        ));
    }
    if let Some(audio) = &request.settings.audio
        && (audio.sample_rate == 0
            || audio.sample_rate > i32::MAX as u32
            || audio.bit_rate == 0
            || audio.bit_rate > i64::MAX as u64
            || !matches!(audio.channels, 1 | 2))
    {
        return Err(MediaError::InvalidRequest(
            "audio export settings are outside FFmpeg limits".into(),
        ));
    }
    let parent = request
        .destination
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let metadata = std::fs::metadata(parent).at_path(parent)?;
    if !metadata.is_dir() {
        return Err(MediaError::InvalidRequest(format!(
            "export parent is not a directory: {}",
            parent.display()
        )));
    }
    Ok(())
}

fn staging_path(destination: &Path) -> Result<PathBuf> {
    let parent = destination
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    let file_name = destination
        .file_name()
        .ok_or_else(|| MediaError::InvalidRequest("export destination has no file name".into()))?;
    let mut staged_name = OsString::from(".");
    staged_name.push(file_name);
    let extension = destination
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or("mp4");
    staged_name.push(format!(".{}.partial.{extension}", Uuid::new_v4()));
    Ok(parent.join(staged_name))
}

struct StagedFile {
    path: PathBuf,
    committed: bool,
}

impl StagedFile {
    fn new(path: PathBuf) -> Self {
        Self {
            path,
            committed: false,
        }
    }
}

impl Drop for StagedFile {
    fn drop(&mut self) {
        if !self.committed {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

fn commit_staged_file(stage: &Path, destination: &Path, overwrite: bool) -> Result<()> {
    if overwrite {
        std::fs::rename(stage, destination).at_path(destination)
    } else {
        rename_noreplace(stage, destination).map_err(|source| {
            if source.kind() == std::io::ErrorKind::AlreadyExists {
                MediaError::DestinationExists(destination.to_owned())
            } else {
                MediaError::Io {
                    path: destination.to_owned(),
                    source,
                }
            }
        })
    }
}

fn rename_noreplace(source: &Path, destination: &Path) -> std::io::Result<()> {
    let source = CString::new(source.as_os_str().as_bytes())
        .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidInput))?;
    let destination = CString::new(destination.as_os_str().as_bytes())
        .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidInput))?;
    let result = unsafe {
        libc::renameat2(
            libc::AT_FDCWD,
            source.as_ptr(),
            libc::AT_FDCWD,
            destination.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    };
    if result == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

fn path_exists(path: &Path) -> Result<bool> {
    match std::fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(source) => Err(MediaError::Io {
            path: path.to_owned(),
            source,
        }),
    }
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
    use std::sync::{Condvar, Mutex};

    use super::*;

    struct EmptySource;

    impl ExportFrameSource for EmptySource {
        fn capabilities(&self) -> RendererCapabilities {
            RendererCapabilities {
                supported_effects: Default::default(),
                video_decoder_codec_ids: Default::default(),
                audio_decoder_codec_ids: Default::default(),
                display_rotations: [0].into_iter().collect(),
                max_width: 1920,
                max_height: 1080,
                supports_nested_compositions: true,
                supports_display_mirroring: false,
            }
        }

        fn render_video_frame(
            &self,
            _frame_index: u64,
            width: u32,
            height: u32,
        ) -> Result<RgbaFrame> {
            Ok(RgbaFrame {
                width,
                height,
                bytes: vec![0; width as usize * height as usize * 4],
            })
        }

        fn render_audio(
            &self,
            _start_sample: u64,
            sample_count: usize,
            _sample_rate: u32,
            channels: u16,
        ) -> Result<InterleavedAudio> {
            Ok(InterleavedAudio {
                channels,
                samples: vec![0.0; sample_count * usize::from(channels)],
            })
        }
    }

    struct GateBackend {
        started: Arc<tokio::sync::Notify>,
        gate: Arc<(Mutex<bool>, Condvar)>,
    }

    impl ExportBackend for GateBackend {
        fn export(
            &self,
            request: &ExportRequest,
            _source: &dyn ExportFrameSource,
            _cancellation: &CancellationToken,
            _progress: &(dyn Fn(ExportProgress) + Send + Sync),
        ) -> Result<ExportReceipt> {
            self.started.notify_one();
            let (lock, condition) = &*self.gate;
            let mut released = lock.lock().unwrap();
            while !*released {
                released = condition.wait(released).unwrap();
            }
            Ok(ExportReceipt {
                destination: request.destination.clone(),
                video_frames: 1,
                audio_samples: 0,
                bytes_written: 1,
            })
        }
    }

    fn empty_request(name: &str) -> ExportRequest {
        ExportRequest {
            destination: PathBuf::from(format!("/tmp/{name}.mp4")),
            overwrite: false,
            plan: CompositionPlan {
                id: name.into(),
                frame_rate: FrameRate::new(24, 1).unwrap(),
                width: 64,
                height: 64,
                duration_frames: 1,
                tracks: Vec::new(),
            },
            media: HashMap::new(),
            settings: ExportSettings {
                video_bit_rate: 100_000,
                video_encoder: None,
                audio: None,
            },
        }
    }

    #[tokio::test(flavor = "current_thread")]
    async fn queued_job_can_be_cancelled_before_it_starts() {
        let started = Arc::new(tokio::sync::Notify::new());
        let gate = Arc::new((Mutex::new(false), Condvar::new()));
        let queue = ExportQueue::new(
            2,
            1,
            Arc::new(GateBackend {
                started: Arc::clone(&started),
                gate: Arc::clone(&gate),
            }),
        )
        .unwrap();
        let first = queue
            .submit(empty_request("first"), Arc::new(EmptySource))
            .unwrap();
        started.notified().await;
        let second = queue
            .submit(empty_request("second"), Arc::new(EmptySource))
            .unwrap();

        second.cancel();
        let second_state = second.wait().await;

        assert_eq!(second_state, ExportState::Cancelled);
        let (lock, condition) = &*gate;
        *lock.lock().unwrap() = true;
        condition.notify_all();
        assert!(matches!(first.wait().await, ExportState::Completed { .. }));
    }

    #[tokio::test(flavor = "current_thread")]
    async fn exports_h264_aac_when_system_encoders_are_available() {
        if initialize_ffmpeg_blocking().is_err()
            || ffmpeg::encoder::find(ffmpeg::codec::Id::H264).is_none()
            || ffmpeg::encoder::find(ffmpeg::codec::Id::AAC).is_none()
        {
            return;
        }
        let destination =
            std::env::temp_dir().join(format!("palmier-export-{}.mp4", Uuid::new_v4()));
        let mut request = empty_request("ffmpeg-export");
        request.destination = destination.clone();
        request.plan.duration_frames = 2;
        request.settings.audio = Some(AudioExportSettings {
            sample_rate: 48_000,
            channels: 2,
            bit_rate: 128_000,
        });
        let result = tokio::task::spawn_blocking(move || {
            FfmpegExportBackend.export(&request, &EmptySource, &CancellationToken::new(), &|_| {})
        })
        .await
        .unwrap();

        let receipt = result.unwrap();
        assert!(receipt.bytes_written > 0);
        assert_eq!(receipt.video_frames, 2);
        assert!(receipt.audio_samples > 0);
        let probe = crate::probe_media(destination.clone()).await.unwrap();
        assert_eq!(probe.kind, crate::MediaKind::AudioVideo);
        let _ = std::fs::remove_file(destination);
    }
}

mod audio;
mod audio_decode;
mod cache;
mod compose;
mod decode;
mod error;
mod export;
mod ffmpeg;
mod plan;
mod probe;
mod project_render;
mod renderer;
mod time;

#[cfg(feature = "gpu-preview")]
mod wgpu_preview;

#[cfg(feature = "playback")]
pub use audio::output::PreviewAudioPlayer;
pub use audio::{MixedAudioBuffer, mix_mono_to_interleaved};
pub use audio_decode::{PcmRange, decode_pcm_range};
pub use cache::{
    AssetFingerprint, BoundedMediaCache, CacheCost, CacheInsertOutcome, CacheLimits, CacheStats,
    ThumbnailCache, ThumbnailFormat, ThumbnailKey, Waveform, WaveformCache, WaveformChannelMode,
    WaveformKey,
};
pub use compose::{
    ComposeRequest, LayerFrame, compose_frame, effects_to_layer_defaults, empty_plan_frame,
};
pub use decode::{
    DecodedFrame, DecodedFrameData, FrameOutput, PausedFrameRequest, decode_paused_frame,
    decode_paused_frame_cancellable, decode_paused_frame_sync,
};
pub use error::{MediaError, Result};
pub use export::{
    AudioExportSettings, ExportBackend, ExportFrameSource, ExportJobHandle, ExportJobId,
    ExportPhase, ExportProgress, ExportQueue, ExportReceipt, ExportRequest, ExportSettings,
    ExportState, InterleavedAudio, RgbaFrame, export_media, export_media_cancellable,
};
pub use ffmpeg::{
    CodecCapabilities, CodecCapability, CodecMediaType, discover_codec_capabilities,
    initialize_ffmpeg,
};
pub use palmier_core as core;
pub use plan::{
    ClipPlan, ClipSource, CompositionMapper, CompositionPlan, Effect, EffectKind, MediaSource,
    SourceFrameMapping, TrackKind, TrackPlan,
};
pub use probe::{AudioProbe, MediaKind, MediaProbe, VideoProbe, probe_media};
pub use project_render::{
    PreparedProjectRender, ProjectFrameSource, encode_jpeg, prepare_project_render,
    resolve_media_path,
};
pub use renderer::{
    PreflightLocation, RenderPreflightReport, RendererCapabilities, UnsupportedRenderItem,
    UnsupportedRenderReason, preflight_render,
};
pub use time::{ExactRational, FrameRange, FrameRate, MediaTime};

#[cfg(feature = "gpu-preview")]
pub use wgpu_preview::WgpuCompositor;

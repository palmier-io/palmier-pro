use std::ffi::c_void;
use std::sync::OnceLock;

use ffmpeg_next as ffmpeg;
use serde::{Deserialize, Serialize};

use crate::error::{MediaError, Result};

static FFMPEG_INIT: OnceLock<std::result::Result<(), String>> = OnceLock::new();

pub async fn initialize_ffmpeg() -> Result<()> {
    tokio::task::spawn_blocking(initialize_ffmpeg_blocking)
        .await
        .map_err(|error| MediaError::BlockingTask(error.to_string()))?
}

pub(crate) fn initialize_ffmpeg_blocking() -> Result<()> {
    FFMPEG_INIT
        .get_or_init(|| {
            ffmpeg::init().map_err(|error| error.to_string())?;
            ffmpeg::format::network::init();
            Ok(())
        })
        .clone()
        .map_err(MediaError::Initialization)
}

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CodecMediaType {
    Video,
    Audio,
    Subtitle,
    Data,
    Attachment,
    Unknown,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct CodecCapability {
    pub name: String,
    pub description: String,
    pub codec_id: String,
    pub media_type: CodecMediaType,
    pub can_encode: bool,
    pub can_decode: bool,
    pub experimental: bool,
    pub hardware: bool,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub struct CodecCapabilities {
    pub avcodec_version: u32,
    pub avformat_version: u32,
    pub avutil_version: u32,
    pub codecs: Vec<CodecCapability>,
}

impl CodecCapabilities {
    pub fn encoder(&self, name: &str) -> Option<&CodecCapability> {
        self.codecs
            .iter()
            .find(|codec| codec.can_encode && codec.name == name)
    }

    pub fn decoder(&self, name: &str) -> Option<&CodecCapability> {
        self.codecs
            .iter()
            .find(|codec| codec.can_decode && codec.name == name)
    }

    pub fn can_decode_codec_id(&self, codec_id: &str) -> bool {
        self.codecs
            .iter()
            .any(|codec| codec.can_decode && codec.codec_id == codec_id)
    }

    pub fn h264_encoders(&self) -> impl Iterator<Item = &CodecCapability> {
        self.codecs
            .iter()
            .filter(|codec| codec.can_encode && codec.codec_id == "h264")
    }

    pub fn aac_encoders(&self) -> impl Iterator<Item = &CodecCapability> {
        self.codecs
            .iter()
            .filter(|codec| codec.can_encode && codec.codec_id == "aac")
    }
}

pub async fn discover_codec_capabilities() -> Result<CodecCapabilities> {
    tokio::task::spawn_blocking(discover_codec_capabilities_blocking)
        .await
        .map_err(|error| MediaError::BlockingTask(error.to_string()))?
}

pub(crate) fn discover_codec_capabilities_blocking() -> Result<CodecCapabilities> {
    initialize_ffmpeg_blocking()?;

    let mut codecs = Vec::new();
    let mut opaque: *mut c_void = std::ptr::null_mut();
    loop {
        let pointer = unsafe { ffmpeg::ffi::av_codec_iterate(&mut opaque) };
        if pointer.is_null() {
            break;
        }
        let codec = unsafe { ffmpeg::Codec::wrap(pointer) };
        let capabilities = codec.capabilities();
        let name = codec.name().to_owned();
        codecs.push(CodecCapability {
            description: codec.description().to_owned(),
            codec_id: format!("{:?}", codec.id()).to_ascii_lowercase(),
            media_type: media_type(codec.medium()),
            can_encode: codec.is_encoder(),
            can_decode: codec.is_decoder(),
            experimental: capabilities
                .contains(ffmpeg::codec::capabilities::Capabilities::EXPERIMENTAL),
            hardware: is_hardware_codec(&name),
            name,
        });
    }

    codecs.sort_by(|left, right| {
        left.name
            .cmp(&right.name)
            .then_with(|| left.can_encode.cmp(&right.can_encode))
            .then_with(|| left.can_decode.cmp(&right.can_decode))
    });

    Ok(CodecCapabilities {
        avcodec_version: ffmpeg::codec::version(),
        avformat_version: ffmpeg::format::version(),
        avutil_version: ffmpeg::util::version(),
        codecs,
    })
}

fn media_type(value: ffmpeg::media::Type) -> CodecMediaType {
    match value {
        ffmpeg::media::Type::Video => CodecMediaType::Video,
        ffmpeg::media::Type::Audio => CodecMediaType::Audio,
        ffmpeg::media::Type::Subtitle => CodecMediaType::Subtitle,
        ffmpeg::media::Type::Data => CodecMediaType::Data,
        ffmpeg::media::Type::Attachment => CodecMediaType::Attachment,
        _ => CodecMediaType::Unknown,
    }
}

fn is_hardware_codec(name: &str) -> bool {
    [
        "_nvenc",
        "_vaapi",
        "_qsv",
        "_v4l2m2m",
        "_videotoolbox",
        "_amf",
        "_mediacodec",
        "_cuda",
    ]
    .iter()
    .any(|suffix| name.contains(suffix))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capability_lookup_distinguishes_encoder_and_decoder() {
        let capabilities = CodecCapabilities {
            avcodec_version: 0,
            avformat_version: 0,
            avutil_version: 0,
            codecs: vec![
                CodecCapability {
                    name: "decoder".into(),
                    description: String::new(),
                    codec_id: "h264".into(),
                    media_type: CodecMediaType::Video,
                    can_encode: false,
                    can_decode: true,
                    experimental: false,
                    hardware: false,
                },
                CodecCapability {
                    name: "encoder".into(),
                    description: String::new(),
                    codec_id: "h264".into(),
                    media_type: CodecMediaType::Video,
                    can_encode: true,
                    can_decode: false,
                    experimental: false,
                    hardware: false,
                },
            ],
        };

        assert!(capabilities.can_decode_codec_id("h264"));
        assert_eq!(capabilities.h264_encoders().count(), 1);
        assert!(capabilities.decoder("encoder").is_none());
    }

    #[test]
    fn discovers_registered_codecs_when_ffmpeg_is_available() {
        if initialize_ffmpeg_blocking().is_err() {
            return;
        }

        let capabilities = discover_codec_capabilities_blocking().unwrap();

        assert!(!capabilities.codecs.is_empty());
    }
}

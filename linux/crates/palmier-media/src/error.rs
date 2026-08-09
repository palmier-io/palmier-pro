use std::path::PathBuf;

#[derive(Debug, thiserror::Error)]
pub enum MediaError {
    #[error("FFmpeg initialization failed: {0}")]
    Initialization(String),
    #[error("FFmpeg operation failed: {0}")]
    Ffmpeg(#[from] ffmpeg_next::Error),
    #[error("blocking media task failed: {0}")]
    BlockingTask(String),
    #[error("invalid media request: {0}")]
    InvalidRequest(String),
    #[error("invalid composition plan: {0}")]
    InvalidPlan(String),
    #[error("arithmetic overflow while calculating {0}")]
    ArithmeticOverflow(&'static str),
    #[error("media has no {0} stream")]
    StreamNotFound(&'static str),
    #[error("unsupported media: {0}")]
    UnsupportedMedia(String),
    #[error("no frame is available at the requested time")]
    FrameNotFound,
    #[error("renderer preflight failed with {0} unsupported item(s)")]
    UnsupportedRender(usize),
    #[error("required codec is unavailable: {0}")]
    CodecUnavailable(String),
    #[error("export queue is full")]
    QueueFull,
    #[error("export was cancelled")]
    Cancelled,
    #[error("destination already exists: {0:?}")]
    DestinationExists(PathBuf),
    #[error("I/O failed for {path:?}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
}

pub type Result<T> = std::result::Result<T, MediaError>;

pub(crate) trait IoResultExt<T> {
    fn at_path(self, path: impl Into<PathBuf>) -> Result<T>;
}

impl<T> IoResultExt<T> for std::io::Result<T> {
    fn at_path(self, path: impl Into<PathBuf>) -> Result<T> {
        self.map_err(|source| MediaError::Io {
            path: path.into(),
            source,
        })
    }
}

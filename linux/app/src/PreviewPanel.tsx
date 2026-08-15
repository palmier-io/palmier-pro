import {
  Camera,
  ChevronLeft,
  ChevronRight,
  Pause,
  Play,
  RotateCcw,
  SkipBack,
  SkipForward,
  ZoomIn,
} from 'lucide-react'
import { useEffect, useRef, useState, type CSSProperties } from 'react'
import {
  findAsset,
  projectDurationFrames,
  selectedClipForState,
  useEditor,
} from './editorState'
import { UserText, useI18n } from './i18n'
import type { MediaAsset, TimelineClip } from './model'
import {
  decodePreviewAudio,
  playAudioBuffer,
  resumeAudioContext,
  stopAudioSource,
} from './previewAudio'
import { errorMessage } from './errors'
import { previewFrameObjectUrl } from './previewFrame'
import { IconButton, Panel, Spinner, formatTimecode } from './ui'

type CanvasStyle = CSSProperties & {
  '--canvas-scale': string
  '--canvas-opacity': string
  '--canvas-x': string
  '--canvas-y': string
  '--canvas-rotation': string
}

function currentTimelineClip(
  frame: number,
  clips: TimelineClip[],
): TimelineClip | null {
  const visible = clips.filter(
    (clip) =>
      clip.kind !== 'audio' &&
      frame >= clip.startFrame &&
      frame < clip.startFrame + clip.durationFrames,
  )
  return visible.at(-1) ?? null
}

function PreviewCanvas({
  asset,
  clip,
}: {
  asset: MediaAsset | null
  clip: TimelineClip | null
}) {
  const { state, relinkAsset, backend } = useEditor()
  const { t } = useI18n()
  const project = state.project
  const status = asset?.status
  const transform = clip?.transform
  const [renderedFrame, setRenderedFrame] = useState<string | null>(null)
  const [previewError, setPreviewError] = useState<string | null>(null)
  const urlRef = useRef<string | null>(null)
  const inflightRef = useRef(false)
  const latestRef = useRef<{
    frame: number
    sourceAssetId: string | null
    playing: boolean
  } | null>(null)

  useEffect(() => {
    if (backend.kind !== 'tauri' || !project) {
      if (urlRef.current) {
        URL.revokeObjectURL(urlRef.current)
        urlRef.current = null
      }
      setRenderedFrame(null)
      setPreviewError(null)
      return
    }
    if (state.previewAssetId && asset?.kind === 'audio') {
      setPreviewError(null)
      return
    }

    latestRef.current = {
      frame: state.activeFrame,
      sourceAssetId: state.previewAssetId,
      playing: state.isPlaying,
    }

    const pump = () => {
      const pending = latestRef.current
      if (!pending || inflightRef.current) return
      inflightRef.current = true
      latestRef.current = null
      const maxWidth = pending.playing ? 640 : 1280
      const maxHeight = pending.playing ? 360 : 720
      const request = pending.sourceAssetId
        ? backend.decodeAssetPreview?.(
            project.id,
            pending.sourceAssetId,
            pending.frame / Math.max(1, project.fps),
            maxWidth,
            maxHeight,
          )
        : backend.renderPreviewFrame(
            project.id,
            pending.frame,
            maxWidth,
            maxHeight,
          )
      if (!request) {
        inflightRef.current = false
        return
      }
      void request
        .then((frame) => {
          inflightRef.current = false
          const url = frame ? previewFrameObjectUrl(frame) : null
          if (url) {
            if (urlRef.current) URL.revokeObjectURL(urlRef.current)
            urlRef.current = url
            setPreviewError(null)
            setRenderedFrame(url)
          } else if (!latestRef.current) {
            setPreviewError(frame ? 'Preview frame is not an image' : null)
          }
          pump()
        })
        .catch((error: unknown) => {
          inflightRef.current = false
          if (!latestRef.current) {
            setPreviewError(errorMessage(error))
          }
          pump()
        })
    }

    pump()
  }, [
    asset?.kind,
    backend,
    project,
    state.activeFrame,
    state.isPlaying,
    state.previewAssetId,
  ])

  useEffect(() => {
    return () => {
      if (urlRef.current) URL.revokeObjectURL(urlRef.current)
    }
  }, [])

  const style = {
    '--canvas-scale': String(state.canvasZoom),
    '--canvas-opacity': String(
      renderedFrame ? 1 : (transform?.opacity ?? 100) / 100,
    ),
    '--canvas-x': `${renderedFrame ? 0 : (transform?.positionX ?? 0)}%`,
    '--canvas-y': `${renderedFrame ? 0 : (transform?.positionY ?? 0)}%`,
    '--canvas-rotation': `${renderedFrame ? 0 : (transform?.rotation ?? 0)}deg`,
  } as CanvasStyle

  return (
    <div className="preview-stage">
      <div
        className={`preview-frame media-accent-${asset?.accent ?? 'moss'}`}
        style={style}
      >
        {renderedFrame ? (
          <img
            className="preview-rendered-frame"
            src={renderedFrame}
            alt=""
            onError={() => {
              setRenderedFrame(null)
              setPreviewError('Preview image could not be displayed')
            }}
          />
        ) : (
          <div className="preview-art" aria-hidden="true">
            <span className="preview-art-orbit" />
            <span className="preview-art-grain" />
          </div>
        )}
        {asset?.kind === 'audio' ? (
          <div className="preview-audio">
            <div className="preview-audio-icon">
              <Play aria-hidden="true" />
            </div>
            <UserText>{asset.name}</UserText>
            <div className="large-waveform" aria-hidden="true">
              {Array.from({ length: 42 }, (_, index) => (
                <i key={index} />
              ))}
            </div>
          </div>
        ) : !renderedFrame && !previewError ? (
          <div className="preview-title-overlay">
            <strong>palmier<span>.</span></strong>
            <small>{t('previewTagline')}</small>
          </div>
        ) : null}
        {previewError ? (
          <div className="preview-state-overlay is-error">
            <RotateCcw aria-hidden="true" />
            <strong>{t('failed')}</strong>
            <p>{previewError}</p>
          </div>
        ) : null}
        <div className="preview-safe-area" aria-hidden="true" />
        <span className="preview-project-label">
          <UserText>{project?.name ?? t('appName')}</UserText>
        </span>

        {status?.kind === 'generating' || status?.kind === 'importing' ? (
          <div className="preview-state-overlay">
            <Spinner />
            <strong>
              {status.kind === 'generating'
                ? status.label
                : t('importingMedia')}
            </strong>
            <span>{Math.round(status.progress * 100)}%</span>
          </div>
        ) : null}

        {status?.kind === 'offline' && asset ? (
          <div className="preview-state-overlay is-error">
            <RotateCcw aria-hidden="true" />
            <strong>{t('sourceOffline')}</strong>
            <p>{t('sourceOfflineDetail')}</p>
            <button
              type="button"
              className="button-primary"
              onClick={() => relinkAsset(asset.id)}
            >
              {t('relink')}
            </button>
          </div>
        ) : null}

        {status?.kind === 'failed' ? (
          <div className="preview-state-overlay is-error">
            <RotateCcw aria-hidden="true" />
            <strong>{t('failed')}</strong>
            <p>{status.message}</p>
          </div>
        ) : null}
      </div>
    </div>
  )
}

function usePreviewAudio(duration: number) {
  const { state, backend } = useEditor()
  const sourceRef = useRef<AudioBufferSourceNode | null>(null)
  const playheadRef = useRef(state.activeFrame)
  playheadRef.current = state.activeFrame

  useEffect(() => {
    if (!state.isPlaying || !state.project || backend.kind !== 'tauri') {
      stopAudioSource(sourceRef.current)
      sourceRef.current = null
      return
    }

    let cancelled = false
    const project = state.project
    const fps = Math.max(1, project.fps)
    const previewAssetId = state.previewAssetId
    let nextFrame = playheadRef.current

    const stopSource = () => {
      stopAudioSource(sourceRef.current)
      sourceRef.current = null
    }

    const playChunk = async () => {
      await resumeAudioContext()
      while (!cancelled) {
        if (nextFrame >= duration) {
          nextFrame = 0
        }
        const frameCount = Math.min(
          Math.max(1, Math.round(fps / 2)),
          Math.max(1, duration - nextFrame),
        )
        const request = previewAssetId
          ? backend.decodeAssetAudio?.(
              project.id,
              previewAssetId,
              nextFrame / fps,
              frameCount / fps,
            )
          : backend.renderPreviewAudio?.(project.id, nextFrame, frameCount)
        const payload = await request
        if (cancelled || !payload?.samplesBase64) return
        const buffer = decodePreviewAudio(payload)
        if (!buffer || cancelled) return
        stopSource()
        sourceRef.current = playAudioBuffer(buffer)
        nextFrame += frameCount
        await new Promise((resolve) => {
          window.setTimeout(resolve, (frameCount / fps) * 1000)
        })
      }
    }

    void playChunk().catch(() => undefined)
    return () => {
      cancelled = true
      stopSource()
    }
  }, [backend, duration, state.isPlaying, state.previewAssetId, state.project])
}

export function PreviewPanel() {
  const { state, dispatch, captureFrame } = useEditor()
  const { t } = useI18n()
  const project = state.project
  const sourceAsset = state.previewAssetId
    ? findAsset(project, state.previewAssetId)
    : null
  const duration = sourceAsset
    ? Math.max(1, sourceAsset.durationFrames)
    : projectDurationFrames(project)
  usePreviewAudio(duration)
  const timelineClip = currentTimelineClip(
    state.activeFrame,
    project?.tracks.flatMap((track) => track.clips) ?? [],
  )
  const selectedClip = selectedClipForState(state)
  const displayedClip = sourceAsset ? null : timelineClip ?? selectedClip
  const displayedAsset =
    sourceAsset ??
    (displayedClip ? findAsset(project, displayedClip.assetId) : null)

  const header = (
    <div className="preview-tabs">
      <div className="preview-nav">
        <IconButton
          compact
          icon={ChevronLeft}
          label={t('back')}
          disabled={!sourceAsset}
          onClick={() =>
            dispatch({ type: 'SET_PREVIEW_ASSET', assetId: null })
          }
        />
        <IconButton
          compact
          icon={ChevronRight}
          label={t('forward')}
          disabled
        />
      </div>
      <button
        type="button"
        className={!sourceAsset ? 'is-active' : ''}
        onClick={() =>
          dispatch({ type: 'SET_PREVIEW_ASSET', assetId: null })
        }
      >
        {t('timeline')}
      </button>
      {sourceAsset ? (
        <button type="button" className="is-active">
          <UserText>{sourceAsset.name}</UserText>
        </button>
      ) : null}
    </div>
  )

  return (
    <Panel id="preview" title={t('preview')} header={header}>
      <div className="preview-panel-body">
        <PreviewCanvas asset={displayedAsset} clip={displayedClip} />

        <div className="preview-scrubber">
          <input
            type="range"
            min={0}
            max={Math.max(1, duration)}
            value={state.activeFrame}
            onChange={(event) =>
              dispatch({
                type: 'SET_ACTIVE_FRAME',
                frame: Number(event.target.value),
              })
            }
            aria-label={t('timelinePlayhead')}
          />
        </div>

        <div className="preview-transport">
          <span className="timecode">
            <strong>
              {formatTimecode(state.activeFrame, project?.fps ?? 30)}
            </strong>
            <span>/</span>
            <span>{formatTimecode(duration, project?.fps ?? 30)}</span>
          </span>
          <div className="transport-buttons">
            <IconButton
              icon={SkipBack}
              label={t('goToStart')}
              onClick={() => dispatch({ type: 'SET_ACTIVE_FRAME', frame: 0 })}
            />
            <IconButton
              icon={ChevronLeft}
              label={t('previousFrame')}
              onClick={() =>
                dispatch({
                  type: 'SET_ACTIVE_FRAME',
                  frame: state.activeFrame - 1,
                })
              }
            />
            <button
              type="button"
              className="play-button"
              aria-label={state.isPlaying ? t('pause') : t('play')}
              onClick={() => {
                if (!state.isPlaying) {
                  void resumeAudioContext()
                }
                dispatch({ type: 'TOGGLE_PLAYBACK' })
              }}
            >
              {state.isPlaying ? (
                <Pause aria-hidden="true" />
              ) : (
                <Play aria-hidden="true" />
              )}
            </button>
            <IconButton
              icon={ChevronRight}
              label={t('nextFrame')}
              onClick={() =>
                dispatch({
                  type: 'SET_ACTIVE_FRAME',
                  frame: state.activeFrame + 1,
                })
              }
            />
            <IconButton
              icon={SkipForward}
              label={t('goToEnd')}
              onClick={() =>
                dispatch({ type: 'SET_ACTIVE_FRAME', frame: duration })
              }
            />
          </div>
          <div className="preview-options">
            <IconButton
              icon={Camera}
              label={t('captureFrame')}
              disabled={sourceAsset?.kind === 'audio'}
              onClick={() => {
                void captureFrame()
              }}
            />
            <label className="zoom-select">
              <ZoomIn aria-hidden="true" />
              <select
                value={state.canvasZoom}
                onChange={(event) =>
                  dispatch({
                    type: 'SET_CANVAS_ZOOM',
                    zoom: Number(event.target.value),
                  })
                }
                aria-label={t('zoom')}
              >
                <option value={0.5}>50%</option>
                <option value={0.75}>75%</option>
                <option value={1}>{t('fit')}</option>
                <option value={1.25}>125%</option>
                <option value={1.5}>150%</option>
              </select>
            </label>
          </div>
        </div>
      </div>
    </Panel>
  )
}

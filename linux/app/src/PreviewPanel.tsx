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
import { useEffect, useState, type CSSProperties } from 'react'
import {
  findAsset,
  projectDurationFrames,
  selectedClipForState,
  useEditor,
} from './editorState'
import { UserText, useI18n } from './i18n'
import type { MediaAsset, TimelineClip } from './model'
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
  useEffect(() => {
    if (
      backend.kind !== 'tauri' ||
      !project ||
      state.previewAssetId
    ) {
      setRenderedFrame(null)
      return
    }
    let active = true
    const timer = window.setTimeout(() => {
      void backend
        .renderPreviewFrame(project.id, state.activeFrame, 1280, 720)
        .then((frame) => {
          if (!active) return
          setRenderedFrame(
            frame
              ? `data:${frame.mimeType};base64,${frame.dataBase64}`
              : null,
          )
        })
        .catch(() => {
          if (active) setRenderedFrame(null)
        })
    }, 50)
    return () => {
      active = false
      window.clearTimeout(timer)
    }
  }, [
    backend,
    project,
    state.activeFrame,
    state.previewAssetId,
  ])

  const style = {
    '--canvas-scale': String(
      renderedFrame
        ? state.canvasZoom
        : ((transform?.scale ?? 100) / 100) * state.canvasZoom,
    ),
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
        ) : !renderedFrame ? (
          <div className="preview-title-overlay">
            <strong>palmier<span>.</span></strong>
            <small>{t('previewTagline')}</small>
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

export function PreviewPanel() {
  const { state, dispatch } = useEditor()
  const { t } = useI18n()
  const project = state.project
  const duration = projectDurationFrames(project)
  const timelineClip = currentTimelineClip(
    state.activeFrame,
    project?.tracks.flatMap((track) => track.clips) ?? [],
  )
  const selectedClip = selectedClipForState(state)
  const sourceAsset = state.previewAssetId
    ? findAsset(project, state.previewAssetId)
    : null
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
              onClick={() => dispatch({ type: 'TOGGLE_PLAYBACK' })}
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
            <IconButton icon={Camera} label={t('captureFrame')} />
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

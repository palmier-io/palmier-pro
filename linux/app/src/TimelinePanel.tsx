import {
  Eye,
  EyeOff,
  Lock,
  LockOpen,
  MousePointer2,
  Redo2,
  Scissors,
  SplitSquareHorizontal,
  Trash2,
  Undo2,
  Volume2,
  VolumeX,
  ZoomIn,
  ZoomOut,
} from 'lucide-react'
import {
  useRef,
  useState,
  type CSSProperties,
  type DragEvent,
  type KeyboardEvent,
  type PointerEvent,
} from 'react'
import {
  findAsset,
  projectDurationFrames,
  useEditor,
} from './editorState'
import { UserText, useI18n } from './i18n'
import type { TimelineClip, TimelineTrack } from './model'
import { IconButton, Panel, formatTimecode } from './ui'

type TimelineContentStyle = CSSProperties & {
  '--timeline-content-width': string
}

type PositionedStyle = CSSProperties & {
  '--timeline-left': string
  '--timeline-width'?: string
}

interface DragSession {
  mode: 'move' | 'trim-start' | 'trim-end'
  pointerId: number
  originX: number
  laneWidth: number
  startFrame: number
  durationFrames: number
  trackId: string
}

function ToolbarDivider() {
  return <span className="toolbar-divider" aria-hidden="true" />
}

function TimelineToolbar() {
  const { state, dispatch, canUndo, canRedo } = useEditor()
  const { t } = useI18n()
  const hasSelection = state.selectedClipIds.length > 0

  return (
    <div className="timeline-toolbar">
      <div className="toolbar-group">
        <IconButton
          icon={Undo2}
          label={t('undo')}
          disabled={!canUndo}
          onClick={() => dispatch({ type: 'UNDO' })}
        />
        <IconButton
          icon={Redo2}
          label={t('redo')}
          disabled={!canRedo}
          onClick={() => dispatch({ type: 'REDO' })}
        />
      </div>
      <ToolbarDivider />
      <div className="toolbar-group">
        <IconButton
          icon={MousePointer2}
          label={t('pointer')}
          active={state.toolMode === 'pointer'}
          onClick={() => dispatch({ type: 'SET_TOOL_MODE', mode: 'pointer' })}
        />
        <IconButton
          icon={Scissors}
          label={t('razor')}
          active={state.toolMode === 'razor'}
          onClick={() => dispatch({ type: 'SET_TOOL_MODE', mode: 'razor' })}
        />
        <IconButton
          icon={SplitSquareHorizontal}
          label={t('trim')}
          active={state.toolMode === 'trim'}
          onClick={() => dispatch({ type: 'SET_TOOL_MODE', mode: 'trim' })}
        />
      </div>
      <ToolbarDivider />
      <div className="toolbar-group">
        <IconButton
          icon={SplitSquareHorizontal}
          label={t('splitAtPlayhead')}
          disabled={!hasSelection}
          onClick={() => dispatch({ type: 'SPLIT_AT_PLAYHEAD' })}
        />
        <IconButton
          icon={Trash2}
          label={t('deleteSelection')}
          disabled={!hasSelection}
          onClick={() => dispatch({ type: 'DELETE_SELECTION' })}
        />
      </div>
      <div className="toolbar-spacer" />
      <div className="timeline-zoom">
        <IconButton
          compact
          icon={ZoomOut}
          label={t('zoomOut')}
          disabled={state.timelineZoom <= 0.5}
          onClick={() =>
            dispatch({
              type: 'SET_TIMELINE_ZOOM',
              zoom: state.timelineZoom / 1.25,
            })
          }
        />
        <input
          type="range"
          min={0.5}
          max={4}
          step={0.1}
          value={state.timelineZoom}
          onChange={(event) =>
            dispatch({
              type: 'SET_TIMELINE_ZOOM',
              zoom: Number(event.target.value),
            })
          }
          aria-label={t('zoom')}
        />
        <IconButton
          compact
          icon={ZoomIn}
          label={t('zoomIn')}
          disabled={state.timelineZoom >= 4}
          onClick={() =>
            dispatch({
              type: 'SET_TIMELINE_ZOOM',
              zoom: state.timelineZoom * 1.25,
            })
          }
        />
      </div>
    </div>
  )
}

function TrackHeader({ track }: { track: TimelineTrack }) {
  const { dispatch } = useEditor()
  const { t } = useI18n()
  return (
    <div className="track-header">
      <strong>{track.name}</strong>
      <div className="track-controls">
        <IconButton
          compact
          icon={track.hidden ? EyeOff : Eye}
          label={track.hidden ? t('showTrack') : t('hideTrack')}
          active={!track.hidden}
          onClick={() =>
            dispatch({
              type: 'TOGGLE_TRACK_SETTING',
              trackId: track.id,
              setting: 'hidden',
            })
          }
        />
        <IconButton
          compact
          icon={track.muted ? VolumeX : Volume2}
          label={track.muted ? t('unmuteTrack') : t('muteTrack')}
          active={!track.muted}
          onClick={() =>
            dispatch({
              type: 'TOGGLE_TRACK_SETTING',
              trackId: track.id,
              setting: 'muted',
            })
          }
        />
        <IconButton
          compact
          icon={track.locked ? Lock : LockOpen}
          label={track.locked ? t('unlockTrack') : t('lockTrack')}
          active={track.locked}
          onClick={() =>
            dispatch({
              type: 'TOGGLE_TRACK_SETTING',
              trackId: track.id,
              setting: 'locked',
            })
          }
        />
      </div>
    </div>
  )
}

function TimelineClipView({
  clip,
  track,
  duration,
}: {
  clip: TimelineClip
  track: TimelineTrack
  duration: number
}) {
  const { state, dispatch } = useEditor()
  const { t } = useI18n()
  const [preview, setPreview] = useState<{
    startFrame: number
    durationFrames: number
    trackId: string
  } | null>(null)
  const drag = useRef<DragSession | null>(null)
  const asset = findAsset(state.project, clip.assetId)
  const selected = state.selectedClipIds.includes(clip.id)
  const displayStart = preview?.startFrame ?? clip.startFrame
  const displayDuration = preview?.durationFrames ?? clip.durationFrames
  const left = `${(displayStart / duration) * 100}%`
  const width = `${(displayDuration / duration) * 100}%`

  const beginDrag = (
    event: PointerEvent<HTMLElement>,
    mode: DragSession['mode'],
  ) => {
    if (track.locked) return
    event.preventDefault()
    event.stopPropagation()
    const lane = event.currentTarget.closest('.timeline-lane')
    const laneWidth = lane?.getBoundingClientRect().width ?? 1
    drag.current = {
      mode,
      pointerId: event.pointerId,
      originX: event.clientX,
      laneWidth,
      startFrame: clip.startFrame,
      durationFrames: clip.durationFrames,
      trackId: track.id,
    }
    event.currentTarget.setPointerCapture(event.pointerId)
    dispatch({
      type: 'SELECT_CLIP',
      clipId: clip.id,
      additive: event.metaKey || event.ctrlKey || event.shiftKey,
    })
  }

  const moveDrag = (event: PointerEvent<HTMLElement>) => {
    const session = drag.current
    if (!session || session.pointerId !== event.pointerId) return
    const delta = Math.round(
      ((event.clientX - session.originX) / session.laneWidth) * duration,
    )
    if (session.mode === 'move') {
      const hovered = document
        .elementFromPoint(event.clientX, event.clientY)
        ?.closest<HTMLElement>('[data-track-id]')
      setPreview({
        startFrame: Math.max(0, session.startFrame + delta),
        durationFrames: session.durationFrames,
        trackId: hovered?.dataset.trackId ?? session.trackId,
      })
    } else if (session.mode === 'trim-start') {
      const applied = Math.max(
        -session.startFrame,
        Math.min(session.durationFrames - 3, delta),
      )
      setPreview({
        startFrame: session.startFrame + applied,
        durationFrames: session.durationFrames - applied,
        trackId: session.trackId,
      })
    } else {
      setPreview({
        startFrame: session.startFrame,
        durationFrames: Math.max(3, session.durationFrames + delta),
        trackId: session.trackId,
      })
    }
  }

  const finishDrag = (event: PointerEvent<HTMLElement>) => {
    const session = drag.current
    if (!session || session.pointerId !== event.pointerId) return
    event.currentTarget.releasePointerCapture(event.pointerId)
    if (preview) {
      if (session.mode === 'move') {
        dispatch({
          type: 'MOVE_CLIP',
          clipId: clip.id,
          trackId: preview.trackId,
          startFrame: preview.startFrame,
        })
      } else {
        dispatch({
          type: 'TRIM_CLIP',
          clipId: clip.id,
          edge: session.mode === 'trim-start' ? 'start' : 'end',
          delta:
            session.mode === 'trim-start'
              ? preview.startFrame - session.startFrame
              : preview.durationFrames - session.durationFrames,
        })
      }
    }
    drag.current = null
    setPreview(null)
  }

  const selectFromKeyboard = (event: KeyboardEvent<HTMLDivElement>) => {
    if (
      event.altKey &&
      (event.key === 'ArrowLeft' || event.key === 'ArrowRight')
    ) {
      event.preventDefault()
      dispatch({
        type: 'MOVE_CLIP',
        clipId: clip.id,
        trackId: clip.trackId,
        startFrame:
          clip.startFrame + (event.key === 'ArrowLeft' ? -1 : 1),
      })
      return
    }
    if (event.key !== 'Enter' && event.key !== ' ') return
    event.preventDefault()
    dispatch({
      type: 'SELECT_CLIP',
      clipId: clip.id,
      additive: event.metaKey || event.ctrlKey || event.shiftKey,
    })
  }

  return (
    <div
      role="button"
      tabIndex={0}
      className={`timeline-clip clip-${clip.kind}${
        selected ? ' is-selected' : ''
      }${asset?.status.kind === 'offline' ? ' is-offline' : ''}${
        preview ? ' is-dragging' : ''
      }`}
      style={
        {
          '--timeline-left': left,
          '--timeline-width': width,
        } as PositionedStyle
      }
      aria-label={clip.name}
      aria-pressed={selected}
      onPointerDown={(event) => {
        if (state.toolMode === 'razor') {
          event.stopPropagation()
          const rect = event.currentTarget.getBoundingClientRect()
          const fraction = Math.max(
            0,
            Math.min(1, (event.clientX - rect.left) / rect.width),
          )
          const frame =
            clip.startFrame + Math.round(clip.durationFrames * fraction)
          dispatch({
            type: 'SELECT_CLIP',
            clipId: clip.id,
            additive: false,
          })
          dispatch({ type: 'SET_ACTIVE_FRAME', frame })
          window.setTimeout(
            () => dispatch({ type: 'SPLIT_AT_PLAYHEAD' }),
            0,
          )
          return
        }
        beginDrag(event, 'move')
      }}
      onPointerMove={moveDrag}
      onPointerUp={finishDrag}
      onPointerCancel={() => {
        drag.current = null
        setPreview(null)
      }}
      onKeyDown={selectFromKeyboard}
      onDoubleClick={() =>
        dispatch({ type: 'SET_PREVIEW_ASSET', assetId: clip.assetId })
      }
      title={`${clip.name} · ${formatTimecode(
        clip.durationFrames,
        state.project?.fps ?? 30,
      )}`}
    >
      <button
        type="button"
        className="trim-handle trim-handle-start"
        aria-label={`${t('trim')} ${t('start')}`}
        onPointerDown={(event) => beginDrag(event, 'trim-start')}
        onPointerMove={moveDrag}
        onPointerUp={finishDrag}
        onKeyDown={(event) => {
          if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return
          event.preventDefault()
          event.stopPropagation()
          dispatch({
            type: 'TRIM_CLIP',
            clipId: clip.id,
            edge: 'start',
            delta: event.key === 'ArrowLeft' ? -1 : 1,
          })
        }}
      />
      <span className="clip-visual" aria-hidden="true">
        {clip.kind === 'audio' ? (
          <span className="clip-waveform">
            {Array.from({ length: 26 }, (_, index) => (
              <i key={index} />
            ))}
          </span>
        ) : (
          <span
            className={`clip-filmstrip media-accent-${
              asset?.accent ?? 'slate'
            }`}
          >
            {Array.from({ length: 5 }, (_, index) => (
              <i key={index} />
            ))}
          </span>
        )}
      </span>
      <span className="clip-label">
        <UserText>{clip.name}</UserText>
      </span>
      {asset?.status.kind === 'offline' ? (
        <span className="clip-offline-label">{t('offline')}</span>
      ) : null}
      <button
        type="button"
        className="trim-handle trim-handle-end"
        aria-label={`${t('trim')} ${t('end')}`}
        onPointerDown={(event) => beginDrag(event, 'trim-end')}
        onPointerMove={moveDrag}
        onPointerUp={finishDrag}
        onKeyDown={(event) => {
          if (event.key !== 'ArrowLeft' && event.key !== 'ArrowRight') return
          event.preventDefault()
          event.stopPropagation()
          dispatch({
            type: 'TRIM_CLIP',
            clipId: clip.id,
            edge: 'end',
            delta: event.key === 'ArrowLeft' ? -1 : 1,
          })
        }}
      />
    </div>
  )
}

function Ruler({
  duration,
  fps,
}: {
  duration: number
  fps: number
}) {
  const { state, dispatch } = useEditor()
  const { t } = useI18n()
  const ticks = Array.from({ length: 13 }, (_, index) => {
    const frame = Math.round((duration / 12) * index)
    return { frame, left: `${(frame / duration) * 100}%` }
  })
  const playheadLeft = `${(state.activeFrame / duration) * 100}%`

  return (
    <div className="timeline-ruler-row">
      <div className="timeline-corner">
        <span>{formatTimecode(state.activeFrame, fps)}</span>
      </div>
      <div
        className="timeline-ruler"
        onPointerDown={(event) => {
          const rect = event.currentTarget.getBoundingClientRect()
          const frame =
            ((event.clientX - rect.left) / rect.width) * duration
          dispatch({ type: 'SET_ACTIVE_FRAME', frame })
        }}
        aria-label={t('timelineRuler')}
      >
        {ticks.map((tick) => (
          <span
            className="ruler-tick"
            key={tick.frame}
            style={{ '--timeline-left': tick.left } as PositionedStyle}
          >
            <i aria-hidden="true" />
            <small>{formatTimecode(tick.frame, fps).slice(3, 8)}</small>
          </span>
        ))}
        <span
          className="playhead-head"
          style={{ '--timeline-left': playheadLeft } as PositionedStyle}
          aria-hidden="true"
        />
      </div>
    </div>
  )
}

function TrackRow({
  track,
  duration,
}: {
  track: TimelineTrack
  duration: number
}) {
  const { state, dispatch } = useEditor()
  const playheadLeft = `${(state.activeFrame / duration) * 100}%`

  const seek = (event: PointerEvent<HTMLDivElement>) => {
    if ((event.target as HTMLElement).closest('.timeline-clip')) return
    const rect = event.currentTarget.getBoundingClientRect()
    dispatch({
      type: 'SET_ACTIVE_FRAME',
      frame: ((event.clientX - rect.left) / rect.width) * duration,
    })
    dispatch({ type: 'CLEAR_SELECTION' })
  }

  const dropAsset = (event: DragEvent<HTMLDivElement>) => {
    const assetId = event.dataTransfer.getData(
      'application/x-palmier-asset',
    )
    if (!assetId) return
    event.preventDefault()
    const rect = event.currentTarget.getBoundingClientRect()
    const frame =
      ((event.clientX - rect.left) / rect.width) * duration
    dispatch({ type: 'PLACE_ASSET', assetId, trackId: track.id, frame })
  }

  return (
    <div
      className={`timeline-track track-${track.kind}${
        track.hidden ? ' is-hidden' : ''
      }${track.locked ? ' is-locked' : ''}`}
    >
      <TrackHeader track={track} />
      <div
        className="timeline-lane"
        data-track-id={track.id}
        onPointerDown={seek}
        onDragOver={(event) => {
          if (
            event.dataTransfer.types.includes(
              'application/x-palmier-asset',
            )
          ) {
            event.preventDefault()
            event.dataTransfer.dropEffect = 'copy'
          }
        }}
        onDrop={dropAsset}
      >
        <span className="lane-grid" aria-hidden="true" />
        {track.clips.map((clip) => (
          <TimelineClipView
            key={clip.id}
            clip={clip}
            track={track}
            duration={duration}
          />
        ))}
        <span
          className="track-playhead"
          style={{ '--timeline-left': playheadLeft } as PositionedStyle}
          aria-hidden="true"
        />
      </div>
    </div>
  )
}

export function TimelinePanel() {
  const { state } = useEditor()
  const { t } = useI18n()
  const project = state.project
  const duration = projectDurationFrames(project)

  const header = (
    <div className="timeline-tab">
      <span className="timeline-tab-dot" aria-hidden="true" />
      <span>{t('mainTimeline')}</span>
    </div>
  )

  return (
    <Panel id="timeline" title={t('timeline')} header={header}>
      <div className="timeline-panel-body">
        <TimelineToolbar />
        <div className="timeline-scroll">
          <div
            className="timeline-content"
            style={
              {
                '--timeline-content-width': `${Math.max(
                  100,
                  state.timelineZoom * 100,
                )}%`,
              } as TimelineContentStyle
            }
          >
            <Ruler duration={duration} fps={project?.fps ?? 30} />
            <div className="timeline-tracks">
              {project?.tracks.map((track) => (
                <TrackRow key={track.id} track={track} duration={duration} />
              ))}
              {project?.tracks.length === 0 ? (
                <div className="timeline-empty">{t('timelineEmpty')}</div>
              ) : null}
            </div>
          </div>
        </div>
      </div>
    </Panel>
  )
}

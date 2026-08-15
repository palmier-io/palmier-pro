import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useReducer,
  useRef,
  type Dispatch,
  type PropsWithChildren,
} from 'react'
import { createBackendAdapter } from './backend'
import { errorMessage } from './errors'
import {
  planClipPropertyEdit,
  planMoveClip,
  planProjectSettings,
  planRemoveClips,
  planSplitClip,
  planTrimClip,
  planUpdateTrack,
  type RemoteEditPlan,
} from './editCommands'
import type {
  BackendAdapter,
  EditResult,
  EditorCommand,
  ExportJob,
  ExportRequest,
  GenerationJob,
  GenerationRequest,
  ImportCandidate,
  LayoutPreset,
  MediaAsset,
  PanelId,
  ProjectDocument,
  ProviderSettings,
  RecentProject,
  Screen,
  TimelineClip,
  TimelineTrack,
} from './model'

export type ToolMode = 'pointer' | 'razor' | 'trim'
export type MediaTab = 'library' | 'generate'
export type MediaViewMode = 'grid' | 'list'
export type DialogId = 'settings' | 'export' | 'new-project'

interface HistoryState {
  past: ProjectDocument[]
  future: ProjectDocument[]
}

export interface EditorState {
  bootStatus: 'loading' | 'ready' | 'error'
  screen: Screen
  recentProjects: RecentProject[]
  project: ProjectDocument | null
  layout: LayoutPreset
  panelVisibility: Record<'media' | 'inspector', boolean>
  focusedPanel: PanelId
  maximizedPanel: PanelId | null
  selectedClipIds: string[]
  selectedAssetIds: string[]
  previewAssetId: string | null
  activeFrame: number
  isPlaying: boolean
  timelineZoom: number
  canvasZoom: number
  toolMode: ToolMode
  mediaTab: MediaTab
  mediaViewMode: MediaViewMode
  mediaQuery: string
  settings: ProviderSettings
  generationJobs: GenerationJob[]
  exportJobs: ExportJob[]
  openDialogs: DialogId[]
  operationLabel: string | null
  errorMessage: string | null
  toastMessage: string | null
  isOnline: boolean
  dirty: boolean
  history: HistoryState
  revision: number
  undoDepth: number
  redoDepth: number
}

type ClipPatch = Partial<Omit<TimelineClip, 'transform'>> & {
  transform?: Partial<TimelineClip['transform']>
}

export type EditorAction =
  | {
      type: 'BOOTSTRAP_SUCCESS'
      recentProjects: RecentProject[]
      settings: ProviderSettings
    }
  | { type: 'BOOTSTRAP_ERROR'; message: string }
  | { type: 'LOAD_PROJECT'; project: ProjectDocument }
  | { type: 'GO_HOME' }
  | { type: 'SET_LAYOUT'; layout: LayoutPreset }
  | { type: 'TOGGLE_PANEL'; panel: 'media' | 'inspector' }
  | { type: 'FOCUS_PANEL'; panel: PanelId }
  | { type: 'TOGGLE_MAXIMIZE'; panel: PanelId }
  | { type: 'SELECT_CLIP'; clipId: string; additive: boolean }
  | { type: 'SELECT_ASSET'; assetId: string; additive: boolean }
  | { type: 'CLEAR_SELECTION' }
  | { type: 'SET_PREVIEW_ASSET'; assetId: string | null }
  | { type: 'SET_ACTIVE_FRAME'; frame: number }
  | { type: 'STEP_PLAYBACK'; frames: number }
  | { type: 'TOGGLE_PLAYBACK' }
  | { type: 'SET_PLAYING'; playing: boolean }
  | { type: 'SET_TIMELINE_ZOOM'; zoom: number }
  | { type: 'SET_CANVAS_ZOOM'; zoom: number }
  | { type: 'SET_TOOL_MODE'; mode: ToolMode }
  | { type: 'SET_MEDIA_TAB'; tab: MediaTab }
  | { type: 'SET_MEDIA_VIEW_MODE'; mode: MediaViewMode }
  | { type: 'SET_MEDIA_QUERY'; query: string }
  | { type: 'ADD_ASSETS'; assets: MediaAsset[] }
  | {
      type: 'UPDATE_MEDIA_STATUS'
      assetId: string
      status: MediaAsset['status']
      sourcePath?: string
    }
  | { type: 'PLACE_ASSET'; assetId: string; trackId?: string; frame: number }
  | {
      type: 'MOVE_CLIP'
      clipId: string
      trackId: string
      startFrame: number
    }
  | { type: 'TRIM_CLIP'; clipId: string; edge: 'start' | 'end'; delta: number }
  | { type: 'SPLIT_AT_PLAYHEAD' }
  | { type: 'DELETE_SELECTION' }
  | { type: 'UPDATE_CLIP'; clipId: string; patch: ClipPatch }
  | {
      type: 'UPDATE_PROJECT_SETTINGS'
      patch: Partial<Pick<ProjectDocument, 'width' | 'height' | 'fps' | 'name'>>
    }
  | {
      type: 'TOGGLE_TRACK_SETTING'
      trackId: string
      setting: 'muted' | 'hidden' | 'locked'
    }
  | { type: 'UNDO' }
  | { type: 'REDO' }
  | { type: 'SET_SETTINGS'; settings: ProviderSettings }
  | {
      type: 'SET_GENERATION_RESULT'
      asset: MediaAsset
      job: GenerationJob
    }
  | { type: 'SET_GENERATION_JOBS'; jobs: GenerationJob[] }
  | { type: 'ADD_EXPORT_JOB'; job: ExportJob }
  | { type: 'SET_EXPORT_JOBS'; jobs: ExportJob[] }
  | { type: 'CLEAR_FINISHED_EXPORTS' }
  | { type: 'SET_DIALOG'; dialog: DialogId; open: boolean }
  | { type: 'SET_OPERATION'; label: string | null }
  | { type: 'SET_ERROR'; message: string | null }
  | { type: 'SET_TOAST'; message: string | null }
  | { type: 'SET_ONLINE'; online: boolean }
  | { type: 'MARK_SAVED' }
  | { type: 'APPLY_EDIT_RESULT'; result: EditResult }

const initialState: EditorState = {
  bootStatus: 'loading',
  screen: 'home',
  recentProjects: [],
  project: null,
  layout: 'default',
  panelVisibility: {
    media: true,
    inspector: true,
  },
  focusedPanel: 'timeline',
  maximizedPanel: null,
  selectedClipIds: [],
  selectedAssetIds: [],
  previewAssetId: null,
  activeFrame: 0,
  isPlaying: false,
  timelineZoom: 1,
  canvasZoom: 1,
  toolMode: 'pointer',
  mediaTab: 'library',
  mediaViewMode: 'grid',
  mediaQuery: '',
  settings: {
    falKey: '',
    replicateKey: '',
  },
  generationJobs: [],
  exportJobs: [],
  openDialogs: [],
  operationLabel: null,
  errorMessage: null,
  toastMessage: null,
  isOnline: typeof navigator === 'undefined' ? true : navigator.onLine,
  dirty: false,
  history: {
    past: [],
    future: [],
  },
  revision: 0,
  undoDepth: 0,
  redoDepth: 0,
}

function cloneProject(project: ProjectDocument): ProjectDocument {
  return JSON.parse(JSON.stringify(project)) as ProjectDocument
}

function sortClips(track: TimelineTrack): TimelineTrack {
  return {
    ...track,
    clips: [...track.clips].sort(
      (left, right) => left.startFrame - right.startFrame,
    ),
  }
}

function commitProject(
  state: EditorState,
  project: ProjectDocument,
): EditorState {
  if (!state.project) return state
  return {
    ...state,
    project,
    dirty: true,
    history: {
      past: [...state.history.past.slice(-39), cloneProject(state.project)],
      future: [],
    },
    revision: state.revision + 1,
  }
}

function updateClipInProject(
  project: ProjectDocument,
  clipId: string,
  update: (clip: TimelineClip) => TimelineClip,
): ProjectDocument {
  return {
    ...project,
    tracks: project.tracks.map((track) => ({
      ...track,
      clips: track.clips.map((clip) =>
        clip.id === clipId ? update(clip) : clip,
      ),
    })),
  }
}

function selectedClips(state: EditorState): TimelineClip[] {
  if (!state.project) return []
  const selected = new Set(state.selectedClipIds)
  return state.project.tracks.flatMap((track) =>
    track.clips.filter((clip) => selected.has(clip.id)),
  )
}

export function projectDurationFrames(
  project: ProjectDocument | null,
): number {
  if (!project) return 0
  return Math.max(
    project.fps * 10,
    ...project.tracks.flatMap((track) =>
      track.clips.map((clip) => clip.startFrame + clip.durationFrames),
    ),
  )
}

function previewDuration(state: EditorState): number {
  if (state.previewAssetId) {
    const asset = findAsset(state.project, state.previewAssetId)
    return Math.max(1, asset?.durationFrames ?? 1)
  }
  return projectDurationFrames(state.project)
}

export function findClip(
  project: ProjectDocument | null,
  clipId: string,
): TimelineClip | null {
  if (!project) return null
  for (const track of project.tracks) {
    const clip = track.clips.find((candidate) => candidate.id === clipId)
    if (clip) return clip
  }
  return null
}

function linkedPartnerClips(
  project: ProjectDocument,
  clipId: string,
): TimelineClip[] {
  const clip = findClip(project, clipId)
  if (!clip?.linkGroupId) return []
  return project.tracks.flatMap((track) =>
    track.clips.filter(
      (candidate) =>
        candidate.linkGroupId === clip.linkGroupId && candidate.id !== clipId,
    ),
  )
}

export function findAsset(
  project: ProjectDocument | null,
  assetId: string,
): MediaAsset | null {
  return project?.media.find((asset) => asset.id === assetId) ?? null
}

function editorReducer(
  state: EditorState,
  action: EditorAction,
): EditorState {
  switch (action.type) {
    case 'BOOTSTRAP_SUCCESS':
      return {
        ...state,
        bootStatus: 'ready',
        recentProjects: action.recentProjects,
        settings: action.settings,
      }
    case 'BOOTSTRAP_ERROR':
      return {
        ...state,
        bootStatus: 'error',
        errorMessage: action.message,
      }
    case 'LOAD_PROJECT':
      return {
        ...state,
        screen: 'editor',
        project: cloneProject(action.project),
        activeFrame: 0,
        isPlaying: false,
        selectedClipIds: [],
        selectedAssetIds: [],
        previewAssetId: null,
        generationJobs: [],
        exportJobs: [],
        openDialogs: [],
        operationLabel: null,
        errorMessage: null,
        dirty: false,
        history: { past: [], future: [] },
        revision: 0,
        undoDepth: 0,
        redoDepth: 0,
      }
    case 'GO_HOME':
      return {
        ...state,
        screen: 'home',
        isPlaying: false,
        maximizedPanel: null,
        openDialogs: [],
      }
    case 'SET_LAYOUT':
      return {
        ...state,
        layout: action.layout,
        maximizedPanel: null,
      }
    case 'TOGGLE_PANEL':
      return {
        ...state,
        panelVisibility: {
          ...state.panelVisibility,
          [action.panel]: !state.panelVisibility[action.panel],
        },
        maximizedPanel: null,
      }
    case 'FOCUS_PANEL':
      return { ...state, focusedPanel: action.panel }
    case 'TOGGLE_MAXIMIZE':
      return {
        ...state,
        focusedPanel: action.panel,
        maximizedPanel:
          state.maximizedPanel === action.panel ? null : action.panel,
      }
    case 'SELECT_CLIP': {
      const current = new Set(state.selectedClipIds)
      if (action.additive) {
        if (current.has(action.clipId)) {
          current.delete(action.clipId)
        } else {
          current.add(action.clipId)
        }
      } else {
        current.clear()
        current.add(action.clipId)
      }
      return {
        ...state,
        selectedClipIds: [...current],
        selectedAssetIds: [],
        previewAssetId: null,
        focusedPanel: 'timeline',
      }
    }
    case 'SELECT_ASSET': {
      const current = new Set(state.selectedAssetIds)
      if (action.additive) {
        if (current.has(action.assetId)) {
          current.delete(action.assetId)
        } else {
          current.add(action.assetId)
        }
      } else {
        current.clear()
        current.add(action.assetId)
      }
      return {
        ...state,
        selectedAssetIds: [...current],
        selectedClipIds: [],
        focusedPanel: 'media',
      }
    }
    case 'CLEAR_SELECTION':
      return {
        ...state,
        selectedClipIds: [],
        selectedAssetIds: [],
      }
    case 'SET_PREVIEW_ASSET':
      return {
        ...state,
        previewAssetId: action.assetId,
        focusedPanel: 'preview',
      }
    case 'SET_ACTIVE_FRAME': {
      const duration = previewDuration(state)
      return {
        ...state,
        activeFrame: Math.max(0, Math.min(duration, Math.round(action.frame))),
      }
    }
    case 'STEP_PLAYBACK': {
      const duration = previewDuration(state)
      const next = state.activeFrame + action.frames
      return {
        ...state,
        activeFrame: duration > 0 ? next % duration : 0,
      }
    }
    case 'TOGGLE_PLAYBACK':
      return { ...state, isPlaying: !state.isPlaying }
    case 'SET_PLAYING':
      return { ...state, isPlaying: action.playing }
    case 'SET_TIMELINE_ZOOM':
      return {
        ...state,
        timelineZoom: Math.max(0.5, Math.min(4, action.zoom)),
      }
    case 'SET_CANVAS_ZOOM':
      return {
        ...state,
        canvasZoom: Math.max(0.25, Math.min(2, action.zoom)),
      }
    case 'SET_TOOL_MODE':
      return { ...state, toolMode: action.mode }
    case 'SET_MEDIA_TAB':
      return { ...state, mediaTab: action.tab, focusedPanel: 'media' }
    case 'SET_MEDIA_VIEW_MODE':
      return { ...state, mediaViewMode: action.mode }
    case 'SET_MEDIA_QUERY':
      return { ...state, mediaQuery: action.query }
    case 'ADD_ASSETS':
      if (!state.project) return state
      return {
        ...state,
        project: {
          ...state.project,
          media: [
            ...state.project.media,
            ...action.assets.filter(
              (asset) =>
                !state.project?.media.some((existing) => existing.id === asset.id),
            ),
          ],
        },
        selectedAssetIds: action.assets.map((asset) => asset.id),
        dirty: true,
      }
    case 'UPDATE_MEDIA_STATUS':
      if (!state.project) return state
      return {
        ...state,
        project: {
          ...state.project,
          media: state.project.media.map((asset) =>
            asset.id === action.assetId
              ? {
                  ...asset,
                  status: action.status,
                  sourcePath: action.sourcePath ?? asset.sourcePath,
                }
              : asset,
          ),
        },
        dirty: true,
        revision: state.revision + 1,
      }
    case 'PLACE_ASSET': {
      if (!state.project) return state
      const asset = findAsset(state.project, action.assetId)
      if (!asset) return state
      const desiredKind = asset.kind === 'audio' ? 'audio' : 'video'
      const track =
        state.project.tracks.find(
          (candidate) =>
            candidate.id === action.trackId &&
            candidate.kind === desiredKind &&
            !candidate.locked,
        ) ??
        state.project.tracks.find(
          (candidate) =>
            candidate.kind === desiredKind && !candidate.locked,
        )
      if (!track) return state
      const clipId = `clip-${asset.id}-${state.revision + 1}`
      const linkGroupId =
        asset.kind === 'video' && asset.hasAudio
          ? `link-${asset.id}-${state.revision + 1}`
          : undefined
      const clip: TimelineClip = {
        id: clipId,
        assetId: asset.id,
        name: asset.name.replace(/\.[^.]+$/, ''),
        kind: asset.kind,
        trackId: track.id,
        startFrame: Math.max(0, Math.round(action.frame)),
        durationFrames: Math.max(3, asset.durationFrames),
        sourceOffsetFrames: 0,
        trimEndFrames: 0,
        speed: 1,
        volume: 1,
        fadeInFrames: 0,
        fadeOutFrames: 0,
        linkGroupId,
        transform: {
          positionX: 0,
          positionY: 0,
          scale: 100,
          rotation: 0,
          opacity: 100,
        },
      }
      const audioTrack =
        linkGroupId == null
          ? undefined
          : state.project.tracks.find(
              (candidate) => candidate.kind === 'audio' && !candidate.locked,
            )
      const audioClip: TimelineClip | null =
        linkGroupId && audioTrack
          ? {
              ...clip,
              id: `${clipId}-audio`,
              kind: 'audio',
              trackId: audioTrack.id,
            }
          : null
      const project = {
        ...state.project,
        tracks: state.project.tracks.map((candidate) => {
          const clips = [...candidate.clips]
          if (candidate.id === track.id) clips.push(clip)
          if (audioClip && candidate.id === audioTrack?.id) clips.push(audioClip)
          return sortClips({ ...candidate, clips })
        }),
      }
      return {
        ...commitProject(state, project),
        selectedClipIds: [clipId],
        selectedAssetIds: [],
      }
    }
    case 'MOVE_CLIP': {
      if (!state.project) return state
      const clip = findClip(state.project, action.clipId)
      const destination = state.project.tracks.find(
        (track) => track.id === action.trackId,
      )
      if (!clip || !destination || destination.locked) return state
      const compatible =
        (clip.kind === 'audio' && destination.kind === 'audio') ||
        (clip.kind !== 'audio' && destination.kind === 'video')
      if (!compatible) return state
      const moved = {
        ...clip,
        trackId: destination.id,
        startFrame: Math.max(0, Math.round(action.startFrame)),
      }
      const delta = moved.startFrame - clip.startFrame
      const relocated = new Map<string, TimelineClip>([[moved.id, moved]])
      for (const partner of linkedPartnerClips(state.project, clip.id)) {
        relocated.set(partner.id, {
          ...partner,
          startFrame: Math.max(0, partner.startFrame + delta),
        })
      }
      const project = {
        ...state.project,
        tracks: state.project.tracks.map((track) =>
          sortClips({
            ...track,
            clips: [
              ...track.clips.filter((candidate) => !relocated.has(candidate.id)),
              ...[...relocated.values()].filter((candidate) => {
                const trackId =
                  candidate.id === action.clipId
                    ? destination.id
                    : candidate.trackId
                return trackId === track.id
              }),
            ],
          }),
        ),
      }
      return commitProject(state, project)
    }
    case 'TRIM_CLIP': {
      if (!state.project || action.delta === 0) return state
      const targets = [
        action.clipId,
        ...linkedPartnerClips(state.project, action.clipId).map(
          (clip) => clip.id,
        ),
      ]
      let project = state.project
      for (const clipId of targets) {
        project = updateClipInProject(project, clipId, (clip) => {
          if (action.edge === 'start') {
            const applied = Math.max(
              -clip.startFrame,
              Math.min(clip.durationFrames - 3, Math.round(action.delta)),
            )
            return {
              ...clip,
              startFrame: clip.startFrame + applied,
              durationFrames: clip.durationFrames - applied,
              sourceOffsetFrames: Math.max(
                0,
                clip.sourceOffsetFrames + applied,
              ),
            }
          }
          return {
            ...clip,
            durationFrames: Math.max(
              3,
              clip.durationFrames + Math.round(action.delta),
            ),
          }
        })
      }
      return commitProject(state, project)
    }
    case 'SPLIT_AT_PLAYHEAD': {
      if (!state.project) return state
      const targets = selectedClips(state).filter(
        (clip) =>
          state.activeFrame > clip.startFrame &&
          state.activeFrame < clip.startFrame + clip.durationFrames,
      )
      if (targets.length === 0) return state
      const targetIds = new Set(targets.map((clip) => clip.id))
      const newSelection: string[] = []
      const project = {
        ...state.project,
        tracks: state.project.tracks.map((track) =>
          sortClips({
            ...track,
            clips: track.clips.flatMap((clip) => {
              if (!targetIds.has(clip.id)) return [clip]
              const firstDuration = state.activeFrame - clip.startFrame
              const secondId = `${clip.id}-split-${state.activeFrame}`
              const second: TimelineClip = {
                ...clip,
                id: secondId,
                startFrame: state.activeFrame,
                durationFrames: clip.durationFrames - firstDuration,
                sourceOffsetFrames:
                  clip.sourceOffsetFrames +
                  Math.round(firstDuration * clip.speed),
              }
              newSelection.push(secondId)
              return [
                { ...clip, durationFrames: firstDuration },
                second,
              ]
            }),
          }),
        ),
      }
      return {
        ...commitProject(state, project),
        selectedClipIds: newSelection,
      }
    }
    case 'DELETE_SELECTION': {
      if (!state.project || state.selectedClipIds.length === 0) return state
      const selected = new Set(state.selectedClipIds)
      const project = {
        ...state.project,
        tracks: state.project.tracks.map((track) => ({
          ...track,
          clips: track.clips.filter((clip) => !selected.has(clip.id)),
        })),
      }
      return {
        ...commitProject(state, project),
        selectedClipIds: [],
      }
    }
    case 'UPDATE_CLIP': {
      if (!state.project || !findClip(state.project, action.clipId)) return state
      const project = updateClipInProject(
        state.project,
        action.clipId,
        (clip) => ({
          ...clip,
          ...action.patch,
          transform: action.patch.transform
            ? { ...clip.transform, ...action.patch.transform }
            : clip.transform,
        }),
      )
      return commitProject(state, project)
    }
    case 'UPDATE_PROJECT_SETTINGS':
      if (!state.project) return state
      return commitProject(state, {
        ...state.project,
        ...action.patch,
      })
    case 'TOGGLE_TRACK_SETTING':
      if (!state.project) return state
      if (action.setting === 'locked') {
        return {
          ...state,
          project: {
            ...state.project,
            tracks: state.project.tracks.map((track) =>
              track.id === action.trackId
                ? { ...track, locked: !track.locked }
                : track,
            ),
          },
        }
      }
      return commitProject(state, {
        ...state.project,
        tracks: state.project.tracks.map((track) =>
          track.id === action.trackId
            ? { ...track, [action.setting]: !track[action.setting] }
            : track,
        ),
      })
    case 'UNDO': {
      if (!state.project || state.history.past.length === 0) return state
      const previous = state.history.past.at(-1)
      if (!previous) return state
      return {
        ...state,
        project: cloneProject(previous),
        selectedClipIds: state.selectedClipIds.filter((clipId) =>
          Boolean(findClip(previous, clipId)),
        ),
        dirty: true,
        history: {
          past: state.history.past.slice(0, -1),
          future: [cloneProject(state.project), ...state.history.future],
        },
        revision: state.revision + 1,
      }
    }
    case 'REDO': {
      if (!state.project || state.history.future.length === 0) return state
      const next = state.history.future[0]
      if (!next) return state
      return {
        ...state,
        project: cloneProject(next),
        selectedClipIds: state.selectedClipIds.filter((clipId) =>
          Boolean(findClip(next, clipId)),
        ),
        dirty: true,
        history: {
          past: [...state.history.past, cloneProject(state.project)],
          future: state.history.future.slice(1),
        },
        revision: state.revision + 1,
      }
    }
    case 'SET_SETTINGS':
      return { ...state, settings: action.settings }
    case 'SET_GENERATION_RESULT':
      if (!state.project) return state
      return {
        ...state,
        project: {
          ...state.project,
          media: [...state.project.media, action.asset],
        },
        generationJobs: [
          action.job,
          ...state.generationJobs.filter(
            (job) => job.id !== action.job.id,
          ),
        ],
        selectedAssetIds: [action.asset.id],
        mediaTab: 'library',
        dirty: true,
        revision: state.revision + 1,
      }
    case 'SET_GENERATION_JOBS': {
      if (!state.project) return { ...state, generationJobs: action.jobs }
      const jobsByAsset = new Map(
        action.jobs.map((job) => [job.assetId, job]),
      )
      return {
        ...state,
        generationJobs: action.jobs,
        project: {
          ...state.project,
          media: state.project.media.map((asset) => {
            const job = jobsByAsset.get(asset.id)
            if (!job) return asset
            if (job.status === 'completed') {
              return { ...asset, status: readyMediaStatus }
            }
            if (job.status === 'failed') {
              return {
                ...asset,
                status: {
                  kind: 'failed',
                  message: job.error ?? 'Generation failed',
                },
              }
            }
            if (job.status === 'canceled') {
              return {
                ...asset,
                status: {
                  kind: 'failed',
                  message: 'Generation canceled',
                },
              }
            }
            return {
              ...asset,
              status: {
                kind: 'generating',
                progress: job.progress,
                label: job.label,
              },
            }
          }),
        },
      }
    }
    case 'ADD_EXPORT_JOB':
      return {
        ...state,
        exportJobs: [
          action.job,
          ...state.exportJobs.filter((job) => job.id !== action.job.id),
        ],
      }
    case 'SET_EXPORT_JOBS':
      return { ...state, exportJobs: action.jobs }
    case 'CLEAR_FINISHED_EXPORTS':
      return {
        ...state,
        exportJobs: state.exportJobs.filter((job) =>
          ['waiting', 'preparing', 'running'].includes(job.status),
        ),
      }
    case 'SET_DIALOG': {
      const dialogs = new Set(state.openDialogs)
      if (action.open) {
        dialogs.add(action.dialog)
      } else {
        dialogs.delete(action.dialog)
      }
      return { ...state, openDialogs: [...dialogs] }
    }
    case 'SET_OPERATION':
      return { ...state, operationLabel: action.label }
    case 'SET_ERROR':
      return { ...state, errorMessage: action.message }
    case 'SET_TOAST':
      return { ...state, toastMessage: action.message }
    case 'SET_ONLINE':
      return { ...state, isOnline: action.online }
    case 'MARK_SAVED':
      return { ...state, dirty: false }
    case 'APPLY_EDIT_RESULT': {
      const { result } = action
      const created = result.receipt.createdClipIds ?? []
      const selectedClipIds = state.selectedClipIds.filter((clipId) =>
        Boolean(findClip(result.project, clipId)),
      )
      const locks = new Map(
        (state.project?.tracks ?? []).map((track) => [track.id, track.locked]),
      )
      const project = cloneProject(result.project)
      project.tracks = project.tracks.map((track) => ({
        ...track,
        locked: locks.get(track.id) ?? track.locked,
      }))
      return {
        ...state,
        project,
        selectedClipIds:
          created.length > 0 ? created : selectedClipIds,
        dirty: result.dirty ?? true,
        revision: result.revision,
        undoDepth: result.undoDepth ?? state.undoDepth,
        redoDepth: result.redoDepth ?? state.redoDepth,
        history: { past: [], future: [] },
      }
    }
  }
}

const readyMediaStatus: MediaAsset['status'] = { kind: 'ready' }

interface EditorContextValue {
  state: EditorState
  dispatch: Dispatch<EditorAction>
  backend: BackendAdapter
  canUndo: boolean
  canRedo: boolean
  createProject: (name: string) => Promise<void>
  openProject: (path?: string) => Promise<void>
  importFiles: (files: File[]) => Promise<void>
  importFromDialog: () => Promise<void>
  saveProject: () => Promise<void>
  saveSettings: (settings: ProviderSettings) => Promise<void>
  startGeneration: (request: Omit<GenerationRequest, 'projectId'>) => Promise<void>
  startExport: (request: Omit<ExportRequest, 'projectId'>) => Promise<void>
  cancelExport: (jobId: string) => Promise<void>
  captureFrame: () => Promise<void>
  relinkAsset: (assetId: string, file?: File) => void
}

function planRemoteMutation(
  state: EditorState,
  action: EditorAction,
): RemoteEditPlan | null {
  if (!state.project) return { kind: 'noop' }
  switch (action.type) {
    case 'UNDO':
      return { kind: 'command', command: { command: 'undo' } }
    case 'REDO':
      return { kind: 'command', command: { command: 'redo' } }
    case 'MOVE_CLIP':
      return planMoveClip(
        state.project,
        action.clipId,
        action.trackId,
        action.startFrame,
      )
    case 'TRIM_CLIP':
      return planTrimClip(
        state.project,
        action.clipId,
        action.edge,
        action.delta,
      )
    case 'SPLIT_AT_PLAYHEAD': {
      const targets = selectedClips(state).filter(
        (clip) =>
          state.activeFrame > clip.startFrame &&
          state.activeFrame < clip.startFrame + clip.durationFrames,
      )
      if (targets.length === 0) return { kind: 'noop' }
      return planSplitClip(
        state.project,
        targets[0]!.id,
        state.activeFrame,
      )
    }
    case 'DELETE_SELECTION':
      return planRemoveClips(state.project, state.selectedClipIds)
    case 'TOGGLE_TRACK_SETTING':
      if (action.setting === 'locked') {
        // Ephemeral session lock. Apply through the local reducer.
        return null
      }
      return planUpdateTrack(state.project, action.trackId, action.setting)
    case 'UPDATE_CLIP':
      return planClipPropertyEdit(state.project, action.clipId, action.patch)
    case 'UPDATE_PROJECT_SETTINGS':
      return planProjectSettings(state.project, action.patch)
    default:
      return null
  }
}

function withTimeline(command: EditorCommand, timelineId: string): EditorCommand {
  if (command.command === 'undo' || command.command === 'redo') return command
  if (!timelineId || ('timelineId' in command && command.timelineId)) {
    return command
  }
  return { ...command, timelineId }
}

const EditorContext = createContext<EditorContextValue | null>(null)

interface EditorProviderProps extends PropsWithChildren {
  backend?: BackendAdapter
}

export function EditorProvider({
  backend: providedBackend,
  children,
}: EditorProviderProps) {
  const backend = useMemo(
    () => providedBackend ?? createBackendAdapter(),
    [providedBackend],
  )
  const [state, rawDispatch] = useReducer(editorReducer, initialState)
  const stateRef = useRef(state)
  stateRef.current = state
  const projectRef = useRef<ProjectDocument | null>(null)
  projectRef.current = state.project
  const editQueue = useRef(Promise.resolve())

  const commitRemote = useCallback(
    (command: EditorCommand, expectedRevision: number) => {
      const project = stateRef.current.project
      if (!project) return
      editQueue.current = editQueue.current
        .catch(() => undefined)
        .then(async () => {
          const latest = stateRef.current
          if (!latest.project || latest.revision !== expectedRevision) {
            rawDispatch({
              type: 'SET_ERROR',
              message: 'revisionMismatch',
            })
            return
          }
          try {
            const result = await backend.commitEdit({
              projectId: latest.project.id,
              expectedRevision,
              command: withTimeline(command, latest.project.timelineId),
            })
            if (stateRef.current.revision !== expectedRevision) {
              rawDispatch({
                type: 'SET_ERROR',
                message: 'revisionMismatch',
              })
              return
            }
            rawDispatch({ type: 'APPLY_EDIT_RESULT', result })
            if (result.receipt.warnings?.length) {
              rawDispatch({
                type: 'SET_TOAST',
                message: result.receipt.warnings[0] ?? null,
              })
            }
          } catch (error) {
            rawDispatch({ type: 'SET_ERROR', message: errorMessage(error) })
          }
        })
    },
    [backend],
  )

  const dispatch = useCallback<Dispatch<EditorAction>>(
    (action) => {
      if (backend.kind !== 'tauri') {
        rawDispatch(action)
        return
      }
      const plan = planRemoteMutation(stateRef.current, action)
      if (plan === null) {
        if (action.type === 'PLACE_ASSET' && backend.placeAsset) {
          const latest = stateRef.current
          if (!latest.project) return
          const expectedRevision = latest.revision
          editQueue.current = editQueue.current
            .catch(() => undefined)
            .then(async () => {
              const current = stateRef.current
              if (!current.project || current.revision !== expectedRevision) {
                rawDispatch({
                  type: 'SET_ERROR',
                  message: 'revisionMismatch',
                })
                return
              }
              try {
                const result = await backend.placeAsset!(
                  current.project.id,
                  expectedRevision,
                  action.assetId,
                  action.trackId,
                  Math.max(0, Math.round(action.frame)),
                )
                if (stateRef.current.revision !== expectedRevision) {
                  rawDispatch({
                    type: 'SET_ERROR',
                    message: 'revisionMismatch',
                  })
                  return
                }
                rawDispatch({ type: 'APPLY_EDIT_RESULT', result })
            if (result.receipt.warnings?.length) {
              rawDispatch({
                type: 'SET_TOAST',
                message: result.receipt.warnings[0] ?? null,
              })
            }
              } catch (error) {
                rawDispatch({ type: 'SET_ERROR', message: errorMessage(error) })
              }
            })
          return
        }
        rawDispatch(action)
        return
      }
      if (plan.kind === 'noop') return
      if (plan.kind === 'unsupported') {
        rawDispatch({ type: 'SET_ERROR', message: plan.message })
        return
      }
      commitRemote(plan.command, stateRef.current.revision)
    },
    [backend, commitRemote],
  )

  useEffect(() => {
    let active = true
    void backend
      .bootstrap()
      .then((payload) => {
        if (!active) return
        rawDispatch({
          type: 'BOOTSTRAP_SUCCESS',
          recentProjects: payload.recentProjects,
          settings: payload.settings,
        })
      })
      .catch((error: unknown) => {
        if (!active) return
        rawDispatch({ type: 'BOOTSTRAP_ERROR', message: errorMessage(error) })
      })
    return () => {
      active = false
    }
  }, [backend])

  useEffect(() => {
    const setOnline = () =>
      rawDispatch({ type: 'SET_ONLINE', online: navigator.onLine })
    window.addEventListener('online', setOnline)
    window.addEventListener('offline', setOnline)
    return () => {
      window.removeEventListener('online', setOnline)
      window.removeEventListener('offline', setOnline)
    }
  }, [])

  useEffect(() => {
    if (!state.isPlaying || !state.project) return
    const fps = Math.max(1, state.project.fps)
    let last = performance.now()
    const timer = window.setInterval(() => {
      const now = performance.now()
      const frames = Math.max(1, Math.round(((now - last) / 1000) * fps))
      last = now
      rawDispatch({ type: 'STEP_PLAYBACK', frames })
    }, Math.round(1000 / fps))
    return () => window.clearInterval(timer)
  }, [state.isPlaying, state.project])

  useEffect(() => {
    if (!state.project || !state.dirty) return
    const project = state.project
    const revision = state.revision
    const timer = window.setTimeout(() => {
      void backend
        .persistProject(project)
        .then(() => {
          if (
            stateRef.current.project?.id === project.id &&
            stateRef.current.revision === revision
          ) {
            rawDispatch({ type: 'MARK_SAVED' })
          }
        })
        .catch((error: unknown) => {
          rawDispatch({ type: 'SET_ERROR', message: errorMessage(error) })
        })
    }, 600)
    return () => window.clearTimeout(timer)
  }, [backend, state.dirty, state.project, state.revision])

  const hasActiveGeneration = state.generationJobs.some((job) =>
    ['waiting', 'preparing', 'running'].includes(job.status),
  )
  useEffect(() => {
    if (!state.project || !hasActiveGeneration || !state.isOnline) return
    const projectId = state.project.id
    const refresh = () => {
      void backend
        .listGenerationJobs(projectId)
        .then((jobs) => rawDispatch({ type: 'SET_GENERATION_JOBS', jobs }))
        .catch((error: unknown) =>
          rawDispatch({ type: 'SET_ERROR', message: errorMessage(error) }),
        )
    }
    refresh()
    const timer = window.setInterval(refresh, 400)
    return () => window.clearInterval(timer)
  }, [backend, hasActiveGeneration, state.isOnline, state.project])

  const hasActiveExport = state.exportJobs.some((job) =>
    ['waiting', 'preparing', 'running'].includes(job.status),
  )
  useEffect(() => {
    if (!state.project || !hasActiveExport) return
    const projectId = state.project.id
    const refresh = () => {
      void backend
        .listExportJobs(projectId)
        .then((jobs) => rawDispatch({ type: 'SET_EXPORT_JOBS', jobs }))
        .catch((error: unknown) =>
          rawDispatch({ type: 'SET_ERROR', message: errorMessage(error) }),
        )
    }
    refresh()
    const timer = window.setInterval(refresh, 500)
    return () => window.clearInterval(timer)
  }, [backend, hasActiveExport, state.project])

  useEffect(() => {
    if (!state.toastMessage) return
    const timer = window.setTimeout(
      () => rawDispatch({ type: 'SET_TOAST', message: null }),
      2600,
    )
    return () => window.clearTimeout(timer)
  }, [state.toastMessage])

  const createProject = useCallback(
    async (name: string) => {
      rawDispatch({ type: 'SET_OPERATION', label: 'creatingProject' })
      try {
        const project = await backend.createProject(name)
        rawDispatch({ type: 'LOAD_PROJECT', project })
      } catch (error) {
        rawDispatch({ type: 'SET_OPERATION', label: null })
        rawDispatch({ type: 'SET_ERROR', message: errorMessage(error) })
      }
    },
    [backend],
  )

  const openProject = useCallback(
    async (path?: string) => {
      rawDispatch({ type: 'SET_OPERATION', label: 'openingProject' })
      try {
        const project = await backend.openProject(path)
        rawDispatch({ type: 'LOAD_PROJECT', project })
      } catch (error) {
        rawDispatch({ type: 'SET_OPERATION', label: null })
        rawDispatch({ type: 'SET_ERROR', message: errorMessage(error) })
      }
    },
    [backend],
  )

  const importFiles = useCallback(
    async (files: File[]) => {
      const project = projectRef.current
      if (!project) return
      rawDispatch({ type: 'SET_OPERATION', label: 'importingMedia' })
      const candidates: ImportCandidate[] = files.map((file) => ({
        name: file.name,
        type: file.type,
        size: file.size,
        path: 'path' in file ? String((file as File & { path?: string }).path) : undefined,
      }))
      try {
        const assets = await backend.importMedia(project.id, candidates)
        rawDispatch({ type: 'ADD_ASSETS', assets })
        rawDispatch({ type: 'SET_OPERATION', label: null })
        rawDispatch({
          type: 'SET_TOAST',
          message: `importComplete:${assets.length}`,
        })
        if (!stateRef.current.previewAssetId && assets[0]) {
          rawDispatch({ type: 'SET_PREVIEW_ASSET', assetId: assets[0].id })
        }
      } catch (error) {
        rawDispatch({ type: 'SET_OPERATION', label: null })
        rawDispatch({ type: 'SET_ERROR', message: errorMessage(error) })
      }
    },
    [backend],
  )

  const importFromDialog = useCallback(async () => {
    const project = projectRef.current
    if (!project) return
    if (backend.kind === 'tauri' && backend.importMediaDialog) {
      rawDispatch({ type: 'SET_OPERATION', label: 'importingMedia' })
      try {
        const assets = await backend.importMediaDialog(project.id)
        rawDispatch({ type: 'ADD_ASSETS', assets })
        rawDispatch({ type: 'SET_OPERATION', label: null })
        rawDispatch({
          type: 'SET_TOAST',
          message: `importComplete:${assets.length}`,
        })
        if (!stateRef.current.previewAssetId && assets[0]) {
          rawDispatch({ type: 'SET_PREVIEW_ASSET', assetId: assets[0].id })
        }
      } catch (error) {
        rawDispatch({ type: 'SET_OPERATION', label: null })
        const message = errorMessage(error)
        if (message !== 'import canceled') {
          rawDispatch({ type: 'SET_ERROR', message })
        }
      }
      return
    }
    // Demo / browser fallback uses the hidden file input via MediaPanel.
  }, [backend])

  const captureFrame = useCallback(async () => {
    const latest = stateRef.current
    const project = latest.project
    if (!project || !backend.captureFrame) return
    rawDispatch({ type: 'SET_OPERATION', label: 'capturingFrame' })
    try {
      const fps = Math.max(1, project.fps)
      const assets = latest.previewAssetId
        ? await backend.captureFrame(project.id, {
            mediaRef: latest.previewAssetId,
            sourceSeconds: latest.activeFrame / fps,
          })
        : await backend.captureFrame(project.id, {
            timelineFrame: latest.activeFrame,
          })
      rawDispatch({ type: 'ADD_ASSETS', assets })
      rawDispatch({ type: 'SET_OPERATION', label: null })
      rawDispatch({ type: 'SET_TOAST', message: 'captureComplete' })
    } catch (error) {
      rawDispatch({ type: 'SET_OPERATION', label: null })
      rawDispatch({ type: 'SET_ERROR', message: errorMessage(error) })
    }
  }, [backend])

  const saveProject = useCallback(async () => {
    const project = projectRef.current
    if (!project) return
    rawDispatch({ type: 'SET_OPERATION', label: 'saveProject' })
    try {
      await backend.persistProject(project)
      rawDispatch({ type: 'MARK_SAVED' })
      rawDispatch({ type: 'SET_OPERATION', label: null })
    } catch (error) {
      rawDispatch({ type: 'SET_OPERATION', label: null })
      rawDispatch({ type: 'SET_ERROR', message: errorMessage(error) })
    }
  }, [backend])

  const saveSettings = useCallback(
    async (settings: ProviderSettings) => {
      rawDispatch({ type: 'SET_OPERATION', label: 'savingSettings' })
      try {
        await backend.saveProviderSettings(settings)
        rawDispatch({
          type: 'SET_SETTINGS',
          settings: {
            falKey: '',
            replicateKey: '',
            falConfigured:
              Boolean(settings.falKey) || settings.falConfigured,
            replicateConfigured:
              Boolean(settings.replicateKey) ||
              settings.replicateConfigured,
          },
        })
        rawDispatch({ type: 'SET_DIALOG', dialog: 'settings', open: false })
        rawDispatch({ type: 'SET_OPERATION', label: null })
      } catch (error) {
        rawDispatch({ type: 'SET_OPERATION', label: null })
        rawDispatch({ type: 'SET_ERROR', message: errorMessage(error) })
      }
    },
    [backend],
  )

  const startGeneration = useCallback(
    async (request: Omit<GenerationRequest, 'projectId'>) => {
      const project = projectRef.current
      if (!project) return
      if (!navigator.onLine) {
        rawDispatch({ type: 'SET_ERROR', message: 'reconnecting' })
        return
      }
      rawDispatch({ type: 'SET_OPERATION', label: 'working' })
      try {
        const result = await backend.startGeneration({
          ...request,
          projectId: project.id,
        })
        rawDispatch({ type: 'SET_GENERATION_RESULT', ...result })
        rawDispatch({ type: 'SET_OPERATION', label: null })
        rawDispatch({ type: 'SET_TOAST', message: 'generationStarted' })
      } catch (error) {
        rawDispatch({ type: 'SET_OPERATION', label: null })
        rawDispatch({ type: 'SET_ERROR', message: errorMessage(error) })
      }
    },
    [backend],
  )

  const startExport = useCallback(
    async (request: Omit<ExportRequest, 'projectId'>) => {
      const project = projectRef.current
      if (!project) return
      rawDispatch({ type: 'SET_OPERATION', label: 'working' })
      try {
        const job = await backend.startExport({
          ...request,
          projectId: project.id,
        })
        rawDispatch({ type: 'ADD_EXPORT_JOB', job })
        rawDispatch({ type: 'SET_OPERATION', label: null })
        rawDispatch({ type: 'SET_TOAST', message: 'exportStarted' })
      } catch (error) {
        rawDispatch({ type: 'SET_OPERATION', label: null })
        rawDispatch({ type: 'SET_ERROR', message: errorMessage(error) })
      }
    },
    [backend],
  )

  const cancelExport = useCallback(
    async (jobId: string) => {
      try {
        await backend.cancelExport(jobId)
        const project = projectRef.current
        if (project) {
          const jobs = await backend.listExportJobs(project.id)
          rawDispatch({ type: 'SET_EXPORT_JOBS', jobs })
        }
      } catch (error) {
        rawDispatch({ type: 'SET_ERROR', message: errorMessage(error) })
      }
    },
    [backend],
  )

  const relinkAsset = useCallback((assetId: string, file?: File) => {
    rawDispatch({
      type: 'UPDATE_MEDIA_STATUS',
      assetId,
      status: readyMediaStatus,
      sourcePath: file ? `/Relinked/${file.name}` : undefined,
    })
  }, [])

  const canUndo =
    backend.kind === 'tauri'
      ? state.undoDepth > 0
      : state.history.past.length > 0
  const canRedo =
    backend.kind === 'tauri'
      ? state.redoDepth > 0
      : state.history.future.length > 0

  const value = useMemo<EditorContextValue>(
    () => ({
      state,
      dispatch,
      backend,
      canUndo,
      canRedo,
      createProject,
      openProject,
      importFiles,
      importFromDialog,
      saveProject,
      saveSettings,
      startGeneration,
      startExport,
      cancelExport,
      captureFrame,
      relinkAsset,
    }),
    [
      backend,
      canRedo,
      canUndo,
      cancelExport,
      captureFrame,
      createProject,
      dispatch,
      importFiles,
      importFromDialog,
      openProject,
      relinkAsset,
      saveProject,
      saveSettings,
      startExport,
      startGeneration,
      state,
    ],
  )

  return (
    <EditorContext.Provider value={value}>
      {children}
    </EditorContext.Provider>
  )
}

export function useEditor(): EditorContextValue {
  const value = useContext(EditorContext)
  if (!value) {
    throw new Error('useEditor must be used inside EditorProvider')
  }
  return value
}

export function selectedClipForState(
  state: EditorState,
): TimelineClip | null {
  if (state.selectedClipIds.length !== 1) return null
  const clipId = state.selectedClipIds[0]
  return clipId ? findClip(state.project, clipId) : null
}

export function selectedAssetForState(
  state: EditorState,
): MediaAsset | null {
  if (state.selectedAssetIds.length !== 1) return null
  const assetId = state.selectedAssetIds[0]
  return assetId ? findAsset(state.project, assetId) : null
}

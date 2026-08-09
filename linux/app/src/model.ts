export type Screen = 'home' | 'editor'

export type LayoutPreset = 'default' | 'media' | 'vertical'

export type PanelId = 'media' | 'preview' | 'inspector' | 'timeline'

export type MediaKind = 'video' | 'audio' | 'image'

export type MediaStatus =
  | { kind: 'ready' }
  | { kind: 'importing'; progress: number }
  | { kind: 'generating'; progress: number; label: string }
  | { kind: 'offline'; reason: string }
  | { kind: 'failed'; message: string }

export interface MediaAsset {
  id: string
  name: string
  kind: MediaKind
  durationFrames: number
  width?: number
  height?: number
  sourcePath?: string
  createdAt: string
  status: MediaStatus
  accent: 'moss' | 'amber' | 'violet' | 'slate' | 'rose' | 'ocean'
  generated?: boolean
}

export type TrackKind = 'video' | 'audio'

export interface ClipTransform {
  positionX: number
  positionY: number
  scale: number
  rotation: number
  opacity: number
}

export interface TimelineClip {
  id: string
  assetId: string
  name: string
  kind: MediaKind
  trackId: string
  startFrame: number
  durationFrames: number
  sourceOffsetFrames: number
  trimEndFrames: number
  speed: number
  volume: number
  fadeInFrames: number
  fadeOutFrames: number
  transform: ClipTransform
}

export interface TimelineTrack {
  id: string
  name: string
  kind: TrackKind
  muted: boolean
  hidden: boolean
  locked: boolean
  clips: TimelineClip[]
}

export interface ProjectDocument {
  id: string
  name: string
  path?: string
  timelineId: string
  width: number
  height: number
  fps: number
  updatedAt: string
  media: MediaAsset[]
  tracks: TimelineTrack[]
}

export interface RecentProject {
  id: string
  name: string
  path: string
  updatedAt: string
  durationLabel: string
}

export interface ProviderSettings {
  falKey: string
  replicateKey: string
  falConfigured?: boolean
  replicateConfigured?: boolean
  unavailableReason?: string
}

export type GenerationKind = 'video' | 'image' | 'audio'

export interface GenerationRequest {
  projectId: string
  kind: GenerationKind
  model: string
  prompt: string
  aspectRatio: string
  durationSeconds: number
}

export type JobStatus =
  | 'waiting'
  | 'preparing'
  | 'running'
  | 'completed'
  | 'failed'
  | 'canceled'

export interface GenerationJob {
  id: string
  assetId: string
  label: string
  progress: number
  status: JobStatus
  error?: string
}

export type ExportDestination = 'video' | 'timeline' | 'project'

export interface ExportRequest {
  projectId: string
  destination: ExportDestination
  codec: 'H.264' | 'HEVC' | 'ProRes'
  resolution: 'timeline' | '1080p' | '720p'
  timelineFormat: 'FCPXML' | 'XMEML'
}

export interface ExportJob {
  id: string
  filename: string
  progress: number
  status: JobStatus
  createdAt: string
  error?: string
}

export interface BootstrapPayload {
  recentProjects: RecentProject[]
  settings: ProviderSettings
}

export interface ImportCandidate {
  name: string
  type: string
  size: number
  path?: string
}

export type MutationKind =
  | 'addClips'
  | 'moveClips'
  | 'splitClip'
  | 'trimClips'
  | 'removeClips'
  | 'overwrite'
  | 'rippleDelete'
  | 'rippleInsert'
  | 'linkClips'
  | 'unlinkClips'
  | 'addTrack'
  | 'removeTracks'
  | 'reorderTrack'
  | 'updateTrack'
  | 'upsertKeyframe'
  | 'removeKeyframe'
  | 'moveKeyframe'
  | 'setKeyframeInterpolation'
  | 'pasteClips'
  | 'changeProjectSettings'
  | 'undo'
  | 'redo'

export type MutationStatus = 'applied' | 'noOp' | 'undone' | 'redone'

export interface MutationReceipt {
  action: MutationKind
  status: MutationStatus
  revisionBefore: number
  revisionAfter: number
  timelineId: string
  createdClipIds: string[]
  updatedClipIds: string[]
  removedClipIds: string[]
  affectedTrackIds: string[]
  createdTrackIds: string[]
  removedTrackIds: string[]
  skippedIds: string[]
  warnings: string[]
  details: Record<string, unknown>
}

export interface MoveClipRequest {
  clipId: string
  trackId: string
  startFrame: number
}

export interface TrimClipRequest {
  clipId: string
  trimStartFrame: number
  trimEndFrame: number
}

export interface TrackPatch {
  muted?: boolean
  hidden?: boolean
  syncLocked?: boolean
  displayHeight?: number
}

export type AnimatableProperty =
  | 'opacity'
  | 'position'
  | 'scale'
  | 'rotation'
  | 'crop'
  | 'volume'

export type KeyframeValue =
  | number
  | { a: number; b: number }
  | { left: number; top: number; right: number; bottom: number }

export type EditorCommand =
  | {
      command: 'moveClips'
      timelineId: string
      moves: MoveClipRequest[]
    }
  | {
      command: 'splitClip'
      timelineId: string
      clipId: string
      atFrame: number
    }
  | {
      command: 'trimClips'
      timelineId: string
      edits: TrimClipRequest[]
    }
  | {
      command: 'removeClips'
      timelineId: string
      clipIds: string[]
      pruneEmptyTracks?: boolean
    }
  | {
      command: 'updateTrack'
      timelineId: string
      trackId: string
      patch: TrackPatch
    }
  | {
      command: 'upsertKeyframe'
      timelineId: string
      clipId: string
      property: AnimatableProperty
      frame: number
      value: KeyframeValue
    }
  | {
      command: 'changeProjectSettings'
      timelineId: string
      fps: number
      width: number
      height: number
    }
  | {
      command: 'setClipSpeed'
      timelineId: string
      clipIds: string[]
      speed: number
      ripple?: boolean
    }
  | {
      command: 'setClipFades'
      timelineId: string
      clipId: string
      fadeInFrames?: number
      fadeOutFrames?: number
    }
  | {
      command: 'slipClips'
      timelineId: string
      clipId: string
      deltaFrames: number
      propagateToLinked?: boolean
    }
  | { command: 'undo' }
  | { command: 'redo' }

export interface EditRequest {
  projectId: string
  expectedRevision: number
  command: EditorCommand
}

export interface EditResult {
  receipt: MutationReceipt
  project: ProjectDocument
  revision: number
  dirty?: boolean
  undoDepth?: number
  redoDepth?: number
}

export interface PreviewEditResult {
  receipt: MutationReceipt
  project: ProjectDocument
  expectedRevision: number
}

export interface PreviewFrame {
  width: number
  height: number
  mimeType: string
  dataBase64: string
}

export interface BackendAdapter {
  readonly kind: 'tauri' | 'demo'
  bootstrap(): Promise<BootstrapPayload>
  createProject(name: string): Promise<ProjectDocument>
  openProject(path?: string): Promise<ProjectDocument>
  importMedia(projectId: string, files: ImportCandidate[]): Promise<MediaAsset[]>
  persistProject(project: ProjectDocument): Promise<void>
  saveProviderSettings(settings: ProviderSettings): Promise<void>
  startGeneration(request: GenerationRequest): Promise<{
    job: GenerationJob
    asset: MediaAsset
  }>
  listGenerationJobs(projectId: string): Promise<GenerationJob[]>
  startExport(request: ExportRequest): Promise<ExportJob>
  listExportJobs(projectId: string): Promise<ExportJob[]>
  cancelExport(jobId: string): Promise<void>
  previewEdit(request: EditRequest): Promise<PreviewEditResult>
  commitEdit(request: EditRequest): Promise<EditResult>
  renderPreviewFrame(
    projectId: string,
    frame: number,
    maxWidth: number,
    maxHeight: number,
  ): Promise<PreviewFrame | null>
}

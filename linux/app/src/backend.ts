import { applyEditorCommand } from './editCommands'
import type {
  BackendAdapter,
  BootstrapPayload,
  EditRequest,
  EditResult,
  ExportJob,
  ExportRequest,
  GenerationJob,
  GenerationRequest,
  ImportCandidate,
  MediaAsset,
  MediaKind,
  PreviewEditResult,
  PreviewFrame,
  ProjectDocument,
  ProviderSettings,
  TimelineClip,
} from './model'

interface CommandMap {
  editor_bootstrap: {
    args: Record<string, never>
    result: BootstrapPayload
  }
  create_project: {
    args: { name: string }
    result: ProjectDocument
  }
  open_project: {
    args: { path?: string }
    result: ProjectDocument
  }
  import_media: {
    args: { projectId: string; files: ImportCandidate[] }
    result: MediaAsset[]
  }
  import_media_dialog: {
    args: { projectId: string }
    result: MediaAsset[]
  }
  persist_project: {
    args: { project: ProjectDocument }
    result: void
  }
  save_provider_settings: {
    args: { settings: ProviderSettings }
    result: void
  }
  start_generation: {
    args: { request: GenerationRequest }
    result: { job: GenerationJob; asset: MediaAsset }
  }
  list_generation_jobs: {
    args: { projectId: string }
    result: GenerationJob[]
  }
  start_export: {
    args: { request: ExportRequest }
    result: ExportJob
  }
  list_export_jobs: {
    args: { projectId: string }
    result: ExportJob[]
  }
  cancel_export: {
    args: { jobId: string }
    result: void
  }
  preview_edit: {
    args: EditRequest
    result: PreviewEditResult
  }
  commit_edit: {
    args: EditRequest
    result: EditResult
  }
  render_preview_frame: {
    args: {
      projectId: string
      frame: number
      maxWidth: number
      maxHeight: number
    }
    result: PreviewFrame
  }
}

type CommandName = keyof CommandMap

interface TauriWindow extends Window {
  __TAURI_INTERNALS__?: unknown
  __TAURI__?: unknown
}

async function invokeCommand<Name extends CommandName>(
  command: Name,
  args: CommandMap[Name]['args'],
): Promise<CommandMap[Name]['result']> {
  const { invoke } = await import('@tauri-apps/api/core')
  return invoke<CommandMap[Name]['result']>(
    command,
    args as Record<string, unknown>,
  )
}

class TauriBackendAdapter implements BackendAdapter {
  readonly kind = 'tauri' as const

  bootstrap() {
    return invokeCommand('editor_bootstrap', {})
  }

  createProject(name: string) {
    return invokeCommand('create_project', { name })
  }

  openProject(path?: string) {
    return invokeCommand('open_project', { path })
  }

  importMedia(projectId: string, files: ImportCandidate[]) {
    return invokeCommand('import_media', { projectId, files })
  }

  importMediaDialog(projectId: string) {
    return invokeCommand('import_media_dialog', { projectId })
  }

  persistProject(project: ProjectDocument) {
    return invokeCommand('persist_project', { project })
  }

  saveProviderSettings(settings: ProviderSettings) {
    return invokeCommand('save_provider_settings', { settings })
  }

  startGeneration(request: GenerationRequest) {
    return invokeCommand('start_generation', { request })
  }

  listGenerationJobs(projectId: string) {
    return invokeCommand('list_generation_jobs', { projectId })
  }

  startExport(request: ExportRequest) {
    return invokeCommand('start_export', { request })
  }

  listExportJobs(projectId: string) {
    return invokeCommand('list_export_jobs', { projectId })
  }

  cancelExport(jobId: string) {
    return invokeCommand('cancel_export', { jobId })
  }

  previewEdit(request: EditRequest) {
    return invokeCommand('preview_edit', request)
  }

  commitEdit(request: EditRequest) {
    return invokeCommand('commit_edit', request)
  }

  renderPreviewFrame(
    projectId: string,
    frame: number,
    maxWidth: number,
    maxHeight: number,
  ) {
    return invokeCommand('render_preview_frame', {
      projectId,
      frame,
      maxWidth,
      maxHeight,
    })
  }
}

interface TimedJob<T> {
  value: T
  startedAt: number
}

export interface DemoBackendOptions {
  latencyMs?: number
  now?: () => number
}

const DEMO_DATE = '2026-08-09T01:31:00.000Z'

function ready(): MediaAsset['status'] {
  return { kind: 'ready' }
}

function demoAsset(
  id: string,
  name: string,
  kind: MediaKind,
  durationFrames: number,
  accent: MediaAsset['accent'],
): MediaAsset {
  return {
    id,
    name,
    kind,
    durationFrames,
    width: kind === 'audio' ? undefined : 3840,
    height: kind === 'audio' ? undefined : 2160,
    sourcePath: `/Demo media/${name}`,
    createdAt: DEMO_DATE,
    status: ready(),
    accent,
  }
}

function demoClip(
  clip: Omit<
    TimelineClip,
    'trimEndFrames' | 'fadeInFrames' | 'fadeOutFrames'
  > &
    Partial<
      Pick<TimelineClip, 'trimEndFrames' | 'fadeInFrames' | 'fadeOutFrames'>
    >,
): TimelineClip {
  return {
    trimEndFrames: 0,
    fadeInFrames: 0,
    fadeOutFrames: 0,
    ...clip,
  }
}

export function createDemoProject(name = 'Aesthetic video'): ProjectDocument {
  const media = [
    demoAsset('asset-ferns', 'fern_closeup.mov', 'video', 180, 'moss'),
    demoAsset('asset-eye', 'eye_macro.mov', 'video', 150, 'amber'),
    demoAsset('asset-scan', 'film_scan_04.mov', 'video', 210, 'slate'),
    demoAsset('asset-dancer', 'dancer_motion.mov', 'video', 240, 'violet'),
    demoAsset('asset-street', 'street_night.mov', 'video', 195, 'ocean'),
    demoAsset('asset-still', 'title_plate.png', 'image', 120, 'rose'),
    demoAsset('asset-score', 'ambient_score.wav', 'audio', 810, 'moss'),
    {
      ...demoAsset('asset-offline', 'archive_insert.mov', 'video', 120, 'slate'),
      status: {
        kind: 'offline' as const,
        reason: 'The source file is not available',
      },
    },
  ]

  return {
    id: 'project-aesthetic',
    name,
    path: `/Projects/${name.replaceAll(' ', '-')}.palmier`,
    timelineId: 'timeline-main',
    width: 1920,
    height: 1080,
    fps: 30,
    updatedAt: DEMO_DATE,
    media,
    tracks: [
      {
        id: 'track-v1',
        name: 'V1',
        kind: 'video',
        muted: false,
        hidden: false,
        locked: false,
        clips: [
          demoClip({
            id: 'clip-ferns',
            assetId: 'asset-ferns',
            name: 'fern_closeup',
            kind: 'video',
            trackId: 'track-v1',
            startFrame: 0,
            durationFrames: 90,
            sourceOffsetFrames: 0,
            speed: 1,
            volume: 1,
            transform: {
              positionX: 0,
              positionY: 0,
              scale: 100,
              rotation: 0,
              opacity: 100,
            },
          }),
          demoClip({
            id: 'clip-eye',
            assetId: 'asset-eye',
            name: 'eye_macro',
            kind: 'video',
            trackId: 'track-v1',
            startFrame: 90,
            durationFrames: 105,
            sourceOffsetFrames: 12,
            speed: 1,
            volume: 1,
            transform: {
              positionX: 0,
              positionY: 0,
              scale: 100,
              rotation: 0,
              opacity: 100,
            },
          }),
          demoClip({
            id: 'clip-dancer',
            assetId: 'asset-dancer',
            name: 'dancer_motion',
            kind: 'video',
            trackId: 'track-v1',
            startFrame: 195,
            durationFrames: 150,
            sourceOffsetFrames: 18,
            speed: 1,
            volume: 1,
            transform: {
              positionX: 0,
              positionY: 0,
              scale: 100,
              rotation: 0,
              opacity: 100,
            },
          }),
          demoClip({
            id: 'clip-street',
            assetId: 'asset-street',
            name: 'street_night',
            kind: 'video',
            trackId: 'track-v1',
            startFrame: 345,
            durationFrames: 135,
            sourceOffsetFrames: 0,
            speed: 1,
            volume: 1,
            transform: {
              positionX: 0,
              positionY: 0,
              scale: 100,
              rotation: 0,
              opacity: 100,
            },
          }),
        ],
      },
      {
        id: 'track-v2',
        name: 'V2',
        kind: 'video',
        muted: false,
        hidden: false,
        locked: false,
        clips: [
          demoClip({
            id: 'clip-title',
            assetId: 'asset-still',
            name: 'palmier title',
            kind: 'image',
            trackId: 'track-v2',
            startFrame: 42,
            durationFrames: 210,
            sourceOffsetFrames: 0,
            speed: 1,
            volume: 1,
            transform: {
              positionX: 0,
              positionY: 8,
              scale: 88,
              rotation: 0,
              opacity: 100,
            },
          }),
        ],
      },
      {
        id: 'track-a1',
        name: 'A1',
        kind: 'audio',
        muted: false,
        hidden: false,
        locked: false,
        clips: [
          demoClip({
            id: 'clip-score',
            assetId: 'asset-score',
            name: 'ambient_score',
            kind: 'audio',
            trackId: 'track-a1',
            startFrame: 0,
            durationFrames: 540,
            sourceOffsetFrames: 0,
            speed: 1,
            volume: 0.82,
            transform: {
              positionX: 0,
              positionY: 0,
              scale: 100,
              rotation: 0,
              opacity: 100,
            },
          }),
        ],
      },
    ],
  }
}

function inferKind(candidate: ImportCandidate): MediaKind {
  if (candidate.type.startsWith('audio/')) return 'audio'
  if (candidate.type.startsWith('image/')) return 'image'
  const extension = candidate.name.split('.').pop()?.toLowerCase()
  if (['wav', 'mp3', 'aac', 'flac'].includes(extension ?? '')) return 'audio'
  if (['png', 'jpg', 'jpeg', 'webp'].includes(extension ?? '')) return 'image'
  return 'video'
}

function cloneProject(project: ProjectDocument): ProjectDocument {
  return JSON.parse(JSON.stringify(project)) as ProjectDocument
}

interface DemoProjectState {
  project: ProjectDocument
  revision: number
  past: ProjectDocument[]
  future: ProjectDocument[]
}

export function createDemoBackend(
  options: DemoBackendOptions = {},
): BackendAdapter {
  const latencyMs = options.latencyMs ?? 80
  const now = options.now ?? Date.now
  let importCounter = 0
  let generationCounter = 0
  let exportCounter = 0
  const generationJobs = new Map<string, TimedJob<GenerationJob>>()
  const exportJobs = new Map<string, TimedJob<ExportJob>>()
  const projects = new Map<string, DemoProjectState>()

  const wait = async () => {
    if (latencyMs <= 0) return
    await new Promise<void>((resolve) => {
      window.setTimeout(resolve, latencyMs)
    })
  }

  const storeProject = (project: ProjectDocument): ProjectDocument => {
    const stored = cloneProject(project)
    projects.set(stored.id, {
      project: stored,
      revision: 0,
      past: [],
      future: [],
    })
    return cloneProject(stored)
  }

  const requireProject = (projectId: string, expectedRevision: number) => {
    const state = projects.get(projectId)
    if (!state) {
      throw new Error(`Unknown project: ${projectId}`)
    }
    if (state.revision !== expectedRevision) {
      throw new Error(
        `Revision mismatch: expected ${expectedRevision}, actual ${state.revision}`,
      )
    }
    return state
  }

  return {
    kind: 'demo',

    async bootstrap() {
      await wait()
      return {
        recentProjects: [
          {
            id: 'recent-aesthetic',
            name: 'Aesthetic video',
            path: '/Projects/Aesthetic-video.palmier',
            updatedAt: DEMO_DATE,
            durationLabel: '18 sec',
          },
          {
            id: 'recent-campaign',
            name: 'Summer campaign',
            path: '/Projects/Summer-campaign.palmier',
            updatedAt: '2026-08-08T18:24:00.000Z',
            durationLabel: '42 sec',
          },
          {
            id: 'recent-product',
            name: 'Product story',
            path: '/Projects/Product-story.palmier',
            updatedAt: '2026-08-07T15:10:00.000Z',
            durationLabel: '1 min 08 sec',
          },
        ],
        settings: { falKey: '', replicateKey: '' },
      }
    },

    async createProject(name) {
      await wait()
      return storeProject(createDemoProject(name))
    },

    async openProject() {
      await wait()
      return storeProject(createDemoProject())
    },

    async importMedia(_projectId, files) {
      await wait()
      const candidates =
        files.length > 0
          ? files
          : [
              {
                name: 'imported_take.mov',
                type: 'video/quicktime',
                size: 24_000_000,
              },
            ]
      return candidates.map((candidate, index) => {
        importCounter += 1
        const kind = inferKind(candidate)
        const id = `asset-import-${importCounter}`
        return {
          id,
          name: candidate.name,
          kind,
          durationFrames: kind === 'image' ? 120 : 150 + index * 30,
          width: kind === 'audio' ? undefined : 1920,
          height: kind === 'audio' ? undefined : 1080,
          sourcePath: candidate.path ?? `/Imported/${candidate.name}`,
          createdAt: new Date(now()).toISOString(),
          status: ready(),
          accent: ['moss', 'amber', 'ocean', 'rose'][index % 4] as MediaAsset['accent'],
        }
      })
    },

    async persistProject() {
      await wait()
    },

    async saveProviderSettings() {
      await wait()
    },

    async startGeneration(request) {
      await wait()
      generationCounter += 1
      const id = `generation-${generationCounter}`
      const assetId = `asset-${id}`
      const label = `Generating with ${request.model}`
      const job: GenerationJob = {
        id,
        assetId,
        label,
        progress: 0,
        status: 'preparing',
      }
      generationJobs.set(id, { value: job, startedAt: now() })
      return {
        job,
        asset: {
          id: assetId,
          name: `${request.kind}_${generationCounter}`,
          kind: request.kind,
          durationFrames:
            request.kind === 'image'
              ? 120
              : request.durationSeconds * 30,
          width: request.kind === 'audio' ? undefined : 1920,
          height: request.kind === 'audio' ? undefined : 1080,
          createdAt: new Date(now()).toISOString(),
          status: { kind: 'generating', progress: 0, label },
          accent: 'violet',
          generated: true,
        },
      }
    },

    async listGenerationJobs() {
      await wait()
      return [...generationJobs.values()].map((timed) => {
        if (
          timed.value.status === 'failed' ||
          timed.value.status === 'canceled'
        ) {
          return { ...timed.value }
        }
        const elapsed = Math.max(0, now() - timed.startedAt)
        const progress = Math.min(1, elapsed / 2400)
        const status: GenerationJob['status'] =
          progress >= 1 ? 'completed' : progress < 0.12 ? 'preparing' : 'running'
        timed.value = { ...timed.value, progress, status }
        return { ...timed.value }
      })
    },

    async startExport(request) {
      await wait()
      exportCounter += 1
      const extension =
        request.destination === 'timeline'
          ? request.timelineFormat.toLowerCase()
          : request.destination === 'project'
            ? 'palmier'
            : request.codec === 'ProRes'
              ? 'mov'
              : 'mp4'
      const job: ExportJob = {
        id: `export-${exportCounter}`,
        filename: `Aesthetic-video-${exportCounter}.${extension}`,
        progress: 0,
        status: 'waiting',
        createdAt: new Date(now()).toISOString(),
      }
      exportJobs.set(job.id, { value: job, startedAt: now() })
      return { ...job }
    },

    async listExportJobs() {
      await wait()
      return [...exportJobs.values()].map((timed) => {
        if (
          timed.value.status === 'failed' ||
          timed.value.status === 'canceled'
        ) {
          return { ...timed.value }
        }
        const elapsed = Math.max(0, now() - timed.startedAt)
        const progress = Math.min(1, elapsed / 3600)
        const status: ExportJob['status'] =
          progress >= 1 ? 'completed' : progress < 0.1 ? 'preparing' : 'running'
        timed.value = { ...timed.value, progress, status }
        return { ...timed.value }
      })
    },

    async cancelExport(jobId) {
      await wait()
      const timed = exportJobs.get(jobId)
      if (timed) {
        timed.value = { ...timed.value, status: 'canceled' }
      }
    },

    async renderPreviewFrame() {
      await wait()
      return null
    },

    async previewEdit(request) {
      await wait()
      const state = requireProject(request.projectId, request.expectedRevision)
      const preview = applyEditorCommand(
        state.project,
        state.revision,
        request.command,
      )
      return {
        receipt: preview.receipt,
        project: cloneProject(preview.project),
        expectedRevision: request.expectedRevision,
      }
    },

    async commitEdit(request) {
      await wait()
      const state = requireProject(request.projectId, request.expectedRevision)
      if (request.command.command === 'undo') {
        const previous = state.past.at(-1)
        if (!previous) {
          return {
            receipt: {
              action: 'undo',
              status: 'noOp',
              revisionBefore: state.revision,
              revisionAfter: state.revision,
              timelineId: state.project.timelineId,
              createdClipIds: [],
              updatedClipIds: [],
              removedClipIds: [],
              affectedTrackIds: [],
              createdTrackIds: [],
              removedTrackIds: [],
              skippedIds: [],
              warnings: [],
              details: {},
            },
            project: cloneProject(state.project),
            revision: state.revision,
            dirty: true,
            undoDepth: state.past.length,
            redoDepth: state.future.length,
          }
        }
        state.future = [cloneProject(state.project), ...state.future]
        state.past = state.past.slice(0, -1)
        state.project = cloneProject(previous)
        state.revision += 1
        return {
          receipt: {
            action: 'undo',
            status: 'undone',
            revisionBefore: state.revision - 1,
            revisionAfter: state.revision,
            timelineId: state.project.timelineId,
            createdClipIds: [],
            updatedClipIds: [],
            removedClipIds: [],
            affectedTrackIds: [],
            createdTrackIds: [],
            removedTrackIds: [],
            skippedIds: [],
            warnings: [],
            details: {},
          },
          project: cloneProject(state.project),
          revision: state.revision,
          dirty: true,
          undoDepth: state.past.length,
          redoDepth: state.future.length,
        }
      }
      if (request.command.command === 'redo') {
        const next = state.future[0]
        if (!next) {
          return {
            receipt: {
              action: 'redo',
              status: 'noOp',
              revisionBefore: state.revision,
              revisionAfter: state.revision,
              timelineId: state.project.timelineId,
              createdClipIds: [],
              updatedClipIds: [],
              removedClipIds: [],
              affectedTrackIds: [],
              createdTrackIds: [],
              removedTrackIds: [],
              skippedIds: [],
              warnings: [],
              details: {},
            },
            project: cloneProject(state.project),
            revision: state.revision,
            dirty: true,
            undoDepth: state.past.length,
            redoDepth: state.future.length,
          }
        }
        state.past = [...state.past, cloneProject(state.project)]
        state.future = state.future.slice(1)
        state.project = cloneProject(next)
        state.revision += 1
        return {
          receipt: {
            action: 'redo',
            status: 'redone',
            revisionBefore: state.revision - 1,
            revisionAfter: state.revision,
            timelineId: state.project.timelineId,
            createdClipIds: [],
            updatedClipIds: [],
            removedClipIds: [],
            affectedTrackIds: [],
            createdTrackIds: [],
            removedTrackIds: [],
            skippedIds: [],
            warnings: [],
            details: {},
          },
          project: cloneProject(state.project),
          revision: state.revision,
          dirty: true,
          undoDepth: state.past.length,
          redoDepth: state.future.length,
        }
      }

      const before = cloneProject(state.project)
      const applied = applyEditorCommand(
        state.project,
        state.revision,
        request.command,
      )
      if (applied.receipt.status === 'applied') {
        state.past = [...state.past.slice(-39), before]
        state.future = []
      }
      state.project = applied.project
      state.revision = applied.revision
      return {
        receipt: applied.receipt,
        project: cloneProject(state.project),
        revision: state.revision,
        dirty: true,
        undoDepth: state.past.length,
        redoDepth: state.future.length,
      }
    },
  }
}

function hasTauriRuntime(): boolean {
  if (typeof window === 'undefined') return false
  const candidate = window as TauriWindow
  return Boolean(candidate.__TAURI_INTERNALS__ ?? candidate.__TAURI__)
}

export function createBackendAdapter(): BackendAdapter {
  return hasTauriRuntime()
    ? new TauriBackendAdapter()
    : createDemoBackend()
}

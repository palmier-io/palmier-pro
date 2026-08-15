/**
 * Hand-written command surface for the Tauri backend.
 *
 * Specta / tauri-specta were skipped: workspace specta is 2.0.0-rc.22 while
 * current tauri-specta wants specta 2.0.0-rc.26+. Keep this file aligned with
 * `linux/app/src-tauri/src/commands.rs` and `src/backend.ts` CommandMap.
 */

import type {
  BootstrapPayload,
  ExportJob,
  ExportRequest,
  GenerationJob,
  GenerationRequest,
  ImportCandidate,
  MediaAsset,
  PreviewFrame,
  PreviewAudio,
  ProjectDocument,
  ProviderSettings,
  EditResult,
} from '../model'

export type CommandMap = {
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
  commit_edit: {
    args: {
      projectId: string
      expectedRevision: number
      command: unknown
    }
    result: unknown
  }
  preview_edit: {
    args: {
      projectId: string
      expectedRevision: number
      command: unknown
    }
    result: unknown
  }
  get_project: {
    args: { projectId: string }
    result: ProjectDocument
  }
  close_project: {
    args: { projectId: string }
    result: void
  }
  decode_preview_frame: {
    args: {
      path: string
      timeSeconds?: number | null
      maxWidth?: number | null
      maxHeight?: number | null
    }
    result: {
      width: number
      height: number
      mimeType: string
      dataBase64: string
    }
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
  place_asset: {
    args: {
      projectId: string
      expectedRevision: number
      assetId: string
      trackId?: string
      startFrame: number
    }
    result: EditResult
  }
  decode_asset_preview: {
    args: {
      projectId: string
      assetId: string
      timeSeconds?: number | null
      maxWidth?: number | null
      maxHeight?: number | null
    }
    result: PreviewFrame
  }
  render_preview_audio: {
    args: {
      projectId: string
      startFrame: number
      frameCount: number
    }
    result: PreviewAudio
  }
  decode_asset_audio: {
    args: {
      projectId: string
      assetId: string
      timeSeconds?: number | null
      durationSeconds?: number | null
    }
    result: PreviewAudio
  }
}

export type CommandName = keyof CommandMap

export const commandNames = [
  'editor_bootstrap',
  'create_project',
  'open_project',
  'import_media',
  'import_media_dialog',
  'persist_project',
  'save_provider_settings',
  'start_generation',
  'list_generation_jobs',
  'start_export',
  'list_export_jobs',
  'cancel_export',
  'commit_edit',
  'preview_edit',
  'get_project',
  'close_project',
  'decode_preview_frame',
  'decode_asset_preview',
  'render_preview_frame',
  'render_preview_audio',
  'decode_asset_audio',
  'place_asset',
] as const satisfies readonly CommandName[]

import {
  ArrowLeft,
  Check,
  Columns3,
  Download,
  PanelLeft,
  PanelRight,
  Save,
  Settings,
} from 'lucide-react'
import { useEffect } from 'react'
import { InspectorPanel } from './InspectorPanel'
import { MediaPanel } from './MediaPanel'
import { PreviewPanel } from './PreviewPanel'
import { TimelinePanel } from './TimelinePanel'
import { useEditor } from './editorState'
import { UserText, useI18n } from './i18n'
import type { LayoutPreset, PanelId } from './model'
import { BrandMark, IconButton } from './ui'

function isEditableTarget(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false
  if (target.isContentEditable) return true
  return Boolean(target.closest('input, textarea, select, [contenteditable="true"]'))
}

function ProjectTitle() {
  const { state } = useEditor()
  const { t } = useI18n()
  if (!state.project) return null
  return (
    <div className="titlebar-project" data-tauri-drag-region>
      <UserText>{state.project.name}</UserText>
      {state.dirty ? (
        <span
          className="dirty-indicator"
          aria-label={t('unsavedChanges')}
        />
      ) : (
        <Check aria-label={t('saved')} />
      )}
    </div>
  )
}

function LayoutPicker() {
  const { state, dispatch } = useEditor()
  const { t } = useI18n()
  return (
    <label className="layout-picker">
      <Columns3 aria-hidden="true" />
      <span className="visually-hidden">{t('layout')}</span>
      <select
        value={state.layout}
        onChange={(event) =>
          dispatch({
            type: 'SET_LAYOUT',
            layout: event.target.value as LayoutPreset,
          })
        }
        aria-label={t('layout')}
      >
        <option value="default">{t('defaultLayout')}</option>
        <option value="media">{t('mediaLayout')}</option>
        <option value="vertical">{t('verticalLayout')}</option>
      </select>
    </label>
  )
}

function EditorTitleBar() {
  const { state, dispatch, saveProject } = useEditor()
  const { t } = useI18n()
  const hasActiveExport = state.exportJobs.some((job) =>
    ['waiting', 'preparing', 'running'].includes(job.status),
  )

  return (
    <header className="editor-titlebar" data-tauri-drag-region>
      <div className="titlebar-leading">
        <IconButton
          icon={ArrowLeft}
          label={t('backHome')}
          onClick={() => dispatch({ type: 'GO_HOME' })}
        />
        <BrandMark compact />
        <span className="titlebar-divider" aria-hidden="true" />
        <IconButton
          icon={PanelLeft}
          label={
            state.panelVisibility.media
              ? t('hideMediaPanel')
              : t('showMediaPanel')
          }
          active={state.panelVisibility.media}
          onClick={() => dispatch({ type: 'TOGGLE_PANEL', panel: 'media' })}
        />
        <IconButton
          icon={PanelRight}
          label={
            state.panelVisibility.inspector
              ? t('hideInspectorPanel')
              : t('showInspectorPanel')
          }
          active={state.panelVisibility.inspector}
          onClick={() =>
            dispatch({ type: 'TOGGLE_PANEL', panel: 'inspector' })
          }
        />
        <LayoutPicker />
      </div>
      <ProjectTitle />
      <div className="titlebar-trailing">
        <IconButton
          icon={Save}
          label={t('saveProject')}
          disabled={!state.dirty}
          onClick={() => void saveProject()}
        />
        <button
          type="button"
          className="titlebar-action"
          onClick={() =>
            dispatch({ type: 'SET_DIALOG', dialog: 'export', open: true })
          }
        >
          <span className="titlebar-action-icon">
            <Download aria-hidden="true" />
            {hasActiveExport ? (
              <i className="activity-dot" aria-hidden="true" />
            ) : null}
          </span>
          {t('export')}
        </button>
        <IconButton
          icon={Settings}
          label={t('settings')}
          onClick={() =>
            dispatch({ type: 'SET_DIALOG', dialog: 'settings', open: true })
          }
        />
        <span className="user-avatar" aria-label={t('user')}>
          B
        </span>
      </div>
    </header>
  )
}

function shouldRenderPanel(
  panel: PanelId,
  maximized: PanelId | null,
  mediaVisible: boolean,
  inspectorVisible: boolean,
): boolean {
  if (maximized) return maximized === panel
  if (panel === 'media') return mediaVisible
  if (panel === 'inspector') return inspectorVisible
  return true
}

function useEditorShortcuts() {
  const { state, dispatch } = useEditor()

  useEffect(() => {
    const handleKeyDown = (event: globalThis.KeyboardEvent) => {
      if (isEditableTarget(event.target)) return
      const modifier = event.metaKey || event.ctrlKey
      const key = event.key.toLowerCase()

      if (modifier && key === 'z') {
        event.preventDefault()
        dispatch({ type: event.shiftKey ? 'REDO' : 'UNDO' })
        return
      }
      if (modifier && key === 'k') {
        event.preventDefault()
        dispatch({ type: 'SPLIT_AT_PLAYHEAD' })
        return
      }
      if (modifier && key === 'e') {
        event.preventDefault()
        dispatch({ type: 'SET_DIALOG', dialog: 'export', open: true })
        return
      }
      if (modifier && ['1', '2', '3'].includes(key)) {
        event.preventDefault()
        const layouts: Record<string, LayoutPreset> = {
          '1': 'default',
          '2': 'media',
          '3': 'vertical',
        }
        const layout = layouts[key]
        if (layout) dispatch({ type: 'SET_LAYOUT', layout })
        return
      }
      if (key === 'escape') {
        if (state.openDialogs.length > 0) {
          const dialog = state.openDialogs.at(-1)
          if (dialog) {
            dispatch({ type: 'SET_DIALOG', dialog, open: false })
          }
        } else if (state.maximizedPanel) {
          dispatch({
            type: 'TOGGLE_MAXIMIZE',
            panel: state.maximizedPanel,
          })
        }
        return
      }
      if (event.key === 'Delete' || event.key === 'Backspace') {
        event.preventDefault()
        dispatch({ type: 'DELETE_SELECTION' })
        return
      }
      if (event.key === ' ') {
        event.preventDefault()
        dispatch({ type: 'TOGGLE_PLAYBACK' })
        return
      }
      if (key === 'arrowleft' || key === 'arrowright') {
        event.preventDefault()
        dispatch({
          type: 'SET_ACTIVE_FRAME',
          frame: state.activeFrame + (key === 'arrowleft' ? -1 : 1),
        })
        return
      }
      if (key === 'f') {
        event.preventDefault()
        dispatch({
          type: 'TOGGLE_MAXIMIZE',
          panel: state.focusedPanel,
        })
        return
      }
      const tools = {
        v: 'pointer',
        c: 'razor',
        t: 'trim',
      } as const
      const mode = tools[key as keyof typeof tools]
      if (mode) {
        event.preventDefault()
        dispatch({ type: 'SET_TOOL_MODE', mode })
      }
    }

    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [
    dispatch,
    state.activeFrame,
    state.focusedPanel,
    state.maximizedPanel,
    state.openDialogs,
  ])
}

export function EditorShell() {
  const { state } = useEditor()
  useEditorShortcuts()

  const media = shouldRenderPanel(
    'media',
    state.maximizedPanel,
    state.panelVisibility.media,
    state.panelVisibility.inspector,
  )
  const preview = shouldRenderPanel(
    'preview',
    state.maximizedPanel,
    state.panelVisibility.media,
    state.panelVisibility.inspector,
  )
  const inspector = shouldRenderPanel(
    'inspector',
    state.maximizedPanel,
    state.panelVisibility.media,
    state.panelVisibility.inspector,
  )
  const timeline = shouldRenderPanel(
    'timeline',
    state.maximizedPanel,
    state.panelVisibility.media,
    state.panelVisibility.inspector,
  )

  return (
    <main className="editor-shell">
      <EditorTitleBar />
      <div
        className={`editor-workspace layout-${state.layout}${
          state.maximizedPanel ? ' is-maximized' : ''
        }`}
        data-media-visible={media}
        data-inspector-visible={inspector}
        data-maximized={state.maximizedPanel ?? 'none'}
      >
        {media ? <MediaPanel /> : null}
        {preview ? <PreviewPanel /> : null}
        {inspector ? <InspectorPanel /> : null}
        {timeline ? <TimelinePanel /> : null}
      </div>
    </main>
  )
}

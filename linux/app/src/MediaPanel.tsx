import {
  AudioLines,
  Bot,
  Film,
  Grid2X2,
  Image,
  Import,
  List,
  RefreshCw,
  Search,
  Sparkles,
  UploadCloud,
} from 'lucide-react'
import {
  useMemo,
  useRef,
  useState,
  type CSSProperties,
  type DragEvent,
  type FormEvent,
} from 'react'
import { useEditor } from './editorState'
import { writeAssetDrag } from './assetDrag'
import { UserText, useI18n } from './i18n'
import type { GenerationKind, MediaAsset } from './model'
import { IconButton, Panel, Spinner } from './ui'

type ProgressStyle = CSSProperties & {
  '--progress': string
}

const models: Record<GenerationKind, string[]> = {
  video: ['Kling 2.1', 'Seedance 1.0', 'Veo 3'],
  image: ['Flux Pro', 'Ideogram 3', 'Recraft V3'],
  audio: ['MusicGen', 'Eleven Music', 'Stable Audio'],
}

const emptyMedia: MediaAsset[] = []

function AssetIcon({ asset }: { asset: MediaAsset }) {
  if (asset.kind === 'audio') return <AudioLines aria-hidden="true" />
  if (asset.kind === 'image') return <Image aria-hidden="true" />
  return <Film aria-hidden="true" />
}

function AssetStatus({ asset }: { asset: MediaAsset }) {
  const { t } = useI18n()
  if (asset.status.kind === 'ready') return null

  if (
    asset.status.kind === 'importing' ||
    asset.status.kind === 'generating'
  ) {
    const label =
      asset.status.kind === 'generating'
        ? asset.status.label
        : t('importingMedia')
    return (
      <span className="asset-status asset-status-progress">
        <Spinner />
        <span>{label}</span>
        <span
          className="asset-progress"
          style={
            {
              '--progress': `${Math.round(asset.status.progress * 100)}%`,
            } as ProgressStyle
          }
        />
      </span>
    )
  }

  return (
    <span
      className={`asset-status asset-status-${asset.status.kind}`}
      title={
        asset.status.kind === 'offline'
          ? asset.status.reason
          : asset.status.message
      }
    >
      {asset.status.kind === 'offline' ? t('sourceOffline') : t('failed')}
    </span>
  )
}

function AssetCard({
  asset,
  selected,
  list,
}: {
  asset: MediaAsset
  selected: boolean
  list: boolean
}) {
  const { dispatch, relinkAsset } = useEditor()
  const { t } = useI18n()

  const beginDrag = (event: DragEvent<HTMLButtonElement>) => {
    writeAssetDrag(event.dataTransfer, asset.id)
  }

  return (
    <button
      type="button"
      className={`asset-card${selected ? ' is-selected' : ''}${
        list ? ' is-list' : ''
      }`}
      draggable
      onDragStart={beginDrag}
      onClick={(event) =>
        dispatch({
          type: 'SELECT_ASSET',
          assetId: asset.id,
          additive: event.metaKey || event.ctrlKey || event.shiftKey,
        })
      }
      onDoubleClick={() =>
        dispatch({ type: 'SET_PREVIEW_ASSET', assetId: asset.id })
      }
      aria-pressed={selected}
      aria-label={asset.name}
    >
      <span
        className={`asset-art media-accent-${asset.accent}`}
        aria-hidden="true"
      >
        <AssetIcon asset={asset} />
        {asset.kind === 'audio' ? (
          <span className="asset-waveform">
            {Array.from({ length: 18 }, (_, index) => (
              <i key={index} />
            ))}
          </span>
        ) : null}
      </span>
      <span className="asset-card-copy">
        <UserText title={asset.name}>{asset.name}</UserText>
        <small>
          {asset.kind.toUpperCase()}
          {asset.generated ? ` · ${t('generatedMedia')}` : ''}
        </small>
      </span>
      <AssetStatus asset={asset} />
      {asset.status.kind === 'offline' ? (
        <span
          className="asset-relink"
          role="button"
          tabIndex={0}
          onClick={(event) => {
            event.stopPropagation()
            relinkAsset(asset.id)
          }}
          onKeyDown={(event) => {
            if (event.key === 'Enter') relinkAsset(asset.id)
          }}
        >
          <RefreshCw aria-hidden="true" />
          {t('relink')}
        </span>
      ) : null}
    </button>
  )
}

function GenerationForm() {
  const { state, startGeneration } = useEditor()
  const { t } = useI18n()
  const [kind, setKind] = useState<GenerationKind>('video')
  const [model, setModel] = useState(models.video[0] ?? '')
  const [prompt, setPrompt] = useState('')
  const [aspectRatio, setAspectRatio] = useState('16:9')
  const [durationSeconds, setDurationSeconds] = useState(5)
  const [validationError, setValidationError] = useState<string | null>(null)

  const submit = (event: FormEvent) => {
    event.preventDefault()
    if (!prompt.trim()) {
      setValidationError(t('generationNeedsPrompt'))
      return
    }
    setValidationError(null)
    void startGeneration({
      kind,
      model,
      prompt: prompt.trim(),
      aspectRatio,
      durationSeconds,
    })
    setPrompt('')
  }

  const activeJobs = state.generationJobs.filter((job) =>
    ['waiting', 'preparing', 'running'].includes(job.status),
  )

  return (
    <div className="generation-panel">
      <div className="generation-heading">
        <span className="generation-glyph">
          <Sparkles aria-hidden="true" />
        </span>
        <div>
          <h3>{t('generation')}</h3>
          <p>{t('generationDescription')}</p>
        </div>
      </div>

      {activeJobs.length > 0 ? (
        <div className="generation-jobs" aria-live="polite">
          {activeJobs.map((job) => (
            <div className="generation-job" key={job.id}>
              <Spinner />
              <span>{job.label}</span>
              <strong>{Math.round(job.progress * 100)}%</strong>
              <span
                className="generation-job-progress"
                style={
                  {
                    '--progress': `${Math.round(job.progress * 100)}%`,
                  } as ProgressStyle
                }
              />
            </div>
          ))}
        </div>
      ) : null}

      {state.settings.unavailableReason ? (
        <p className="form-error" role="alert">
          {t('generationUnavailable')}{' '}
          <UserText>{state.settings.unavailableReason}</UserText>
        </p>
      ) : null}

      <form className="generation-form" onSubmit={submit}>
        <div className="segmented-control generation-kinds">
          {(['video', 'image', 'audio'] as const).map((option) => (
            <button
              type="button"
              key={option}
              className={kind === option ? 'is-selected' : ''}
              onClick={() => {
                setKind(option)
                setModel(models[option][0] ?? '')
              }}
              aria-pressed={kind === option}
            >
              {t(option)}
            </button>
          ))}
        </div>

        <label className="field-stack">
          <span>{t('prompt')}</span>
          <textarea
            value={prompt}
            onChange={(event) => setPrompt(event.target.value)}
            placeholder={t('promptPlaceholder')}
            rows={5}
          />
        </label>

        <div className="form-columns">
          <label className="field-stack">
            <span>{t('model')}</span>
            <select
              value={model}
              onChange={(event) => setModel(event.target.value)}
            >
              {models[kind].map((candidate) => (
                <option key={candidate}>{candidate}</option>
              ))}
            </select>
          </label>
          <label className="field-stack">
            <span>{t('aspectRatio')}</span>
            <select
              value={aspectRatio}
              onChange={(event) => setAspectRatio(event.target.value)}
              disabled={kind === 'audio'}
            >
              <option>16:9</option>
              <option>9:16</option>
              <option>1:1</option>
              <option>4:3</option>
            </select>
          </label>
        </div>

        {kind !== 'image' ? (
          <label className="field-stack">
            <span>{t('generationDuration')}</span>
            <select
              value={durationSeconds}
              onChange={(event) =>
                setDurationSeconds(Number(event.target.value))
              }
            >
              <option value={5}>{t('secondsShort', { value: 5 })}</option>
              <option value={10}>{t('secondsShort', { value: 10 })}</option>
              <option value={15}>{t('secondsShort', { value: 15 })}</option>
            </select>
          </label>
        ) : null}

        {validationError ? (
          <p className="form-error" role="alert">
            {validationError}
          </p>
        ) : null}

        <button
          type="submit"
          className="button-primary generation-submit"
          disabled={
            !state.isOnline ||
            Boolean(state.operationLabel) ||
            Boolean(state.settings.unavailableReason)
          }
        >
          <Bot aria-hidden="true" />
          {t('startGeneration')}
        </button>
      </form>
    </div>
  )
}

export function MediaPanel() {
  const { state, dispatch, importFiles, importFromDialog, backend } = useEditor()
  const { t } = useI18n()
  const inputRef = useRef<HTMLInputElement>(null)
  const [dropActive, setDropActive] = useState(false)

  const media = state.project?.media ?? emptyMedia
  const filtered = useMemo(() => {
    const query = state.mediaQuery.trim().toLocaleLowerCase()
    if (!query) return media
    return media.filter((asset) =>
      asset.name.toLocaleLowerCase().includes(query),
    )
  }, [media, state.mediaQuery])

  const receiveDrop = (event: DragEvent) => {
    event.preventDefault()
    setDropActive(false)
    if (!event.dataTransfer.types.includes('Files')) return
    const files = [...event.dataTransfer.files]
    if (files.length > 0) {
      void importFiles(files)
      return
    }
  }

  const header = (
    <div className="panel-tabs" role="tablist">
      <button
        type="button"
        role="tab"
        aria-selected={state.mediaTab === 'library'}
        className={state.mediaTab === 'library' ? 'is-active' : ''}
        onClick={() => dispatch({ type: 'SET_MEDIA_TAB', tab: 'library' })}
      >
        {t('media')}
      </button>
      <button
        type="button"
        role="tab"
        aria-selected={state.mediaTab === 'generate'}
        className={state.mediaTab === 'generate' ? 'is-active' : ''}
        onClick={() => dispatch({ type: 'SET_MEDIA_TAB', tab: 'generate' })}
      >
        <Sparkles aria-hidden="true" />
        {t('generate')}
      </button>
    </div>
  )

  const actions =
    state.mediaTab === 'library' ? (
      <>
        <IconButton
          compact
          icon={Import}
          label={t('import')}
          onClick={() => {
            if (backend.kind === 'tauri') {
              void importFromDialog()
              return
            }
            inputRef.current?.click()
          }}
        />
        <IconButton
          compact
          icon={state.mediaViewMode === 'grid' ? List : Grid2X2}
          label={
            state.mediaViewMode === 'grid' ? t('listView') : t('gridView')
          }
          onClick={() =>
            dispatch({
              type: 'SET_MEDIA_VIEW_MODE',
              mode: state.mediaViewMode === 'grid' ? 'list' : 'grid',
            })
          }
        />
      </>
    ) : null

  return (
    <Panel id="media" title={t('media')} header={header} actions={actions}>
      <input
        ref={inputRef}
        className="visually-hidden"
        type="file"
        accept="video/*,audio/*,image/*"
        multiple
        aria-label={t('import')}
        onChange={(event) => {
          const files = [...(event.target.files ?? [])]
          if (files.length > 0) void importFiles(files)
          event.target.value = ''
        }}
      />
      {state.mediaTab === 'generate' ? (
        <GenerationForm />
      ) : (
        <div
          className={`media-browser${dropActive ? ' is-drop-active' : ''}`}
          onDragOver={(event) => {
            if (!event.dataTransfer.types.includes('Files')) return
            event.preventDefault()
            setDropActive(true)
          }}
          onDragLeave={(event) => {
            if (!event.currentTarget.contains(event.relatedTarget as Node)) {
              setDropActive(false)
            }
          }}
          onDrop={receiveDrop}
        >
          <div className="media-tools">
            <label className="search-field">
              <Search aria-hidden="true" />
              <input
                value={state.mediaQuery}
                onChange={(event) =>
                  dispatch({
                    type: 'SET_MEDIA_QUERY',
                    query: event.target.value,
                  })
                }
                placeholder={t('searchMedia')}
                aria-label={t('searchMedia')}
              />
            </label>
            <span className="media-count">{filtered.length}</span>
          </div>

          <div
            className={`asset-grid ${
              state.mediaViewMode === 'list' ? 'is-list' : ''
            }`}
          >
            {filtered.map((asset) => (
              <AssetCard
                key={asset.id}
                asset={asset}
                selected={state.selectedAssetIds.includes(asset.id)}
                list={state.mediaViewMode === 'list'}
              />
            ))}
            {filtered.length === 0 ? (
              <div className="empty-state media-empty">
                <UploadCloud aria-hidden="true" />
                <span>{t('noMedia')}</span>
              </div>
            ) : null}
          </div>

          {dropActive ? (
            <div className="media-drop-overlay">
              <UploadCloud aria-hidden="true" />
              <strong>{t('dropMedia')}</strong>
            </div>
          ) : null}
        </div>
      )}
    </Panel>
  )
}

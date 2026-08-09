import {
  Check,
  Eye,
  EyeOff,
  FileArchive,
  FileVideo,
  Film,
  KeyRound,
  ListVideo,
  Trash2,
  XCircle,
} from 'lucide-react'
import { useEffect, useState, type FormEvent } from 'react'
import { useEditor } from './editorState'
import { UserText, useI18n } from './i18n'
import type {
  ExportDestination,
  ExportRequest,
  ProviderSettings,
} from './model'
import { IconButton, Modal, Spinner, StatusBadge } from './ui'

function SettingsDialog() {
  const { state, dispatch, saveSettings } = useEditor()
  const { t } = useI18n()
  const isOpen = state.openDialogs.includes('settings')
  const [draft, setDraft] = useState<ProviderSettings>(state.settings)
  const [showKeys, setShowKeys] = useState(false)

  useEffect(() => {
    if (isOpen) setDraft(state.settings)
  }, [isOpen, state.settings])

  if (!isOpen) return null

  const close = () =>
    dispatch({ type: 'SET_DIALOG', dialog: 'settings', open: false })

  return (
    <Modal title={t('settings')} onClose={close} className="settings-dialog">
      <div className="settings-layout">
        <aside className="settings-sidebar">
          <button type="button" className="is-selected">
            <KeyRound aria-hidden="true" />
            {t('providerSettings')}
          </button>
        </aside>
        <form
          className="settings-content"
          onSubmit={(event) => {
            event.preventDefault()
            void saveSettings(draft)
          }}
        >
          <div className="settings-title">
            <div>
              <h3>{t('providerSettings')}</h3>
              <p>{t('apiKeyHelp')}</p>
            </div>
            <IconButton
              icon={showKeys ? EyeOff : Eye}
              label={showKeys ? t('hideKey') : t('showKey')}
              onClick={() => setShowKeys((current) => !current)}
            />
          </div>
          {state.settings.unavailableReason ? (
            <p className="form-error" role="alert">
              {t('generationUnavailable')}{' '}
              <UserText>{state.settings.unavailableReason}</UserText>
            </p>
          ) : null}
          <label className="field-stack">
            <span>{t('falKey')}</span>
            <div className="secret-field">
              <input
                type={showKeys ? 'text' : 'password'}
                value={draft.falKey}
                onChange={(event) =>
                  setDraft((current) => ({
                    ...current,
                    falKey: event.target.value,
                  }))
                }
                autoComplete="off"
                spellCheck={false}
              />
              {draft.falKey || draft.falConfigured ? (
                <Check aria-hidden="true" />
              ) : null}
            </div>
          </label>
          <label className="field-stack">
            <span>{t('replicateKey')}</span>
            <div className="secret-field">
              <input
                type={showKeys ? 'text' : 'password'}
                value={draft.replicateKey}
                onChange={(event) =>
                  setDraft((current) => ({
                    ...current,
                    replicateKey: event.target.value,
                  }))
                }
                autoComplete="off"
                spellCheck={false}
              />
              {draft.replicateKey || draft.replicateConfigured ? (
                <Check aria-hidden="true" />
              ) : null}
            </div>
          </label>
          <footer className="modal-actions settings-actions">
            <button type="button" className="button-secondary" onClick={close}>
              {t('cancel')}
            </button>
            <button
              type="submit"
              className="button-primary"
              disabled={Boolean(state.settings.unavailableReason)}
            >
              {t('save')}
            </button>
          </footer>
        </form>
      </div>
    </Modal>
  )
}

function DestinationButton({
  destination,
  selected,
  onClick,
}: {
  destination: ExportDestination
  selected: boolean
  onClick: () => void
}) {
  const { t } = useI18n()
  const Icon =
    destination === 'video'
      ? Film
      : destination === 'timeline'
        ? ListVideo
        : FileArchive
  return (
    <button
      type="button"
      className={`export-destination${selected ? ' is-selected' : ''}`}
      onClick={onClick}
      aria-pressed={selected}
    >
      <Icon aria-hidden="true" />
      <span>{t(destination)}</span>
    </button>
  )
}

function ExportDialog() {
  const { state, dispatch, startExport, cancelExport } = useEditor()
  const { t } = useI18n()
  const isOpen = state.openDialogs.includes('export')
  const [destination, setDestination] =
    useState<ExportDestination>('video')
  const [codec, setCodec] = useState<ExportRequest['codec']>('H.264')
  const [resolution, setResolution] =
    useState<ExportRequest['resolution']>('timeline')
  const [timelineFormat, setTimelineFormat] =
    useState<ExportRequest['timelineFormat']>('FCPXML')

  if (!isOpen) return null

  const close = () =>
    dispatch({ type: 'SET_DIALOG', dialog: 'export', open: false })

  const submit = (event: FormEvent) => {
    event.preventDefault()
    void startExport({
      destination,
      codec,
      resolution,
      timelineFormat,
    })
  }

  return (
    <Modal title={t('export')} onClose={close} className="export-dialog">
      <div className="export-layout">
        <form className="export-settings" onSubmit={submit}>
          <section className="export-section">
            <h3>{t('destination')}</h3>
            <div className="export-destinations">
              {(['video', 'timeline', 'project'] as const).map((option) => (
                <DestinationButton
                  key={option}
                  destination={option}
                  selected={destination === option}
                  onClick={() => setDestination(option)}
                />
              ))}
            </div>
          </section>

          {destination === 'video' ? (
            <section className="export-section export-fields">
              <label>
                <span>{t('codec')}</span>
                <select
                  value={codec}
                  onChange={(event) =>
                    setCodec(event.target.value as ExportRequest['codec'])
                  }
                >
                  <option>H.264</option>
                  <option>HEVC</option>
                  <option>ProRes</option>
                </select>
              </label>
              <label>
                <span>{t('resolution')}</span>
                <select
                  value={resolution}
                  onChange={(event) =>
                    setResolution(
                      event.target.value as ExportRequest['resolution'],
                    )
                  }
                >
                  <option value="timeline">{t('matchTimeline')}</option>
                  <option value="1080p">1080p</option>
                  <option value="720p">720p</option>
                </select>
              </label>
              <label>
                <span>{t('frameRate')}</span>
                <output>{state.project?.fps ?? 30} fps</output>
              </label>
            </section>
          ) : null}

          {destination === 'timeline' ? (
            <section className="export-section export-fields">
              <label>
                <span>{t('format')}</span>
                <select
                  value={timelineFormat}
                  onChange={(event) =>
                    setTimelineFormat(
                      event.target.value as ExportRequest['timelineFormat'],
                    )
                  }
                >
                  <option>FCPXML</option>
                  <option>XMEML</option>
                </select>
              </label>
              <p>{t('exportTimelineDescription')}</p>
            </section>
          ) : null}

          {destination === 'project' ? (
            <section className="export-section export-summary">
              <FileVideo aria-hidden="true" />
              <div>
                <strong>{t('portableProject')}</strong>
                <p>{t('portableProjectDescription')}</p>
              </div>
            </section>
          ) : null}

          <footer className="modal-actions export-actions">
            <button type="button" className="button-secondary" onClick={close}>
              {t('close')}
            </button>
            <button type="submit" className="button-primary">
              {t('startExport')}
            </button>
          </footer>
        </form>

        <aside className="export-queue">
          <header>
            <div>
              <h3>{t('exportQueue')}</h3>
              <span>{state.exportJobs.length}</span>
            </div>
            <IconButton
              icon={Trash2}
              label={t('clearFinished')}
              disabled={!state.exportJobs.some((job) =>
                ['completed', 'failed', 'canceled'].includes(job.status),
              )}
              onClick={() => dispatch({ type: 'CLEAR_FINISHED_EXPORTS' })}
            />
          </header>
          <div className="export-job-list">
            {state.exportJobs.length === 0 ? (
              <div className="empty-state export-empty">
                <Film aria-hidden="true" />
                <span>{t('noExports')}</span>
              </div>
            ) : (
              state.exportJobs.map((job) => (
                <article className="export-job" key={job.id}>
                  <div className="export-job-icon">
                    <FileVideo aria-hidden="true" />
                  </div>
                  <div className="export-job-main">
                    <UserText title={job.filename}>{job.filename}</UserText>
                    <StatusBadge status={job.status} />
                    {['waiting', 'preparing', 'running'].includes(
                      job.status,
                    ) ? (
                      <div className="job-progress">
                        <progress max={1} value={job.progress} />
                        <span>{Math.round(job.progress * 100)}%</span>
                      </div>
                    ) : null}
                  </div>
                  {['waiting', 'preparing', 'running'].includes(
                    job.status,
                  ) ? (
                    <IconButton
                      compact
                      icon={XCircle}
                      label={t('cancelJob')}
                      onClick={() => void cancelExport(job.id)}
                    />
                  ) : null}
                </article>
              ))
            )}
          </div>
        </aside>
      </div>
    </Modal>
  )
}

function ToastAndStatus() {
  const { state, dispatch } = useEditor()
  const { t } = useI18n()

  const toast = state.toastMessage ? t(state.toastMessage) : null

  return (
    <>
      {!state.isOnline ? (
        <div className="offline-banner" role="status">
          <span className="status-dot" aria-hidden="true" />
          {t('offline')}
        </div>
      ) : null}
      {state.operationLabel ? (
        <div className="operation-toast" role="status">
          <Spinner />
          {t(state.operationLabel)}
        </div>
      ) : null}
      {toast ? (
        <div className="success-toast" role="status">
          <Check aria-hidden="true" />
          {toast}
        </div>
      ) : null}
      {state.errorMessage ? (
        <div className="error-toast" role="alert">
          <XCircle aria-hidden="true" />
          <span>{t(state.errorMessage)}</span>
          <button
            type="button"
            onClick={() => dispatch({ type: 'SET_ERROR', message: null })}
          >
            {t('dismiss')}
          </button>
        </div>
      ) : null}
    </>
  )
}

export function DialogHost() {
  return (
    <>
      <SettingsDialog />
      <ExportDialog />
      <ToastAndStatus />
    </>
  )
}

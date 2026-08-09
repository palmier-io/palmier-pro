import {
  Clock3,
  FolderOpen,
  LayoutGrid,
  Plus,
  Settings,
  Sparkles,
} from 'lucide-react'
import { useState } from 'react'
import { useEditor } from './editorState'
import { UserText, useI18n } from './i18n'
import { BrandMark, Modal, Spinner } from './ui'

const samples = [
  {
    id: 'sample-product',
    nameKey: 'productLaunch',
    descriptionKey: 'productLaunchDescription',
    accent: 'ocean',
  },
  {
    id: 'sample-travel',
    nameKey: 'travelJournal',
    descriptionKey: 'travelJournalDescription',
    accent: 'moss',
  },
  {
    id: 'sample-portrait',
    nameKey: 'portraitStudy',
    descriptionKey: 'portraitStudyDescription',
    accent: 'violet',
  },
] as const

function NewProjectDialog() {
  const { state, dispatch, createProject } = useEditor()
  const { t } = useI18n()
  const [name, setName] = useState('Untitled film')
  const isOpen = state.openDialogs.includes('new-project')
  if (!isOpen) return null

  const close = () =>
    dispatch({ type: 'SET_DIALOG', dialog: 'new-project', open: false })

  return (
    <Modal title={t('newProject')} onClose={close} className="modal-small">
      <form
        className="modal-form"
        onSubmit={(event) => {
          event.preventDefault()
          const trimmed = name.trim()
          if (!trimmed) return
          close()
          void createProject(trimmed)
        }}
      >
        <label className="field-stack">
          <span>{t('projectName')}</span>
          <input
            autoFocus
            value={name}
            onChange={(event) => setName(event.target.value)}
            aria-label={t('projectName')}
          />
        </label>
        <footer className="modal-actions">
          <button type="button" className="button-secondary" onClick={close}>
            {t('cancel')}
          </button>
          <button
            type="submit"
            className="button-primary"
            disabled={!name.trim()}
          >
            {t('create')}
          </button>
        </footer>
      </form>
    </Modal>
  )
}

export function HomeView() {
  const { state, dispatch, openProject, createProject } = useEditor()
  const { t, locale } = useI18n()

  if (state.bootStatus === 'loading') {
    return (
      <main className="home-loading">
        <BrandMark />
        <Spinner label={t('loadingProject')} />
      </main>
    )
  }

  return (
    <main className="home-shell">
      <aside className="home-sidebar">
        <div className="home-brand">
          <BrandMark compact />
          <span>{t('appName')}</span>
        </div>
        <nav className="home-actions" aria-label={t('projectMenu')}>
          <button
            type="button"
            className="sidebar-button is-primary"
            onClick={() =>
              dispatch({
                type: 'SET_DIALOG',
                dialog: 'new-project',
                open: true,
              })
            }
          >
            <Plus aria-hidden="true" />
            {t('newProject')}
          </button>
          <button
            type="button"
            className="sidebar-button"
            onClick={() => void openProject()}
          >
            <FolderOpen aria-hidden="true" />
            {t('openProject')}
          </button>
        </nav>
        <div className="home-sidebar-spacer" />
        <div className="home-tip">
          <Sparkles aria-hidden="true" />
          <div>
            <strong>{t('generatedMedia')}</strong>
            <span>{t('providerTip')}</span>
          </div>
        </div>
        <button
          type="button"
          className="sidebar-button"
          onClick={() =>
            dispatch({ type: 'SET_DIALOG', dialog: 'settings', open: true })
          }
        >
          <Settings aria-hidden="true" />
          {t('settings')}
        </button>
      </aside>

      <section className="home-content">
        <header className="home-header">
          <div>
            <p className="eyebrow">{t('appName')}</p>
            <h1>{t('welcome')}</h1>
            <p>{t('homeSubtitle')}</p>
          </div>
          <button
            type="button"
            className="button-primary home-create-button"
            onClick={() =>
              dispatch({
                type: 'SET_DIALOG',
                dialog: 'new-project',
                open: true,
              })
            }
          >
            <Plus aria-hidden="true" />
            {t('newProject')}
          </button>
        </header>

        <section className="home-section">
          <div className="section-heading">
            <div>
              <p className="eyebrow">{t('sampleProjects')}</p>
              <h2>{t('sampleHeading')}</h2>
            </div>
            <LayoutGrid aria-hidden="true" />
          </div>
          <div className="sample-grid">
            {samples.map((sample) => (
              <button
                type="button"
                className="sample-card"
                key={sample.id}
                onClick={() => void createProject(t(sample.nameKey))}
              >
                <span
                  className={`sample-art media-accent-${sample.accent}`}
                  aria-hidden="true"
                >
                  <span className="sample-play">
                    <Sparkles />
                  </span>
                </span>
                <span className="sample-copy">
                  <span>{t(sample.nameKey)}</span>
                  <small>{t(sample.descriptionKey)}</small>
                </span>
              </button>
            ))}
          </div>
        </section>

        <section className="home-section recent-section">
          <div className="section-heading">
            <div>
              <p className="eyebrow">{t('recentProjects')}</p>
              <h2>{t('continueHeading')}</h2>
            </div>
            <Clock3 aria-hidden="true" />
          </div>
          {state.recentProjects.length === 0 ? (
            <div className="empty-state">{t('noRecentProjects')}</div>
          ) : (
            <div className="recent-list">
              {state.recentProjects.map((project, index) => (
                <button
                  type="button"
                  className="recent-row"
                  key={project.id}
                  onClick={() => void openProject(project.path)}
                >
                  <span
                    className={`recent-thumbnail media-accent-${
                      ['moss', 'amber', 'violet'][index % 3]
                    }`}
                    aria-hidden="true"
                  />
                  <span className="recent-main">
                    <UserText>{project.name}</UserText>
                    <UserText className="recent-path">
                      {project.path}
                    </UserText>
                  </span>
                  <span className="recent-meta">
                    <span>{project.durationLabel}</span>
                    <time dateTime={project.updatedAt}>
                      {new Intl.DateTimeFormat(locale, {
                        month: 'short',
                        day: 'numeric',
                      }).format(new Date(project.updatedAt))}
                    </time>
                  </span>
                </button>
              ))}
            </div>
          )}
        </section>
      </section>
      <NewProjectDialog />
    </main>
  )
}

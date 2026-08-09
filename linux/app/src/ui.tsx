import {
  Maximize2,
  Minimize2,
  X,
  type LucideIcon,
} from 'lucide-react'
import type {
  ButtonHTMLAttributes,
  MouseEvent,
  PropsWithChildren,
  ReactNode,
} from 'react'
import { useEditor } from './editorState'
import { useI18n } from './i18n'
import type { JobStatus, PanelId } from './model'

export function BrandMark({ compact = false }: { compact?: boolean }) {
  return (
    <span
      aria-hidden="true"
      className={`brand-mark${compact ? ' brand-mark-compact' : ''}`}
    >
      <span className="brand-mark-leaf brand-mark-leaf-left" />
      <span className="brand-mark-leaf brand-mark-leaf-center" />
      <span className="brand-mark-leaf brand-mark-leaf-right" />
    </span>
  )
}

interface IconButtonProps
  extends Omit<ButtonHTMLAttributes<HTMLButtonElement>, 'children'> {
  icon: LucideIcon
  label: string
  active?: boolean
  compact?: boolean
}

export function IconButton({
  icon: Icon,
  label,
  active = false,
  compact = false,
  className = '',
  ...buttonProps
}: IconButtonProps) {
  return (
    <button
      type="button"
      className={`icon-button${active ? ' is-active' : ''}${
        compact ? ' is-compact' : ''
      } ${className}`}
      aria-label={label}
      title={label}
      aria-pressed={active || undefined}
      {...buttonProps}
    >
      <Icon aria-hidden="true" />
    </button>
  )
}

interface PanelProps extends PropsWithChildren {
  id: PanelId
  title: string
  icon?: LucideIcon
  header?: ReactNode
  actions?: ReactNode
  className?: string
}

export function Panel({
  id,
  title,
  icon: Icon,
  header,
  actions,
  className = '',
  children,
}: PanelProps) {
  const { state, dispatch } = useEditor()
  const { t } = useI18n()
  const maximized = state.maximizedPanel === id

  const focusPanel = (event: MouseEvent<HTMLElement>) => {
    if ((event.target as HTMLElement).closest('button, input, select, textarea')) {
      return
    }
    dispatch({ type: 'FOCUS_PANEL', panel: id })
  }

  return (
    <section
      className={`editor-panel ${className}${
        state.focusedPanel === id ? ' is-focused' : ''
      }`}
      data-panel={id}
      aria-label={title}
      onMouseDown={focusPanel}
    >
      <header
        className="panel-header"
        onDoubleClick={() => dispatch({ type: 'TOGGLE_MAXIMIZE', panel: id })}
      >
        {header ?? (
          <div className="panel-title">
            {Icon ? <Icon aria-hidden="true" /> : null}
            <span>{title}</span>
          </div>
        )}
        <div className="panel-header-actions">
          {actions}
          <IconButton
            compact
            icon={maximized ? Minimize2 : Maximize2}
            label={maximized ? t('restorePanels') : t('maximizePanel')}
            onClick={() => dispatch({ type: 'TOGGLE_MAXIMIZE', panel: id })}
          />
        </div>
      </header>
      <div className="panel-content">{children}</div>
    </section>
  )
}

interface ModalProps extends PropsWithChildren {
  title: string
  onClose: () => void
  className?: string
  labelledBy?: string
}

export function Modal({
  title,
  onClose,
  className = '',
  labelledBy = 'modal-title',
  children,
}: ModalProps) {
  const { t } = useI18n()
  return (
    <div className="modal-backdrop" role="presentation" onMouseDown={onClose}>
      <section
        className={`modal-card ${className}`}
        role="dialog"
        aria-modal="true"
        aria-labelledby={labelledBy}
        onMouseDown={(event) => event.stopPropagation()}
      >
        <header className="modal-header">
          <h2 id={labelledBy}>{title}</h2>
          <IconButton icon={X} label={t('close')} onClick={onClose} />
        </header>
        {children}
      </section>
    </div>
  )
}

export function StatusBadge({ status }: { status: JobStatus }) {
  const { t } = useI18n()
  return (
    <span className={`status-badge status-${status}`}>
      <span className="status-dot" aria-hidden="true" />
      {t(status)}
    </span>
  )
}

export function formatTimecode(frame: number, fps: number): string {
  const safeFps = Math.max(1, fps)
  const safeFrame = Math.max(0, Math.round(frame))
  const frames = safeFrame % safeFps
  const totalSeconds = Math.floor(safeFrame / safeFps)
  const seconds = totalSeconds % 60
  const minutes = Math.floor(totalSeconds / 60) % 60
  const hours = Math.floor(totalSeconds / 3600)
  return [hours, minutes, seconds, frames]
    .map((part) => String(part).padStart(2, '0'))
    .join(':')
}

export function Spinner({ label }: { label?: string }) {
  return (
    <span className="spinner-wrap" role={label ? 'status' : undefined}>
      <span className="spinner" aria-hidden="true" />
      {label ? <span>{label}</span> : null}
    </span>
  )
}

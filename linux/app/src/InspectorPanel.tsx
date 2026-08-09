import {
  AudioLines,
  Clapperboard,
  FileVideo,
  Gauge,
  Image,
  RotateCcw,
  SlidersHorizontal,
} from 'lucide-react'
import { useState, type ChangeEvent } from 'react'
import {
  findAsset,
  selectedAssetForState,
  selectedClipForState,
  useEditor,
} from './editorState'
import { UserText, useI18n } from './i18n'
import type { TimelineClip } from './model'
import { Panel } from './ui'

function NumericControl({
  label,
  value,
  min,
  max,
  step,
  suffix,
  disabled = false,
  onChange,
}: {
  label: string
  value: number
  min: number
  max: number
  step: number
  suffix?: string
  disabled?: boolean
  onChange: (value: number) => void
}) {
  const update = (event: ChangeEvent<HTMLInputElement>) => {
    const next = Number(event.target.value)
    if (Number.isFinite(next)) onChange(next)
  }

  return (
    <label className="inspector-control">
      <span>{label}</span>
      <div className="inspector-input">
        <input
          type="number"
          value={Number(value.toFixed(2))}
          min={min}
          max={max}
          step={step}
          disabled={disabled}
          onChange={update}
        />
        {suffix ? <small>{suffix}</small> : null}
      </div>
    </label>
  )
}

function RangeControl({
  label,
  value,
  min,
  max,
  step,
  suffix,
  onChange,
}: {
  label: string
  value: number
  min: number
  max: number
  step: number
  suffix: string
  onChange: (value: number) => void
}) {
  return (
    <label className="inspector-range">
      <span>{label}</span>
      <input
        type="range"
        value={value}
        min={min}
        max={max}
        step={step}
        onChange={(event) => onChange(Number(event.target.value))}
      />
      <strong>
        {Math.round(value)}
        {suffix}
      </strong>
    </label>
  )
}

function ClipInspector({ clip }: { clip: TimelineClip }) {
  const { state, dispatch } = useEditor()
  const { t } = useI18n()
  const asset = findAsset(state.project, clip.assetId)
  const isAudio = clip.kind === 'audio'
  const [tab, setTab] = useState<'video' | 'audio'>(
    isAudio ? 'audio' : 'video',
  )

  const updateClip = (patch: {
    speed?: number
    volume?: number
    fadeInFrames?: number
    fadeOutFrames?: number
    transform?: Partial<TimelineClip['transform']>
  }) => {
    dispatch({
      type: 'UPDATE_CLIP',
      clipId: clip.id,
      patch,
    })
  }

  const updateTransform = (
    patch: Partial<TimelineClip['transform']>,
  ) => {
    updateClip({ transform: patch })
  }

  return (
    <div className="inspector-scroll">
      <div className="inspector-selection-header">
        <span
          className={`inspector-media-icon media-accent-${
            asset?.accent ?? 'slate'
          }`}
        >
          {isAudio ? (
            <AudioLines aria-hidden="true" />
          ) : asset?.kind === 'image' ? (
            <Image aria-hidden="true" />
          ) : (
            <FileVideo aria-hidden="true" />
          )}
        </span>
        <div>
          <UserText>{clip.name}</UserText>
          <small>{isAudio ? t('audio') : t('video')}</small>
        </div>
      </div>

      {!isAudio ? (
        <div className="inspector-tabs" role="tablist">
          <button
            type="button"
            role="tab"
            aria-selected={tab === 'video'}
            className={tab === 'video' ? 'is-active' : ''}
            onClick={() => setTab('video')}
          >
            {t('video')}
          </button>
          <button
            type="button"
            role="tab"
            aria-selected={tab === 'audio'}
            className={tab === 'audio' ? 'is-active' : ''}
            onClick={() => setTab('audio')}
          >
            {t('audio')}
          </button>
        </div>
      ) : null}

      {asset?.status.kind === 'offline' ? (
        <div className="inspector-warning">
          <RotateCcw aria-hidden="true" />
          <div>
            <strong>{t('sourceOffline')}</strong>
            <p>{asset.status.reason}</p>
          </div>
        </div>
      ) : null}

      {tab === 'video' && !isAudio ? (
        <>
          <section className="inspector-section">
            <header>
              <div>
                <SlidersHorizontal aria-hidden="true" />
                <h3>{t('transform')}</h3>
              </div>
              <button
                type="button"
                className="text-button"
                onClick={() =>
                  updateTransform({
                    positionX: 0,
                    positionY: 0,
                    scale: 100,
                    rotation: 0,
                    opacity: 100,
                  })
                }
              >
                {t('reset')}
              </button>
            </header>
            <div className="inspector-control-grid">
              <NumericControl
                label={t('positionX')}
                value={clip.transform.positionX}
                min={-100}
                max={100}
                step={1}
                suffix="%"
                onChange={(positionX) => updateTransform({ positionX })}
              />
              <NumericControl
                label={t('positionY')}
                value={clip.transform.positionY}
                min={-100}
                max={100}
                step={1}
                suffix="%"
                onChange={(positionY) => updateTransform({ positionY })}
              />
              <NumericControl
                label={t('scale')}
                value={clip.transform.scale}
                min={1}
                max={400}
                step={1}
                suffix="%"
                onChange={(scale) => updateTransform({ scale })}
              />
              <NumericControl
                label={t('rotation')}
                value={clip.transform.rotation}
                min={-360}
                max={360}
                step={1}
                suffix="°"
                onChange={(rotation) => updateTransform({ rotation })}
              />
            </div>
            <RangeControl
              label={t('opacity')}
              value={clip.transform.opacity}
              min={0}
              max={100}
              step={1}
              suffix="%"
              onChange={(opacity) => updateTransform({ opacity })}
            />
          </section>
          <section className="inspector-section">
            <header>
              <div>
                <Gauge aria-hidden="true" />
                <h3>{t('playback')}</h3>
              </div>
            </header>
            <NumericControl
              label={t('speed')}
              value={clip.speed}
              min={0.25}
              max={4}
              step={0.05}
              suffix="x"
              onChange={(speed) => updateClip({ speed })}
            />
          </section>
        </>
      ) : (
        <section className="inspector-section">
          <header>
            <div>
              <AudioLines aria-hidden="true" />
              <h3>{t('audio')}</h3>
            </div>
          </header>
          <RangeControl
            label={t('volume')}
            value={clip.volume * 100}
            min={0}
            max={150}
            step={1}
            suffix="%"
            onChange={(volume) => updateClip({ volume: volume / 100 })}
          />
          <NumericControl
            label={t('speed')}
            value={clip.speed}
            min={0.25}
            max={4}
            step={0.05}
            suffix="x"
            onChange={(speed) => updateClip({ speed })}
          />
          <NumericControl
            label={t('fadeIn')}
            value={clip.fadeInFrames}
            min={0}
            max={Math.max(0, clip.durationFrames)}
            step={1}
            suffix="f"
            onChange={(fadeInFrames) => updateClip({ fadeInFrames })}
          />
          <NumericControl
            label={t('fadeOut')}
            value={clip.fadeOutFrames}
            min={0}
            max={Math.max(0, clip.durationFrames)}
            step={1}
            suffix="f"
            onChange={(fadeOutFrames) => updateClip({ fadeOutFrames })}
          />
        </section>
      )}
    </div>
  )
}

function AssetInspector() {
  const { state, relinkAsset } = useEditor()
  const { t } = useI18n()
  const asset = selectedAssetForState(state)
  if (!asset) return null

  return (
    <div className="inspector-scroll">
      <div className="inspector-selection-header">
        <span
          className={`inspector-media-icon media-accent-${asset.accent}`}
        >
          {asset.kind === 'audio' ? (
            <AudioLines aria-hidden="true" />
          ) : asset.kind === 'image' ? (
            <Image aria-hidden="true" />
          ) : (
            <FileVideo aria-hidden="true" />
          )}
        </span>
        <div>
          <UserText>{asset.name}</UserText>
          <small>{t(asset.kind)}</small>
        </div>
      </div>
      <section className="inspector-section metadata-section">
        <header>
          <div>
            <FileVideo aria-hidden="true" />
            <h3>{t('file')}</h3>
          </div>
        </header>
        <dl>
          <div>
            <dt>{t('duration')}</dt>
            <dd>
              {t('secondsShort', {
                value: (
                  asset.durationFrames / (state.project?.fps ?? 30)
                ).toFixed(1),
              })}
            </dd>
          </div>
          {asset.width && asset.height ? (
            <div>
              <dt>{t('dimensions')}</dt>
              <dd>
                {asset.width} × {asset.height}
              </dd>
            </div>
          ) : null}
          <div>
            <dt>{t('path')}</dt>
            <dd>
              <UserText>{asset.sourcePath ?? t('sourceOffline')}</UserText>
            </dd>
          </div>
        </dl>
        {asset.status.kind === 'offline' ? (
          <button
            type="button"
            className="button-secondary"
            onClick={() => relinkAsset(asset.id)}
          >
            <RotateCcw aria-hidden="true" />
            {t('relink')}
          </button>
        ) : null}
      </section>
    </div>
  )
}

function ProjectInspector() {
  const { state, dispatch } = useEditor()
  const { t } = useI18n()
  const project = state.project
  if (!project) return null

  const resolution = `${project.width}x${project.height}`

  return (
    <div className="inspector-scroll">
      <section className="inspector-section metadata-section">
        <header>
          <div>
            <Clapperboard aria-hidden="true" />
            <h3>{t('project')}</h3>
          </div>
        </header>
        <dl>
          <div>
            <dt>{t('projectName')}</dt>
            <dd>
              <UserText>{project.name}</UserText>
            </dd>
          </div>
          <div>
            <dt>{t('path')}</dt>
            <dd>
              <UserText>{project.path ?? t('project')}</UserText>
            </dd>
          </div>
        </dl>
      </section>
      <section className="inspector-section">
        <header>
          <div>
            <SlidersHorizontal aria-hidden="true" />
            <h3>{t('projectSettings')}</h3>
          </div>
        </header>
        <label className="inspector-control">
          <span>{t('resolution')}</span>
          <select
            value={resolution}
            onChange={(event) => {
              const [width, height] = event.target.value
                .split('x')
                .map(Number)
              if (!width || !height) return
              dispatch({
                type: 'UPDATE_PROJECT_SETTINGS',
                patch: { width, height },
              })
            }}
          >
            <option value="3840x2160">3840 × 2160</option>
            <option value="1920x1080">1920 × 1080</option>
            <option value="1080x1920">1080 × 1920</option>
            <option value="1080x1080">1080 × 1080</option>
          </select>
        </label>
        <label className="inspector-control">
          <span>{t('frameRate')}</span>
          <select
            value={project.fps}
            onChange={(event) =>
              dispatch({
                type: 'UPDATE_PROJECT_SETTINGS',
                patch: { fps: Number(event.target.value) },
              })
            }
          >
            <option value={24}>24 fps</option>
            <option value={25}>25 fps</option>
            <option value={30}>30 fps</option>
            <option value={60}>60 fps</option>
          </select>
        </label>
        <label className="inspector-control">
          <span>{t('aspectRatio')}</span>
          <output>
            {project.width > project.height
              ? '16:9'
              : project.width === project.height
                ? '1:1'
                : '9:16'}
          </output>
        </label>
      </section>
    </div>
  )
}

export function InspectorPanel() {
  const { state } = useEditor()
  const { t } = useI18n()
  const clip = selectedClipForState(state)
  const asset = selectedAssetForState(state)

  return (
    <Panel
      id="inspector"
      title={t('inspector')}
      icon={SlidersHorizontal}
    >
      {clip ? (
        <ClipInspector key={clip.id} clip={clip} />
      ) : asset ? (
        <AssetInspector />
      ) : (
        <ProjectInspector />
      )}
    </Panel>
  )
}

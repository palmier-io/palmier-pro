import { render, screen } from '@testing-library/react'
import { describe, expect, test } from 'vitest'
import {
  LocalizationProvider,
  availableLocales,
  translate,
  useI18n,
} from './i18n'
import enCatalog from './locales/en.json'
import esCatalog from './locales/es.json'
import frCatalog from './locales/fr.json'
import { messageKeys } from './locales/messages'

function Probe({ messageKey }: { messageKey: string }) {
  const { t, locale } = useI18n()
  return (
    <div>
      <span data-testid="locale">{locale}</span>
      <span data-testid="label">{t(messageKey)}</span>
    </div>
  )
}

describe('locale catalogs', () => {
  test('loads en, es, and fr catalogs from synced macOS strings', () => {
    expect(availableLocales()).toEqual(
      expect.arrayContaining(['en', 'es', 'fr']),
    )
    expect(enCatalog['New Project']).toBe('New Project')
    expect(esCatalog['New Project']).toBe('Nuevo proyecto')
    expect(frCatalog['New Project']).toBe('Nouveau projet')
    expect(esCatalog.Inspector).toBe('Inspector')
    expect(frCatalog.Inspector).toBe('Inspecteur')
  })

  test('resolves app keys through locale catalogs', () => {
    expect(translate('es', 'newProject')).toBe('Nuevo proyecto')
    expect(translate('fr', 'undo')).toBe('Annuler')
    expect(translate('en', 'opacity')).toBe('Opacity')
    expect(translate('es', 'unsupportedFeature:speed')).toBe(
      translate('es', 'unsupportedFeature', {
        feature: translate('es', 'featureSpeed'),
      }),
    )
  })

  test('keeps Linux-only copy available when missing from macOS catalogs', () => {
    expect(translate('en', 'welcome')).toBe(messageKeys.welcome)
    expect(translate('es', 'welcome')).toBe(messageKeys.welcome)
  })

  test('LocalizationProvider exposes the forced locale', () => {
    render(
      <LocalizationProvider locale="fr">
        <Probe messageKey="inspector" />
      </LocalizationProvider>,
    )
    expect(screen.getByTestId('locale')).toHaveTextContent('fr')
    expect(screen.getByTestId('label')).toHaveTextContent('Inspecteur')
  })
})

import {
  createContext,
  useContext,
  useMemo,
  type PropsWithChildren,
} from 'react'
import enCatalog from './locales/en.json'
import esCatalog from './locales/es.json'
import frCatalog from './locales/fr.json'
import {
  featureLabels,
  messageKeys,
  type MessageKey,
} from './locales/messages'

type Variables = Record<string, string | number>
type Catalog = Record<string, string>

interface LocalizationContextValue {
  locale: string
  t: (key: string, variables?: Variables) => string
}

const catalogs: Record<string, Catalog> = {
  en: enCatalog as Catalog,
  es: esCatalog as Catalog,
  fr: frCatalog as Catalog,
}

function detectLocale(): string {
  if (typeof navigator === 'undefined') return 'en'
  const language = navigator.language.toLowerCase()
  if (language.startsWith('es')) return 'es'
  if (language.startsWith('fr')) return 'fr'
  return 'en'
}

function formatMessage(template: string, variables?: Variables): string {
  if (!variables) return template
  return Object.entries(variables).reduce(
    (message, [name, value]) =>
      message.replaceAll(`{{${name}}}`, String(value)),
    template,
  )
}

function resolveSource(key: string): string {
  if (key in messageKeys) {
    return messageKeys[key as MessageKey]
  }
  return key
}

export function translate(
  locale: string,
  key: string,
  variables?: Variables,
): string {
  if (key.startsWith('unsupportedFeature:')) {
    const feature = key.slice('unsupportedFeature:'.length)
    const featureKey = featureLabels[feature]
    const featureLabel = featureKey
      ? translate(locale, featureKey)
      : feature
    return translate(locale, 'unsupportedFeature', {
      feature: featureLabel,
    })
  }
  if (key.startsWith('importComplete:')) {
    return translate(locale, 'importComplete', {
      count: Number(key.split(':')[1] ?? 0),
    })
  }

  const source = resolveSource(key)
  const catalog = catalogs[locale] ?? catalogs.en
  const english = catalogs.en
  const template = catalog?.[source] ?? english?.[source] ?? source
  return formatMessage(template, variables)
}

const LocalizationContext = createContext<LocalizationContextValue | null>(
  null,
)

export function LocalizationProvider({
  children,
  locale: forcedLocale,
}: PropsWithChildren<{ locale?: string }>) {
  const locale = forcedLocale ?? detectLocale()
  const value = useMemo<LocalizationContextValue>(
    () => ({
      locale,
      t: (key, variables) => translate(locale, key, variables),
    }),
    [locale],
  )

  return (
    <LocalizationContext.Provider value={value}>
      {children}
    </LocalizationContext.Provider>
  )
}

export function useI18n(): LocalizationContextValue {
  const value = useContext(LocalizationContext)
  if (!value) {
    throw new Error('useI18n must be used inside LocalizationProvider')
  }
  return value
}

export function UserText({
  children,
  className,
  title,
}: {
  children: string
  className?: string
  title?: string
}) {
  return (
    <span className={className} title={title} translate="no">
      {children}
    </span>
  )
}

export function availableLocales(): string[] {
  return Object.keys(catalogs)
}

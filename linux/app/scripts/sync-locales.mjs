#!/usr/bin/env node
import { mkdir, readdir, readFile, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const appRoot = path.resolve(__dirname, '..')
const repoRoot = path.resolve(appRoot, '../..')
const localizationRoot = path.join(
  repoRoot,
  'Sources/PalmierPro/Resources/Localization',
)
const outputRoot = path.join(appRoot, 'src/locales')

const REQUIRED_LOCALES = ['en', 'es', 'fr']

function unescapeStringsValue(value) {
  return value
    .replace(/\\"/g, '"')
    .replace(/\\n/g, '\n')
    .replace(/\\r/g, '\r')
    .replace(/\\t/g, '\t')
    .replace(/\\\\/g, '\\')
}

function parseStrings(contents) {
  const catalog = {}
  const pattern = /"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)"\s*;/g
  for (const match of contents.matchAll(pattern)) {
    const key = unescapeStringsValue(match[1] ?? '')
    const value = unescapeStringsValue(match[2] ?? '')
    catalog[key] = value
  }
  return catalog
}

function localeFromDirectory(name) {
  return name.replace(/\.lproj$/i, '')
}

async function main() {
  const entries = await readdir(localizationRoot, { withFileTypes: true })
  const localeDirs = entries
    .filter((entry) => entry.isDirectory() && entry.name.endsWith('.lproj'))
    .map((entry) => localeFromDirectory(entry.name))
    .sort()

  await mkdir(outputRoot, { recursive: true })

  const written = []
  for (const locale of localeDirs) {
    const stringsPath = path.join(
      localizationRoot,
      `${locale}.lproj`,
      'Localizable.strings',
    )
    let contents
    try {
      contents = await readFile(stringsPath, 'utf8')
    } catch {
      continue
    }
    const catalog = parseStrings(contents)
    const outputPath = path.join(outputRoot, `${locale}.json`)
    await writeFile(
      outputPath,
      `${JSON.stringify(catalog, null, 2)}\n`,
      'utf8',
    )
    written.push(locale)
  }

  const missingRequired = REQUIRED_LOCALES.filter(
    (locale) => !written.includes(locale),
  )
  if (missingRequired.length > 0) {
    throw new Error(
      `Missing required locale catalogs: ${missingRequired.join(', ')}`,
    )
  }

  const manifestPath = path.join(outputRoot, 'manifest.json')
  await writeFile(
    manifestPath,
    `${JSON.stringify({ locales: written }, null, 2)}\n`,
    'utf8',
  )

  console.log(
    `Synced ${written.length} locale catalogs into ${path.relative(appRoot, outputRoot)}`,
  )
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error)
  process.exitCode = 1
})

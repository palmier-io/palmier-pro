import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { describe, expect, test } from 'vitest'

const componentCss = readFileSync(
  resolve(process.cwd(), 'src/App.css'),
  'utf8',
)
const themeCss = readFileSync(
  resolve(process.cwd(), 'src/AppTheme.css'),
  'utf8',
)

describe('AppTheme boundary', () => {
  test('defines every component token in AppTheme', () => {
    const definitions = new Set(
      [...themeCss.matchAll(/(--[\w-]+)\s*:/g)].map((match) => match[1]),
    )
    const references = new Set(
      [...componentCss.matchAll(/var\((--[\w-]+)/g)].map(
        (match) => match[1],
      ),
    )
    const missing = [...references].filter(
      (reference) => !definitions.has(reference),
    )

    expect(missing).toEqual([])
  })

  test('keeps raw visual constants out of component CSS', () => {
    const rawVisualValues = componentCss.match(
      /#[\da-f]{3,8}|rgba?\(|\d+(?:\.\d+)?(?:px|rem|em|ms)\b/gi,
    )

    expect(rawVisualValues).toBeNull()
  })
})

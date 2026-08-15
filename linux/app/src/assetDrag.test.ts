import { describe, expect, test } from 'vitest'
import {
  ASSET_DRAG_MIME,
  ASSET_DRAG_PREFIX,
  isAssetDrag,
  readAssetDrag,
  writeAssetDrag,
} from './assetDrag'

function fakeDataTransfer(initial: Record<string, string> = {}) {
  const store = { ...initial }
  return {
    effectAllowed: 'none',
    setData(type: string, value: string) {
      store[type] = value
    },
    getData(type: string) {
      return store[type] ?? ''
    },
  } as unknown as DataTransfer
}

describe('asset drag payload', () => {
  test('writes a plain-text fallback for WebKit', () => {
    const data = fakeDataTransfer()
    writeAssetDrag(data, '8E62425E')
    expect(data.getData(ASSET_DRAG_MIME)).toBe('8E62425E')
    expect(data.getData('text/plain')).toBe(`${ASSET_DRAG_PREFIX}8E62425E`)
  })

  test('reads the text fallback when the custom MIME is empty', () => {
    const data = fakeDataTransfer({
      'text/plain': `${ASSET_DRAG_PREFIX}asset-1`,
    })
    expect(readAssetDrag(data)).toBe('asset-1')
  })

  test('still writes the text fallback if custom MIME is rejected', () => {
    const data = fakeDataTransfer()
    const original = data.setData.bind(data)
    data.setData = (type: string, value: string) => {
      if (type === ASSET_DRAG_MIME) {
        throw new Error('unknown MIME type')
      }
      original(type, value)
    }
    writeAssetDrag(data, '8E62425E')
    expect(data.getData('text/plain')).toBe(`${ASSET_DRAG_PREFIX}8E62425E`)
    expect(readAssetDrag(data)).toBe('8E62425E')
  })

  test('ignores ordinary text drops', () => {
    const data = fakeDataTransfer({ 'text/plain': 'hello' })
    expect(readAssetDrag(data)).toBeNull()
    expect(isAssetDrag(['text/plain'])).toBe(true)
    expect(isAssetDrag(['Files'])).toBe(false)
  })
})

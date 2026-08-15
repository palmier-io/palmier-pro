import { describe, expect, test } from 'vitest'
import { previewFrameObjectUrl } from './previewFrame'

describe('preview frame urls', () => {
  test('rejects non-image payloads', () => {
    expect(
      previewFrameObjectUrl({
        width: 2,
        height: 2,
        mimeType: 'application/octet-stream',
        dataBase64: 'AAAA',
      }),
    ).toBeNull()
  })

  test('builds a blob url from jpeg bytes', () => {
    const url = previewFrameObjectUrl({
      width: 1,
      height: 1,
      mimeType: 'image/jpeg',
      dataBase64: 'QQ==',
    })
    expect(url).toMatch(/^blob:/)
    if (url) URL.revokeObjectURL(url)
  })
})

import type { PreviewFrame } from './model'

export function previewFrameObjectUrl(frame: PreviewFrame): string | null {
  if (!frame.dataBase64 || !frame.mimeType.startsWith('image/')) {
    return null
  }
  try {
    const binary = atob(frame.dataBase64)
    const bytes = new Uint8Array(binary.length)
    for (let index = 0; index < binary.length; index += 1) {
      bytes[index] = binary.charCodeAt(index)
    }
    return URL.createObjectURL(new Blob([bytes], { type: frame.mimeType }))
  } catch {
    return null
  }
}

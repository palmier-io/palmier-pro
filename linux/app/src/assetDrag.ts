export const ASSET_DRAG_MIME = 'application/x-palmier-asset'
export const ASSET_DRAG_PREFIX = 'palmier-asset:'

export function writeAssetDrag(data: DataTransfer, assetId: string): void {
  data.effectAllowed = 'copy'
  data.setData('text/plain', `${ASSET_DRAG_PREFIX}${assetId}`)
  try {
    data.setData(ASSET_DRAG_MIME, assetId)
  } catch {
    // WebKitGTK rejects custom MIME types.
  }
}

export function readAssetDrag(data: DataTransfer): string | null {
  const custom = data.getData(ASSET_DRAG_MIME).trim()
  if (custom) return custom
  const text = data.getData('text/plain').trim()
  if (text.startsWith(ASSET_DRAG_PREFIX)) {
    return text.slice(ASSET_DRAG_PREFIX.length)
  }
  return null
}

export function isAssetDrag(types: readonly string[]): boolean {
  return types.includes(ASSET_DRAG_MIME) || types.includes('text/plain')
}

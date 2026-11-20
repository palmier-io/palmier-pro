# Caption styles

`CaptionStyle` is a named caption look — bundled font, size ratio against canvas
height, weight, case, colour, outline, scrim/box, shadow, vertical position, and
the animation preset (with highlight colour for per-word looks). Resolution is a
pure clamped computation; 31 presets live in `CaptionStyles`, grouped Loud,
On a box, and Calm. Only bundled app fonts are referenced.

## Usage

- Panel: the Style group of the Captions tab renders every preset over sample
  text with `CaptionPreviewRender`. Selecting writes the id onto
  `EditorViewModel.selectedCaptionStyleId`, persisted as
  `ProjectFile.captionStyleId`; unknown ids fall back to the app default.
- Generation: the panel applies the resolved style, animation, and position.
- Agent: `add_captions captionStyle` accepts one curated id. It conflicts with
  `style`, `animation`, `highlightColor`, and x/rotation transforms (it encodes
  those decisions); unknown ids refuse with the full option list. The Agent is
  instructed to offer the gallery and ask before captioning.
- Readback: caption clips store the resolved style/animation from the
  generation path; `add_captions` returns the group summary exposing it, and
  `update_text` can restyle later per clip or group.

## Limits

- Native gallery/panel verification (focus, Escape, invalid styles, tiling on
  small panels) and representative playback remain manual.
- `deliveryVerified` and global project settings are unchanged.

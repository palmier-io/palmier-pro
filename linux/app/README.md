# Palmier for Linux

React 19 frontend for the Palmier Linux editor.

## Commands

```bash
npm install
npm run dev
npm run build
npm run lint
npm test
npm run tauri:dev
npm run tauri:build
```

Desktop shell lives in `src-tauri/` (`palmier-app`). Run Tauri commands from this directory so the CLI finds `src-tauri/tauri.conf.json`.

TypeScript command names are listed in `src/bindings/commands.ts`. Specta export is not enabled yet because workspace `specta` (rc.22) does not match current `tauri-specta` (needs rc.26+).

## Backend boundary

`src/backend.ts` selects the Tauri adapter when a Tauri runtime is present. A deterministic demo adapter is used in a browser and in tests.

The frontend owns transient interaction state. Project mutations go through the editor reducer so timeline changes share selection, undo, preview, inspector, and persistence behavior.

## Theme and localization

All fixed CSS values are defined in `src/AppTheme.css`. Component styles reference those tokens from `src/App.css`.

Fixed interface copy goes through `src/i18n.tsx`. Project names, filenames, prompts, and other user content are rendered verbatim.

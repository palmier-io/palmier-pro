# Intel Editor-Only Runtime Test Checklist

This checklist is for the experimental Intel editor-only app artifact. It is not
official Palmier Intel support.

## Test Setup

- Download the latest `palmier-pro-intel-editor-only-app` artifact from the
  passing GitHub Actions run on branch `intel-mac-support-experiment`.
- Confirm the app is running on an Intel Mac, not through Rosetta on Apple
  Silicon.
- Confirm the machine is running macOS 15.7.7 or the target macOS 15 version.
- Keep the app outside `/Applications` unless intentionally testing install
  behavior.
- Do not bypass macOS security beyond normal user-controlled open prompts.

## Smoke Tests

- Launch the app.
- Confirm the main editor window opens.
- Confirm no account, generation, or updater error appears on launch.
- Open About or Settings if available and check for obvious broken controls.
- Quit and relaunch once.

## Import And Timeline

- Import a short screen recording with audio.
- Import a short video without audio.
- Import an image.
- Import an audio-only file if supported by the UI.
- Drag imported media into the timeline.
- Play and pause the timeline.
- Scrub the playhead.
- Split a clip.
- Trim a clip start and end.
- Move a clip on the same track.
- Move a clip to another track.
- Add a text or caption clip manually.
- Undo and redo a few edits.
- Confirm no editor-only disabled-feature message appears during local editing.

## Project Save And Reopen

- Save a new `.palmier` project.
- Close the project.
- Reopen the saved project.
- Confirm imported media references remain connected.
- Confirm timeline clips, text, timing, and tracks are preserved.
- Move the project package to another folder and reopen it if the app supports
  that workflow.

## Export

- Export a short H.264 `.mp4`.
- Open the exported video in QuickTime Player.
- Confirm video duration, resolution, audio, and text overlays.
- Export a short HEVC file if available.
- Export XML if available.
- Export a Palmier project package if available.
- Try canceling an export and confirm the app remains usable.

## Search And Indexing

- Let the app finish any local visual indexing work.
- Search for visual content in an imported video or image.
- Confirm the search UI handles missing or downloading models gracefully.
- Confirm spoken/audio search does not crash when no transcript exists.
- If a project already has transcript data, test spoken search against it.

## Disabled Feature Behavior

These features are expected to be unavailable in the experimental Intel
editor-only build. Each should show a clear message and should not crash:

- Account login or profile management.
- Subscription, billing, credits, or plan management.
- Hosted AI image generation.
- Hosted AI video generation.
- Hosted AI audio/music generation.
- Upscale, rerun, or hosted generation download flows.
- Hosted model catalog loading.
- Automatic transcription.
- Automatic caption generation from audio.
- Backend feedback submission.
- Hosted Palmier agent streaming that requires Palmier auth.
- Sparkle automatic update checks against the official Palmier feed.

Expected message:

```text
This feature is unavailable in the experimental Intel editor-only build.
```

## Stability Pass

- Use the app for 20 to 30 minutes with a small project.
- Watch for beachballs, crashes, runaway CPU, or memory growth.
- Check Console.app for repeated crashes or sandbox/security errors.
- Confirm quitting the app does not leave export or indexing work stuck.

## Results To Record

- GitHub Actions run URL.
- Artifact name and download time.
- Mac model, CPU, RAM, and macOS version.
- Whether launch passed.
- Whether import/edit/playback passed.
- Whether save/reopen passed.
- Whether export passed.
- Whether disabled features showed clear messages.
- Any crash logs, Console messages, or exact UI errors.

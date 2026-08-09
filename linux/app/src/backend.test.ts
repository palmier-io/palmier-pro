import { describe, expect, test } from 'vitest'
import { createDemoBackend } from './backend'

describe('demo backend edits', () => {
  test('commit_edit applies move and undo with revision checks', async () => {
    const backend = createDemoBackend({ latencyMs: 0 })
    const project = await backend.createProject('Edit study')

    const moved = await backend.commitEdit({
      projectId: project.id,
      expectedRevision: 0,
      command: {
        command: 'moveClips',
        timelineId: project.timelineId,
        moves: [
          {
            clipId: 'clip-eye',
            trackId: 'track-v1',
            startFrame: 120,
          },
        ],
      },
    })

    expect(moved.revision).toBe(1)
    expect(moved.receipt.status).toBe('applied')
    const eye = moved.project.tracks
      .flatMap((track) => track.clips)
      .find((clip) => clip.id === 'clip-eye')
    expect(eye?.startFrame).toBe(120)
    expect(moved.undoDepth).toBe(1)

    await expect(
      backend.commitEdit({
        projectId: project.id,
        expectedRevision: 0,
        command: { command: 'undo' },
      }),
    ).rejects.toThrow(/Revision mismatch/)

    const undone = await backend.commitEdit({
      projectId: project.id,
      expectedRevision: 1,
      command: { command: 'undo' },
    })
    expect(undone.revision).toBe(2)
    expect(undone.receipt.status).toBe('undone')
    const restored = undone.project.tracks
      .flatMap((track) => track.clips)
      .find((clip) => clip.id === 'clip-eye')
    expect(restored?.startFrame).toBe(90)
  })

  test('preview_edit does not persist mutations', async () => {
    const backend = createDemoBackend({ latencyMs: 0 })
    const project = await backend.createProject('Preview study')

    const preview = await backend.previewEdit({
      projectId: project.id,
      expectedRevision: 0,
      command: {
        command: 'removeClips',
        timelineId: project.timelineId,
        clipIds: ['clip-eye'],
      },
    })
    expect(
      preview.project.tracks.some((track) =>
        track.clips.some((clip) => clip.id === 'clip-eye'),
      ),
    ).toBe(false)

    const committed = await backend.commitEdit({
      projectId: project.id,
      expectedRevision: 0,
      command: {
        command: 'splitClip',
        timelineId: project.timelineId,
        clipId: 'clip-ferns',
        atFrame: 30,
      },
    })
    expect(committed.revision).toBe(1)
    expect(
      committed.project.tracks
        .flatMap((track) => track.clips)
        .some((clip) => clip.id === 'clip-eye'),
    ).toBe(true)
  })
})

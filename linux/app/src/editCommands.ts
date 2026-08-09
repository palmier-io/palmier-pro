import type {
  EditorCommand,
  MutationKind,
  MutationReceipt,
  MutationStatus,
  ProjectDocument,
  TimelineClip,
  TimelineTrack,
} from './model'

export type RemoteEditPlan =
  | { kind: 'command'; command: EditorCommand }
  | { kind: 'unsupported'; feature: string; message: string }
  | { kind: 'noop' }

function cloneProject(project: ProjectDocument): ProjectDocument {
  return JSON.parse(JSON.stringify(project)) as ProjectDocument
}

function sortClips(track: TimelineTrack): TimelineTrack {
  return {
    ...track,
    clips: [...track.clips].sort(
      (left, right) => left.startFrame - right.startFrame,
    ),
  }
}

function findClip(
  project: ProjectDocument,
  clipId: string,
): TimelineClip | null {
  for (const track of project.tracks) {
    const clip = track.clips.find((candidate) => candidate.id === clipId)
    if (clip) return clip
  }
  return null
}

function updateClip(
  project: ProjectDocument,
  clipId: string,
  update: (clip: TimelineClip) => TimelineClip,
): ProjectDocument {
  return {
    ...project,
    tracks: project.tracks.map((track) => ({
      ...track,
      clips: track.clips.map((clip) =>
        clip.id === clipId ? update(clip) : clip,
      ),
    })),
  }
}

function receipt(
  action: MutationKind,
  status: MutationStatus,
  revisionBefore: number,
  revisionAfter: number,
  timelineId: string,
  partial: Partial<MutationReceipt> = {},
): MutationReceipt {
  return {
    action,
    status,
    revisionBefore,
    revisionAfter,
    timelineId,
    createdClipIds: [],
    updatedClipIds: [],
    removedClipIds: [],
    affectedTrackIds: [],
    createdTrackIds: [],
    removedTrackIds: [],
    skippedIds: [],
    warnings: [],
    details: {},
    ...partial,
  }
}

export function planMoveClip(
  project: ProjectDocument,
  clipId: string,
  trackId: string,
  startFrame: number,
): RemoteEditPlan {
  const clip = findClip(project, clipId)
  if (!clip) return { kind: 'noop' }
  return {
    kind: 'command',
    command: {
      command: 'moveClips',
      timelineId: project.timelineId,
      moves: [
        {
          clipId,
          trackId,
          startFrame: Math.max(0, Math.round(startFrame)),
        },
      ],
    },
  }
}

export function planTrimClip(
  project: ProjectDocument,
  clipId: string,
  edge: 'start' | 'end',
  delta: number,
): RemoteEditPlan {
  const clip = findClip(project, clipId)
  if (!clip || delta === 0) return { kind: 'noop' }
  const sourceDelta = Math.round(delta * clip.speed)
  const trimStartFrame =
    edge === 'start'
      ? Math.max(0, clip.sourceOffsetFrames + sourceDelta)
      : clip.sourceOffsetFrames
  const trimEndFrame =
    edge === 'end'
      ? Math.max(0, clip.trimEndFrames - sourceDelta)
      : clip.trimEndFrames
  return {
    kind: 'command',
    command: {
      command: 'trimClips',
      timelineId: project.timelineId,
      edits: [{ clipId, trimStartFrame, trimEndFrame }],
    },
  }
}

export function planSplitClip(
  project: ProjectDocument,
  clipId: string,
  atFrame: number,
): RemoteEditPlan {
  const clip = findClip(project, clipId)
  if (
    !clip ||
    atFrame <= clip.startFrame ||
    atFrame >= clip.startFrame + clip.durationFrames
  ) {
    return { kind: 'noop' }
  }
  return {
    kind: 'command',
    command: {
      command: 'splitClip',
      timelineId: project.timelineId,
      clipId,
      atFrame: Math.round(atFrame),
    },
  }
}

export function planRemoveClips(
  project: ProjectDocument,
  clipIds: string[],
): RemoteEditPlan {
  if (clipIds.length === 0) return { kind: 'noop' }
  return {
    kind: 'command',
    command: {
      command: 'removeClips',
      timelineId: project.timelineId,
      clipIds: [...clipIds],
      pruneEmptyTracks: false,
    },
  }
}

export function planUpdateTrack(
  project: ProjectDocument,
  trackId: string,
  setting: 'muted' | 'hidden' | 'locked',
): RemoteEditPlan {
  const track = project.tracks.find((candidate) => candidate.id === trackId)
  if (!track) return { kind: 'noop' }
  if (setting === 'locked') {
    return {
      kind: 'unsupported',
      feature: 'trackLock',
      message: 'unsupportedFeature:trackLock',
    }
  }
  return {
    kind: 'command',
    command: {
      command: 'updateTrack',
      timelineId: project.timelineId,
      trackId,
      patch: {
        [setting]: !track[setting],
      },
    },
  }
}

export function planClipPropertyEdit(
  project: ProjectDocument,
  clipId: string,
  patch: {
    speed?: number
    volume?: number
    fadeInFrames?: number
    fadeOutFrames?: number
    transform?: Partial<TimelineClip['transform']>
  },
): RemoteEditPlan {
  const clip = findClip(project, clipId)
  if (!clip) return { kind: 'noop' }

  if (patch.speed !== undefined) {
    return {
      kind: 'unsupported',
      feature: 'speed',
      message: 'unsupportedFeature:speed',
    }
  }
  if (patch.fadeInFrames !== undefined || patch.fadeOutFrames !== undefined) {
    return {
      kind: 'unsupported',
      feature: 'fades',
      message: 'unsupportedFeature:fades',
    }
  }

  if (patch.volume !== undefined) {
    return {
      kind: 'command',
      command: {
        command: 'upsertKeyframe',
        timelineId: project.timelineId,
        clipId,
        property: 'volume',
        frame: clip.startFrame,
        value: patch.volume,
      },
    }
  }

  const transform = patch.transform
  if (!transform) return { kind: 'noop' }

  if (transform.opacity !== undefined) {
    return {
      kind: 'command',
      command: {
        command: 'upsertKeyframe',
        timelineId: project.timelineId,
        clipId,
        property: 'opacity',
        frame: clip.startFrame,
        value: transform.opacity / 100,
      },
    }
  }
  if (transform.rotation !== undefined) {
    return {
      kind: 'command',
      command: {
        command: 'upsertKeyframe',
        timelineId: project.timelineId,
        clipId,
        property: 'rotation',
        frame: clip.startFrame,
        value: transform.rotation,
      },
    }
  }
  if (transform.positionX !== undefined || transform.positionY !== undefined) {
    return {
      kind: 'command',
      command: {
        command: 'upsertKeyframe',
        timelineId: project.timelineId,
        clipId,
        property: 'position',
        frame: clip.startFrame,
        value: {
          a: (transform.positionX ?? clip.transform.positionX) / 100 + 0.5,
          b: (transform.positionY ?? clip.transform.positionY) / 100 + 0.5,
        },
      },
    }
  }
  if (transform.scale !== undefined) {
    const normalized = transform.scale / 100
    return {
      kind: 'command',
      command: {
        command: 'upsertKeyframe',
        timelineId: project.timelineId,
        clipId,
        property: 'scale',
        frame: clip.startFrame,
        value: { a: normalized, b: normalized },
      },
    }
  }

  return { kind: 'noop' }
}

export function planProjectSettings(
  project: ProjectDocument,
  patch: Partial<Pick<ProjectDocument, 'width' | 'height' | 'fps'>>,
): RemoteEditPlan {
  if (
    patch.width === undefined &&
    patch.height === undefined &&
    patch.fps === undefined
  ) {
    return { kind: 'noop' }
  }
  return {
    kind: 'command',
    command: {
      command: 'changeProjectSettings',
      timelineId: project.timelineId,
      fps: patch.fps ?? project.fps,
      width: patch.width ?? project.width,
      height: patch.height ?? project.height,
    },
  }
}

export function applyEditorCommand(
  project: ProjectDocument,
  revision: number,
  command: EditorCommand,
): { project: ProjectDocument; receipt: MutationReceipt; revision: number } {
  const timelineId = project.timelineId
  const revisionBefore = revision

  switch (command.command) {
    case 'undo':
    case 'redo':
      return {
        project: cloneProject(project),
        revision,
        receipt: receipt(
          command.command,
          'noOp',
          revisionBefore,
          revisionBefore,
          timelineId,
          { warnings: ['Demo history is owned by the editor UI'] },
        ),
      }
    case 'moveClips': {
      let next = cloneProject(project)
      const updated: string[] = []
      for (const move of command.moves) {
        const clip = findClip(next, move.clipId)
        const destination = next.tracks.find(
          (track) => track.id === move.trackId,
        )
        if (!clip || !destination || destination.locked) continue
        const compatible =
          (clip.kind === 'audio' && destination.kind === 'audio') ||
          (clip.kind !== 'audio' && destination.kind === 'video')
        if (!compatible) continue
        const moved = {
          ...clip,
          trackId: destination.id,
          startFrame: Math.max(0, Math.round(move.startFrame)),
        }
        next = {
          ...next,
          tracks: next.tracks.map((track) =>
            sortClips({
              ...track,
              clips: [
                ...track.clips.filter(
                  (candidate) => candidate.id !== move.clipId,
                ),
                ...(track.id === destination.id ? [moved] : []),
              ],
            }),
          ),
        }
        updated.push(move.clipId)
      }
      const revisionAfter = updated.length > 0 ? revision + 1 : revision
      return {
        project: next,
        revision: revisionAfter,
        receipt: receipt(
          'moveClips',
          updated.length > 0 ? 'applied' : 'noOp',
          revisionBefore,
          revisionAfter,
          timelineId,
          { updatedClipIds: updated },
        ),
      }
    }
    case 'trimClips': {
      let next = cloneProject(project)
      const updated: string[] = []
      for (const edit of command.edits) {
        const clip = findClip(next, edit.clipId)
        if (!clip) continue
        const startDelta = Math.round(
          (edit.trimStartFrame - clip.sourceOffsetFrames) / clip.speed,
        )
        const endDelta = Math.round(
          (clip.trimEndFrames - edit.trimEndFrame) / clip.speed,
        )
        next = updateClip(next, edit.clipId, (current) => {
          let startFrame = current.startFrame
          let durationFrames = current.durationFrames
          let sourceOffsetFrames = current.sourceOffsetFrames
          if (startDelta !== 0) {
            const applied = Math.max(
              -current.startFrame,
              Math.min(current.durationFrames - 3, startDelta),
            )
            startFrame = current.startFrame + applied
            durationFrames = current.durationFrames - applied
            sourceOffsetFrames = Math.max(
              0,
              current.sourceOffsetFrames + applied,
            )
          }
          if (endDelta !== 0) {
            durationFrames = Math.max(3, durationFrames + endDelta)
          }
          return {
            ...current,
            startFrame,
            durationFrames,
            sourceOffsetFrames,
            trimEndFrames: edit.trimEndFrame,
          }
        })
        updated.push(edit.clipId)
      }
      const revisionAfter = updated.length > 0 ? revision + 1 : revision
      return {
        project: next,
        revision: revisionAfter,
        receipt: receipt(
          'trimClips',
          updated.length > 0 ? 'applied' : 'noOp',
          revisionBefore,
          revisionAfter,
          timelineId,
          { updatedClipIds: updated },
        ),
      }
    }
    case 'splitClip': {
      const clip = findClip(project, command.clipId)
      if (
        !clip ||
        command.atFrame <= clip.startFrame ||
        command.atFrame >= clip.startFrame + clip.durationFrames
      ) {
        return {
          project: cloneProject(project),
          revision,
          receipt: receipt(
            'splitClip',
            'noOp',
            revisionBefore,
            revisionBefore,
            timelineId,
          ),
        }
      }
      const firstDuration = command.atFrame - clip.startFrame
      const secondId = `${clip.id}-split-${command.atFrame}`
      const next = {
        ...project,
        tracks: project.tracks.map((track) =>
          sortClips({
            ...track,
            clips: track.clips.flatMap((candidate) => {
              if (candidate.id !== command.clipId) return [candidate]
              const second: TimelineClip = {
                ...candidate,
                id: secondId,
                startFrame: command.atFrame,
                durationFrames: candidate.durationFrames - firstDuration,
                sourceOffsetFrames:
                  candidate.sourceOffsetFrames +
                  Math.round(firstDuration * candidate.speed),
              }
              return [
                { ...candidate, durationFrames: firstDuration },
                second,
              ]
            }),
          }),
        ),
      }
      const revisionAfter = revision + 1
      return {
        project: next,
        revision: revisionAfter,
        receipt: receipt(
          'splitClip',
          'applied',
          revisionBefore,
          revisionAfter,
          timelineId,
          {
            createdClipIds: [secondId],
            updatedClipIds: [command.clipId],
          },
        ),
      }
    }
    case 'removeClips': {
      const selected = new Set(command.clipIds)
      const next = {
        ...project,
        tracks: project.tracks.map((track) => ({
          ...track,
          clips: track.clips.filter((clip) => !selected.has(clip.id)),
        })),
      }
      const revisionAfter = revision + 1
      return {
        project: next,
        revision: revisionAfter,
        receipt: receipt(
          'removeClips',
          'applied',
          revisionBefore,
          revisionAfter,
          timelineId,
          { removedClipIds: [...command.clipIds] },
        ),
      }
    }
    case 'updateTrack': {
      const next = {
        ...project,
        tracks: project.tracks.map((track) =>
          track.id === command.trackId
            ? {
                ...track,
                muted: command.patch.muted ?? track.muted,
                hidden: command.patch.hidden ?? track.hidden,
              }
            : track,
        ),
      }
      const revisionAfter = revision + 1
      return {
        project: next,
        revision: revisionAfter,
        receipt: receipt(
          'updateTrack',
          'applied',
          revisionBefore,
          revisionAfter,
          timelineId,
          { affectedTrackIds: [command.trackId] },
        ),
      }
    }
    case 'upsertKeyframe': {
      const clip = findClip(project, command.clipId)
      if (!clip) {
        return {
          project: cloneProject(project),
          revision,
          receipt: receipt(
            'upsertKeyframe',
            'noOp',
            revisionBefore,
            revisionBefore,
            timelineId,
          ),
        }
      }
      const next = updateClip(project, command.clipId, (current) => {
        if (command.property === 'volume' && typeof command.value === 'number') {
          return { ...current, volume: command.value }
        }
        if (
          command.property === 'opacity' &&
          typeof command.value === 'number'
        ) {
          return {
            ...current,
            transform: {
              ...current.transform,
              opacity: command.value * 100,
            },
          }
        }
        if (
          command.property === 'rotation' &&
          typeof command.value === 'number'
        ) {
          return {
            ...current,
            transform: {
              ...current.transform,
              rotation: command.value,
            },
          }
        }
        if (
          command.property === 'position' &&
          typeof command.value === 'object' &&
          'a' in command.value
        ) {
          return {
            ...current,
            transform: {
              ...current.transform,
              positionX: (command.value.a - 0.5) * 100,
              positionY: (command.value.b - 0.5) * 100,
            },
          }
        }
        if (
          command.property === 'scale' &&
          typeof command.value === 'object' &&
          'a' in command.value
        ) {
          return {
            ...current,
            transform: {
              ...current.transform,
              scale: command.value.a * 100,
            },
          }
        }
        return current
      })
      const revisionAfter = revision + 1
      return {
        project: next,
        revision: revisionAfter,
        receipt: receipt(
          'upsertKeyframe',
          'applied',
          revisionBefore,
          revisionAfter,
          timelineId,
          { updatedClipIds: [command.clipId] },
        ),
      }
    }
    case 'changeProjectSettings': {
      const next = {
        ...project,
        fps: command.fps,
        width: command.width,
        height: command.height,
      }
      const revisionAfter = revision + 1
      return {
        project: next,
        revision: revisionAfter,
        receipt: receipt(
          'changeProjectSettings',
          'applied',
          revisionBefore,
          revisionAfter,
          timelineId,
        ),
      }
    }
    default: {
      const unsupported = command as { command?: string }
      return {
        project: cloneProject(project),
        revision,
        receipt: receipt(
          'moveClips',
          'noOp',
          revisionBefore,
          revisionBefore,
          timelineId,
          {
            warnings: [
              `Unsupported demo command: ${unsupported.command ?? 'unknown'}`,
            ],
          },
        ),
      }
    }
  }
}

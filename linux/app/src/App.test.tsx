import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, test } from 'vitest'
import App from './App'
import { createDemoBackend } from './backend'

async function renderEditor(projectName = 'Test cut') {
  const user = userEvent.setup()
  render(<App backend={createDemoBackend({ latencyMs: 0 })} />)

  await screen.findByRole('heading', { name: 'Welcome to Palmier' })
  await user.click(
    screen.getAllByRole('button', { name: 'New Project' })[0]!,
  )
  const nameInput = screen.getByRole('textbox', { name: 'Project name' })
  await user.clear(nameInput)
  await user.type(nameInput, projectName)
  await user.click(screen.getByRole('button', { name: 'Create' }))
  await screen.findByRole('button', { name: 'eye_macro' })

  return user
}

describe('Palmier editor', () => {
  test('creates a project from the home screen', async () => {
    await renderEditor('Night study')

    expect(screen.getAllByText('Night study').length).toBeGreaterThan(0)
    expect(
      screen.getByRole('region', { name: 'Media' }),
    ).toBeInTheDocument()
    expect(
      screen.getByRole('region', { name: 'Preview' }),
    ).toBeInTheDocument()
    expect(
      screen.getByRole('region', { name: 'Inspector' }),
    ).toBeInTheDocument()
    expect(
      screen.getByRole('region', { name: 'Timeline' }),
    ).toBeInTheDocument()
  })

  test('deletes a selected clip and restores it with undo', async () => {
    const user = await renderEditor()
    const clip = screen.getByRole('button', { name: 'eye_macro' })

    await user.click(clip)
    await user.click(
      screen.getByRole('button', { name: 'Delete Selection' }),
    )
    expect(
      screen.queryByRole('button', { name: 'eye_macro' }),
    ).not.toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: 'Undo' }))
    expect(
      screen.getByRole('button', { name: 'eye_macro' }),
    ).toBeInTheDocument()
  })

  test('guards editor shortcuts while typing in a search field', async () => {
    const user = await renderEditor()
    const razor = screen.getByRole('button', { name: 'Razor' })

    await user.click(razor)
    expect(razor).toHaveAttribute('aria-pressed', 'true')

    const search = screen.getByRole('textbox', { name: 'Search media' })
    await user.click(search)
    await user.type(search, 'v')

    expect(razor).toHaveAttribute('aria-pressed', 'true')
    expect(
      screen.getByRole('button', { name: 'Pointer' }),
    ).not.toHaveAttribute('aria-pressed', 'true')
  })

  test(
    'switches layouts and queues an export',
    async () => {
      const user = await renderEditor()
      const layout = screen.getByRole('combobox', { name: 'Layout' })

      await user.selectOptions(layout, 'vertical')
      expect(layout).toHaveValue('vertical')

      await user.click(screen.getByRole('button', { name: 'Export' }))
      expect(
        screen.getByRole('dialog', { name: 'Export' }),
      ).toBeInTheDocument()
      await user.click(screen.getByRole('button', { name: 'Start Export' }))

      await waitFor(
        () => {
          expect(
            screen.getByText('Aesthetic-video-1.mp4'),
          ).toBeInTheDocument()
        },
        { timeout: 10_000 },
      )
    },
    15_000,
  )
})

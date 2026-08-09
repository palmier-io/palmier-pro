import type { BackendAdapter } from './model'
import { DialogHost } from './Dialogs'
import { EditorShell } from './EditorShell'
import { EditorProvider, useEditor } from './editorState'
import { HomeView } from './HomeView'
import { LocalizationProvider } from './i18n'
import './AppTheme.css'
import './App.css'

function PalmierApp() {
  const { state } = useEditor()
  return (
    <>
      {state.screen === 'home' ? <HomeView /> : <EditorShell />}
      <DialogHost />
    </>
  )
}

export interface AppProps {
  backend?: BackendAdapter
}

function App({ backend }: AppProps) {
  return (
    <LocalizationProvider>
      <EditorProvider backend={backend}>
        <PalmierApp />
      </EditorProvider>
    </LocalizationProvider>
  )
}

export default App

import AppKit

Log.bootstrap()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.mainMenu = MainMenuBuilder.buildMenu()
app.run()

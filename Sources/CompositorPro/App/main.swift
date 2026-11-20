import AppKit

Log.bootstrap()

if CLIHandler.isCLIInvocation(CommandLine.arguments) {
    let exitCode = await CLIHandler.run(CommandLine.arguments)
    exit(Int32(exitCode))
}
Telemetry.start()
Analytics.start()
Analytics.capture(.appOpened)
BundledFonts.register()
AccountService.shared.configure()
ModelCatalog.shared.configure()

// Shorten the default tooltip delay from 2s to 0.01s.
UserDefaults.standard.set(10, forKey: "NSInitialToolTipDelay")

let app = NSApplication.shared
AppAppearanceStore.shared.apply()
let delegate = AppDelegate.shared
app.delegate = delegate
app.mainMenu = MainMenuBuilder.buildMenu()
app.run()

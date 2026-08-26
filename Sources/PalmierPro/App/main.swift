import AppKit

if let sceneURL = MotionSceneBakeCommand.sceneURL(from: CommandLine.arguments) {
    MotionSceneBakeCommand.run(sceneURL: sceneURL)
}

Log.bootstrap()
Telemetry.start()
Analytics.start()
Analytics.capture(.appOpened)
BundledFonts.register()
ElevenLabsService.shared.configure()
OpenRouterService.shared.configure()
GeminiOmniService.shared.configure()
AgentModelCatalog.shared.configure()

// Shorten the default tooltip delay from 2s to 0.01s.
UserDefaults.standard.set(10, forKey: "NSInitialToolTipDelay")

let app = NSApplication.shared
AppAppearanceStore.shared.apply()
let delegate = AppDelegate.shared
app.delegate = delegate
app.mainMenu = MainMenuBuilder.buildMenu()
app.run()

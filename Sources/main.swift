import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var reader: ReaderController?
    private var queuedURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        reader = ReaderController()
        reader?.showWindow()
        if let queuedURL { reader?.importURL(queuedURL); self.queuedURL = nil }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let reader { reader.showWindow(); reader.importURL(url) } else { queuedURL = url }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        reader?.showWindow()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        reader?.prepareToQuit() ?? .terminateNow
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
if let testIndex = CommandLine.arguments.firstIndex(of: "--ui-smoke-test") {
    let output = CommandLine.arguments.count > testIndex + 1 ? CommandLine.arguments[testIndex + 1] : "/private/tmp/CornerReaderPreview"
    do {
        try ReaderUITests.run(outputDirectory: URL(fileURLWithPath: output, isDirectory: true))
        print("UI smoke tests passed. Previews: \(output)")
        exit(0)
    } catch {
        fputs("UI smoke test failed: \(error)\n", stderr)
        exit(1)
    }
} else {
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}

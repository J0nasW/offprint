import OffprintCore
import SwiftUI

/// Receives files opened from Finder, the Dock, and `open -a Offprint file.pdf`.
///
/// SwiftUI's `onOpenURL` covers URL schemes but not file opens, so this still
/// needs an app delegate.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let didOpen = Notification.Name("OffprintDidOpenFiles")

    func applicationWillFinishLaunching(_ notification: Notification) {
        // No Dock icon, no menu bar, no window for a `--convert` run.
        if Headless.isRequested { NSApp.setActivationPolicy(.prohibited) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Headless work is started here rather than from App.init: almost
        // everything in this target is MainActor-isolated by default, so
        // blocking the main thread to wait for it deadlocks instead of running.
        guard Headless.isRequested else { return }
        Task { await Headless.run() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        NotificationCenter.default.post(name: Self.didOpen, object: nil,
                                        userInfo: ["urls": urls])
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct OffprintApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var library = ConversionLibrary()


    var body: some Scene {
        Window("Offprint", id: "main") {
            ContentView()
                .environment(library)
                .frame(minWidth: 720, minHeight: 480)
                .onReceive(NotificationCenter.default.publisher(for: AppDelegate.didOpen)) { note in
                    guard let urls = note.userInfo?["urls"] as? [URL] else { return }
                    library.add(urls)
                }
        }
        .defaultSize(width: 1000, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { library.add(FilePicker.chooseFiles()) }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .toolbar) {
                Button("Stop Converting") { library.cancelAll() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!library.isRunning)
            }
        }

        Settings {
            SettingsView().environment(library)
        }
    }
}

enum FilePicker {
    /// Presents the open panel for PDFs and folders of PDFs.
    static func chooseFiles() -> [URL] {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.pdf]
        panel.prompt = "Convert"
        panel.message = "Choose PDFs, or a folder of PDFs."
        return panel.runModal() == .OK ? panel.urls : []
    }

    /// Asks where to write the exports for a document.
    static func chooseExportDirectory(named name: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Save"
        panel.message = "Where should \(name) be saved?"
        return panel.runModal() == .OK ? panel.url : nil
    }
}

import AppKit
import SwiftUI

@main
@MainActor
struct SoNovelApp: App {
    @Environment(\.openWindow) private var openWindow
    @StateObject private var library = LibraryModel()
    @StateObject private var preferences = DownloadPreferences()

    var body: some Scene {
        Window("搜小说", id: "library") {
            LibraryView(library: library, preferences: preferences)
        }
        .defaultSize(width: 1130, height: 680)
        .defaultPosition(.center)

        Settings {
            PreferencesView(preferences: preferences)
        }

        MenuBarExtra("搜小说", systemImage: "books.vertical") {
            Button("显示搜小说") {
                openWindow(id: "library")
                NSApp.activate()
            }
            SettingsLink {
                Text("设置…")
            }
            Divider()
            Button("退出搜小说") {
                NSApp.terminate(nil)
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

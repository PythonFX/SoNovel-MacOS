import AppKit
import SoNovelCore
import SwiftUI

@MainActor
final class DownloadPreferences: ObservableObject {
    private let defaults: UserDefaults

    @Published private(set) var folder: URL {
        didSet { defaults.set(folder.path, forKey: "downloadFolder") }
    }

    @Published var format: BookFormat {
        didSet { defaults.set(format.rawValue, forKey: "downloadFormat") }
    }

    @Published var separateChapters: Bool {
        didSet { defaults.set(separateChapters, forKey: "separateChapters") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        folder = defaults.string(forKey: "downloadFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? downloads.appendingPathComponent("SoNovel", isDirectory: true)
        format = defaults.string(forKey: "downloadFormat").flatMap(BookFormat.init(rawValue:)) ?? .epub
        separateChapters = defaults.bool(forKey: "separateChapters")
    }

    var options: ExportOptions {
        ExportOptions(folder: folder, format: format, separateChapters: separateChapters)
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择下载位置"
        panel.prompt = "选择"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.fileExists(atPath: folder.path)
            ? folder : folder.deletingLastPathComponent()

        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { [weak self] response in
                if response == .OK, let url = panel.url {
                    self?.folder = url
                }
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            folder = url
        }
    }
}

struct PreferencesView: View {
    @ObservedObject var preferences: DownloadPreferences

    var body: some View {
        Form {
            Section("保存位置") {
                LabeledContent("下载文件夹") {
                    VStack(alignment: .trailing, spacing: 7) {
                        Text((preferences.folder.path as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                        Button("选择文件夹…") {
                            preferences.chooseFolder()
                        }
                    }
                }
            }

            Section("文件格式") {
                Picker("默认格式", selection: $preferences.format) {
                    ForEach(BookFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                Toggle("另外为每章保存一个 TXT 文件", isOn: $preferences.separateChapters)
            }
        }
        .formStyle(.grouped)
        .frame(width: 530)
        .fixedSize(horizontal: true, vertical: true)
    }
}

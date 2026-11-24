import AppKit
import SoNovelCore
import SwiftUI

struct DownloadView: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject var preferences: DownloadPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                bookSummary
                Spacer(minLength: 16)
                SettingsLink {
                    Label(preferences.format.displayName, systemImage: "folder")
                }
                .controlSize(.small)
                .help(preferences.folder.path)
            }

            HStack(spacing: 8) {
                Text("章节范围")
                    .foregroundStyle(.secondary)
                TextField("起始章", text: $library.firstChapter)
                    .accessibilityLabel("起始章")
                    .frame(width: 68)
                Text("至")
                    .foregroundStyle(.secondary)
                TextField("结束章", text: $library.lastChapter)
                    .accessibilityLabel("结束章")
                    .frame(width: 68)
                Button("下载章节") { library.downloadRange(options: preferences.options) }
                    .disabled(!canDownload)
                Spacer()
                Button {
                    library.downloadAll(options: preferences.options)
                } label: {
                    Label("下载全部", systemImage: "arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canDownload)
            }

            if let rangeError = library.rangeError {
                Label(rangeError, systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.red)
            } else {
                downloadStatus
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
    }

    private var canDownload: Bool {
        library.selectedBook != nil && !library.downloadState.isActive
    }

    @ViewBuilder
    private var bookSummary: some View {
        if let book = library.selectedBook {
            HStack(spacing: 8) {
                Text(book.title)
                    .font(.headline)
                    .help(book.title)
                if !book.author.isEmpty {
                    Text(book.author)
                        .foregroundStyle(.secondary)
                        .help(book.author)
                }
                Text(book.sourceName)
                    .foregroundStyle(.secondary)
                Link(destination: book.url) {
                    Image(systemName: "arrow.up.right.square")
                }
                .help(book.url.absoluteString)
                .accessibilityLabel("打开书源网页")
            }
            .lineLimit(1)
        } else {
            Text("选择一本小说后下载")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var downloadStatus: some View {
        switch library.downloadState {
        case .ready:
            EmptyView()
        case .loadingDirectory:
            activeDownload("正在读取目录…")
        case .downloading(let completed, let failed, let total):
            let progress = "已下载 \(completed)/\(total) 章"
            activeDownload(failed == 0 ? progress : "\(progress) · \(failed) 章失败", completed: completed + failed, total: total)
        case .exporting:
            activeDownload("正在写入文件…")
        case .done(let file):
            HStack(spacing: 8) {
                Label("已保存 \(file.lastPathComponent)", systemImage: "checkmark.circle")
                    .lineLimit(1)
                    .help(file.path)
                Spacer()
                Button("在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                }
                .controlSize(.small)
            }
            .font(.callout)
        case .cancelled:
            Label("下载已取消", systemImage: "xmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .incomplete(let completed, let total, let failures):
            HStack(spacing: 8) {
                Label("已下载 \(completed)/\(total) 章 · \(failures.count) 章失败", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                if let book = library.downloadBook {
                    Text("\(book.title) · \(book.sourceName)")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("失败详情") { library.showsDownloadFailures.toggle() }
                    .popover(isPresented: $library.showsDownloadFailures) {
                        ChapterFailuresView(failures: failures)
                    }
                Button("重试失败章节") { library.retryFailedChapters() }
                    .buttonStyle(.borderedProminent)
            }
            .font(.callout)
            .controlSize(.small)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.circle")
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .lineLimit(3)
                .help(message)
        }
    }

    private func activeDownload(_ message: String, completed: Int? = nil, total: Int? = nil) -> some View {
        HStack(spacing: 8) {
            if let completed, let total {
                ProgressView(value: Double(completed), total: Double(total))
                    .frame(width: 110)
                    .accessibilityLabel("章节下载进度")
            } else {
                ProgressView()
                    .accessibilityHidden(true)
            }
            Text(library.isCancellingDownload ? "正在取消…" : message)
                .monospacedDigit()
                .layoutPriority(1)
            if let title = library.downloadBook?.title {
                Text(title)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .help(title)
            }
            Spacer()
            Button("取消下载") { library.cancelDownload() }
                .disabled(library.isCancellingDownload)
        }
        .font(.callout)
        .controlSize(.small)
    }
}

private struct ChapterFailuresView: View {
    let failures: [ChapterDownloadFailure]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(failures) { failure in
                    VStack(alignment: .leading, spacing: 4) {
                        Link("打开目录第 \(failure.id) 项", destination: failure.chapter.url)
                        Text(failure.message)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
        .frame(width: 420, height: min(280, CGFloat(failures.count) * 75 + 20))
    }
}

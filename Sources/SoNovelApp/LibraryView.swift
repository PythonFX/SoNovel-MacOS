import AppKit
import SoNovelCore
import SwiftUI

struct LibraryView: View {
    @ObservedObject var library: LibraryModel
    @ObservedObject var preferences: DownloadPreferences
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            results
            Divider()
            DownloadView(library: library, preferences: preferences)
        }
        .frame(minWidth: 860, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .defaultFocus($searchFocused, true)
    }

    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("输入书名、作者或关键词", text: $library.keyword)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("搜索小说")
                        .focused($searchFocused)
                        .onSubmit { library.search() }
                    if !library.keyword.isEmpty {
                        Button {
                            library.keyword = ""
                            searchFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("清除关键词")
                        .accessibilityLabel("清除关键词")
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 33)
                .background(.background, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .strokeBorder(
                            searchFocused ? Color.accentColor : Color(nsColor: .separatorColor),
                            lineWidth: searchFocused ? 2 : 1
                        )
                        .allowsHitTesting(false)
                }

                Button {
                    library.search()
                } label: {
                    Text("搜书").frame(minWidth: 52)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!library.canSearch)

                Button {
                    library.showsSourceWebsites.toggle()
                } label: {
                    Label("书库网站", systemImage: "globe")
                }
                .controlSize(.large)
                .popover(isPresented: $library.showsSourceWebsites, arrowEdge: .bottom) {
                    SourceWebsitesView(library: library)
                }
            }

            HStack(spacing: 8) {
                if library.searchState == .searching {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
                Text(resultStatus)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if !library.sourceFailures.isEmpty {
                    Button {
                        library.showsSourceWebsites = true
                    } label: {
                        Label("\(library.sourceFailures.count) 个书源出错", systemImage: "exclamationmark.triangle")
                    }
                    .controlSize(.small)
                }
                Spacer()
                if library.searchState == .searching {
                    Button("停止搜索") {
                        library.stopSearch()
                    }
                    .controlSize(.small)
                }
            }
            .frame(minHeight: 22)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
    }

    private var resultStatus: String {
        switch library.searchState {
        case .ready:
            "已启用 \(library.sourceCount) 个书源"
        case .searching:
            "已搜索 \(library.completedSources)/\(library.sourceCount) 个书源 · \(library.books.count) 条结果"
        case .finished:
            "\(library.books.count) 条结果"
        case .cancelled:
            "搜索已停止 · \(library.books.count) 条结果"
        case .failed:
            "搜索出错 · \(library.books.count) 条结果"
        }
    }

    private var results: some View {
        Table(library.books, selection: $library.selectedID) {
            TableColumn("书名") { book in
                TableValue(value: book.title, emphasized: true)
            }
            .width(min: 135, ideal: 230)
            TableColumn("作者") { TableValue(value: $0.author) }
                .width(min: 75, ideal: 104)
            TableColumn("书源网站") { TableValue(value: $0.sourceName) }
                .width(min: 90, ideal: 115)
            TableColumn("状态") { TableValue(value: $0.status) }
                .width(min: 55, ideal: 68)
            TableColumn("分类") { TableValue(value: $0.category) }
                .width(min: 66, ideal: 78)
            TableColumn("最新章节") { TableValue(value: $0.latestChapter) }
                .width(min: 125, ideal: 192)
            TableColumn("更新时间") { TableValue(value: $0.updatedAt) }
                .width(min: 87, ideal: 120)
            TableColumn("总字数") { TableValue(value: $0.wordCount) }
                .width(min: 66, ideal: 82)
        }
        .alternatingRowBackgrounds(.enabled)
        .overlay {
            if library.books.isEmpty {
                emptyResults
                    .padding(.top, 24)
                    .padding(.horizontal, 35)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var emptyResults: some View {
        switch library.searchState {
        case .ready:
            if library.sourceCount == 0 {
                ContentUnavailableView("没有启用的书源", systemImage: "books.vertical")
            } else {
                ContentUnavailableView("搜索小说", systemImage: "magnifyingglass",
                                       description: Text("输入书名、作者或关键词以开始搜索。"))
            }
        case .searching:
            ContentUnavailableView("正在搜索", systemImage: "magnifyingglass",
                                   description: Text("各书源的结果会陆续显示。"))
        case .finished:
            if library.sourceFailures.count == library.sourceCount && library.sourceCount > 0 {
                ContentUnavailableView("本次搜索未能连接书源", systemImage: "exclamationmark.triangle",
                                       description: Text("可从「书库网站」打开主页，在站内手动搜索。"))
            } else {
                ContentUnavailableView("没有找到小说", systemImage: "text.magnifyingglass",
                                       description: Text("试试其他书名或关键词。"))
            }
        case .cancelled:
            ContentUnavailableView("搜索已停止", systemImage: "magnifyingglass")
        case .failed(let message):
            ContentUnavailableView("搜索不可用", systemImage: "exclamationmark.triangle",
                                   description: Text(message))
        }
    }
}

private struct TableValue: View {
    let value: String
    var emphasized = false

    var body: some View {
        Text(value.isEmpty ? "—" : value)
            .fontWeight(emphasized ? .medium : .regular)
            .foregroundStyle(value.isEmpty ? .tertiary : .primary)
            .lineLimit(1)
            .help(value)
    }
}


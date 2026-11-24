import Foundation
import SoNovelCore
import SwiftUI

@MainActor
final class LibraryModel: ObservableObject {
    enum SearchState: Equatable {
        case ready
        case searching
        case finished
        case cancelled
        case failed(String)
    }

    struct SourceFailure: Identifiable {
        let source: String
        let message: String
        var id: String { source }
    }

    enum DownloadState {
        case ready
        case loadingDirectory
        case downloading(completed: Int, failed: Int, total: Int)
        case exporting
        case done(URL)
        case cancelled
        case incomplete(completed: Int, total: Int, failures: [ChapterDownloadFailure])
        case failed(String)

        var isActive: Bool {
            switch self {
            case .loadingDirectory, .downloading, .exporting: true
            default: false
            }
        }
    }

    @Published var keyword = ""
    @Published var selectedID: BookResult.ID? {
        didSet { rangeError = nil }
    }
    @Published var showsSourceWebsites = false
    @Published var showsDownloadFailures = false
    @Published var firstChapter = "1" {
        didSet { rangeError = nil }
    }
    @Published var lastChapter = "" {
        didSet { rangeError = nil }
    }
    @Published private(set) var books: [BookResult] = []
    @Published private(set) var searchState = SearchState.ready
    @Published private(set) var sourceFailures: [SourceFailure] = []
    @Published private(set) var completedSources = 0
    @Published private(set) var downloadState = DownloadState.ready
    @Published private(set) var downloadBook: BookResult?
    @Published private(set) var isCancellingDownload = false
    @Published private(set) var rangeError: String?

    private let sources: Result<BookSources, Error>
    let sourceWebsites: Result<[SourceWebsite], Error>
    private let exporter = BookExporter()
    private var searchTask: Task<Void, Never>?
    private var searchID: UUID?
    private var downloadTask: Task<Void, Never>?
    private var pendingDownload: PendingDownload?

    private struct PendingDownload {
        let book: BookResult
        let range: ClosedRange<Int>?
        let options: ExportOptions
        let batch: ChapterDownloadBatch
    }

    init() {
        sources = Result { try BookSources(rulesData: loadBundledSourceRules()) }
        sourceWebsites = Result { try loadBundledSourceWebsites() }
        if case let .failure(error) = sources {
            searchState = .failed(error.localizedDescription)
        }
    }

    var selectedBook: BookResult? {
        books.first { $0.id == selectedID }
    }

    var sourceCount: Int { (try? sources.get().searchableSourceCount) ?? 0 }

    var searchableSourceIDs: Set<String> { (try? sources.get().searchableSourceIDs) ?? [] }

    var canSearch: Bool {
        sourceCount > 0 && !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func search() {
        guard canSearch, let sources = try? sources.get() else { return }
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        let id = UUID()
        searchID = id
        books = []
        selectedID = nil
        sourceFailures = []
        completedSources = 0
        searchState = .searching
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await sources.search(query) { [weak self] update in
                    guard let self, searchID == id, !Task.isCancelled else { return }
                    completedSources += 1
                    if let message = update.failure {
                        sourceFailures.append(SourceFailure(source: update.sourceName, message: message))
                    }
                    var known = Set(books.map(\.id))
                    let newBooks = update.books.filter { known.insert($0.id).inserted }
                    if !newBooks.isEmpty {
                        books = (books + newBooks).sorted { Self.compare($0, $1, query: query) }
                    }
                }
                guard searchID == id else { return }
                searchState = .finished
            } catch {
                guard searchID == id else { return }
                searchState = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
            }
            searchTask = nil
            searchID = nil
        }
    }

    func stopSearch() {
        searchID = nil
        searchTask?.cancel()
        searchTask = nil
        searchState = .cancelled
    }

    func downloadAll(options: ExportOptions) {
        download(range: nil, options: options)
    }

    func downloadRange(options: ExportOptions) {
        guard let first = Int(firstChapter.trimmingCharacters(in: .whitespacesAndNewlines)),
              let last = Int(lastChapter.trimmingCharacters(in: .whitespacesAndNewlines)),
              first > 0, last >= first else {
            rangeError = "请填写有效的章节范围。章节从 1 开始，结束章须大于或等于起始章。"
            return
        }
        download(range: first...last, options: options)
    }

    private func download(range: ClosedRange<Int>?, options: ExportOptions) {
        guard !downloadState.isActive, let book = selectedBook else { return }
        startDownload(book: book, range: range, options: options)
    }

    func retryFailedChapters() {
        guard !downloadState.isActive, let pending = pendingDownload else { return }
        startDownload(book: pending.book, range: pending.range, options: pending.options, batch: pending.batch)
    }

    private func startDownload(
        book: BookResult, range: ClosedRange<Int>?, options: ExportOptions, batch: ChapterDownloadBatch? = nil
    ) {
        guard let sources = try? sources.get() else { return }
        rangeError = nil
        showsDownloadFailures = false
        pendingDownload = nil
        downloadBook = book
        if let batch {
            downloadState = .downloading(completed: batch.chapters.count, failed: 0, total: batch.total)
        } else {
            downloadState = .loadingDirectory
        }
        downloadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                downloadTask = nil
                isCancellingDownload = false
            }
            do {
                let initial: ChapterDownloadBatch
                if let batch {
                    initial = batch
                } else {
                    let catalog = try await sources.chapters(for: book)
                    try Task.checkCancellation()
                    if let range, range.upperBound > catalog.count {
                        throw DownloadError.invalidRange(total: catalog.count)
                    }
                    let chosen = range.map { Array(catalog[($0.lowerBound - 1)..<$0.upperBound]) } ?? catalog
                    initial = ChapterDownloadBatch(chapters: chosen, catalog: catalog)
                }
                let result = try await sources.downloadChapters(initial, book: book) { completed, failed, total in
                    self.downloadState = .downloading(completed: completed, failed: failed, total: total)
                }
                try Task.checkCancellation()

                guard result.failures.isEmpty else {
                    pendingDownload = PendingDownload(book: book, range: range, options: options, batch: result)
                    downloadState = .incomplete(completed: result.chapters.count, total: result.total, failures: result.failures)
                    return
                }
                downloadState = .exporting
                let file = try await exporter.export(book: book, chapters: result.chapters, options: options, range: range)
                downloadState = .done(file)
            } catch {
                downloadState = Task.isCancelled ? .cancelled : .failed(error.localizedDescription)
            }
        }
    }

    func cancelDownload() {
        guard downloadState.isActive else { return }
        isCancellingDownload = true
        downloadTask?.cancel()
    }

    private static func compare(_ first: BookResult, _ second: BookResult, query: String) -> Bool {
        let firstRank = rank(first, query: query)
        let secondRank = rank(second, query: query)
        if firstRank != secondRank { return firstRank < secondRank }
        for (left, right) in [(first.title, second.title), (first.author, second.author),
                              (first.sourceName, second.sourceName)] {
            let order = left.localizedStandardCompare(right)
            if order != .orderedSame { return order == .orderedAscending }
        }
        return first.id < second.id
    }

    private static func rank(_ book: BookResult, query: String) -> Int {
        if book.title.localizedCaseInsensitiveCompare(query) == .orderedSame { return 0 }
        if book.author.localizedCaseInsensitiveCompare(query) == .orderedSame { return 1 }
        if book.title.localizedStandardContains(query) { return 2 }
        return 3
    }
}

private enum DownloadError: LocalizedError {
    case invalidRange(total: Int)

    var errorDescription: String? {
        switch self {
        case .invalidRange(let total):
            "这个书源的目录共 \(total) 章，请选择目录内的章节范围。"
        }
    }
}

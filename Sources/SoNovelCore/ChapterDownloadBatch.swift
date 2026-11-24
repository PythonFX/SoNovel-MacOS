import Foundation

public struct ChapterDownloadFailure: Identifiable, Sendable {
    public var id: Int { chapter.index }
    public let chapter: ChapterReference
    public let message: String
}

public struct ChapterDownloadBatch: Sendable {
    public let total: Int
    public fileprivate(set) var chapters: [DownloadedChapter] = []
    public fileprivate(set) var failures: [ChapterDownloadFailure] = []
    fileprivate var remaining: [ChapterReference]
    fileprivate let catalogURLs: Set<URL>

    public init(chapters: [ChapterReference], catalog: [ChapterReference]) {
        total = chapters.count
        remaining = chapters
        catalogURLs = Set(catalog.map(\.url))
    }

    fileprivate enum Outcome: Sendable {
        case downloaded(DownloadedChapter)
        case failed(ChapterDownloadFailure)
    }
}

extension BookSources {
    public func downloadChapters(
        _ batch: ChapterDownloadBatch,
        book: BookResult,
        onProgress: @MainActor (_ completed: Int, _ failed: Int, _ total: Int) -> Void
    ) async throws -> ChapterDownloadBatch {
        let concurrency = try chapterConcurrency(for: book)
        return try await withThrowingTaskGroup(of: ChapterDownloadBatch.Outcome.self) { group in
            var result = batch
            result.failures = []
            var waiting = batch.remaining.makeIterator()
            let catalogURLs = batch.catalogURLs

            func enqueueChapter() {
                guard let reference = waiting.next() else { return }
                group.addTask {
                    do {
                        let chapter = try await self.content(for: reference, book: book, catalogURLs: catalogURLs)
                        return .downloaded(chapter)
                    } catch {
                        try Task.checkCancellation()
                        return .failed(ChapterDownloadFailure(chapter: reference, message: error.localizedDescription))
                    }
                }
            }

            onProgress(result.chapters.count, 0, result.total)
            for _ in 0..<min(concurrency, batch.remaining.count) { enqueueChapter() }

            while let outcome = try await group.next() {
                try Task.checkCancellation()
                switch outcome {
                case .downloaded(let chapter): result.chapters.append(chapter)
                case .failed(let failure): result.failures.append(failure)
                }
                onProgress(result.chapters.count, result.failures.count, result.total)
                enqueueChapter()
            }

            result.chapters.sort { $0.index < $1.index }
            result.failures.sort { $0.id < $1.id }
            result.remaining = result.failures.map(\.chapter)
            return result
        }
    }
}

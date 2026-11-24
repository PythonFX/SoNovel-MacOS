import CoreFoundation
import Foundation
import OSLog

public struct BookResult: Identifiable, Hashable, Sendable {
    public var id: String { sourceID + "\u{1F}" + url.absoluteString }

    public let title: String
    public let author: String
    public let sourceName: String
    public let category: String
    public let status: String
    public let latestChapter: String
    public let updatedAt: String
    public let wordCount: String
    public let url: URL
    public let sourceID: String

    public init(
        title: String, author: String = "", sourceName: String, category: String = "",
        status: String = "", latestChapter: String = "", updatedAt: String = "", wordCount: String = "",
        url: URL, sourceID: String
    ) {
        self.title = title
        self.author = author
        self.sourceName = sourceName
        self.category = category
        self.status = status
        self.latestChapter = latestChapter
        self.updatedAt = updatedAt
        self.wordCount = wordCount
        self.url = url
        self.sourceID = sourceID
    }
}

public struct SearchUpdate: Sendable {
    public let sourceName: String
    public let books: [BookResult]
    public let failure: String?

    public init(sourceName: String, books: [BookResult], failure: String? = nil) {
        self.sourceName = sourceName
        self.books = books
        self.failure = failure
    }
}

public struct ChapterReference: Sendable {
    public let index: Int
    public let title: String
    public let url: URL

    public init(index: Int, title: String, url: URL) {
        self.index = index
        self.title = title
        self.url = url
    }
}

public struct DownloadedChapter: Sendable {
    public let index: Int
    public let title: String
    public let paragraphs: [String]

    public init(index: Int, title: String, paragraphs: [String]) {
        self.index = index
        self.title = title
        self.paragraphs = paragraphs
    }
}

@MainActor
public final class BookSources {
    static let defaultChapterConcurrency = 16
    private static let downloadLog = Logger(subsystem: "com.pcdd.sonovel.macos", category: "Download")
    private static let liveSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = defaultChapterConcurrency
        return URLSession(configuration: configuration)
    }()

    private let rules: [SourceRule]
    private let session: URLSession
    private lazy var parser = SourceHTML()

    public init(rulesData: Data, session: URLSession? = nil) throws {
        rules = try JSONDecoder().decode([SourceRule].self, from: rulesData)
        self.session = session ?? Self.liveSession
    }

    public var searchableSourceCount: Int { searchableRules.count }

    public var searchableSourceIDs: Set<String> { Set(searchableRules.map(\.id)) }

    public func search(_ keyword: String, onUpdate: @escaping @MainActor (SearchUpdate) -> Void) async throws {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }

        try await withThrowingTaskGroup(of: SearchUpdate.self) { group in
            for rule in searchableRules {
                guard let searchRule = rule.search else { continue }
                group.addTask {
                    try await self.search(keyword, source: rule, rule: searchRule)
                }
            }

            for try await update in group {
                try Task.checkCancellation()
                onUpdate(update)
            }
        }
    }

    public func chapters(for book: BookResult) async throws -> [ChapterReference] {
        let source = try source(for: book)
        let rule = source.toc
        let identifier = Self.bookIdentifier(url: book.url, rule: source.book?.url)
        let firstURL: URL
        if let template = rule.url, !template.isEmpty {
            let expanded = try Self.expand(template, with: identifier)
            firstURL = try Self.httpURL(expanded, relativeTo: book.url)
        } else {
            firstURL = book.url
        }

        func read(_ url: URL) async throws -> (contents: CatalogPage, canonicalURL: URL) {
            let page = try await fetch(url, timeout: rule.timeout ?? 60)
            let base = try rule.baseUri.flatMap { template in
                try Self.httpURL(Self.expand(template, with: identifier), relativeTo: page.url)
            } ?? page.url

            let contents: CatalogPage = try await parser.parse(page.html, operation: "toc", options: [
                "baseURL": base.absoluteString,
                "list": rule.list ?? "",
                "item": rule.item,
                "nextPage": rule.nextPage ?? ""
            ])
            return (contents, page.url)
        }

        let (firstPage, canonicalURL) = try await read(firstURL)
        var rows = [CatalogRow]()
        func append(_ page: CatalogPage) {
            // The rule controls the chapter order within a page. Pagination
            // still follows the directory controls in their original order.
            rows.append(contentsOf: rule.isDesc == true ? Array(page.rows.reversed()) : page.rows)
        }
        let optionURLs = firstPage.next.filter(\.isOption).map(\.url)
        if !optionURLs.isEmpty {
            // The dropdown supplies the order. Its first option need not be the page we fetched.
            let hasFirstPage = optionURLs.contains(canonicalURL) || optionURLs.contains(firstURL)
            var visited = hasFirstPage ? Set<URL>() : [canonicalURL]
            if !hasFirstPage { append(firstPage) }
            for optionURL in optionURLs {
                let url = optionURL == firstURL ? canonicalURL : optionURL
                guard visited.insert(url).inserted else { continue }
                if url == canonicalURL {
                    append(firstPage)
                } else {
                    try await pause(source)
                    let (page, actualURL) = try await read(url)
                    if actualURL != url, !visited.insert(actualURL).inserted { continue }
                    guard !page.rows.isEmpty else { throw SourceError.emptyCatalog }
                    append(page)
                }
            }
        } else {
            var queue = [firstURL]
            var seen: Set = [firstURL, canonicalURL]
            var cursor = 0
            while cursor < queue.count {
                let page: CatalogPage
                if cursor == 0 {
                    page = firstPage
                } else {
                    try await pause(source)
                    let fetched = try await read(queue[cursor])
                    seen.insert(fetched.canonicalURL)
                    page = fetched.contents
                    guard !page.rows.isEmpty else { throw SourceError.emptyCatalog }
                }
                append(page)
                queue.append(contentsOf: page.next.map(\.url).filter { seen.insert($0).inserted })
                cursor += 1
            }
        }

        guard !rows.isEmpty else { throw SourceError.emptyCatalog }
        // Some directories list the latest chapters twice. Keep their chronological entries.
        var urls = Set<URL>()
        let unique = rows.reversed().filter { urls.insert($0.url).inserted }.reversed()

        return unique.enumerated().map { index, row in
            ChapterReference(index: index + 1, title: row.title, url: row.url)
        }
    }

    public func content(for chapter: ChapterReference, book: BookResult) async throws -> DownloadedChapter {
        try await content(for: chapter, book: book, catalogURLs: [])
    }

    func chapterConcurrency(for book: BookResult) throws -> Int {
        let limit = try source(for: book).crawl?.concurrency ?? Self.defaultChapterConcurrency
        return max(1, min(limit, Self.defaultChapterConcurrency))
    }

    func content(for chapter: ChapterReference, book: BookResult, catalogURLs: Set<URL>) async throws -> DownloadedChapter {
        let source = try source(for: book)
        do {
            let paragraphs = try await chapterParagraphs(for: chapter, source: source, catalogURLs: catalogURLs)
            let title = chapter.title.replacingOccurrences(
                of: #"^(\d+)\s*\.\s*(.+)$"#, with: "第$1章 $2", options: .regularExpression
            )
            return DownloadedChapter(index: chapter.index, title: title, paragraphs: paragraphs)
        } catch {
            try Task.checkCancellation()
            throw SourceError.chapterFailed(chapter.title, error)
        }
    }

    private var searchableRules: [SourceRule] {
        rules.filter {
            $0.disabled != true && $0.needProxy != true && $0.search != nil && $0.search?.disabled != true
        }
    }

    private func source(for book: BookResult) throws -> SourceRule {
        guard let source = rules.first(where: { $0.id == book.sourceID && $0.disabled != true }) else {
            throw SourceError.unknownSource
        }
        return source
    }

    private func search(_ keyword: String, source: SourceRule, rule: SourceRule.Search) async throws -> SearchUpdate {
        var books = [BookResult]()
        do {
            let encodedKeyword = Self.encodeQueryValue(keyword)
            let firstURL = try Self.httpURL(rule.url.replacingOccurrences(of: "%s", with: encodedKeyword))
            var queue = [firstURL]
            var seenURLs = Set(queue)
            var seenBooks = Set<String>()
            var cursor = 0
            while cursor < queue.count {
                try Task.checkCancellation()
                let url = queue[cursor]
                let hasForm = cursor == 0 && rule.method?.lowercased() == "post"
                let form = hasForm ? Self.formBody(rule.data, keyword: keyword) : nil
                let page = try await fetch(url, timeout: rule.timeout ?? 15, form: form, cookies: rule.cookies)
                let base = try rule.baseUri.map { try Self.httpURL($0, relativeTo: page.url) } ?? page.url
                let results: SearchPage = try await parser.parse(page.html, operation: "search", options: [
                    "baseURL": base.absoluteString,
                    "pageURL": page.url.absoluteString,
                    "fields": rule.fields,
                    "detailFields": (source.book ?? Self.defaultBook).fields,
                    "result": rule.result,
                    "nextPage": rule.nextPage ?? ""
                ])

                for row in results.rows {
                    let result = BookResult(
                        title: row.title, author: row.author ?? "", sourceName: source.name,
                        category: row.category ?? "", status: row.status ?? "", latestChapter: row.latestChapter ?? "",
                        updatedAt: row.updatedAt ?? "", wordCount: row.wordCount ?? "", url: row.url, sourceID: source.id
                    )
                    if seenBooks.insert(result.id).inserted {
                        books.append(result)
                    }
                }
                seenURLs.insert(page.url)
                queue.append(contentsOf: results.next.map(\.url).filter { seenURLs.insert($0).inserted })
                cursor += 1
            }
            return SearchUpdate(sourceName: source.name, books: books)
        } catch {
            try Task.checkCancellation()
            return SearchUpdate(sourceName: source.name, books: books, failure: error.localizedDescription)
        }
    }

    private func chapterParagraphs(
        for chapter: ChapterReference, source: SourceRule, catalogURLs: Set<URL>
    ) async throws -> [String] {
        var paragraphs = [String]()
        var current: URL? = chapter.url
        var pageIndex = 1
        var seen = Set<URL>()

        while let url = current, seen.insert(url).inserted {
            let (result, pageURL, next) = try await readChapterPage(url, chapter: chapter, pageIndex: pageIndex, source: source)
            var pageParagraphs = result.paragraphs
            if pageParagraphs.count > 1,
               [result.title, chapter.title].contains(pageParagraphs[0]) {
                pageParagraphs.removeFirst()
            }
            paragraphs.append(contentsOf: pageParagraphs)
            seen.insert(pageURL)
            if let next, catalogURLs.contains(next) { break }
            current = next
            pageIndex += 1
        }
        return paragraphs
    }

    private func readChapterPage(
        _ url: URL, chapter: ChapterReference, pageIndex: Int, source: SourceRule
    ) async throws -> (ChapterPage, URL, URL?) {
        let rule = source.chapter
        let retries = max(0, min(source.crawl?.maxAttempts ?? 3, 5))
        var attempt = 0
        while true {
            try await pause(source, retry: attempt)
            attempt += 1
            do {
                let page = try await fetch(url, timeout: rule.timeout ?? 15)
                let base = try rule.baseUri.map { try Self.httpURL($0, relativeTo: page.url) } ?? page.url
                let result: ChapterPage = try await parser.parse(page.html, operation: "chapter", options: [
                    "baseURL": base.absoluteString,
                    "title": rule.title ?? "",
                    "content": rule.content,
                    "paragraphTag": rule.paragraphTag ?? "",
                    "paragraphTagClosed": rule.paragraphTagClosed ?? false,
                    "filterTxt": rule.filterTxt ?? "",
                    "filterTag": rule.filterTag ?? "",
                    "nextPage": rule.nextPage ?? "",
                    "nextPageInJs": rule.nextPageInJs ?? ""
                ])
                guard !result.paragraphs.isEmpty else { throw SourceError.emptyChapter(chapter.title) }
                return (result, page.url, Self.nextChapterPage(result.next, rule: rule, base: base))
            } catch {
                try Task.checkCancellation()
                let willRetry = attempt <= retries && Self.canRetry(error)
                let code = error as NSError
                Self.downloadLog.log(level: willRetry ? .info : .error,
                    "\(source.name, privacy: .public) chapter=\(chapter.index) page=\(pageIndex) attempt=\(attempt) url=\(url.absoluteString, privacy: .private) error=\(code.domain, privacy: .public):\(code.code)")
                guard willRetry else {
                    throw SourceError.chapterPageFailed(page: pageIndex, attempts: attempt, error)
                }
            }
        }
    }

    private func fetch(
        _ url: URL, timeout: Double, form: String? = nil, cookies: String? = nil
    ) async throws -> (url: URL, html: String) {
        try Task.checkCancellation()
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/17.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        if var origin = URLComponents(url: url, resolvingAgainstBaseURL: true) {
            origin.path = "/"
            origin.query = nil
            origin.fragment = nil
            request.setValue(origin.string, forHTTPHeaderField: "Referer")
        }
        if let cookies, !cookies.isEmpty { request.setValue(cookies, forHTTPHeaderField: "Cookie") }
        if let form {
            request.httpMethod = "POST"
            request.httpBody = Data(form.utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, let responseURL = response.url else {
            throw SourceError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else { throw SourceError.httpStatus(response.statusCode) }
        guard let html = Self.decodeHTML(data, charset: response.textEncodingName) else {
            throw SourceError.unsupportedEncoding
        }
        return (try Self.httpURL(responseURL.absoluteString), html)
    }

    private func pause(_ source: SourceRule, retry: Int = 0) async throws {
        let configuredMin = retry == 0 ? source.crawl?.minInterval ?? 200 : source.crawl?.retryMinInterval ?? 2_000
        let configuredMax = retry == 0 ? source.crawl?.maxInterval ?? 400 : source.crawl?.retryMaxInterval ?? 4_000
        let lowerBound = max(0, min(configuredMin, 60_000))
        let upperBound = max(lowerBound, min(configuredMax, 60_000))
        let duration = Int.random(in: lowerBound...upperBound) * max(1, retry)
        try await Task.sleep(for: .milliseconds(duration))
    }

    private static let defaultBook = SourceRule.Book(
        url: nil, bookName: nil, author: nil, category: nil, latestChapter: nil, lastUpdateTime: nil, status: nil
    )

    private static func httpURL(_ value: String, relativeTo base: URL? = nil) throws -> URL {
        guard let url = URL(string: value, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              url.host != nil, url.user == nil, url.password == nil else { throw SourceError.invalidURL }
        return url
    }

    private static func encodeQueryValue(_ string: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }

    private static func formBody(_ description: String?, keyword: String) -> String {
        let trimmed = description?.trimmingCharacters(in: CharacterSet(charactersIn: "{} \t\n")) ?? "searchkey: %s"
        return trimmed.split(separator: ",").compactMap { pair in
            let fields = pair.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r\"'"))
            }
            guard fields.count == 2, let key = fields.first, let value = fields.last else { return nil }
            return encodeQueryValue(key) + "=" + encodeQueryValue(value.replacingOccurrences(of: "%s", with: keyword))
        }.joined(separator: "&")
    }

    private static func bookIdentifier(url: URL, rule: String?) -> String? {
        guard let rule, !rule.isEmpty,
              let regex = try? NSRegularExpression(pattern: rule.components(separatedBy: "@js:")[0]) else {
            return nil
        }
        // Sources may redirect HTTP book links to HTTPS while keeping the same path.
        var candidates = [url.absoluteString]
        if var alternate = URLComponents(url: url, resolvingAgainstBaseURL: true) {
            alternate.scheme = url.scheme == "https" ? "http" : "https"
            if let string = alternate.string { candidates.append(string) }
        }
        for candidate in candidates {
            if let match = regex.firstMatch(in: candidate, range: NSRange(candidate.startIndex..., in: candidate)),
               match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: candidate) {
                return String(candidate[range])
            }
        }
        return nil
    }

    private static func expand(_ template: String, with identifier: String?) throws -> String {
        guard template.contains("%s") else { return template }
        guard let identifier else { throw SourceError.invalidURL }
        return template.replacingOccurrences(of: "%s", with: identifier)
    }

    private static func decodeHTML(_ data: Data, charset: String?) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        let prefix = String(decoding: data.prefix(8_192), as: UTF8.self)
        let pattern = #"(?i)<meta[^>]+charset\s*=\s*["']?([A-Za-z0-9_-]+)"#
        let metaCharset = prefix.range(of: pattern, options: .regularExpression).map {
            String(prefix[$0]).replacingOccurrences(of: #"(?i)^.*charset\s*=\s*["']?"#, with: "", options: .regularExpression)
        }
        let encodings = [charset, metaCharset, "utf-8", "gb18030", "big5"]
        for name in encodings.compactMap({ $0 }) {
            let normalized = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            let effective = ["gb2312", "gbk", "x-gbk"].contains(normalized) ? "gb18030" : normalized
            let encoding = CFStringConvertIANACharSetNameToEncoding(effective as CFString)
            guard encoding != kCFStringEncodingInvalidId else { continue }
            if let decoded = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))) {
                return decoded
            }
        }
        return nil
    }

    private static func nextChapterPage(_ link: ChapterPage.Next?, rule: SourceRule.Chapter, base: URL) -> URL? {
        guard let link, !link.url.isEmpty, link.url != "END" else { return nil }
        if let pattern = rule.nextChapterLink,
           link.url.range(of: "^(?:\(pattern))$", options: .regularExpression) != nil { return nil }
        guard let url = try? httpURL(link.url, relativeTo: base) else { return nil }
        let pageSuffix = url.path.range(of: #"[-_]\d+\.html?$"#, options: .regularExpression) != nil
        let nextChapterLabel = link.label.range(of: "下一[章节節]|下[一壹]章|没有了|没有更多|沒有了|>>|书末页|書末頁",
                                                options: .regularExpression) != nil
        return nextChapterLabel && !pageSuffix ? nil : url
    }

    private static func canRetry(_ error: Error) -> Bool {
        switch error {
        case SourceError.httpStatus(let status):
            return status == 408 || status == 429 || (500..<600).contains(status)
        case SourceError.blocked, SourceError.invalidURL, SourceError.unknownSource:
            return false
        default:
            return true
        }
    }
}

private struct PageLink: Decodable {
    let url: URL
    let isOption: Bool
}

private struct SearchPage: Decodable {
    struct Row: Decodable {
        let title: String
        let author: String?
        let category: String?
        let status: String?
        let latestChapter: String?
        let updatedAt: String?
        let wordCount: String?
        let url: URL
    }

    let rows: [Row]
    let next: [PageLink]
}

private struct CatalogRow: Decodable {
    let title: String
    let url: URL
}

private struct CatalogPage: Decodable {
    let rows: [CatalogRow]
    let next: [PageLink]
}

private struct ChapterPage: Decodable {
    struct Next: Decodable {
        let url: String
        let label: String
    }

    let title: String
    let paragraphs: [String]
    let next: Next?
}

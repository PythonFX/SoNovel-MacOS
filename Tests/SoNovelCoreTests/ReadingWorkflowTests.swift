import Foundation
import PDFKit
import XCTest
import SoNovelCore

final class ReadingWorkflowTests: XCTestCase {
    @MainActor
    func testBundledRulesCanBeLoaded() throws {
        let sources = try BookSources(rulesData: loadBundledSourceRules())
        XCTAssertGreaterThan(sources.searchableSourceCount, 0)

        let websites = try loadBundledSourceWebsites()
        XCTAssertTrue(sources.searchableSourceIDs.isSubset(of: Set(websites.map(\.id))))
        XCTAssertGreaterThan(websites.count, sources.searchableSourceCount)
        let hetushu = try XCTUnwrap(websites.first { $0.name == "和图书" })
        XCTAssertEqual(hetushu.homepage.absoluteString, "https://www.hetushu.com/")
    }

    @MainActor
    func testSearchToFullBookAndChapterRange() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BookSiteFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let sources = try BookSources(rulesData: Data(BookSiteFixture.rules.utf8), session: session)
        var updates: [SearchUpdate] = []
        try await sources.search("测试 小说 &册") { updates.append($0) }
        XCTAssertEqual(updates.count, 2)
        XCTAssertEqual(updates.filter { $0.failure != nil }.map(\.sourceName), ["故障书源"])

        let matches = updates.flatMap(\.books)
        XCTAssertEqual(matches.count, 1)
        let book = try XCTUnwrap(matches.first)
        XCTAssertEqual(book.title, "测试小说")
        XCTAssertEqual(book.author, "编者")
        XCTAssertEqual(book.sourceName, "本地书源")
        XCTAssertEqual(book.category, "文学")
        XCTAssertEqual(book.status, "完结")
        XCTAssertEqual(book.latestChapter, "第三章")
        XCTAssertEqual(book.updatedAt, "2026-11-17")
        XCTAssertEqual(book.wordCount, "100 字")

        let references = try await sources.chapters(for: book)
        XCTAssertEqual(references.map(\.index), [1, 2, 3])
        XCTAssertEqual(references.map(\.title), ["第一章", "第二章", "第三章"])

        var contents: [DownloadedChapter] = []
        for reference in references {
            contents.append(try await sources.content(for: reference, book: book))
        }
        XCTAssertEqual(contents[1].paragraphs, ["第二章上半 & 引文", "第二章下半"])

        let output = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: output) }
        let exporter = BookExporter()
        let options = ExportOptions(folder: output, format: .txt, separateChapters: true)
        let range = 2...3
        let partial = try await exporter.export(
            book: book, chapters: contents.filter { range.contains($0.index) }, options: options, range: range
        )
        let partialText = try String(contentsOf: partial, encoding: .utf8)
        XCTAssertTrue(partialText.contains("第二章上半 & 引文"))
        XCTAssertTrue(partialText.contains("第三章正文"))
        XCTAssertFalse(partialText.contains("第一章正文"))

        let chapterFolder = partial.deletingLastPathComponent().appendingPathComponent("章节")
        let rangeFiles = try FileManager.default.contentsOfDirectory(atPath: chapterFolder.path).sorted()
        XCTAssertEqual(rangeFiles, ["0002 第二章.txt", "0003 第三章.txt"])

        for format in BookFormat.allCases {
            let full = try await exporter.export(
                book: book, chapters: contents,
                options: ExportOptions(folder: output, format: format, separateChapters: false)
            )
            XCTAssertEqual(full.pathExtension, format.rawValue)
            switch format {
            case .txt, .html:
                let text = try String(contentsOf: full, encoding: .utf8)
                let first = try XCTUnwrap(text.range(of: "第一章正文"))
                let third = try XCTUnwrap(text.range(of: "第三章正文"))
                XCTAssertLessThan(first.lowerBound, third.lowerBound)
            case .epub:
                let data = try Data(contentsOf: full)
                XCTAssertEqual(Array(data.prefix(4)), [0x50, 0x4b, 0x03, 0x04])
                XCTAssertEqual(Array(data.dropFirst(8).prefix(2)), [0, 0])
                XCTAssertTrue(data.range(of: Data("mimetypeapplication/epub+zip".utf8)) != nil)
            case .pdf:
                let document = try XCTUnwrap(PDFDocument(url: full))
                XCTAssertGreaterThan(document.pageCount, 0)
                XCTAssertTrue(document.string?.contains("第三章正文") ?? false)
            }
        }

        let repeatExport = try await exporter.export(
            book: book, chapters: contents.filter { range.contains($0.index) }, options: options, range: range
        )
        XCTAssertNotEqual(repeatExport, partial)
        XCTAssertEqual(try String(contentsOf: partial, encoding: .utf8), partialText)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}

private final class BookSiteFixture: URLProtocol {
    static let rules = #"""
    [
      {
        "url": "https://books.invalid/", "name": "本地书源",
        "search": {
          "url": "https://books.invalid/query?q=%s", "result": "table tr",
          "bookName": "td.title > a", "author": ".author", "category": ".category",
          "latestChapter": ".latest", "lastUpdateTime": ".update", "status": ".status", "wordCount": ".words"
        },
        "book": {},
        "toc": {"item": "ol li a", "nextPage": "select option"},
        "chapter": {
          "content": "article", "paragraphTagClosed": true, "filterTag": ".ad, script",
          "nextPage": "a.next", "nextChapterLink": ".*/3\\.html"
        }
      },
      {
        "url": "https://unavailable.invalid/", "name": "故障书源",
        "search": {"url": "https://unavailable.invalid/query?q=%s", "result": "article", "bookName": "a"},
        "book": {}, "toc": {"item": "ol a"}, "chapter": {"content": "article"}
      }
    ]
    """#

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (status, html) = Self.page(at: url)
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "text/html; charset=UTF-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func page(at url: URL) -> (Int, String) {
        guard url.host == "books.invalid" else { return (503, "书源暂不可用") }
        switch url.path {
        case "/query":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            guard query == [URLQueryItem(name: "q", value: "测试 小说 &册")] else { return (400, "书名编码错误") }
            return (200, """
                <table><tr><th>书名</th></tr><tr>
                <td class="title"><a href="/books/42/">测试小说</a></td><td class="author">编者</td>
                <td class="category">文学</td><td class="status">完结</td><td class="latest">第三章</td>
                <td class="update">2026-11-17</td><td class="words">100 字</td></tr></table>
                """)
        case "/books/42/", "/books/42":
            return (200, """
                <ol><li><a href="1.html">第一章</a></li></ol>
                <select><option value="/books/42/">1</option><option value="/books/42/page2">2</option></select>
                """)
        case "/books/42/page2":
            return (200, """
                <ol><li><a href="2.html">第二章</a></li><li><a href="3.html">第三章</a></li></ol>
                """)
        case "/books/42/1.html": return (200, "<article><p>第一章正文</p></article>")
        case "/books/42/2.html":
            return (200, """
                <article><p>第二章上半 &amp; 引文</p><p class="ad">广告文字</p>
                <script>throw new Error('页面脚本不应该执行');</script></article>
                <a class="next" href="2_2.html">下一页</a>
                """)
        case "/books/42/2_2.html":
            return (200, "<article><p>第二章下半</p></article><a class='next' href='3.html'>下一章</a>")
        case "/books/42/3.html": return (200, "<article><p>第三章正文</p></article>")
        default: return (404, "没有此测试页面")
        }
    }
}

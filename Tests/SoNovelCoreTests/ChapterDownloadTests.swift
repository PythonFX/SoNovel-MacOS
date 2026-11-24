import Foundation
import XCTest
@testable import SoNovelCore

final class ChapterDownloadTests: XCTestCase {
    @MainActor
    func testDownloadsConcurrentlyAndRetriesOnlyMissingContent() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ChapterNetworkFixture.self]
        configuration.httpMaximumConnectionsPerHost = 16
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        ChapterNetworkFixture.reset()

        let sources = try BookSources(rulesData: Data(ChapterNetworkFixture.rules.utf8), session: session)
        let base = URL(string: "https://chapters.invalid/")!
        let book = BookResult(title: "测试小说", sourceName: "测试书源", url: base, sourceID: base.absoluteString)
        let catalog = (1...12).map { index in
            ChapterReference(index: index, title: "第\(index)章", url: base.appendingPathComponent("\(index).html"))
        }
        let batch = ChapterDownloadBatch(chapters: catalog, catalog: catalog)
        let firstPass = try await sources.downloadChapters(batch, book: book) { _, _, _ in }
        XCTAssertTrue((4...5).contains(ChapterNetworkFixture.peakConnections))
        XCTAssertEqual(firstPass.failures.map(\.id), [3])
        XCTAssertTrue(firstPass.failures[0].message.contains("尝试 2 次"))
        XCTAssertEqual(firstPass.chapters.map(\.index), [1, 2] + Array(4...12))
        XCTAssertEqual(firstPass.chapters[0].paragraphs, ["正文 1"])
        XCTAssertEqual(firstPass.chapters[1].paragraphs, ["正文 2", "正文 2 续页"])
        XCTAssertEqual(ChapterNetworkFixture.requests(to: "/2.html"), 1)
        XCTAssertEqual(ChapterNetworkFixture.requests(to: "/2_2.html"), 2)
        XCTAssertEqual(ChapterNetworkFixture.requests(to: "/3.html"), 2)

        let completed = try await sources.downloadChapters(firstPass, book: book) { _, _, _ in }
        XCTAssertTrue(completed.failures.isEmpty)
        XCTAssertEqual(completed.chapters.map(\.index), Array(1...12))
        XCTAssertEqual(ChapterNetworkFixture.requests(to: "/3.html"), 3)
        XCTAssertEqual(ChapterNetworkFixture.requests(to: "/12.html"), 1)
    }

    @MainActor
    func testBundledRulesSetConcurrencyPerSource() throws {
        let sources = try BookSources(rulesData: loadBundledSourceRules())
        let fastURL = URL(string: "https://www.biquge365.net/")!
        let limitedURL = URL(string: "https://www.bqg.info/")!
        let fast = BookResult(title: "测试", sourceName: "笔趣阁365", url: fastURL, sourceID: fastURL.absoluteString)
        let limited = BookResult(title: "测试", sourceName: "笔趣阁info", url: limitedURL, sourceID: limitedURL.absoluteString)
        XCTAssertEqual(try sources.chapterConcurrency(for: fast), 16)
        XCTAssertEqual(try sources.chapterConcurrency(for: limited), 4)
    }
}

private final class ChapterNetworkFixture: URLProtocol, @unchecked Sendable {
    static let rules = #"""
    [{
        "url": "https://chapters.invalid/", "name": "测试书源",
        "toc": {"item": "ol a"},
        "chapter": {"content": "article", "nextPage": "a.next"},
        "crawl": {"concurrency": 5, "minInterval": 0, "maxInterval": 0,
                  "maxAttempts": 1, "retryMinInterval": 0, "retryMaxInterval": 0}
    }]
    """#

    private static let lock = NSLock()
    private static var requestsByPath: [String: Int] = [:]
    private static var active = 0
    private static var peak = 0

    static var peakConnections: Int { lock.withLock { peak } }

    static func requests(to path: String) -> Int { lock.withLock { requestsByPath[path, default: 0] } }

    static func reset() {
        lock.withLock {
            requestsByPath = [:]
            active = 0
            peak = 0
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "chapters.invalid" }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.path
        let attempt = Self.lock.withLock {
            Self.active += 1
            Self.peak = max(Self.peak, Self.active)
            Self.requestsByPath[path, default: 0] += 1
            return Self.requestsByPath[path, default: 0]
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) { [self] in
            Self.lock.withLock { Self.active -= 1 }
            if (path == "/2_2.html" && attempt == 1) || (path == "/3.html" && attempt <= 2) {
                client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
                return
            }

            let html: String
            switch path {
            case "/1.html": html = #"<article>正文 1</article><a class="next" href="2.html">下一页</a>"#
            case "/2.html": html = #"<article>正文 2</article><a class="next" href="2_2.html">下一页</a>"#
            case "/2_2.html": html = "<article>正文 2 续页</article>"
            default: html = "<article>正文 \(url.deletingPathExtension().lastPathComponent)</article>"
            }
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html; charset=UTF-8"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(html.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

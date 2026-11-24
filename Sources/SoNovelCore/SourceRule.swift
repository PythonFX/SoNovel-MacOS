import Foundation

struct SourceRule: Decodable, Sendable {
    let url: String
    let name: String
    let disabled: Bool?
    let needProxy: Bool?
    let search: Search?
    let book: Book?
    let toc: TableOfContents
    let chapter: Chapter
    let crawl: Crawl?

    var id: String { url }

    struct Search: Decodable, Sendable {
        let baseUri: String?
        let timeout: Double?
        let url: String
        let method: String?
        let data: String?
        let cookies: String?
        let disabled: Bool?
        let result: String
        let bookName: String
        let author: String?
        let category: String?
        let latestChapter: String?
        let lastUpdateTime: String?
        let status: String?
        let wordCount: String?
        let nextPage: String?

        var fields: [String: String] {
            [
                "title": bookName, "author": author, "category": category, "latestChapter": latestChapter,
                "updatedAt": lastUpdateTime, "status": status, "wordCount": wordCount
            ].compactMapValues { $0 }
        }
    }

    struct Book: Decodable, Sendable {
        let url: String?
        let bookName: String?
        let author: String?
        let category: String?
        let latestChapter: String?
        let lastUpdateTime: String?
        let status: String?

        // These are also the detail page defaults in the command-line tool.
        var fields: [String: String] {
            [
                "title": bookName ?? #"meta[property="og:novel:book_name"]"#,
                "author": author ?? #"meta[property="og:novel:author"]"#,
                "category": category ?? #"meta[property="og:novel:category"]"#,
                "latestChapter": latestChapter ?? #"meta[property="og:novel:latest_chapter_name"]"#,
                "updatedAt": lastUpdateTime ?? #"meta[property="og:novel:update_time"]"#,
                "status": status ?? #"meta[property="og:novel:status"]"#
            ]
        }
    }

    struct TableOfContents: Decodable, Sendable {
        let baseUri: String?
        let url: String?
        let timeout: Double?
        let list: String?
        let item: String
        let nextPage: String?
        let isDesc: Bool?
    }

    struct Chapter: Decodable, Sendable {
        let baseUri: String?
        let timeout: Double?
        let title: String?
        let content: String
        let paragraphTag: String?
        let paragraphTagClosed: Bool?
        let filterTxt: String?
        let filterTag: String?
        let nextPage: String?
        let nextPageInJs: String?
        let nextChapterLink: String?
    }

    struct Crawl: Decodable, Sendable {
        let concurrency: Int?
        let minInterval: Int?
        let maxInterval: Int?
        let maxAttempts: Int?
        let retryMinInterval: Int?
        let retryMaxInterval: Int?
    }
}

enum SourceError: LocalizedError {
    case unknownSource
    case invalidURL
    case invalidResponse
    case httpStatus(Int)
    case unsupportedEncoding
    case blocked
    case emptyCatalog
    case emptyChapter(String)
    case chapterFailed(String, Error)
    case chapterPageFailed(page: Int, attempts: Int, Error)
    case invalidPage

    var errorDescription: String? {
        switch self {
        case .unknownSource: "找不到此书的书源规则。"
        case .invalidURL: "书源提供了无效的链接。"
        case .invalidResponse: "书源没有返回有效的网页。"
        case .httpStatus(let code): "书源返回 HTTP \(code)。"
        case .unsupportedEncoding: "无法读取书源网页的文字编码。"
        case .blocked: "书源要求浏览器验证。"
        case .emptyCatalog: "未能从书源读取章节目录。"
        case .emptyChapter(let title): "「\(title)」的正文为空。"
        case .chapterFailed(let title, let error): "「\(title)」下载失败。\(error.localizedDescription)"
        case .chapterPageFailed(let page, let attempts, let error):
            "第 \(page) 页请求失败（尝试 \(attempts) 次）。\(error.localizedDescription)"
        case .invalidPage: "无法按书源规则解析网页。"
        }
    }
}

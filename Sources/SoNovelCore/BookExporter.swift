import Darwin
import Foundation

public enum BookFormat: String, CaseIterable, Identifiable, Sendable {
    case epub, txt, html, pdf

    public var id: String { rawValue }
    public var displayName: String { rawValue.uppercased() }
}

public struct ExportOptions: Sendable {
    public let folder: URL
    public let format: BookFormat
    public let separateChapters: Bool

    public init(folder: URL, format: BookFormat, separateChapters: Bool) {
        self.folder = folder
        self.format = format
        self.separateChapters = separateChapters
    }
}

enum BookExportError: LocalizedError {
    case noChapters
    case invalidChapterNumbers
    case folderRequired
    case archiveTooLarge
    case pdfLayout

    var errorDescription: String? {
        switch self {
        case .noChapters: "没有可以导出的章节。"
        case .invalidChapterNumbers: "下载的章节编号无效或重复。"
        case .folderRequired: "请选择本地保存文件夹。"
        case .archiveTooLarge: "这本书超过 EPUB 文件大小或章节数量上限。请分段下载。"
        case .pdfLayout: "无法生成 PDF。"
        }
    }
}

public actor BookExporter {
    public init() {}

    public func export(
        book: BookResult,
        chapters: [DownloadedChapter],
        options: ExportOptions,
        range: ClosedRange<Int>? = nil
    ) async throws -> URL {
        try Task.checkCancellation()
        guard !chapters.isEmpty else { throw BookExportError.noChapters }
        guard options.folder.isFileURL else { throw BookExportError.folderRequired }

        let chapters = chapters.sorted { $0.index < $1.index }
        guard chapters[0].index > 0, Set(chapters.map(\.index)).count == chapters.count else {
            throw BookExportError.invalidChapterNumbers
        }

        let hasFolderAccess = options.folder.startAccessingSecurityScopedResource()
        defer {
            if hasFolderAccess { options.folder.stopAccessingSecurityScopedResource() }
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: options.folder, withIntermediateDirectories: true)
        let staging = options.folder.appendingPathComponent(".sonovel-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: staging) }

        let authorSuffix = book.author.isEmpty ? "" : "（\(book.author)）"
        let rangeSuffix = range.map { "（第\($0.lowerBound)–\($0.upperBound)章）" } ?? ""
        let stem = Self.safeFileStem(book.title + authorSuffix, maxBytes: 150) + rangeSuffix
        let filename = "\(stem).\(options.format.rawValue)"
        let primaryFile = staging.appendingPathComponent(filename)

        try Self.writeBook(book, chapters: chapters, format: options.format, to: primaryFile)
        if options.separateChapters {
            try Self.writeChapterFiles(chapters, to: staging.appendingPathComponent("章节", isDirectory: true))
        }

        // Commit on the same volume. The exclusive rename also protects against other exports
        // claiming the same name between writing the files and publishing them.
        var attempt = 1
        while true {
            try Task.checkCancellation()
            let availableStem = attempt == 1 ? stem : "\(stem) (\(attempt))"
            let source = options.separateChapters ? staging : primaryFile
            let destination = options.folder.appendingPathComponent(
                options.separateChapters ? availableStem : "\(availableStem).\(options.format.rawValue)",
                isDirectory: options.separateChapters
            )
            let result = source.withUnsafeFileSystemRepresentation { sourcePath in
                destination.withUnsafeFileSystemRepresentation { destinationPath in
                    guard let sourcePath, let destinationPath else { return EINVAL }
                    return renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
                }
            }
            if result == 0 {
                return options.separateChapters ? destination.appendingPathComponent(filename) : destination
            }
            if result != EEXIST {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(result),
                    userInfo: [NSFilePathErrorKey: destination.path]
                )
            }
            attempt += 1
        }
    }

    private static func writeBook(
        _ book: BookResult,
        chapters: [DownloadedChapter],
        format: BookFormat,
        to url: URL
    ) throws {
        try Data().write(to: url)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }

        switch format {
        case .txt:
            try file.writeUTF8("书名：\(book.title)\n作者：\(book.author)\n书源：\(book.sourceName)\n\n")
            for chapter in chapters {
                try Task.checkCancellation()
                try file.writeUTF8(chapterText(chapter) + "\n")
            }
        case .html:
            try writeHTML(book, chapters: chapters, to: file)
        case .epub:
            try EPUBBookWriter.write(book, chapters: chapters, to: file)
        case .pdf:
            try PDFBookWriter.write(book, chapters: chapters, to: file)
        }
        try file.close()
    }

    private static func writeHTML(
        _ book: BookResult,
        chapters: [DownloadedChapter],
        to file: FileHandle
    ) throws {
        try file.writeUTF8("""
        <!doctype html>
        <html lang="zh">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(book.title.escapedMarkup)</title>
        <style>
        :root { color-scheme: light dark; }
        body { font-family: system-ui, sans-serif; line-height: 1.8; max-width: 44rem; margin: 2rem auto; padding: 0 1rem; }
        header, nav, section { margin-block: 2.5rem; }
        section p { text-indent: 2em; overflow-wrap: anywhere; }
        </style>
        </head>
        <body>
        <header>
        <h1>\(book.title.escapedMarkup)</h1>
        <p>作者：\(book.author.escapedMarkup)</p>
        <p>书源：\(book.sourceName.escapedMarkup)</p>
        </header>
        <nav aria-labelledby="toc"><h2 id="toc">目录</h2><ol>
        """)
        for chapter in chapters {
            try Task.checkCancellation()
            try file.writeUTF8("<li><a href=\"#chapter-\(chapter.index)\">\(chapter.title.escapedMarkup)</a></li>\n")
        }
        try file.writeUTF8("</ol></nav>\n<main>\n")
        for chapter in chapters {
            try Task.checkCancellation()
            try file.writeUTF8("""
            <section id="chapter-\(chapter.index)">
            <h2>\(chapter.title.escapedMarkup)</h2>
            \(chapter.markupParagraphs)
            </section>

            """)
        }
        try file.writeUTF8("</main>\n</body>\n</html>\n")
    }

    private static func writeChapterFiles(_ chapters: [DownloadedChapter], to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let width = max(4, String(chapters.last?.index ?? 0).count)
        for chapter in chapters {
            try Task.checkCancellation()
            let number = String(chapter.index)
            let prefix = String(repeating: "0", count: width - number.count) + number
            let title = safeFileStem(chapter.title, maxBytes: 180)
            let path = folder.appendingPathComponent("\(prefix) \(title).txt")
            try Data(chapterText(chapter).utf8).write(to: path)
        }
    }

    private static func chapterText(_ chapter: DownloadedChapter) -> String {
        chapter.title + "\n\n" + chapter.paragraphs.joined(separator: "\n\n") + "\n"
    }

    private static func safeFileStem(_ value: String, maxBytes: Int) -> String {
        let illegal = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let trim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))
        let sanitized = value.components(separatedBy: illegal).joined(separator: "_").trimmingCharacters(in: trim)
        var result = ""
        var byteCount = 0
        for character in sanitized {
            let size = String(character).utf8.count
            guard byteCount + size <= maxBytes else { break }
            result.append(character)
            byteCount += size
        }
        let trimmed = result.trimmingCharacters(in: trim)
        return trimmed.isEmpty ? "未命名" : trimmed
    }
}

extension FileHandle {
    func writeUTF8(_ text: String) throws {
        try write(contentsOf: Data(text.utf8))
    }
}

extension DownloadedChapter {
    var markupParagraphs: String {
        paragraphs.map { "<p>\($0.escapedMarkup)</p>" }.joined(separator: "\n")
    }
}

extension String {
    var escapedMarkup: String {
        var result = ""
        result.reserveCapacity(utf8.count)
        for scalar in unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default:
                switch scalar.value {
                case 9, 10, 13, 0x20...0xD7FF, 0xE000...0xFFFD, 0x10000...0x10FFFF:
                    result.unicodeScalars.append(scalar)
                default: break // XML 1.0 excludes these scalars.
                }
            }
        }
        return result
    }
}

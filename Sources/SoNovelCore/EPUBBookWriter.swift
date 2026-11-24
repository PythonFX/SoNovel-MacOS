import Foundation
import zlib

enum EPUBBookWriter {
    static func write(_ book: BookResult, chapters: [DownloadedChapter], to file: FileHandle) throws {
        var zip = EPUBZip(file: file)
        try zip.add("mimetype", text: "application/epub+zip")
        try zip.add("META-INF/container.xml", text: """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles>
            <rootfile full-path="EPUB/book.opf" media-type="application/oebps-package+xml"/>
          </rootfiles>
        </container>
        """)
        try zip.add("EPUB/book.opf", text: packageDocument(book, chapters: chapters))
        try zip.add("EPUB/book.css", text: """
        body { line-height: 1.8; }
        article p { text-indent: 2em; }
        """)
        try zip.add("EPUB/title.xhtml", text: xhtml(title: book.title, body: """
        <header>
          <h1>\(book.title.escapedMarkup)</h1>
          <p>作者：\(book.author.escapedMarkup)</p>
          <p>书源：\(book.sourceName.escapedMarkup)</p>
        </header>
        """))
        try zip.add("EPUB/contents.xhtml", text: navigationDocument(chapters))
        for chapter in chapters {
            try Task.checkCancellation()
            try zip.add("EPUB/chapter-\(chapter.index).xhtml", text: xhtml(title: chapter.title, body: """
            <article>
            <h1>\(chapter.title.escapedMarkup)</h1>
            \(chapter.markupParagraphs)
            </article>
            """))
        }
        try zip.finish()
    }

    private static func packageDocument(_ book: BookResult, chapters: [DownloadedChapter]) -> String {
        let identifier = "urn:uuid:\(UUID().uuidString.lowercased())"
        let modified = ISO8601DateFormatter().string(from: Date())
        let creator = book.author.isEmpty ? "" : "<dc:creator>\(book.author.escapedMarkup)</dc:creator>"
        let manifest = chapters.map {
            "<item id=\"chapter-\($0.index)\" href=\"chapter-\($0.index).xhtml\" media-type=\"application/xhtml+xml\"/>"
        }.joined(separator: "\n")
        let spine = chapters.map { "<itemref idref=\"chapter-\($0.index)\"/>" }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="publication-id" xml:lang="zh">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:identifier id="publication-id">\(identifier)</dc:identifier>
        <dc:title>\(book.title.escapedMarkup)</dc:title>
        <dc:language>zh</dc:language>
        \(creator)
        <meta property="dcterms:modified">\(modified)</meta>
        </metadata>
        <manifest>
        <item id="contents" href="contents.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        <item id="title" href="title.xhtml" media-type="application/xhtml+xml"/>
        <item id="styles" href="book.css" media-type="text/css"/>
        \(manifest)
        </manifest>
        <spine>
        <itemref idref="title"/>
        \(spine)
        </spine>
        </package>
        """
    }

    private static func navigationDocument(_ chapters: [DownloadedChapter]) -> String {
        let links = chapters.map {
            "<li><a href=\"chapter-\($0.index).xhtml\">\($0.title.escapedMarkup)</a></li>"
        }.joined(separator: "\n")
        return xhtml(title: "目录", body: """
        <nav epub:type="toc" id="toc">
        <h1>目录</h1>
        <ol>
        \(links)
        </ol>
        </nav>
        """)
    }

    private static func xhtml(title: String, body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="zh" lang="zh">
        <head><title>\(title.escapedMarkup)</title><link rel="stylesheet" href="book.css"/></head>
        <body>
        \(body)
        </body>
        </html>
        """
    }
}

// A streaming ZIP store writer. EPUB permits uncompressed entries and requires the first
// entry (mimetype) to be uncompressed with no extra fields.
private struct EPUBZip {
    private struct Entry {
        let name: Data
        let offset: UInt32
        let checksum: UInt32
        let size: UInt32

        func appendCommonFields(to header: inout Data) {
            header.appendLittleEndian(UInt16(10))    // ZIP 1.0 extraction version
            header.appendLittleEndian(UInt16(0x800)) // UTF-8 filenames
            header.appendLittleEndian(UInt16(0))     // store
            header.appendLittleEndian(UInt16(0))     // DOS time
            header.appendLittleEndian(UInt16(33))    // 1980-01-01
            header.appendLittleEndian(checksum)
            header.appendLittleEndian(size)
            header.appendLittleEndian(size)
            header.appendLittleEndian(UInt16(name.count))
            header.appendLittleEndian(UInt16(0))     // extra field length
        }
    }

    let file: FileHandle
    private var entries: [Entry] = []

    init(file: FileHandle) {
        self.file = file
    }

    mutating func add(_ name: String, text: String) throws {
        let bytes = Data(text.utf8)
        let filename = Data(name.utf8)
        guard let offset = UInt32(exactly: try file.offset()), let size = UInt32(exactly: bytes.count),
              filename.count <= UInt16.max, entries.count < Int(UInt16.max) - 1,
              UInt64(offset) + UInt64(size) + UInt64(filename.count) + 30 < UInt64(UInt32.max) else {
            throw BookExportError.archiveTooLarge
        }
        let checksum = bytes.withUnsafeBytes { buffer in
            crc32(0, buffer.bindMemory(to: UInt8.self).baseAddress, size)
        }
        let entry = Entry(name: filename, offset: offset, checksum: UInt32(checksum), size: size)

        var header = Data()
        header.appendLittleEndian(UInt32(0x04034b50))
        entry.appendCommonFields(to: &header)
        header.append(filename)
        try file.write(contentsOf: header)
        try file.write(contentsOf: bytes)
        entries.append(entry)
    }

    func finish() throws {
        guard let start = UInt32(exactly: try file.offset()) else { throw BookExportError.archiveTooLarge }
        var directory = Data()
        for entry in entries {
            directory.appendLittleEndian(UInt32(0x02014b50))
            directory.appendLittleEndian(UInt16(20)) // ZIP version used to write central record
            entry.appendCommonFields(to: &directory)
            directory.appendLittleEndian(UInt16(0)) // file comment length
            directory.appendLittleEndian(UInt16(0)) // starting disk
            directory.appendLittleEndian(UInt16(0)) // internal attributes
            directory.appendLittleEndian(UInt32(0)) // external attributes
            directory.appendLittleEndian(entry.offset)
            directory.append(entry.name)
        }
        guard let length = UInt32(exactly: directory.count),
              UInt64(start) + UInt64(length) + 22 < UInt64(UInt32.max) else {
            throw BookExportError.archiveTooLarge
        }
        try file.write(contentsOf: directory)

        var footer = Data()
        footer.appendLittleEndian(UInt32(0x06054b50))
        footer.appendLittleEndian(UInt16(0)) // disk numbers
        footer.appendLittleEndian(UInt16(0))
        footer.appendLittleEndian(UInt16(entries.count))
        footer.appendLittleEndian(UInt16(entries.count))
        footer.appendLittleEndian(length)
        footer.appendLittleEndian(start)
        footer.appendLittleEndian(UInt16(0)) // archive comment length
        try file.write(contentsOf: footer)
    }
}

private extension Data {
    mutating func appendLittleEndian<Integer: FixedWidthInteger>(_ value: Integer) {
        var bytes = value.littleEndian
        Swift.withUnsafeBytes(of: &bytes) { append(contentsOf: $0) }
    }
}

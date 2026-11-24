import CoreGraphics
import CoreText
import Foundation

enum PDFBookWriter {
    private static let pageSize = CGRect(x: 0, y: 0, width: 595, height: 842)
    private static let margin: CGFloat = 56

    static func write(_ book: BookResult, chapters: [DownloadedChapter], to file: FileHandle) throws {
        let output = PDFOutput(file: file)
        var callbacks = CGDataConsumerCallbacks(
            putBytes: { info, buffer, count in
                guard let info else { return 0 }
                let output = Unmanaged<PDFOutput>.fromOpaque(info).takeUnretainedValue()
                return output.write(buffer, count: count)
            },
            releaseConsumer: nil
        )
        defer { withExtendedLifetime(output) {} }

        guard let consumer = CGDataConsumer(info: Unmanaged.passUnretained(output).toOpaque(), cbks: &callbacks) else {
            throw BookExportError.pdfLayout
        }
        var mediaBox = pageSize
        let metadata = [
            kCGPDFContextTitle as String: book.title,
            kCGPDFContextAuthor as String: book.author
        ] as CFDictionary
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, metadata) else {
            throw BookExportError.pdfLayout
        }
        try drawDocument(book, chapters: chapters, in: context, output: output)
        if let error = output.error { throw error }
    }

    private static func drawDocument(
        _ book: BookResult,
        chapters: [DownloadedChapter],
        in context: CGContext,
        output: PDFOutput
    ) throws {
        defer { context.closePDF() }

        let path = CGPath(rect: pageSize.insetBy(dx: margin, dy: margin), transform: nil)
        let titleStyle = textStyle(font: "PingFangSC-Semibold", size: 24)
        let chapterStyle = textStyle(font: "PingFangSC-Semibold", size: 17)
        let bodyStyle = textStyle(font: "PingFangSC-Regular", size: 12)
        let footerStyle = textStyle(font: "PingFangSC-Regular", size: 9)

        var pageNumber = 0

        func drawPages(_ text: NSAttributedString) throws {
            let framesetter = CTFramesetterCreateWithAttributedString(text)
            var start = 0
            while start < text.length {
                try Task.checkCancellation()
                if let error = output.error { throw error }
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0), path, nil)
                let length = CTFrameGetVisibleStringRange(frame).length
                guard length > 0 else { throw BookExportError.pdfLayout }

                pageNumber += 1
                context.beginPDFPage(nil)
                context.textMatrix = .identity
                CTFrameDraw(frame, context)

                let number = CTLineCreateWithAttributedString(
                    NSAttributedString(string: String(pageNumber), attributes: footerStyle)
                )
                let numberWidth = CTLineGetTypographicBounds(number, nil, nil, nil)
                context.textPosition = CGPoint(x: pageSize.midX - numberWidth / 2, y: margin / 2)
                CTLineDraw(number, context)
                context.endPDFPage()

                start += length
            }
        }

        let titlePage = NSMutableAttributedString(string: book.title + "\n\n", attributes: titleStyle)
        titlePage.append(NSAttributedString(string: "作者：\(book.author)\n书源：\(book.sourceName)\n", attributes: bodyStyle))
        try drawPages(titlePage)
        for chapter in chapters {
            try Task.checkCancellation()
            try autoreleasepool {
                let content = NSMutableAttributedString(string: chapter.title + "\n\n", attributes: chapterStyle)
                let paragraphs = chapter.paragraphs.map { "　　" + $0 }.joined(separator: "\n\n")
                content.append(NSAttributedString(string: paragraphs, attributes: bodyStyle))
                try drawPages(content)
            }
        }
    }

    private static func textStyle(font name: String, size: CGFloat) -> [NSAttributedString.Key: Any] {
        let font = CTFontCreateWithName(name as CFString, size, nil)
        var spacing: CGFloat = 4
        let paragraph = withUnsafePointer(to: &spacing) { spacing in
            var setting = CTParagraphStyleSetting(
                spec: .minimumLineSpacing,
                valueSize: MemoryLayout<CGFloat>.size,
                value: spacing
            )
            return CTParagraphStyleCreate(&setting, 1)
        }
        return [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph
        ]
    }
}

private final class PDFOutput {
    let file: FileHandle
    private(set) var error: Error?

    init(file: FileHandle) {
        self.file = file
    }

    func write(_ buffer: UnsafeRawPointer, count: Int) -> Int {
        guard error == nil else { return 0 }
        do {
            try file.write(contentsOf: Data(bytes: buffer, count: count))
            return count
        } catch {
            self.error = error
            return 0
        }
    }
}

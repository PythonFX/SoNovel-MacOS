import Foundation
import WebKit

/// Parses markup in a detached HTML document. The WebView only navigates to
/// its blank parser page and never displays or executes the fetched sites.
@MainActor
final class SourceHTML: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var preparation: Task<Void, Error>?
    private var navigation: CheckedContinuation<Void, Error>?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func parse<T: Decodable>(_ html: String, operation: String, options: [String: Any]) async throws -> T {
        try await prepare()
        try Task.checkCancellation()
        let value = try await webView.callAsyncJavaScript(
            Self.parser,
            arguments: ["html": html, "operation": operation, "options": options],
            contentWorld: .defaultClient
        )
        try Task.checkCancellation()

        guard let raw = value as? String, let data = raw.data(using: .utf8) else { throw SourceError.invalidPage }
        if raw == "\"blocked\"" { throw SourceError.blocked }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func prepare() async throws {
        if let preparation {
            return try await preparation.value
        }
        let task = Task {
            guard let networkBlock = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "SoNovelParserNoNetwork",
                encodedContentRuleList: #"[{"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}}]"#
            ) else { throw SourceError.invalidPage }
            webView.configuration.userContentController.add(networkBlock)
            try await withCheckedThrowingContinuation { continuation in
                navigation = continuation
                webView.loadHTMLString(Self.parserPage, baseURL: nil)
            }
        }
        preparation = task
        do {
            try await task.value
        } catch {
            preparation = nil
            throw error
        }
    }

    func webView(_ webView: WKWebView, didFinish finished: WKNavigation!) {
        resolveNavigation(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        resolveNavigation(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        resolveNavigation(.failure(error))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        preparation = nil
        resolveNavigation(.failure(SourceError.invalidPage))
    }

    private func resolveNavigation(_ result: Result<Void, Error>) {
        navigation?.resume(with: result)
        navigation = nil
    }

    private static let parserPage = """
    <!doctype html><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-eval'; base-uri 'none'; form-action 'none'">
    <title>SoNovel Parser</title>
    """

    private static let parser = #"""
    function transform(value, rule) {
        const steps = (rule || '').matchAll(/@(js|java):([\s\S]*?)(?=@(?:js|java):|$)/g);
        for (const [, type, code] of steps) {
            if (type === 'js') {
                // The code is from the bundled rule. Page-derived content is only an argument.
                value = new Function('r', code + '\n;return r;')(value);
            } else if (code.trim() === 'base64.decode()') {
                value = value.split(/\r?\n/).filter(Boolean).map(line =>
                    new TextDecoder().decode(Uint8Array.from(atob(line), char => char.charCodeAt(0)))
                ).join('\n');
            } else {
                throw new Error('Unsupported source rule instruction');
            }
        }
        return String(value ?? '');
    }

    const documentParser = new DOMParser();
    function parseMarkup(markup) {
        // CSP precedes any source-controlled markup in this detached document.
        const csp = '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; base-uri \'none\'; form-action \'none\'">';
        return documentParser.parseFromString(csp + markup, 'text/html');
    }

    const page = parseMarkup(operation === 'search' ? transform(html, options.result) : html);
    if (['Just a moment...', '403 Forbidden', 'Attention Required', 'Checking your browser before accessing'].includes(page.title)
        || page.querySelector('#challenge-form[action*="challenge"]')) {
        return JSON.stringify('blocked');
    }

    function select(root, rule) {
        if (!rule) return [];
        const selector = rule.replace(/@(?:js|java):[\s\S]*$/, '').replace(/@(href|src|content|value)$/, '').trim();
        if (!selector) return [];
        if (/^(\/|\(|\.\/)/.test(selector)) {
            const doc = root.ownerDocument || root;
            const result = doc.evaluate(selector, root, null, XPathResult.ORDERED_NODE_SNAPSHOT_TYPE, null);
            return Array.from({ length: result.snapshotLength }, (_, index) => result.snapshotItem(index));
        }
        // The bundled rules use a terminal jsoup :contains() selector.
        const contains = selector.match(/:contains\((.+)\)$/);
        if (contains) {
            return [...root.querySelectorAll(selector.slice(0, -contains[0].length) || '*')]
                .filter(element => cleanText(element.textContent).toLowerCase().includes(contains[1].toLowerCase()));
        }
        return [...root.querySelectorAll(selector)];
    }

    function cleanText(value) {
        return String(value ?? '').replace(/[\s\u200B\uFEFF]+/g, ' ').trim();
    }

    function link(value) {
        if (!value || value.trim().startsWith('#')) return '';
        try {
            const url = new URL(value, options.baseURL);
            if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) return '';
            url.hash = '';
            return url.href;
        } catch {
            return '';
        }
    }

    function extract(root, rule, format) {
        const nodes = select(root, rule);
        if (!nodes.length) return '';
        const attribute = format || rule.match(/@(href|src|content|value)(?:@|$)/)?.[1]
            || (rule.trim().startsWith('meta[') ? 'content' : 'text');
        if (attribute === 'html') return transform(nodes.map(node => node.innerHTML).join('\n'), rule);
        if (attribute === 'text') return cleanText(transform(nodes.map(node => cleanText(node.textContent)).join(' '), rule));
        const raw = nodes[0].getAttribute(attribute) || '';
        // A title-cleaning rule does not apply to its anchor URL.
        if (format === 'link') return link(nodes[0].getAttribute('href'));
        return attribute === 'href' || attribute === 'src' ? link(transform(link(raw), rule)) : transform(raw, rule);
    }

    function metadata(root, fields) {
        return Object.fromEntries(Object.entries(fields).map(([key, rule]) => [key, extract(root, rule)]));
    }

    function pagination(rule) {
        return select(page, rule).map(element => ({
            url: link(element.getAttribute('href') || element.getAttribute('value')),
            label: cleanText(element.textContent),
            isOption: element.tagName === 'OPTION'
        })).filter(item => item.url);
    }

    if (operation === 'search') {
        const rows = select(page, options.result).map(row => ({
            ...metadata(row, options.fields),
            url: extract(row, options.fields.title, 'link')
        })).filter(row => row.title && row.url);
        if (!rows.length) {
            const detail = metadata(page, options.detailFields);
            if (detail.title) rows.push({ ...detail, url: options.pageURL });
        }
        return JSON.stringify({ rows, next: pagination(options.nextPage) });
    }

    if (operation === 'toc') {
        const root = options.list ? parseMarkup(extract(page, options.list, 'html')) : page;
        const rows = select(root, options.item).map(item => ({
            title: cleanText(item.textContent),
            url: link(item.getAttribute('href'))
        })).filter(row => row.title && row.url);
        return JSON.stringify({ rows, next: pagination(options.nextPage) });
    }

    function chapterParagraphs(markup) {
        const content = parseMarkup(markup);
        for (const element of content.querySelectorAll('script, style, noscript, iframe, object, template')) element.remove();
        for (const element of select(content.body, options.filterTag)) element.remove();

        if (options.paragraphTag && !options.paragraphTagClosed) {
            const separator = new RegExp(options.paragraphTag, 'gi');
            // Normalize attributes on BR elements before applying existing source rules.
            const pieces = content.body.innerHTML.replace(/<br\b[^>]*>/gi, '<br>').split(separator);
            return pieces.flatMap(piece => readParagraphs(parseMarkup(piece).body));
        }
        return readParagraphs(content.body);
    }

    function readParagraphs(root) {
        const block = new Set(['P', 'DIV', 'SECTION', 'ARTICLE', 'LI', 'BLOCKQUOTE', 'PRE', 'ASIDE', 'DD', 'DT', 'HR',
                               'H1', 'H2', 'H3', 'H4', 'H5', 'H6']);
        let text = '';
        let pieces = [];
        function flush() {
            if (text.trim()) pieces.push(text);
            text = '';
        }
        function walk(node) {
            if (node.nodeType === Node.TEXT_NODE) {
                const value = node.nodeValue;
                if (node.parentElement?.tagName === 'PRE') {
                    text += value;
                } else {
                    // Lines inside decoded content delimit paragraphs, while space-only
                    // HTML indentation between elements doesn't produce blank paragraphs.
                    text += value.trim() ? value : ' ';
                }
                return;
            }
            if (node.nodeType !== Node.ELEMENT_NODE) return;
            if (node.tagName === 'BR') {
                flush();
                return;
            }
            const boundary = block.has(node.tagName);
            if (boundary) flush();
            for (const child of node.childNodes) walk(child);
            if (boundary) flush();
        }
        walk(root);
        flush();
        return pieces;
    }

    if (operation === 'chapter') {
        const markup = extract(page, options.content, 'html');
        const filter = options.filterTxt ? new RegExp(options.filterTxt, 'gu') : null;
        const paragraphs = chapterParagraphs(markup).flatMap(piece =>
            options.content.includes('@java:base64.decode()') ? piece.split(/\r?\n/) : [piece]
        ).map(piece => cleanText((filter ? piece.replace(filter, '') : piece).replace(/[\u200B\uFEFF\uE000-\uF8FF]/g, '')))
            .filter(Boolean);
        const next = options.nextPageInJs
            ? { url: extract(page, options.nextPageInJs, 'html'), label: '', isOption: false }
            : pagination(options.nextPage)[0];
        return JSON.stringify({ title: extract(page, options.title), paragraphs, next });
    }

    throw new Error('Unknown parsing operation');
    """#
}

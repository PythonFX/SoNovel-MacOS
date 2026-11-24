import Foundation

public func loadBundledSourceRules() throws -> Data {
    try Data(contentsOf: sourceRulesDirectory.appendingPathComponent("main.json"))
}

public struct SourceWebsite: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let homepage: URL
}

public func loadBundledSourceWebsites() throws -> [SourceWebsite] {
    let directory = sourceRulesDirectory
    let files = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
    ).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    let decoder = JSONDecoder()
    var seen = Set<URL>()
    var websites: [SourceWebsite] = []
    for file in files {
        let rules = try decoder.decode([WebsiteRule].self, from: Data(contentsOf: file))
        for rule in rules {
            // Proxy-backed rules may use a local service as their entry URL.
            let homepage = publicWebsiteURL(rule.url) ?? rule.search?.baseUri.flatMap(publicWebsiteURL)
            guard let homepage, seen.insert(homepage).inserted else { continue }
            websites.append(SourceWebsite(id: rule.url, name: rule.name, homepage: homepage))
        }
    }
    return websites
}

private struct WebsiteRule: Decodable {
    struct Search: Decodable { let baseUri: String? }

    let url: String
    let name: String
    let search: Search?
}

private func publicWebsiteURL(_ value: String) -> URL? {
    guard let url = URL(string: value), let host = url.host()?.lowercased(),
          let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
          host.contains("."), host != "0.0.0.0", !host.hasPrefix("127.") else {
        return nil
    }
    return url
}

private var sourceRulesDirectory: URL {
    if let resources = Bundle.main.resourceURL, Bundle.main.bundleURL.pathExtension == "app" {
        return resources.appendingPathComponent("SourceRules", isDirectory: true)
    }

    // SwiftPM and Xcode can run directly from the checkout. The packaged app
    // always uses the rule file copied into its own Resources directory.
    let checkout = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return checkout.appendingPathComponent("bundle/rules", isDirectory: true)
}

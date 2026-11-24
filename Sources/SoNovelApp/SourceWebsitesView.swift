import SoNovelCore
import SwiftUI

struct SourceWebsitesView: View {
    @ObservedObject var library: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("书库网站").font(.headline)
                Text("打开主页后，可在网站内手动搜索。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()

            switch library.sourceWebsites {
            case .success(let websites) where !websites.isEmpty:
                websiteList(websites)
            case .success:
                Text("没有可显示的书库网站。").padding(16)
            case .failure:
                Text("无法读取书库列表。").padding(16)
            }
        }
        .frame(width: 420)
    }

    private func websiteList(_ websites: [SourceWebsite]) -> some View {
        let searchable = library.searchableSourceIDs
        let failures = Dictionary(library.sourceFailures.map { ($0.source, $0.message) }, uniquingKeysWith: { _, latest in latest })
        let active = websites.filter { searchable.contains($0.id) }
        let failed = active.filter { failures[$0.name] != nil }
        let otherActive = active.filter { failures[$0.name] == nil }
        let manual = websites.filter { !searchable.contains($0.id) }

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                websiteSection("本次搜索出错", websites: failed, failures: failures)
                websiteSection("参与应用内搜索", websites: otherActive)
                websiteSection("可手动访问的网站", websites: manual)
            }
            .padding(16)
        }
        .frame(height: 365)
    }

    @ViewBuilder
    private func websiteSection(
        _ title: String, websites: [SourceWebsite], failures: [String: String] = [:]
    ) -> some View {
        if !websites.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 4)
                ForEach(websites) { site in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(site.name).fontWeight(.medium)
                            Text(site.homepage.host() ?? site.homepage.absoluteString)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let failure = failures[site.name] {
                                Label(failure, systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        Spacer(minLength: 8)
                        Link(destination: site.homepage) {
                            Label("打开主页", systemImage: "arrow.up.right.square")
                        }
                        .accessibilityLabel("打开\(site.name)主页")
                        .help(site.homepage.absoluteString)
                    }
                    .padding(.vertical, 7)
                }
            }
        }
    }
}

import AppKit

/// One published version of the app, as GitHub lists it.
struct Release: Identifiable, Hashable {
    let version: String
    var notes: String
    var date: Date?
    var url: String

    var id: String { version }
}

/// What is known about newer versions.
enum UpdateState: Hashable {
    case unknown, checking, current, failed
    case available(String)
}

/// Reads the app's releases from GitHub. This is the only thing Respool ever asks the network
/// for, and it happens when the user asks, or once a day if they turned that on.
enum Updates {
    static let repository = "ademhatay/respool"
    static let page = "https://github.com/" + repository + "/releases"

    static var installed: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// The latest releases, newest first, or nil when GitHub could not be reached.
    static func fetch(completion: @escaping ([Release]?) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=12") else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Respool", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let releases = ok ? data.flatMap(parse) : nil
            DispatchQueue.main.async { completion(releases) }
        }.resume()
    }

    static func parse(_ data: Data) -> [Release]? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let stamp = ISO8601DateFormatter()
        return list.compactMap { item -> Release? in
            guard let tag = item["tag_name"] as? String, item["draft"] as? Bool != true,
                  item["prerelease"] as? Bool != true else { return nil }
            return Release(
                version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                notes: (item["body"] as? String ?? "").replacingOccurrences(of: "\r\n", with: "\n"),
                date: (item["published_at"] as? String).flatMap(stamp.date(from:)),
                url: item["html_url"] as? String ?? page
            )
        }
        .sorted { isNewer($0.version, than: $1.version) }
    }

    /// Compares versions number by number, so that 0.10.0 is newer than 0.9.0.
    static func isNewer(_ version: String, than other: String) -> Bool {
        func parts(_ text: String) -> [Int] {
            text.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(version), b = parts(other)
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0, right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    /// Starts the app again, for a change that only takes effect at launch.
    static func relaunch() {
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app") else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", path]
        guard (try? process.run()) != nil else { return }
        NSApp.terminate(nil)
    }
}

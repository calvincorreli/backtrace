import Foundation

/// The machine that last changed a session's transcript.
struct SessionMachine: Hashable, Sendable {
    let name: String
    let isThisMac: Bool
}

protocol SessionMachineResolving: Sendable {
    /// Returns nil when the file is not in a synced folder or has no known writer.
    func machine(forFileAt url: URL) async -> SessionMachine?
}

/// Session histories shared between machines with Syncthing carry no machine
/// name of their own, but Syncthing records which device last changed each
/// file. This asks the local Syncthing instance over its REST API.
struct SyncthingMachineResolver: SessionMachineResolving {
    struct Folder: Equatable, Sendable {
        let id: String
        let path: String
    }

    struct Configuration: Equatable, Sendable {
        let baseURL: URL
        let apiKey: String
        let folders: [Folder]
        /// Device names keyed by short device ID, the form the API reports.
        let deviceNames: [String: String]
    }

    let configuration: Configuration
    private let localDevice = LocalDevice()

    static func detect(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> SyncthingMachineResolver? {
        let candidates = [
            "Library/Application Support/Syncthing/config.xml",
            ".local/state/syncthing/config.xml",
            ".config/syncthing/config.xml"
        ]
        for candidate in candidates {
            guard let data = try? Data(contentsOf: home.appendingPathComponent(candidate)),
                  let configuration = parseConfiguration(data) else { continue }
            return SyncthingMachineResolver(configuration: configuration)
        }
        return nil
    }

    static func parseConfiguration(_ data: Data) -> Configuration? {
        guard let document = try? XMLDocument(data: data),
              let root = document.rootElement(),
              let gui = root.elements(forName: "gui").first,
              let apiKey = gui.elements(forName: "apikey").first?.stringValue, !apiKey.isEmpty,
              let address = gui.elements(forName: "address").first?.stringValue, !address.isEmpty
        else { return nil }
        let scheme = gui.attribute(forName: "tls")?.stringValue == "true" ? "https" : "http"
        guard let baseURL = URL(string: "\(scheme)://\(address)") else { return nil }

        let folders = root.elements(forName: "folder").compactMap { element -> Folder? in
            guard let id = element.attribute(forName: "id")?.stringValue,
                  let path = element.attribute(forName: "path")?.stringValue else { return nil }
            let expanded = NSString(string: path).expandingTildeInPath
            return Folder(id: id, path: URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path)
        }
        var deviceNames: [String: String] = [:]
        for element in root.elements(forName: "device") {
            guard let id = element.attribute(forName: "id")?.stringValue,
                  let name = element.attribute(forName: "name")?.stringValue, !name.isEmpty else { continue }
            deviceNames[shortID(id)] = name
        }
        return Configuration(baseURL: baseURL, apiKey: apiKey, folders: folders, deviceNames: deviceNames)
    }

    static func shortID(_ deviceID: String) -> String {
        String(deviceID.prefix(7))
    }

    /// The synced folder that holds the file, and the file's path inside it.
    func location(of url: URL) -> (folder: Folder, relativePath: String)? {
        let path = url.resolvingSymlinksInPath().path
        for folder in configuration.folders.sorted(by: { $0.path.count > $1.path.count }) {
            let prefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
            if path.hasPrefix(prefix) {
                return (folder, String(path.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    func machine(forFileAt url: URL) async -> SessionMachine? {
        guard let (folder, relativePath) = location(of: url),
              let object = await get("rest/db/file", query: ["folder": folder.id, "file": relativePath]),
              let global = object["global"] as? [String: Any],
              let modifiedBy = global["modifiedBy"] as? String, !modifiedBy.isEmpty else { return nil }
        let localID = await localDevice.shortID { await get("rest/system/status", query: [:])?["myID"] as? String }
        return SessionMachine(
            name: configuration.deviceNames[modifiedBy] ?? modifiedBy,
            isThisMac: modifiedBy == localID
        )
    }

    private func get(_ path: String, query: [String: String]) async -> [String: Any]? {
        guard var components = URLComponents(
            url: configuration.baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            // URLComponents leaves "+" alone, and Syncthing reads it as a space.
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue(configuration.apiKey, forHTTPHeaderField: "X-API-Key")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return JSONValue.object(from: data)
    }
}

private actor LocalDevice {
    private var cached: String?

    func shortID(fetch: @Sendable () async -> String?) async -> String? {
        if let cached { return cached }
        cached = await fetch().map(SyncthingMachineResolver.shortID)
        return cached
    }
}

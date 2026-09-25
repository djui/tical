import Foundation

enum AppGroupImport {
    static func takePendingImageData() -> Data? {
        guard let url = pendingURL() else { return nil }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try? Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        return data
    }

    static func pendingURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: TicketDefaults.appGroupID)?
            .appendingPathComponent(TicketDefaults.pendingFilename)
    }
}

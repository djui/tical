import Foundation

/// Files the share extension leaves in the App Group container for the app to pick up.
nonisolated enum AppGroupInbox {
    /// Takes the newest waiting file and clears the inbox.
    static func takeLatest() -> ImportInput? {
        let fileManager = FileManager.default
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: TicketDefaults.appGroupID
        ) else { return nil }

        let inbox = container.appendingPathComponent(TicketDefaults.inboxFolder, isDirectory: true)
        var files = (try? fileManager.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        // Written by earlier builds of the share extension.
        let legacy = container.appendingPathComponent("pending-ticket.jpg")
        if fileManager.fileExists(atPath: legacy.path) {
            files.append(legacy)
        }
        guard !files.isEmpty else { return nil }

        let newest = files.max { modificationDate($0) < modificationDate($1) }
        let data = newest.flatMap { try? Data(contentsOf: $0) }
        for file in files {
            try? fileManager.removeItem(at: file)
        }
        return data.map(ImportInput.init(data:))
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

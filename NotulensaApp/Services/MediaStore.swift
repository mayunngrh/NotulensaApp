import Foundation

/// Owns the on-disk media layout under Desktop/Photobooth/ (local mirror of Google Drive structure).
/// Organized as: Desktop/Photobooth/EventName/Session YYYY-MM-DD HH:MM:SS/
/// SwiftData models store paths relative to `root` so the container can move freely.
enum MediaStore {
    static var root: URL {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        return desktop.appendingPathComponent("Photobooth", isDirectory: true)
    }

    /// Current session context — set when a kiosk session begins so files know where to save.
    /// Structure: Desktop/Photobooth/EventName/Session YYYY-MM-DD-HH-MM-SS/
    static var currentEventName: String = ""
    static var currentSessionName: String = ""

    enum Folder: String {
        case frames
        case idle
        case sessions
    }

    /// Resolves the event/session names to use right now, falling back to a guaranteed
    /// non-empty, timestamped pair if the caller forgot to set currentEventName/
    /// currentSessionName — this must never silently collapse to "Session " and mix
    /// unrelated sessions' files together. Writes any fallback straight back into the
    /// static vars (not just a local return value) so every other reader — including
    /// LivePhotoExporter and SlideshowExporter, which read currentEventName/
    /// currentSessionName directly to build their own returned path strings — sees the
    /// exact same resolved names as the directory that was actually created on disk.
    private static func resolvedSessionNames() -> (event: String, session: String) {
        let eventName = currentEventName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionName = currentSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard eventName.isEmpty || sessionName.isEmpty else { return (eventName, sessionName) }

        let fallbackStamp = Date.now.formatted(.dateTime.year().month().day().hour().minute().second())
            .replacingOccurrences(of: "/", with: "-")
        currentEventName = eventName.isEmpty ? "Untitled Event" : eventName
        currentSessionName = sessionName.isEmpty ? fallbackStamp : sessionName
        NSLog("[MediaStore] WARNING: session context was empty, falling back to '\(currentEventName)/Session \(currentSessionName)'")
        return (currentEventName, currentSessionName)
    }

    /// Computes the session directory path based on current event/session context.
    static func sessionDirectory() -> URL {
        let names = resolvedSessionNames()
        let eventDir = root.appendingPathComponent(names.event, isDirectory: true)
        let sessionDir = eventDir.appendingPathComponent("Session \(names.session)", isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        return sessionDir
    }

    static func url(for relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    static func directory(_ folder: Folder) -> URL {
        let dir = root.appendingPathComponent(folder.rawValue, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Copies a user-selected file into the store; returns the relative path to persist.
    static func importFile(from source: URL, into folder: Folder) throws -> String {
        // Ensure directory exists before attempting copy
        let dir = directory(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Use security-scoped access for the source file
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        // Generate destination filename
        let ext = source.pathExtension.lowercased()
        let name = UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
        let dest = dir.appendingPathComponent(name)

        // Perform the copy operation
        try FileManager.default.copyItem(at: source, to: dest)
        return "\(folder.rawValue)/\(name)"
    }

    /// Writes data into the store; returns the relative path to persist.
    static func write(_ data: Data, into folder: Folder, subfolder: String? = nil, fileName: String) throws -> String {
        var dir = directory(folder)
        var rel = folder.rawValue
        if let subfolder {
            dir = dir.appendingPathComponent(subfolder, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            rel += "/\(subfolder)"
        }
        try data.write(to: dir.appendingPathComponent(fileName))
        return "\(rel)/\(fileName)"
    }

    /// Writes data into the current session directory (mirroring Google Drive structure).
    /// Uses currentEventName and currentSessionName set at session start.
    static func writeToSession(_ data: Data, fileName: String) throws -> String {
        let names = resolvedSessionNames()
        let sessionDir = sessionDirectory()
        try data.write(to: sessionDir.appendingPathComponent(fileName))
        return "\(names.event)/Session \(names.session)/\(fileName)"
    }

    static func delete(relativePath: String) {
        try? FileManager.default.removeItem(at: url(for: relativePath))
    }
}

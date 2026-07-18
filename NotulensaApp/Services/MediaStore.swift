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

    /// Computes the session directory path based on current event/session context.
    static func sessionDirectory() -> URL {
        let eventDir = root.appendingPathComponent(currentEventName, isDirectory: true)
        let sessionDir = eventDir.appendingPathComponent("Session \(currentSessionName)", isDirectory: true)
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
        let dir = directory(folder)
        let name = UUID().uuidString + "." + source.pathExtension.lowercased()
        let dest = dir.appendingPathComponent(name)
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
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
        let sessionDir = sessionDirectory()
        try data.write(to: sessionDir.appendingPathComponent(fileName))
        return "\(currentEventName)/Session \(currentSessionName)/\(fileName)"
    }

    static func delete(relativePath: String) {
        try? FileManager.default.removeItem(at: url(for: relativePath))
    }
}

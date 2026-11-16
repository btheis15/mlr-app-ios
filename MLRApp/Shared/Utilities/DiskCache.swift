import Foundation
import SwiftUI

// MARK: - DiskCache
// Last-known-good snapshots so a screen can paint instantly on open and then
// refresh in the background (stale-while-revalidate). JSON files in Caches, so
// the system may purge them and nothing here is a source of truth.
//
// Keys should include the viewer's id (see `key(_:user:)`): what a member can
// see is per-person, and "View as" / sign-out must never show another
// account's snapshot.

enum DiskCache {
    private static let directory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("mlr-snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()

    static func key(_ name: String, user: UUID?) -> String {
        "\(name)-\(user?.uuidString ?? "guest")"
    }

    private static func url(for key: String) -> URL {
        let safe = key.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("\(safe).json")
    }

    /// The cached value, or nil when absent, unreadable, or written by an older
    /// shape of `T` (a decode failure is treated as a miss, never an error).
    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = try? Data(contentsOf: url(for: key)) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    /// Encodes here (models' Codable conformances are main-actor isolated) and
    /// writes the bytes off the calling actor; failures are ignored (it is only
    /// a cache).
    static func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? encoder.encode(value) else { return }
        let target = url(for: key)
        Task.detached(priority: .utility) {
            try? data.write(to: target, options: .atomic)
        }
    }

    static func remove(key: String) {
        try? FileManager.default.removeItem(at: url(for: key))
    }

    /// Sign-out: drop every snapshot.
    static func removeAll() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files { try? FileManager.default.removeItem(at: file) }
    }
}

// MARK: - Refresh helpers

/// Swap freshly fetched data in with the app's standard spring so rows move
/// rather than flash; plain assignment under Reduce Motion.
@MainActor
func applyRefreshed(_ change: () -> Void) {
    if MLRMotion.reduceMotion { change() } else { withAnimation(MLRMotion.spring, change) }
}

/// Tiny "fetched recently" gate so a tab's `.task` doesn't refetch on every
/// appearance. Pull-to-refresh and realtime refreshes ignore it.
struct FreshnessWindow {
    private var last: Date?
    func isFresh(within seconds: TimeInterval = 30) -> Bool {
        guard let last else { return false }
        return Date().timeIntervalSince(last) < seconds
    }
    mutating func touch() { last = Date() }
    mutating func reset() { last = nil }
}

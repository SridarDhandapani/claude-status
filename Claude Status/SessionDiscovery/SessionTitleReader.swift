import Foundation

/// Reads the session title Claude Code records in a session's `.jsonl` transcript.
///
/// Claude Code appends `{"type":"ai-title","aiTitle":...}` entries as it summarises
/// the conversation, and `{"type":"custom-title","customTitle":...}` when the user
/// runs `/rename`. A custom title wins over the AI title; within each kind the
/// latest entry wins.
///
/// Transcripts can be tens of megabytes, but Claude Code re-emits both entries
/// throughout the session, so the current titles sit near the end of the file.
/// Only the tail is read, widening once if it holds no title, and the result is
/// cached until the file changes.
final class SessionTitleReader {

    private struct Entry {
        let size: UInt64
        let modified: Date
        let title: String?
    }

    private var cache: [URL: Entry] = [:]

    /// Tail sizes to try in turn; the larger one covers long tool outputs between titles.
    static let tailWindows: [UInt64] = [256 * 1024, 4 * 1024 * 1024]
    /// Title entries are tiny; longer lines are skipped without inspection.
    private static let maxTitleLineLength = 4096
    private static let newline = UInt8(ascii: "\n")
    private static let aiTitleMarker = Data(#""type":"ai-title""#.utf8)
    private static let customTitleMarker = Data(#""type":"custom-title""#.utf8)

    /// Returns the current title for the transcript at `url`, or nil if none is recorded.
    func title(forTranscriptAt url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date else {
            cache[url] = nil
            return nil
        }
        if let entry = cache[url], entry.size == size, entry.modified == modified {
            return entry.title
        }

        let title = readTitle(from: url, size: size)
        cache[url] = Entry(size: size, modified: modified, title: title)
        return title
    }

    /// Drops cached state for transcripts not in `urls` (e.g. sessions that ended).
    func retain(only urls: Set<URL>) {
        cache = cache.filter { urls.contains($0.key) }
    }

    private func readTitle(from url: URL, size: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        for window in Self.tailWindows {
            let start = size > window ? size - window : 0
            guard (try? handle.seek(toOffset: start)) != nil,
                  let data = try? handle.read(upToCount: Int(size - start)) else {
                return nil
            }
            if let title = Self.title(in: data, startsMidLine: start > 0) {
                return title
            }
            if start == 0 { break }
        }
        return nil
    }

    private static func title(in data: Data, startsMidLine: Bool) -> String? {
        var lines = data.split(separator: newline)
        if startsMidLine, !lines.isEmpty {
            lines.removeFirst()
        }

        var aiTitle: String?
        var customTitle: String?
        for line in lines where line.count <= maxTitleLineLength {
            let isAI = line.range(of: aiTitleMarker) != nil
            let isCustom = !isAI && line.range(of: customTitleMarker) != nil
            guard isAI || isCustom,
                  let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                continue
            }
            if isAI, let title = normalized(json["aiTitle"]) {
                aiTitle = title
            } else if isCustom, let title = normalized(json["customTitle"]) {
                customTitle = title
            }
        }
        return customTitle ?? aiTitle
    }

    private static func normalized(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty else {
            return nil
        }
        return string
    }
}

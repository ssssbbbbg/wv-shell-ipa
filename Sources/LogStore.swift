//
//  LogStore.swift
//  PokeBonk
//
//  Appends diagnostics from the page to Documents/pokebonk.log.
//
//  UIFileSharingEnabled is set in Info.plist, so the file shows up in the Files
//  app under "On My iPad / PokeBonk". Rotation keeps it bounded at 512 KB.
//
import Foundation

final class LogStore {

    static let shared = LogStore()

    private let queue = DispatchQueue(label: "com.pokebonk.log")
    private let maxBytes = 512 * 1024
    private var url: URL?
    private var seq = 0

    private init() {
        url = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("pokebonk.log")
    }

    var fileURL: URL? { url }

    /// True when the log has content worth sharing (used by the share sheet).
    var hasContent: Bool {
        guard let url = url,
              let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        else { return false }
        return size.intValue > 0
    }

    func reset() {
        queue.async { [weak self] in
            guard let self = self, let url = self.url else { return }
            try? FileManager.default.removeItem(at: url)
            self.open()
        }
    }

    func append(kind: String, text: String) {
        queue.async { [weak self] in
            guard let self = self, let url = self.url else { return }
            if !FileManager.default.fileExists(atPath: url.path) { self.open() }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            handle.seekToEndOfFile()
            let line = "\(Self.stamp()) [\(kind)] \(text)\n"
            if let data = line.data(using: .utf8) { handle.write(data) }
            let size = handle.offsetInFile
            try? handle.close()
            if size > UInt64(self.maxBytes) { self.rotate() }
        }
    }

    // MARK: - Private

    private func open() {
        guard let url = url else { return }
        let header = "=== PokeBonk log \(Self.stamp()) ===\n"
        try? header.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    private func rotate() {
        guard let url = url else { return }
        let old = url.deletingPathExtension().appendingPathExtension("1.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
        open()
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}

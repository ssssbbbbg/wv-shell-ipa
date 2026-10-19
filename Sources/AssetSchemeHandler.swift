//
//  AssetSchemeHandler.swift
//  PokeBonk
//
//  WKURLSchemeHandler that serves `appassets://appassets.local/<path>` from
//  Bundle.main/site/<path>.
//
//  Threading: WebKit calls start()/stop() on the main thread. Every live task is
//  tracked so a task stopped by a navigation is never messaged again
//  (didReceive/didFinish after stop raises "This task has already been stopped").
//

import Foundation
import WebKit
import UniformTypeIdentifiers

final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {

    private let siteRoot: URL
    /// `siteRoot.path + "/"`, used to prove a resolved path stays inside the bundle.
    private let siteRootPrefix: String
    private let fileManager = FileManager.default

    /// In-flight tasks, by object identity (WKURLSchemeTask is not Hashable).
    private var liveTasks = Set<ObjectIdentifier>()
    private let lock = NSLock()

    init(siteRoot: URL) {
        let resolved = siteRoot.resolvingSymlinksInPath().standardizedFileURL
        self.siteRoot = resolved
        var prefix = resolved.path
        if !prefix.hasSuffix("/") { prefix += "/" }
        self.siteRootPrefix = prefix
        super.init()
    }

    // MARK: - URL -> file

    /// Maps a request URL to an on-disk file. nil for anything that is not a clean,
    /// in-bounds path under `site/` (foreign scheme/host, traversal, missing file).
    func fileURL(for url: URL) -> URL? {
        guard url.scheme?.lowercased() == AppScheme.scheme,
              url.host?.lowercased() == AppScheme.host.lowercased()
        else { return nil }

        // url.path is already percent-decoded; `?`/`#` are not part of it.
        var path = url.path
        if path.hasPrefix("/") { path.removeFirst() }
        if path.isEmpty { path = "index.html" }
        if path.hasSuffix("/") { path += "index.html" }   // directory -> SPA entry

        // Reject traversal and NUL/backslash oddities.
        guard !path.contains("\0"), !path.contains("\\") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains("..") else { return nil }

        let candidate = siteRoot
            .appendingPathComponent(path)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        // After resolution it must still live under site/.
        guard candidate.path.hasPrefix(siteRootPrefix) else { return nil }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue {
            let index = candidate.appendingPathComponent("index.html")
            return fileManager.fileExists(atPath: index.path) ? index : nil
        }
        // Exact name only. Case-insensitive fallback is deliberately NOT implemented:
        // CI builds on a case-insensitive volume, the iPad is case-sensitive, so a
        // link that only differs by case must fail here (and in the CI smoke test).
        return candidate
    }

    // MARK: - MIME

    /// Extension -> MIME overrides, applied before the system database.
    /// WebKit enforces strict MIME checking for module scripts: JS served as
    /// application/octet-stream is rejected and the whole game fails to boot.
    static let mimeOverrides: [String: String] = [
        "js":   "text/javascript; charset=utf-8",
        "mjs":  "text/javascript; charset=utf-8",
        "css":  "text/css; charset=utf-8",
        "json": "application/json; charset=utf-8",
        "map":  "application/json; charset=utf-8",
        "html": "text/html; charset=utf-8",
        "htm":  "text/html; charset=utf-8",
        "webmanifest": "application/manifest+json; charset=utf-8",
        "txt":  "text/plain; charset=utf-8",
        "svg":  "image/svg+xml",
        "png":  "image/png",
        "jpg":  "image/jpeg",
        "jpeg": "image/jpeg",
        "webp": "image/webp",
        "gif":  "image/gif",
        "ico":  "image/x-icon",
        "woff": "font/woff",
        "woff2": "font/woff2",
        "ttf":  "font/ttf",
        "otf":  "font/otf",
        "ogg":  "audio/ogg",
        "oga":  "audio/ogg",
        "opus": "audio/ogg",
        "mp3":  "audio/mpeg",
        "m4a":  "audio/mp4",
        "wav":  "audio/wav",
        "mp4":  "video/mp4",
        "webm": "video/webm",
        "glb":  "model/gltf-binary",
        "gltf": "model/gltf+json",
        "bin":  "application/octet-stream",
        "wasm": "application/wasm",
        "ktx2": "image/ktx2",
        "hdr":  "image/vnd.radiance",
        "exr":  "image/aces"
    ]

    static func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if let override = mimeOverrides[ext] { return override }
        if !ext.isEmpty,
           let ut = UTType(filenameExtension: ext),
           let mime = ut.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    /// Hashed Vite bundles never change -> immutable. Entry points revalidate.
    static func cacheControl(for url: URL) -> String {
        switch url.lastPathComponent.lowercased() {
        case "index.html", "manifest.webmanifest", "version.json":
            return "no-cache"
        default:
            return "public, max-age=604800, immutable"
        }
    }

    // MARK: - Task bookkeeping

    private func begin(_ task: WKURLSchemeTask) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return liveTasks.insert(ObjectIdentifier(task)).inserted
    }

    private func isLive(_ task: WKURLSchemeTask) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return liveTasks.contains(ObjectIdentifier(task))
    }

    @discardableResult
    private func end(_ task: WKURLSchemeTask) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return liveTasks.remove(ObjectIdentifier(task)) != nil
    }

    // MARK: - WKURLSchemeHandler

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard begin(urlSchemeTask) else { return }
        guard let requestURL = urlSchemeTask.request.url else {
            end(urlSchemeTask)
            return
        }
        guard let fileURL = fileURL(for: requestURL) else {
            respond(urlSchemeTask, requestURL: requestURL, status: 404,
                    headers: ["Content-Type": "text/plain; charset=utf-8"],
                    body: Data("Not Found\n".utf8))
            return
        }

        let data: Data
        let mtime: Date
        do {
            let attrs = try fileManager.attributesOfItem(atPath: fileURL.path)
            mtime = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
            // .mappedIfSafe keeps 70+ MB of GLB/OGG/PNG off the heap where possible.
            data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch {
            respond(urlSchemeTask, requestURL: requestURL, status: 500,
                    headers: ["Content-Type": "text/plain; charset=utf-8"],
                    body: Data("Read error\n".utf8))
            return
        }

        respond(urlSchemeTask, requestURL: requestURL, status: 200,
                headers: headers(for: fileURL, length: data.count, mtime: mtime),
                body: data)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Synchronous handler: nothing in flight. Forget the task regardless.
        end(urlSchemeTask)
    }

    // MARK: - Response helpers

    private func headers(for url: URL, length: Int, mtime: Date) -> [String: String] {
        [
            "Content-Type": Self.mimeType(for: url),
            "Content-Length": "\(length)",
            "Cache-Control": Self.cacheControl(for: url),
            "Last-Modified": Self.httpDate(mtime),
            // WKURLSchemeHandler cannot answer Range requests. Advertising "none"
            // keeps WebKit/AVFoundation from retrying with ranges; see README.
            "Accept-Ranges": "none",
            "X-Content-Type-Options": "nosniff"
        ]
    }

    private func respond(_ task: WKURLSchemeTask,
                         requestURL: URL,
                         status: Int,
                         headers: [String: String],
                         body: Data) {
        guard isLive(task) else { return }
        let response = HTTPURLResponse(url: requestURL,
                                       statusCode: status,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
        guard isLive(task) else { return }
        task.didReceive(response)
        guard isLive(task) else { return }
        task.didReceive(body)
        guard end(task) else { return }
        task.didFinish()
    }

    // MARK: - HTTP date

    private static let httpDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }()

    static func httpDate(_ date: Date) -> String { httpDateFormatter.string(from: date) }
}

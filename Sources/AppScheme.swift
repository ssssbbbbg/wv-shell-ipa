//
//  AppScheme.swift
//  PokeBonk
//
//  The game is served from a custom URL scheme instead of file://.
//  file:// breaks ES modules (a file: origin is opaque; module scripts are fetched
//  in CORS mode and fail), fetch() of local JSON, and gives localStorage an
//  unstable origin. A registered custom scheme has https-like same-origin semantics
//  with no server on the device.
//

import Foundation

enum AppScheme {
    /// Must match the scheme registered on WKWebViewConfiguration and in Info.plist.
    static let scheme = "appassets"

    /// Host part, so relative URLs resolve exactly like the Android build, whose
    /// virtual origin was `https://appassets.androidplatform.net/`.
    ///   -> appassets://appassets.local/index.html
    static let host = "appassets.local"

    /// Bundle sub-directory that contains the mirrored static site.
    static let siteDirectoryName = "site"

    /// Root URL the WKWebView loads.
    static var indexURL: URL { URL(string: "\(scheme)://\(host)/index.html")! }
    static var origin: String { "\(scheme)://\(host)" }
}

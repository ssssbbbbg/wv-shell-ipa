//
//  WebScripts.swift
//  PokeBonk
//
//  User scripts injected into every main frame.
//
//  .atDocumentStart runs before index.html is parsed, so before
//  <script type="module" src="./assets/main-*.js"> executes. That is the exact slot
//  the Android wrapper used for `/__bridge.js` (a <script> tag in <head>). Here the
//  same file is injected as a user script, keeping the ordering identical without
//  editing any mirrored file.
//

import Foundation
import WebKit

enum WebScripts {

    /// The offline backend (Android assets/bridge.js), copied verbatim into
    /// Resources/site/bridge.js by make_site_zip.sh. Injected unmodified.
    static func bridgeScript() -> WKUserScript? {
        let candidates = [
            Bundle.main.url(forResource: "bridge", withExtension: "js",
                            subdirectory: AppScheme.siteDirectoryName),
            Bundle.main.url(forResource: "bridge", withExtension: "js")
        ].compactMap { $0 }

        guard let fileURL = candidates.first,
              let source = try? String(contentsOf: fileURL, encoding: .utf8)
        else {
            NSLog("[PokeBonk] bridge.js missing from bundle: offline backend disabled")
            return nil
        }
        return WKUserScript(source: source,
                            injectionTime: .atDocumentStart,
                            forMainFrameOnly: true)
    }

    /// Native-side glue that must run before the game code:
    ///   * mark the platform / origin;
    ///   * record a null WebGL context (GPU process death) instead of a silent
    ///     black screen;
    ///   * relay focus of <input>/<textarea> to the native shell: a WKWebView with
    ///     text interaction disabled cannot raise the system keyboard by itself.
    static func bootstrapScript() -> WKUserScript {
        let origin = "\"\(AppScheme.origin)\""
        let source = """
        (function () {
          'use strict';
          try { window.__pbNative = { platform: 'ios', origin: \(origin) }; } catch (e) {}

          // Some WebKit builds return null from getContext when the GPU process was
          // killed under memory pressure. Record it; the log bridge shows it.
          try {
            var orig = HTMLCanvasElement.prototype.getContext;
            HTMLCanvasElement.prototype.getContext = function (type, attrs) {
              var ctx = orig.call(this, type, attrs);
              if (!ctx && /webgl/i.test(String(type))) {
                window.__pbNoWebGL = window.__pbNoWebGL || String(type);
                try { window.webkit.messageHandlers.pbLog.postMessage('no-webgl:' + type); } catch (e) {}
              }
              return ctx;
            };
          } catch (e) {}

          // --- native keyboard relay (account name field) -----------------------
          try {
            var post = function (msg) {
              try { window.webkit.messageHandlers.pbKeyboard.postMessage(msg); } catch (e) {}
            };
            var active = null;
            window.__pbKeyboardBind = function (el) {
              if (!el || el.__pbKb) { return; }
              el.__pbKb = 1;
              if (!el.id) { el.id = 'pb-kb-' + Math.random().toString(36).slice(2, 9); }
              el.addEventListener('focus', function () {
                active = el;
                post({ type: 'focus', id: el.id, value: el.value || '' });
              });
              el.addEventListener('blur', function () {
                if (active === el) { active = null; post({ type: 'blur' }); }
              });
            };
            document.addEventListener('focusin', function (e) {
              var t = e.target;
              if (t && (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA')) { window.__pbKeyboardBind(t); }
            }, true);
            // Inputs created and focused programmatically may miss focusin.
            var scan = function () {
              var list = document.querySelectorAll('input,textarea');
              for (var i = 0; i < list.length; i++) { window.__pbKeyboardBind(list[i]); }
            };
            document.addEventListener('DOMContentLoaded', scan);
            window.addEventListener('load', scan);
          } catch (e) {}
        })();
        """
        return WKUserScript(source: source,
                            injectionTime: .atDocumentStart,
                            forMainFrameOnly: true)
    }

    /// CSS that is not in the mirrored HTML (which must stay untouched):
    /// no callout, no selection, no overscroll.
    static func styleScript() -> WKUserScript {
        let css = """
        *{-webkit-touch-callout:none !important;
           -webkit-user-select:none !important;
           user-select:none !important;
           -webkit-tap-highlight-color:transparent !important;}
        html,body{overscroll-behavior:none !important;overflow:hidden !important;
                  background:#000 !important;}
        """
        let source = "var s=document.createElement('style');s.id='pb-native-style';" +
                     "s.textContent=\(jsStringLiteral(css));" +
                     "(document.head||document.documentElement).appendChild(s);"
        return WKUserScript(source: source,
                            injectionTime: .atDocumentStart,
                            forMainFrameOnly: true)
    }

    /// JSON-safe JS string literal (quotes, backslashes, newlines, U+2028/9).
    static func jsStringLiteral(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(json.dropFirst().dropLast())   // strip the enclosing [ ]
    }
}

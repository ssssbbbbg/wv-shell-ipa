//
//  ApiRouter.swift
//  PokeBonk
//
//  Final fetch layer. Installed *after* bridge.js, so it sits outermost:
//
//      window.fetch = [this router] -> [bridge.js wrapper] -> [network]
//
//  Why this exists
//  ---------------
//  bridge.js decides whether to answer a request locally with:
//
//      if (u.origin !== location.origin || !API.test(u.pathname)) return origFetch(...)
//
//  Under `appassets://appassets.local` that comparison is unreliable: WebKit's
//  URL.origin for a custom scheme is the opaque "null" while location.origin is
//  the scheme://host string (and u.host may come back empty). The result was that
//  every local API call fell through to the network and the asset handler
//  answered 404 — the game then reported "no connection to the server".
//
//  Rather than patch that heuristic (which depends on WebKit internals we cannot
//  see), bridge.js now exports its router in `window.__pbInternals`, and this
//  layer performs the dispatch itself using plain string handling — no URL
//  parsing, no origin comparison.
//
import Foundation
import WebKit

enum ApiRouter {

    static func script() -> WKUserScript {
        let source = """
        (function () {
          'use strict';
          if (window.__pbRouter) return;
          window.__pbRouter = true;

          var prev = window.fetch;
          if (!prev) return;

          // scheme://host/path?query#hash -> { path, query }
          function split(url) {
            var s = String(url), hash = '', query = '';
            var h = s.indexOf('#');
            if (h >= 0) { s = s.slice(0, h); }
            var q = s.indexOf('?');
            if (q >= 0) { query = s.slice(q + 1); s = s.slice(0, q); }
            var m = s.match(/^[a-zA-Z][a-zA-Z0-9+.\\-]*:\\/\\/[^\\/]*(\\/.*)?$/);
            var path;
            if (m) { path = m[1] || '/'; }
            else if (s.charAt(0) === '/') { path = s; }
            else { path = null; }
            return { path: path, query: query };
          }

          var REMOTE = /^https?:\\/\\/([a-z0-9.-]*\\.)?pokebonk\\.com/i;
          var LOCAL  = /^appassets:/i;

          window.fetch = function (input, init) {
            var url = (typeof input === 'string') ? input
                    : (input && input.url) ? input.url
                    : null;
            var I = window.__pbInternals;
            if (!url || !I) return prev.apply(window, arguments);

            var remote = REMOTE.test(url);
            var local = LOCAL.test(url) || url.charAt(0) === '/';
            if (!remote && !local) return prev.apply(window, arguments);

            var parts = split(url);
            if (!parts.path) return prev.apply(window, arguments);

            // 1. Anything the offline backend implements is answered locally.
            if (I.isApi(parts.path)) {
              var method = ((init && init.method) || 'GET').toUpperCase();
              try { (window.__pbDiagLog || function () {})(('route local'), method + ' ' + parts.path); } catch (e) {}
              try {
                return Promise.resolve(
                  I.handle(parts.path,
                           new URLSearchParams(parts.query),
                           method,
                           I.parseBody(init),
                           I.tokenOf(init))
                );
              } catch (e) {
                return Promise.reject(e);
              }
            }

            // 2. Non-API requests to the remote host (assets, etc.) are pointed
            //    back at the bundled copy so the app stays offline.
            if (remote) {
              try { (window.__pbDiagLog || function () {})(('route asset'), parts.path); } catch (e) {}
              var target = location.protocol + '//' + location.host + parts.path +
                           (parts.query ? '?' + parts.query : '');
              return prev.call(window, target, init);
            }

            try {
              (window.__pbDiagLog || function () {})('route pass',
                ((init && init.method) || 'GET') + ' ' + parts.path +
                ' api=' + (I.isApi ? I.isApi(parts.path) : '?'));
            } catch (e) {}
            return prev.apply(window, arguments);
          };
        })();
        """
        return WKUserScript(source: source,
                            injectionTime: .atDocumentStart,
                            forMainFrameOnly: true)
    }
}

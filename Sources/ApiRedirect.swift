//
//  ApiRedirect.swift
//  PokeBonk
//
//  The 0.7.x build hardcodes its backend:
//
//      function WT(e) { return new UT(`https://api.pokebonk.com`...) }
//
//  so every account/leaderboard/clan call is an absolute cross-origin request
//  and never matches bridge.js's same-origin check. Offline (or when the API is
//  unreachable) that surfaces as "no connection to the server".
//
//  This script runs *before* bridge.js at documentStart and rewrites every
//  request whose host is pokebonk.com (api., www., bare) onto the app's own
//  origin. bridge.js then wraps this function as its `origFetch`, sees a
//  same-origin URL, and answers it from localStorage.
//
//  Ordering is load-bearing:
//      Diagnostics -> ApiRedirect -> bridge -> glue -> perf
//  If ApiRedirect ran after bridge, bridge would have captured the untouched
//  fetch and the rewrite would never happen.
//
import Foundation
import WebKit

enum ApiRedirect {

    static func script() -> WKUserScript {
        let source = """
        (function () {
          'use strict';
          if (window.__pbApiRedirect) return;
          window.__pbApiRedirect = true;

          var orig = window.fetch;
          if (!orig) return;

          // appassets://appassets.local — never use location.origin here: for a
          // custom scheme WebKit may report "null".
          var ORIGIN = location.protocol + '//' + location.host;
          var API_RE = /(^|\\.)pokebonk\\.com$/i;

          function rewrite(url) {
            try {
              var u = new URL(url, location.href);
              if (!/^https?:$/.test(u.protocol)) return null;   // already local
              if (!API_RE.test(u.hostname)) return null;
              var out = ORIGIN + u.pathname + u.search + u.hash;
              // Remember the original path so diagnostics can tell them apart.
              try { (window.__pbRewrites = window.__pbRewrites || []).push(u.hostname + u.pathname); } catch (e) {}
              return out;
            } catch (e) { return null; }
          }

          window.fetch = function (input, init) {
            var url = (typeof input === 'string') ? input
                    : (input && input.url) ? input.url
                    : null;
            if (url) {
              var to = rewrite(url);
              if (to) return orig.call(window, to, init);
            }
            return orig.apply(window, arguments);
          };
        })();
        """
        return WKUserScript(source: source,
                            injectionTime: .atDocumentStart,
                            forMainFrameOnly: true)
    }
}

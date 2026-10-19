//
//  Diagnostics.swift
//  PokeBonk
//
//  Boot diagnostics overlay.
//
//  A WKWebView has no visible console, so a failed module load, a CSP rejection
//  or an exception inside the game bundle looks like "black screen". This script
//  runs at documentStart (before any page script), captures every error channel
//  WebKit exposes, and paints them on top of the page when something goes wrong.
//
//  It stays invisible when the game boots normally.
//
import Foundation
import WebKit

enum Diagnostics {

    static func script() -> WKUserScript {
        let source = """
        (function () {
          'use strict';
          if (window.__pbDiag) return;
          var log = [];
          var panel = null;
          var shown = false;

          function paint() {
            if (!document.body) return;
            if (!panel) {
              panel = document.createElement('div');
              panel.id = '__pbDiag';
              panel.style.cssText = [
                'position:fixed','left:0','right:0','top:0','z-index:2147483647',
                'max-height:60vh','overflow:auto','background:rgba(10,8,20,.96)',
                'color:#ffd7d7','font:11px/1.45 ui-monospace,Menlo,monospace',
                'padding:10px 12px','white-space:pre-wrap','word-break:break-all',
                'border-bottom:2px solid #ff5a5a','pointer-events:auto'
              ].join(';');
              panel.addEventListener('dblclick', function () { panel.remove(); panel = null; });
              document.body.appendChild(panel);
            }
            panel.textContent = 'PokeBonk boot diagnostics (double-tap to dismiss)\\n\\n' + log.join('\\n');
            shown = true;
          }

          var stateAdded = false;
          function add(kind, text) {
            if (log.length > 40) return;
            log.push('[' + kind + '] ' + text);
            // On the first network problem, also dump the environment so the
            // screenshot explains itself.
            if (!stateAdded && (kind === 'http' || kind === 'fetch-fail')) {
              stateAdded = true;
              log.push('[state] bridge=' + (window.__pbBridge ? 'y' : 'n') +
                       ' redirect=' + (window.__pbApiRedirect ? 'y' : 'n') +
                       ' perf=' + (window.__pbPerf ? 'y' : 'n') +
                       ' storage=' + (function () {
                         try { localStorage.setItem('__t', '1'); localStorage.removeItem('__t'); return 'ok'; }
                         catch (e) { return 'BLOCKED'; }
                       })() +
                       ' rewrites=' + ((window.__pbRewrites || []).length));
            }
            paint();
          }

          window.__pbDiagLog = add;

          // 1. Plain script errors (module load failures surface here too).
          window.addEventListener('error', function (e) {
            var t = e.target;
            if (t && t !== window && (t.src || t.href)) {
              add('resource', (t.tagName || '?') + ' failed: ' + (t.src || t.href));
            } else {
              add('error', (e.message || 'unknown') + (e.filename ? ' @ ' + e.filename + ':' + e.lineno : ''));
            }
          }, true);

          // 2. Rejected promises (dynamic import() rejects land here).
          window.addEventListener('unhandledrejection', function (e) {
            var r = e.reason;
            add('promise', (r && (r.stack || r.message)) ? (r.stack || r.message) : String(r));
          });

          // 3. console.error / warn, which the game uses for load failures.
          ['error', 'warn'].forEach(function (lvl) {
            var orig = console[lvl];
            console[lvl] = function () {
              try {
                add('console.' + lvl, Array.prototype.map.call(arguments, function (a) {
                  if (a && a.stack) return a.stack;
                  try { return typeof a === 'string' ? a : JSON.stringify(a); }
                  catch (e) { return String(a); }
                }).join(' '));
              } catch (e) {}
              return orig.apply(console, arguments);
            };
          });

          // 4. Network trace. Installed before bridge.js, so bridge's own wrapper
          //    captures this as `origFetch`: every request bridge does NOT answer
          //    locally still lands here, which is exactly what we need to see.
          var reqs = [];
          var origFetch = window.fetch;
          window.fetch = function (input, init) {
            var url = typeof input === 'string' ? input : (input && input.url) || String(input);
            var method = ((init && init.method) || 'GET').toUpperCase();
            var p = origFetch.apply(window, arguments);
            p.then(function (r) {
              if (!r || r.status >= 400) {
                add('http', (r ? r.status : '?') + ' ' + method + ' ' + url);
              } else if (reqs.length < 20) {
                reqs.push(r.status + ' ' + method + ' ' + url);
              }
            }, function (e) {
              add('fetch-fail', method + ' ' + url + ' :: ' + ((e && e.message) || e));
            });
            return p;
          };

          // 5. Boot watchdog: the game paints into #ui; if it is still empty after
          //    6 s, something silently stalled. Report what loaded instead.
          function watchdog() {
            var ui = document.getElementById('ui');
            if (ui && ui.children.length > 0) return;
            if (log.length === 0) {
              var scripts = [].map.call(document.querySelectorAll('script[src]'), function (s) { return s.getAttribute('src'); });
              add('watchdog', '#ui still empty after 6s');
              add('watchdog', 'scripts in DOM: ' + (scripts.join(', ') || 'none'));
              add('watchdog', 'location: ' + location.href);
              add('watchdog', 'canvas ctx: ' + (function () {
                try {
                  var c = document.getElementById('game');
                  if (!c) return 'no canvas';
                  return c.getContext('webgl2') ? 'webgl2' : (c.getContext('webgl') ? 'webgl1' : 'none');
                } catch (e) { return 'err ' + e.message; }
              })());
              add('watchdog', 'body children: ' + document.body.children.length);
            }
            add('state', 'bridge=' + (window.__pbBridge ? 'y' : 'n') +
                          ' perf=' + (window.__pbPerf ? 'y' : 'n') +
                          ' storage=' + (function () { try { localStorage.setItem('__t','1'); localStorage.removeItem('__t'); return 'ok'; } catch (e) { return 'BLOCKED'; } })());
            add('state', 'ok requests: ' + (reqs.slice(0, 6).join(' | ') || 'none'));
          }
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', function () { setTimeout(watchdog, 6000); });
          } else {
            setTimeout(watchdog, 6000);
          }
        })();
        """
        return WKUserScript(source: source,
                            injectionTime: .atDocumentStart,
                            forMainFrameOnly: true)
    }
}

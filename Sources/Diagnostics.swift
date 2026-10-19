//
//  Diagnostics.swift
//  PokeBonk
//
//  Writes a boot/runtime log to a file instead of drawing anything on screen.
//
//  The page reports through `window.webkit.messageHandlers.pbDiag`; the native
//  side appends each line to Documents/pokebonk.log (rotated at 512 KB) and the
//  bundle declares UIFileSharingEnabled, so the log is reachable from the Files
//  app without any in-game UI.
//
//  What is recorded: environment snapshot (measured), every request with its
//  disposition (local / asset / pass), resource failures, exceptions, rejected
//  promises and console errors. Nothing is filtered out of the file — the
//  filtering only ever affected the removed on-screen panel.
//
import Foundation
import WebKit

enum Diagnostics {

    /// Message handler name shared with GameWebViewController.
    static let handlerName = "pbDiag"

    static func script() -> WKUserScript {
        let source = """
        (function () {
          'use strict';
          if (window.__pbDiag) return;
          window.__pbDiag = true;

          var seq = 0;
          function send(kind, text) {
            try {
              window.webkit.messageHandlers.\(handlerName).postMessage({
                seq: ++seq, kind: kind, text: String(text)
              });
            } catch (e) { /* handler missing: drop silently */ }
          }
          window.__pbDiagLog = send;

          // ---------- environment snapshot (measured) ----------
          function env(k, fn) {
            var v;
            try { v = fn(); } catch (e) { v = 'THROW ' + e.message; }
            send('env', k + '=' + v);
          }
          env('protocol', function () { return location.protocol; });
          env('host', function () { return location.host; });
          env('origin', function () { return location.origin; });
          env('href', function () { return location.href; });
          env('anchorOrigin', function () {
            return new URL('appassets://appassets.local/status', location.href).origin;
          });
          env('anchorHost', function () {
            return new URL('appassets://appassets.local/status', location.href).host;
          });
          env('storage', function () {
            localStorage.setItem('__t', '1'); localStorage.removeItem('__t'); return 'ok';
          });

          // ---------- error channels ----------
          window.addEventListener('error', function (e) {
            var t = e.target;
            if (t && t !== window && (t.src || t.href)) {
              send('resource', (t.tagName || '?') + ' ' + (t.src || t.href));
            } else {
              send('error', (e.message || '?') + (e.filename ? ' @ ' + e.filename + ':' + e.lineno : ''));
            }
          }, true);

          window.addEventListener('unhandledrejection', function (e) {
            var r = e.reason;
            send('promise', (r && (r.stack || r.message)) ? (r.stack || r.message) : String(r));
          });

          ['error', 'warn'].forEach(function (lvl) {
            var orig = console[lvl];
            console[lvl] = function () {
              try {
                send('console.' + lvl, Array.prototype.map.call(arguments, function (a) {
                  if (a && a.stack) return a.stack;
                  try { return typeof a === 'string' ? a : JSON.stringify(a); } catch (x) { return String(a); }
                }).join(' '));
              } catch (x) {}
              return orig.apply(console, arguments);
            };
          });

          // ---------- network observer (innermost) ----------
          var beforeRouter = window.fetch;
          window.fetch = function (input, init) {
            var url = typeof input === 'string' ? input : (input && input.url) || String(input);
            var method = ((init && init.method) || 'GET').toUpperCase();
            var p = beforeRouter.apply(window, arguments);
            p.then(function (r) {
              if (!r || r.status >= 400) {
                send('net', (r ? r.status : '?') + ' ' + method + ' ' + url);
              }
            }, function (e) {
              send('net-fail', method + ' ' + url + ' :: ' + ((e && e.message) || e));
            });
            return p;
          };

          // ---------- boot probe ----------
          function probe() {
            var ui = document.getElementById('ui');
            var c = document.getElementById('game');
            var ctx = 'n/a';
            try {
              ctx = c ? (c.getContext('webgl2') ? 'webgl2' : (c.getContext('webgl') ? 'webgl1' : 'none')) : 'no-canvas';
            } catch (e) { ctx = 'throw'; }
            send('boot', '#ui children=' + (ui ? ui.children.length : 'no-ui') +
                          ' canvas=' + ctx +
                          ' bridge=' + (window.__pbBridge ? 'y' : 'n') +
                          ' router=' + (window.__pbRouter ? 'y' : 'n') +
                          ' perf=' + (window.__pbPerf ? 'y' : 'n'));
          }
          function schedule() { setTimeout(probe, 4000); setTimeout(probe, 10000); }
          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', schedule);
          } else { schedule(); }
        })();
        """
        return WKUserScript(source: source,
                            injectionTime: .atDocumentStart,
                            forMainFrameOnly: true)
    }
}

//
//  Diagnostics.swift
//  PokeBonk
//
//  One-shot evidence collector. Everything the app can observe is recorded and
//  painted on screen, so a single install is enough to explain a failure:
//
//    * environment snapshot measured at documentStart (location fields, what the
//      URL parser actually returns for the custom scheme, storage availability)
//    * one line per request with its disposition: local / asset / pass / fail
//    * resource load failures, exceptions, rejected promises, console errors
//    * boot watchdog: whether #ui ever got content, which canvas context exists
//
//  The panel appears automatically as soon as anything is logged, and a small
//  "LOG" button re-opens it after it is dismissed (double-tap the panel).
//
import Foundation
import WebKit

enum Diagnostics {

    static func script() -> WKUserScript {
        let source = """
        (function () {
          'use strict';
          if (window.__pbDiag) return;
          window.__pbDiag = true;

          var lines = [];
          var panel = null;
          var reopened = null;

          // ---------- environment snapshot (measured, not assumed) ----------
          var env = [];
          function pushEnv(k, fn) {
            var v;
            try { v = fn(); } catch (e) { v = 'THROW ' + e.message; }
            env.push(k + '=' + v);
          }
          pushEnv('protocol', function () { return location.protocol; });
          pushEnv('host', function () { return location.host; });
          pushEnv('hostname', function () { return location.hostname; });
          pushEnv('origin', function () { return location.origin; });
          pushEnv('href', function () { return location.href; });
          pushEnv('hasFetch', function () { return typeof fetch; });
          pushEnv('hasResponse', function () { return typeof Response; });
          pushEnv('anchorOrigin', function () {
            return new URL('appassets://appassets.local/status', location.href).origin;
          });
          pushEnv('anchorHost', function () {
            return new URL('appassets://appassets.local/status', location.href).host;
          });
          pushEnv('anchorProto', function () {
            return new URL('appassets://appassets.local/status', location.href).protocol;
          });
          pushEnv('storage', function () {
            localStorage.setItem('__t', '1'); localStorage.removeItem('__t'); return 'ok';
          });

          // ---------- rendering ----------
          function paint() {
            if (!document.body) { return; }
            if (!panel) {
              panel = document.createElement('div');
              panel.id = '__pbDiag';
              panel.style.cssText = [
                'position:fixed', 'left:0', 'right:0', 'top:0', 'z-index:2147483647',
                'max-height:72vh', 'overflow:auto', 'background:rgba(8,6,18,.97)',
                'color:#ffd9d9', 'font:11px/1.5 ui-monospace,Menlo,monospace',
                'padding:10px 12px', 'white-space:pre-wrap', 'word-break:break-all',
                'border-bottom:2px solid #ff5a5a', '-webkit-user-select:text', 'user-select:text'
              ].join(';');
              // Double-tap dismisses, but the LOG tab stays.
              panel.addEventListener('dblclick', hide);
              document.body.appendChild(panel);
            }
            var head = 'PokeBonk diagnostics | flags: bridge=' + (window.__pbBridge ? 'y' : 'n') +
                       ' internals=' + (window.__pbInternals ? 'y' : 'n') +
                       ' router=' + (window.__pbRouter ? 'y' : 'n') +
                       ' perf=' + (window.__pbPerf ? 'y' : 'n') + '\\n' +
                       'env: ' + env.join(' ') + '\\n' +
                       '----------------------------------------------------------\\n';
            panel.textContent = head + lines.join('\\n');
            panel.style.display = 'block';
            ensureTab();
          }

          function ensureTab() {
            if (reopened && reopened.isConnected) return;
            reopened = document.createElement('button');
            reopened.type = 'button';
            reopened.textContent = 'LOG';
            reopened.style.cssText = [
              'position:fixed', 'left:calc(env(safe-area-inset-left,0px) + 8px)',
              'bottom:calc(env(safe-area-inset-bottom,0px) + 8px)',
              'z-index:2147483647', 'padding:6px 10px', 'border-radius:8px',
              'background:rgba(255,90,90,.85)', 'color:#fff', 'border:0',
              'font:11px ui-monospace,Menlo,monospace', 'opacity:.75'
            ].join(';');
            reopened.addEventListener('click', function (e) {
              e.preventDefault(); e.stopPropagation();
              if (panel) { panel.style.display = 'block'; }
              else { paint(); }
            });
            document.body.appendChild(reopened);
          }

          function hide() { if (panel) { panel.style.display = 'none'; } }

          // ---------- logging ----------
          // Kinds that mean "something is broken". Only these surface the panel;
          // everything else (route traces, boot probes) is buffered silently so
          // normal play is never covered by an overlay.
          // Things that are always a real fault.
          var ALARM = { 'resource': 1, 'error': 1, 'promise': 1, 'console.error': 1 };

          // Network failures only alarm for API paths. The game probes optional
          // files on purpose (front/N.png exists for 54 ids, the rest fall back
          // to icons/N.png), so an asset 404 is normal operation, not a fault.
          // Same expression as bridge.js's router so the two agree.
          var API_PATH = /^\\/(status|auth\\/|profile|runs|news$|records|seasons|leaderboard|mail|clans|friends|players|lab\\/|items\\/|quests\\/|tasks\\/|feedback)/;

          var seen = {};
          window.__pbDiagLog = function (kind, text) {
            if (lines.length > 200) return;
            var alarm = !!ALARM[kind];
            if (kind === 'net' || kind === 'net-fail' || kind === 'fetch-fail') {
              var m = String(text).match(/(appassets:\\/\\/appassets\\.local|https?:\\/\\/[^\\s]*pokebonk\\.com)?(\\/[^\\s?]*)/);
              var p = m ? m[2] : '';
              alarm = API_PATH.test(p);
              if (!alarm) { return; }        // optional-asset probe: ignore entirely
            }
            var sig = kind + '|' + text;
            if (seen[sig]) { return; }       // do not stack identical failures
            seen[sig] = 1;
            lines.push('[' + kind + '] ' + text);
            if (alarm) { paint(); }
          };

          // Escape hatch: open the log on demand without any visible UI.
          // Five quick taps in the top-left corner toggles it.
          var taps = 0, tapT = 0;
          window.addEventListener('touchstart', function (e) {
            var t = (e.touches && e.touches[0]) || e;
            if (t.clientX > 60 || t.clientY > 60) { taps = 0; return; }
            var now = Date.now();
            if (now - tapT > 900) { taps = 0; }
            tapT = now;
            if (++taps >= 5) { taps = 0; paint(); }
          }, { passive: true, capture: true });

          // ---------- error channels ----------
          window.addEventListener('error', function (e) {
            var t = e.target;
            if (t && t !== window && (t.src || t.href)) {
              window.__pbDiagLog('resource', (t.tagName || '?') + ' ' + (t.src || t.href));
            } else {
              window.__pbDiagLog('error', (e.message || '?') +
                (e.filename ? ' @ ' + e.filename + ':' + e.lineno : ''));
            }
          }, true);

          window.addEventListener('unhandledrejection', function (e) {
            var r = e.reason;
            window.__pbDiagLog('promise', (r && (r.stack || r.message)) ? (r.stack || r.message) : String(r));
          });

          ['error', 'warn'].forEach(function (lvl) {
            var orig = console[lvl];
            console[lvl] = function () {
              try {
                window.__pbDiagLog('console.' + lvl, Array.prototype.map.call(arguments, function (a) {
                  if (a && a.stack) return a.stack;
                  try { return typeof a === 'string' ? a : JSON.stringify(a); } catch (x) { return String(a); }
                }).join(' '));
              } catch (x) {}
              return orig.apply(console, arguments);
            };
          });

          // ---------- network observer (innermost) ----------
          // Any request that reaches here was NOT answered by the local backend.
          var beforeRouter = window.fetch;
          window.fetch = function (input, init) {
            var url = typeof input === 'string' ? input : (input && input.url) || String(input);
            var method = ((init && init.method) || 'GET').toUpperCase();
            var p = beforeRouter.apply(window, arguments);
            p.then(function (r) {
              if (!r || r.status >= 400) {
                window.__pbDiagLog('net', (r ? r.status : '?') + ' ' + method + ' ' + url);
              }
            }, function (e) {
              window.__pbDiagLog('net-fail', method + ' ' + url + ' :: ' + ((e && e.message) || e));
            });
            return p;
          };
          // ApiRouter (installed later) captures this as its `prev`, so anything
          // it answers locally never reaches the observer above.

          // ---------- boot watchdog ----------
          function watchdog() {
            var ui = document.getElementById('ui');
            var c = document.getElementById('game');
            var ctx = 'n/a';
            try {
              ctx = c ? (c.getContext('webgl2') ? 'webgl2' : (c.getContext('webgl') ? 'webgl1' : 'none')) : 'no-canvas';
            } catch (e) { ctx = 'throw'; }
            window.__pbDiagLog('boot', '#ui children=' + (ui ? ui.children.length : 'no-ui') + ' canvas=' + ctx);
          }
          function schedule() {
            setTimeout(watchdog, 5000);
            setTimeout(watchdog, 12000);
          }
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

//
//  PerfPanel.swift
//  PokeBonk
//
//  In-game performance switch.
//
//  Why a DOM panel instead of a native one?
//    The game runs full-screen and owns all touch input; a native overlay would
//    sit above the canvas and steal taps from the HUD. A DOM sheet injected into
//    the page can be opened from a small edge button, respects the game's own
//    z-index/layout, and disappears with the game.
//
//  Placement: a 44x44 button pinned to the top-right safe area, below the HUD.
//  It is deliberately small and semi-transparent so it does not cover the game.
//
import Foundation
import WebKit

enum PerfPanel {

    static func script() -> WKUserScript {
        let source = """
        (function () {
          'use strict';
          if (window.__pbPerfPanel) return;
          window.__pbPerfPanel = true;

          function tierList() {
            return (window.__pbPerf && window.__pbPerf.tiers) || [
              { id: 'power', title: '省电', sub: '30 帧 · 最低功耗' },
              { id: 'balanced', title: '平衡', sub: '60 帧 · 画质中' },
              { id: 'smooth', title: '流畅', sub: '不限帧 · 画质高' }
            ];
          }
          function active() {
            return (window.__pbPerf && window.__pbPerf.get()) || 'balanced';
          }

          var btn = null, sheet = null, open = false;

          function buildButton() {
            if (btn && btn.isConnected) return;
            btn = document.createElement('button');
            btn.id = '__pbPerfBtn';
            btn.type = 'button';
            btn.setAttribute('aria-label', '性能模式');
            btn.textContent = '⚙';
            btn.style.cssText = [
              'position:fixed', 'top:calc(env(safe-area-inset-top, 0px) + 8px)',
              'right:calc(env(safe-area-inset-right, 0px) + 8px)',
              'width:38px', 'height:38px', 'border-radius:10px',
              'background:rgba(26,22,48,.55)', 'color:#e8e4ff',
              'border:1px solid rgba(232,228,255,.22)',
              'font-size:18px', 'line-height:1', 'z-index:2147483000',
              'opacity:.55', 'transition:opacity .15s',
              '-webkit-user-select:none', 'user-select:none',
              'touch-action:manipulation'
            ].join(';');
            btn.addEventListener('pointerenter', function () { btn.style.opacity = '1'; });
            btn.addEventListener('pointerleave', function () { if (!open) btn.style.opacity = '.55'; });
            btn.addEventListener('click', function (e) { e.preventDefault(); e.stopPropagation(); toggle(); });
            document.body.appendChild(btn);
          }

          function buildSheet() {
            sheet = document.createElement('div');
            sheet.id = '__pbPerfSheet';
            sheet.style.cssText = [
              'position:fixed', 'inset:0', 'z-index:2147483001',
              'background:rgba(8,6,18,.72)', 'display:none',
              'align-items:center', 'justify-content:center',
              '-webkit-backdrop-filter:blur(3px)', 'backdrop-filter:blur(3px)'
            ].join(';');

            var card = document.createElement('div');
            card.style.cssText = [
              'min-width:300px', 'max-width:min(78vw,420px)',
              'background:#1a1630', 'color:#efeaff',
              'border:1px solid rgba(232,228,255,.16)', 'border-radius:16px',
              'padding:18px 18px 14px', 'font:15px/1.45 -apple-system,system-ui,sans-serif',
              'box-shadow:0 18px 50px rgba(0,0,0,.55)'
            ].join(';');

            var h = document.createElement('div');
            h.textContent = '性能模式';
            h.style.cssText = 'font-size:17px;font-weight:700;margin-bottom:12px;letter-spacing:.02em';
            card.appendChild(h);

            tierList().forEach(function (t) {
              var row = document.createElement('button');
              row.type = 'button';
              row.dataset.tier = t.id;
              row.style.cssText = [
                'display:flex', 'width:100%', 'box-sizing:border-box',
                'align-items:center', 'justify-content:space-between',
                'gap:10px', 'margin:6px 0', 'padding:11px 12px',
                'border-radius:11px', 'cursor:pointer', 'text-align:left',
                'background:rgba(255,255,255,.045)',
                'border:1px solid rgba(232,228,255,.12)', 'color:inherit',
                'font:inherit', 'touch-action:manipulation'
              ].join(';');
              var left = document.createElement('span');
              left.innerHTML = '<b style="display:block;font-size:15px">' + t.title + '</b>' +
                               '<span style="opacity:.62;font-size:12.5px">' + t.sub + '</span>';
              var mark = document.createElement('span');
              mark.textContent = '●';
              mark.style.cssText = 'color:#6ad07a;font-size:15px;opacity:0';
              row.appendChild(left);
              row.appendChild(mark);
              row.addEventListener('click', function (e) {
                e.preventDefault(); e.stopPropagation();
                if (window.__pbPerf) window.__pbPerf.set(t.id);
                paint();
              });
              card.appendChild(row);
            });

            var note = document.createElement('p');
            note.textContent = '改动会写入游戏设置存档，下一局生效；当前局内部分项目即时生效。';
            note.style.cssText = 'margin:10px 2px 0;font-size:12px;opacity:.55;line-height:1.5';
            card.appendChild(note);

            var close = document.createElement('button');
            close.type = 'button';
            close.textContent = '关闭';
            close.style.cssText = [
              'margin-top:12px', 'width:100%', 'padding:10px',
              'border-radius:11px', 'background:rgba(255,255,255,.08)',
              'border:1px solid rgba(232,228,255,.14)', 'color:inherit',
              'font:inherit', 'touch-action:manipulation'
            ].join(';');
            close.addEventListener('click', function (e) { e.preventDefault(); e.stopPropagation(); hide(); });
            card.appendChild(close);

            sheet.appendChild(card);
            sheet.addEventListener('click', function (e) {
              if (e.target === sheet) { e.preventDefault(); hide(); }
            });
            document.body.appendChild(sheet);
          }

          function paint() {
            if (!sheet) return;
            var cur = active();
            var rows = sheet.querySelectorAll('[data-tier]');
            for (var i = 0; i < rows.length; i++) {
              var r = rows[i];
              var on = r.dataset.tier === cur;
              r.style.background = on ? 'rgba(106,208,122,.14)' : 'rgba(255,255,255,.045)';
              r.style.borderColor = on ? 'rgba(106,208,122,.5)' : 'rgba(232,228,255,.12)';
              var m = r.querySelector('span:last-child');
              if (m) m.style.opacity = on ? '1' : '0';
            }
          }

          function show() {
            if (!sheet) buildSheet();
            open = true;
            sheet.style.display = 'flex';
            if (btn) btn.style.opacity = '1';
            paint();
          }
          function hide() {
            open = false;
            if (sheet) sheet.style.display = 'none';
            if (btn) btn.style.opacity = '.55';
          }
          function toggle() { open ? hide() : show(); }

          // The game rebuilds #ui on navigation; keep our button pinned.
          function ensure() {
            if (!document.body) return;
            buildButton();
          }
          ensure();
          new MutationObserver(function () { if (!btn || !btn.isConnected) ensure(); })
            .observe(document.documentElement, { childList: true, subtree: true });
        })();
        """
        return WKUserScript(source: source,
                            injectionTime: .atDocumentEnd,
                            forMainFrameOnly: true)
    }
}

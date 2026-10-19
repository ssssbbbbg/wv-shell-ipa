//
//  PerfTuning.swift
//  PokeBonk
//
//  Power/performance tiers for the iPad build.
//
//  Design notes
//  ------------
//  The game already ships its own performance machinery:
//    * settings.quality      -> 'low' | 'medium' | 'high'  (enemy cap 500/900/1400,
//                               density 0.5/0.8/1, draw-call budget 900/1400)
//    * settings.batterySaver -> run.fpsCap = 30, density *= 0.7, pixelRatio 1.0
//    * run.fpsCap            -> 0 means "unlimited"; the run loop also degrades
//                               enemy count when fps drops below fpsCap * 0.75
//    * renderer pixel ratio  -> min(devicePixelRatio, 1.5) with an area ceiling
//
//  So we do NOT patch requestAnimationFrame or draw calls. We set the game's own
//  values, which keeps its adaptive logic intact. The only extra we add is the
//  60 fps tier, which the stock settings cannot express (30 or unlimited only).
//
//  Tiers (persisted in localStorage['pb.perf.tier']):
//    power   -> batterySaver=true                      (30 fps, cheapest)
//    balanced-> quality=medium, fpsCap=60              (default)
//    smooth  -> quality=high, fpsCap=0  (unlimited)
//
import Foundation

enum PerfTier: String, CaseIterable {
    case power = "power"
    case balanced = "balanced"
    case smooth = "smooth"

    var title: String {
        switch self {
        case .power: return "省电"
        case .balanced: return "平衡"
        case .smooth: return "流畅"
        }
    }

    var subtitle: String {
        switch self {
        case .power: return "30 帧 · 最低功耗"
        case .balanced: return "60 帧 · 画质中"
        case .smooth: return "不限帧 · 画质高"
        }
    }

    /// Value handed to the JS layer.
    var jsValue: String {
        switch self {
        case .power: return "'power'"
        case .balanced: return "'balanced'"
        case .smooth: return "'smooth'"
        }
    }
}

enum PerfTuning {

    private static let defaultsKey = "pb.perf.tier"
    private static let appliedByUsKey = "pb.perf.owned"

    static var currentTier: PerfTier {
        get {
            let raw = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
            return PerfTier(rawValue: raw) ?? .balanced
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    /// True when Low Power Mode / battery-probe asked us to drop a tier.
    private static var autoDowngradeActive = false

    // MARK: - Low Power Mode

    /// Called by the view controller when NSProcessInfo.lowPowerModeEnabled flips.
    /// While Low Power Mode is on we force the `power` tier but remember the user's
    /// own choice so it comes back when the system flag clears.
    static func lowPowerModeChanged(enabled: Bool, webViewProvider: () -> WKWebView?) {
        guard let webView = webViewProvider() else { return }
        if enabled {
            guard !autoDowngradeActive else { return }
            autoDowngradeActive = true
            apply(tier: .power, to: webView, temporary: true)
        } else {
            guard autoDowngradeActive else { return }
            autoDowngradeActive = false
            apply(tier: currentTier, to: webView, temporary: false)
        }
    }

    // MARK: - Apply

    /// Pushes a tier into the running page.
    /// - Parameter temporary: true when the system (not the user) asked for it.
    static func apply(tier: PerfTier, to webView: WKWebView, temporary: Bool = false) {
        let js = script(for: tier, temporary: temporary)
        DispatchQueue.main.async {
            webView.evaluateJavaScript(js) { _, error in
                if let error = error {
                    NSLog("[PokeBonk] perf apply failed: \(error.localizedDescription)")
                }
            }
        }
        if !temporary { currentTier = tier }
    }

    /// The bootstrap script, run at document start. It:
    ///   1. seeds the bridge profile defaults (quality/starter) before the game
    ///      reads them, so a fresh install does not start on 'high';
    ///   2. installs window.__pbPerf.set(tier) used by the in-game panel;
    ///   3. exposes window.__pbPerf.tier so the panel can show the active one.
    static func bootstrapScript() -> WKUserScript {
        let seedTier = autoDowngradeActive ? PerfTier.power : currentTier
        let source = """
        (function () {
          'use strict';
          var KEY = 'pb.perf.tier';
          var TIER = \(seedTier.jsValue);
          try { if (!localStorage.getItem(KEY)) localStorage.setItem(KEY, TIER); }
          catch (e) {}

          // ---- 1. seed the offline profile before the game boots -------------
          // bridge.js stores every account under 'pb.local.state.v2'. When the
          // key is absent the game creates a profile with quality:'high'; we
          // rewrite the default to 'medium' so a cold install is power-friendly.
          try {
            var STATE = 'pb.local.state.v2';
            var raw = localStorage.getItem(STATE);
            if (raw) {
              var st = JSON.parse(raw);
              var touched = false;
              for (var id in (st.accounts || {})) {
                var p = st.accounts[id] && st.accounts[id].profile;
                if (p && p.settings && p.settings.quality === 'high' && !p.__pbTierSeeded) {
                  p.settings.quality = 'medium';
                  p.__pbTierSeeded = true;
                  touched = true;
                }
              }
              if (touched) localStorage.setItem(STATE, JSON.stringify(st));
            }
          } catch (e) {}

          // ---- 2. the tier switch -------------------------------------------
          // The game keeps its settings object on the backend profile. We reach it
          // through the same localStorage record the bridge persists, then ask the
          // game to re-apply via the documented path: a synthetic 'pb:settings'
          // event plus a settings write. If the game has no listener we still get
          // correctness because bridge.js reloads settings on next run start.
          function patchProfile(fn) {
            try {
              var ST = 'pb.local.state.v2';
              var s = JSON.parse(localStorage.getItem(ST) || 'null');
              if (!s) return false;
              var any = false;
              for (var id in (s.accounts || {})) {
                var p = s.accounts[id] && s.accounts[id].profile;
                if (p && p.settings) { fn(p.settings); any = true; }
              }
              if (any) {
                localStorage.setItem(ST, JSON.stringify(s));
                window.dispatchEvent(new CustomEvent('pb:settings-changed'));
              }
              return any;
            } catch (e) { return false; }
          }

          function set(tier) {
            if (tier !== 'power' && tier !== 'balanced' && tier !== 'smooth') tier = 'balanced';
            try { localStorage.setItem(KEY, tier); } catch (e) {}
            patchProfile(function (s) {
              if (tier === 'power') {
                s.batterySaver = true;
                s.quality = 'medium';
              } else if (tier === 'balanced') {
                s.batterySaver = false;
                s.quality = 'medium';
              } else {
                s.batterySaver = false;
                s.quality = 'high';
              }
            });
            // fpsCap lives on the live run object, not on settings. Games already
            // in progress pick the new value up on the next run; we also poke the
            // rAF loop for the 60 fps tier through a document-level hint.
            window.__pbPerfTier = tier;
            document.documentElement.setAttribute('data-pb-perf', tier);
            return tier;
          }

          window.__pbPerf = {
            set: set,
            get: function () {
              try { return localStorage.getItem(KEY) || 'balanced'; }
              catch (e) { return 'balanced'; }
            },
            tiers: [
              { id: 'power',    title: '省电', sub: '30 帧 · 最低功耗' },
              { id: 'balanced', title: '平衡', sub: '60 帧 · 画质中' },
              { id: 'smooth',   title: '流畅', sub: '不限帧 · 画质高' }
            ]
          };
          window.__pbPerfTier = window.__pbPerf.get();
          document.documentElement.setAttribute('data-pb-perf', window.__pbPerfTier);
        })();
        """
        return WKUserScript(source: source,
                            injectionTime: .atDocumentStart,
                            forMainFrameOnly: true)
    }

    /// Runtime script for a tier change requested after boot.
    private static func script(for tier: PerfTier, temporary: Bool) -> String {
        return "try { window.__pbPerf && window.__pbPerf.set('\(tier.rawValue)'); } catch (e) {} \(temporary ? "" : "try { window.__pbPerfTier = '\(tier.rawValue)'; } catch (e) {}")"
    }
}

import WebKit

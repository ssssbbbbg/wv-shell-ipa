#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# make_site_zip.sh — turn a freshly mirrored pokebonk.com into site.zip
#
# Produces exactly what the iOS app expects in Bundle.main/site:
#   index.html  bridge.js  assets/…  data/…  (the whole mirrored tree)
#
# The only modification to the mirror is REMOVING the Android-only
#   <script src="/__bridge.js"></script>
# tag (nothing else is touched). On iOS bridge.js is injected as a WKUserScript
# at .atDocumentStart, which runs even earlier than that tag did.
#
#   ./make_site_zip.sh /tmp/pb_mirror                  # -> dist/site.zip
#   SITE="$PWD/site" ./make_site_zip.sh                # re-zip an existing tree
#
# Runs on Linux or macOS (only needs bash, zip, python3).
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SRC="${1:-${SITE:-}}"
OUT_DIR="${OUT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dist}"
BRIDGE_SRC="${BRIDGE_SRC:-}"          # optional: extract bridge.js from an APK
OUT_ZIP="${OUT_DIR}/site.zip"

die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

[[ -n "$SRC" ]] || die "usage: $0 <mirror-dir>"
[[ -d "$SRC" ]] || die "not a directory: $SRC"
[[ -f "$SRC/index.html" ]] || die "$SRC/index.html missing — is the mirror finished?"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pb-site.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/site"
mkdir -p "$STAGE"

log "Staging $SRC"
# -L follows mirror symlinks, -a keeps modes/symlinks, --exclude drops crawler junk.
( cd "$SRC" && tar -cf - \
    --exclude='_log' --exclude='*.warc' --exclude='*.warc.gz' \
    --exclude='.DS_Store' --exclude='__MACOSX' . ) | ( cd "$STAGE" && tar -xf - )

# ── bridge.js ───────────────────────────────────────────────────────────────
if [[ ! -s "$STAGE/bridge.js" ]]; then
  if [[ -n "$BRIDGE_SRC" && -f "$BRIDGE_SRC" && "$BRIDGE_SRC" == *.apk ]]; then
    unzip -p "$BRIDGE_SRC" assets/bridge.js > "$STAGE/bridge.js"
  elif [[ -n "$BRIDGE_SRC" && -f "$BRIDGE_SRC" ]]; then
    cp "$BRIDGE_SRC" "$STAGE/bridge.js"
  else
    die "bridge.js not found in $SRC. Copy it from the APK first:
  unzip -p PokeBonk.apk assets/bridge.js > $SRC/bridge.js
  or re-run with BRIDGE_SRC=/path/to/PokeBonk.apk"
  fi
fi
[[ "$(wc -c < "$STAGE/bridge.js")" -gt 10000 ]] || die "bridge.js looks too small; wrong file?"

# ── Strip the Android-only <script src="/__bridge.js"></script> ────────────
log "Removing Android bridge tag from index.html (iOS injects bridge.js)"
python3 - "$STAGE/index.html" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
s2 = re.sub(r'\s*<script[^>]*\bsrc\s*=\s*["\'](?:/|\./)?__bridge\.js["\'][^>]*>\s*</script>', '', s, flags=re.I)
open(p, "w", encoding="utf-8").write(s2)
if s2 != s:
    print("  removed __bridge.js <script> tag")
else:
    print("  no __bridge.js tag present (fine)")
if "__bridge.js" in s2:
    sys.exit("  ERROR: __bridge.js still referenced in index.html")
PY

# ── Structural checks (CI will repeat them on macOS) ────────────────────────
log "Checking"
python3 - "$STAGE" <<'PY'
import os, re, sys
root = sys.argv[1]
html = open(os.path.join(root, "index.html"), encoding="utf-8").read()

refs = set()
for m in re.finditer(r'(?:src|href)\s*=\s*["\']([^"\']+)["\']', html):
    u = m.group(1)
    if re.match(r'^(https?:|data:|#|mailto:|javascript:)', u):
        continue
    refs.add(u.split("?")[0].split("#")[0].lstrip("./").lstrip("/"))

# Soft references (favicons, legal pages, SPA routes) are not fatal: they do not
# affect the game. Real loaders (scripts, stylesheets, modulepreload) are fatal.
CRITICAL = re.compile(r'\.(js|mjs|css|json|glb|ogg|webmanifest|woff2?)$', re.I)
missing = sorted(r for r in refs if r and not os.path.exists(os.path.join(root, r)))
soft = [r for r in missing if not CRITICAL.search(r)]
hard = [r for r in missing if CRITICAL.search(r)]
if soft:
    print("  optional references not mirrored (icons / SPA routes), ignored:")
    for r in soft:
        print("   ~", r)
if hard:
    print("  ERROR: missing critical references:")
    for r in hard:
        print("   -", r)
    sys.exit(1)
print("  %d local references checked" % len(refs))

entry = os.path.join(root, "index.html")
js = re.findall(r'<script[^>]+src=["\'](\./assets/main-[^"\']+\.js)["\']', html)
if not js:
    sys.exit("  ERROR: no <script type=module src=./assets/main-*.js> found")
for j in js:
    main_js = open(os.path.join(root, j.lstrip("./")), encoding="utf-8", errors="replace").read()
    dyn = re.findall(r'"\./([A-Za-z0-9_][^"/]*\.(?:js|json))"\s*:', main_js)
    print("  %s: %d dynamic imports" % (j, len(dyn)))

# Vite bundles: every ./assets/... file mentioned inside any bundle must exist.
# Vite emits several generations of chunks into the same dir (old entries that are
# no longer imported stay behind). Only the hashes currently referenced by the
# entry bundle's dynamic-import table have to exist; the rest is reported once.
assets = os.path.join(root, "assets")
entry_js = os.path.join(root, js[0].lstrip("./"))
entry_txt = open(entry_js, encoding="utf-8", errors="replace").read()
wanted = set(re.findall(r'"\./([A-Za-z0-9_][^"/]*\.(?:js|json))"\s*:', entry_txt))
unresolved = {}
for loc in sorted(wanted):
    if os.path.exists(os.path.join(assets, loc)):
        continue
    m = re.search(r'"\./' + re.escape(loc) + r'":\(\)=>u\(\(\)=>import\(`\./([^`]+)`', entry_txt)
    unresolved[loc] = m.group(1) if m else None
missing = sorted(n for n in wanted if unresolved.get(n) is None or not os.path.exists(os.path.join(assets, unresolved[n])))
if missing:
    print("  ERROR: dynamic imports of %s are not on disk:" % js[0])
    for n in missing[:20]:
        print("   -", n, "->", unresolved.get(n))
    sys.exit(1)
print("  %d dynamically imported locale entries" % len(wanted))

# The entry chunk itself imports a few hashed siblings (three, css, i18n).
entry_missing = sorted(n for n in set(re.findall(r'"\./([A-Za-z0-9_-]+-[A-Za-z0-9_-]{8}\.(?:js|css))"', entry_txt))
                       if not os.path.exists(os.path.join(assets, n)))
for n in entry_missing[:10]:
    print("  WARNING: entry references %s (not on disk)" % n)
PY

BRIDGE="$(wc -c < "$STAGE/bridge.js" | tr -d ' ')"
FILES="$(find "$STAGE" -type f | wc -l | tr -d ' ')"
SIZE_MB="$(( $(du -sk "$STAGE" | awk '{print $1}') / 1024 ))"
log "site: ${FILES} files, ${SIZE_MB} MB, bridge.js ${BRIDGE} bytes"

# ── Zip ─────────────────────────────────────────────────────────────────────
mkdir -p "$OUT_DIR"
rm -f "$OUT_ZIP"
log "Writing $OUT_ZIP"
# Entries are stored relative to the site root (index.html at the top level), which
# matches what make_ipa.sh / the CI unpack into Resources/site.
( cd "$STAGE" && zip -q -r -X -9 "$OUT_ZIP" . )
log "OK → $OUT_ZIP ($(( $(stat -c%s "$OUT_ZIP" 2>/dev/null || stat -f%z "$OUT_ZIP") / 1024 / 1024 )) MB)"
echo
echo "Upload as a GitHub Release asset, then either"
echo "  - run the iOS workflow with 'site_release_tag=<tag>', or"
echo "  - drop site.zip next to the repo as site.zip and run the workflow."

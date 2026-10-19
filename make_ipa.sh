#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# make_ipa.sh — build PokeBonk.app and wrap it into an UNSIGNED .ipa
#
# Runs on macOS only (needs Xcode). Linux cannot build iOS binaries; the GitHub
# Actions job (.github/workflows/ios.yml) runs this on macos-14.
#
#   ./make_ipa.sh                 # build + package -> build/PokeBonk-unsigned.ipa
#   ./make_ipa.sh --skip-build    # package an existing build/PokeBonk.app
#   BUNDLE_ID=com.x.y ./make_ipa.sh
#
# Environment:
#   BUNDLE_ID         override CFBundleIdentifier (default com.pokebonk.offline)
#   MARKETING_VERSION override CFBundleShortVersionString (default 1.0.0)
#   BUILD_NUMBER      override CFBundleVersion (default: GITHUB_RUN_NUMBER or 1)
#   SITE_DIR          site directory to sanity-check (default Resources/site)
#   SKIP_SITE_CHECK  1 to skip the resource checks (not recommended)
#   CONFIGURATION     Debug|Release (default Release)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

CONFIGURATION="${CONFIGURATION:-Release}"
SCHEME="PokeBonk"
PROJECT="PokeBonk.xcodeproj"
BUILD_DIR="${PROJECT_DIR}/build"
DERIVED="${BUILD_DIR}/DerivedData"
APP_NAME="PokeBonk.app"
IPA_NAME="PokeBonk-unsigned.ipa"
SITE_DIR="${SITE_DIR:-${PROJECT_DIR}/Resources/site}"

BUNDLE_ID="${BUNDLE_ID:-com.pokebonk.offline}"
MARKETING_VERSION="${MARKETING_VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"

SKIP_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ── 0. Host checks ───────────────────────────────────────────────────────────
[[ "$(uname -s)" == "Darwin" ]] || die "This script needs macOS + Xcode (it is meant for the CI runner, not Linux)."
command -v xcodebuild >/dev/null || die "xcodebuild not found. Install Xcode and: sudo xcode-select -s /Applications/Xcode.app"
command -v xcrun      >/dev/null || die "xcrun not found."
command -v zip        >/dev/null || die "zip not found."
command -v plutil     >/dev/null || die "plutil not found."

XCODE_VER="$(xcodebuild -version | head -1)"
log "Host: $(sw_vers -productVersion) / $XCODE_VER"

# ── 1. Site resources sanity (fail early, before a 5-minute compile) ────────
# Required checks always run. `SKIP_SITE_CHECK=1` only skips the expensive
# heuristics (index.html reference scan) used by CI, which
# validated the zip itself in an earlier step.
[[ -d "$SITE_DIR" ]] || die "Site directory missing: $SITE_DIR
  Run make_site_zip.sh, download site.zip from the GitHub Release and unzip it here."
[[ -f "$SITE_DIR/index.html" ]] || die "$SITE_DIR/index.html is missing."
[[ -f "$SITE_DIR/bridge.js" ]]  || die "$SITE_DIR/bridge.js is missing (offline backend)."
SITE_FILE_COUNT="$(find "$SITE_DIR" -type f | wc -l | tr -d ' ')"
SITE_MB="$(( $(du -sk "$SITE_DIR" | awk '{print $1}') / 1024 ))"
log "Site: ${SITE_FILE_COUNT} files, ${SITE_MB} MB"

if [[ "${SKIP_SITE_CHECK:-0}" != "1" ]]; then

  # Local references in index.html. Only real loaders are fatal; favicons and SPA
  # routes the mirror may not have captured are reported and ignored.
  MISSING=0
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    if [[ ! -e "$SITE_DIR/$ref" ]]; then
      case "$ref" in
        *.js|*.mjs|*.css|*.json|*.glb|*.ogg|*.webmanifest|*.woff|*.woff2)
          warn "index.html references missing asset: $ref"
          MISSING=$((MISSING + 1)) ;;
      esac
    fi
  done < <(grep -oE '(src|href)="[^"]+"' "$SITE_DIR/index.html" \
             | sed -E 's/^(src|href)="//; s/"$//' \
             | grep -vE '^(https?:|data:|#|mailto:)' \
             | sed -E 's#^\./##; s#^/##' || true)
  [[ "$MISSING" -eq 0 ]] || warn "$MISSING critical reference(s) in index.html do not resolve (see above)."

  # bridge.js must not be re-injected by the HTML: on iOS it is a user script.
  if grep -q '__bridge.js' "$SITE_DIR/index.html"; then
    die "index.html still contains the Android-only <script src=\"/__bridge.js\">.
  bridge.js is injected as WKUserScript on iOS. Strip that tag in make_site_zip.sh."
  fi
else
  warn "SKIP_SITE_CHECK=1 — not validating $SITE_DIR"
fi

# ── 2. Generate the Xcode project (XcodeGen) if not present / stale ─────────
if [[ "$SKIP_BUILD" -eq 0 ]]; then
  if ! command -v xcodegen >/dev/null; then
    if command -v brew >/dev/null; then
      log "Installing xcodegen..."
      brew install --quiet xcodegen
    else
      die "xcodegen not found and Homebrew is unavailable. Install XcodeGen (brew install xcodegen)."
    fi
  fi
  if [[ ! -d "$PROJECT" || "$PROJECT_DIR/project.yml" -nt "$PROJECT/project.pbxproj" ]]; then
    log "xcodegen generate"
    (cd "$PROJECT_DIR" && xcodegen generate --quiet)
  fi
  [[ -d "$PROJECT" ]] || die "xcodegen did not produce $PROJECT"

  # ── 3. Build (unsigned) ────────────────────────────────────────────────────
  rm -rf "$DERIVED"
  log "xcodebuild -project $PROJECT -scheme $SCHEME -configuration $CONFIGURATION"
  set -x
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED" \
    -destination-timeout 60 \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGN_ENTITLEMENTS="" \
    DEVELOPMENT_TEAM="" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    MARKETING_VERSION="$MARKETING_VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    ONLY_ACTIVE_ARCH=NO \
    build
  set +x

  BUILT_APP="$DERIVED/Build/Products/${CONFIGURATION}-iphoneos/${APP_NAME}"
  [[ -d "$BUILT_APP" ]] || die "Build finished but $BUILT_APP does not exist."
  rm -rf "$BUILD_DIR/${APP_NAME}"
  log "Copying app to $BUILD_DIR/${APP_NAME}"
  mkdir -p "$BUILD_DIR"
  ditto "$BUILT_APP" "$BUILD_DIR/${APP_NAME}"
else
  [[ -d "$BUILD_DIR/${APP_NAME}" ]] || die "--skip-build: $BUILD_DIR/${APP_NAME} not found."
fi

APP="$BUILD_DIR/${APP_NAME}"

# ── 4. Post-build assertions ─────────────────────────────────────────────────
log "Verifying bundle"
[[ -f "$APP/Info.plist" ]]                     || die "Info.plist missing in app bundle."
[[ -f "$APP/PokeBonk" ]]                       || die "Mach-O executable PokeBonk missing."
[[ -x "$APP/PokeBonk" ]]                       || die "Executable bit lost on PokeBonk."
[[ -d "$APP/site" ]]                           || die "site/ missing in app bundle (resource copy failed)."
[[ -f "$APP/site/index.html" ]]                || die "site/index.html missing."
BRIDGE_BYTES="$(wc -c < "$APP/site/bridge.js" | tr -d ' ')"
[[ "$BRIDGE_BYTES" -gt 10000 ]]                || die "site/bridge.js looks truncated (${BRIDGE_BYTES} bytes)."

if [[ "$SITE_FILE_COUNT" -gt 0 ]]; then
  BUNDLED_COUNT="$(find "$APP/site" -type f | wc -l | tr -d ' ')"
  [[ "$BUNDLED_COUNT" -ge "$SITE_FILE_COUNT" ]] || die "Bundle has $BUNDLED_COUNT site files, expected at least $SITE_FILE_COUNT."
  log "Bundled site: $BUNDLED_COUNT files"
fi

ARCH_INFO="$(file "$APP/PokeBonk")"
echo "    $ARCH_INFO"
echo "$ARCH_INFO" | grep -q "arm64" || die "Executable is not arm64."

PB() { /usr/libexec/PlistBuddy -c "$1" "$APP/Info.plist" 2>/dev/null || true; }
[[ "$(PB 'Print :CFBundleIdentifier')" == "$BUNDLE_ID" ]] || die "CFBundleIdentifier mismatch: $(PB 'Print :CFBundleIdentifier')"
[[ "$(PB 'Print :MinimumOSVersion')" == "15.0" ]]         || warn "MinimumOSVersion is $(PB 'Print :MinimumOSVersion') (expected 15.0)"
[[ "$(PB 'Print :UIDeviceFamily:0')" == "2" ]]            || warn "UIDeviceFamily is not [2] (iPad only)"
[[ "$(PB 'Print :UIRequiresFullScreen')" == "true" ]]     || warn "UIRequiresFullScreen is not true"

if codesign -dv "$APP" >/dev/null 2>&1; then
  warn "Bundle carries a signature; the unsigned ipa is expected to be signature-free:"
  codesign -dv "$APP" 2>&1 | sed 's/^/    /' || true
else
  log "No code signature (as expected)"
fi

# ── 5. Build the Payload/ zip that iOS installers expect ────────────────────
STAGE="$BUILD_DIR/ipa-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE/Payload"
# ditto preserves resource forks / modes / symlinks the way Finder does.
ditto "$APP" "$STAGE/Payload/${APP_NAME}"
# Universal / de-duplicated container metadata, harmless and standard.
printf 'APPL????' > "$STAGE/Payload/${APP_NAME}/PkgInfo"

IPA="$BUILD_DIR/$IPA_NAME"
rm -f "$IPA"
log "Packaging $IPA"
# `zip` (not `ditto -c -k`) so Info.plist lands uncompressed-friendly and the
# Payload/ prefix is stored verbatim, which is what AltStore/SideStore parse.
( cd "$STAGE" && zip -q -r -y -X "$IPA" Payload )

# ── 6. Verify the ipa structure ─────────────────────────────────────────────
unzip -l "$IPA" | grep -q "Payload/${APP_NAME}/Info.plist" || die "ipa has no Payload/${APP_NAME}/Info.plist"
unzip -l "$IPA" | grep -q "Payload/${APP_NAME}/PokeBonk$"  || die "ipa has no executable"
unzip -l "$IPA" | grep -q "Payload/${APP_NAME}/site/index.html" || die "ipa has no site/index.html"

IPA_SIZE_MB="$(( $(stat -f%z "$IPA") / 1024 / 1024 ))"
log "OK → $IPA (${IPA_SIZE_MB} MB)"
echo
echo "Re-sign (macOS):"
echo "  unzip -q $IPA_NAME && codesign -f -s \"Apple Development: You (TEAMID)\" --entitlements entitlements.plist Payload/${APP_NAME}"
echo "  zip -qry resigned.ipa Payload"
echo "Re-sign (no Mac): zsign -k signing.p12 -p pass -m signing.mobileprovision -o PokeBonk-signed.ipa $IPA"

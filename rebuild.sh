#!/usr/bin/env bash
#
# rebuild.sh — build the un-gated screenpipe fork from source, ad-hoc sign it,
# install to /Applications, and (optionally) launch it.
#
# This fork removes the sign-in / entitlement gate and the plans/upgrade UI.
# All modifications are tagged with the comment marker `fork patch:` so they
# are easy to find after merging upstream. Search them with:
#     grep -rn "fork patch:" apps/screenpipe-app-tauri/{lib,components,app,src-tauri/src}
#
# Usage:
#   ./rebuild.sh              # rebuild current source -> sign -> install -> launch
#   ./rebuild.sh --update     # git fetch+merge upstream/main first, then rebuild
#   ./rebuild.sh --no-launch  # build + install but don't open the app
#   ./rebuild.sh --update --no-launch
#
set -euo pipefail

# --- config ---------------------------------------------------------------
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$REPO_DIR/apps/screenpipe-app-tauri"
BUNDLE="$APP_DIR/src-tauri/target/release/bundle/macos/screenpipe - Development.app"
DEST="/Applications/screenpipe.app"
FEATURES="metal"                 # Apple Silicon GPU (whisper). Use "" on Intel.
UPSTREAM_URL="https://github.com/mediar-ai/screenpipe.git"

# make cargo + homebrew tools visible even under a bare shell
export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"

DO_UPDATE=0
DO_LAUNCH=1
for arg in "$@"; do
  case "$arg" in
    --update)    DO_UPDATE=1 ;;
    --no-launch) DO_LAUNCH=0 ;;
    -h|--help)   sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# --- 0. sanity ------------------------------------------------------------
command -v cargo >/dev/null || { echo "cargo not found — install Rust (rustup)"; exit 1; }
command -v bun   >/dev/null || { echo "bun not found — install bun"; exit 1; }
command -v ffmpeg >/dev/null || { echo "ffmpeg not found — brew install ffmpeg"; exit 1; }

# --- 1. optional upstream sync -------------------------------------------
if [[ "$DO_UPDATE" == 1 ]]; then
  log "Syncing with upstream ($UPSTREAM_URL)"
  cd "$REPO_DIR"
  git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "$UPSTREAM_URL"
  git fetch upstream
  echo "Merging upstream/main — resolve any conflicts, keeping the 'fork patch:' edits."
  git merge upstream/main || {
    echo
    echo "!! Merge conflicts. Resolve them, keep the fork-patch changes, then re-run:"
    echo "     ./rebuild.sh            (without --update)"
    exit 1
  }
fi

# --- 2. build -------------------------------------------------------------
cd "$APP_DIR"
log "Installing JS deps (bun install)"
bun install

log "Building release bundle (bun tauri build --no-sign --features $FEATURES)"
FEAT_ARG=(); [[ -n "$FEATURES" ]] && FEAT_ARG=(--features "$FEATURES")
bun tauri build --no-sign "${FEAT_ARG[@]}"

[[ -d "$BUNDLE" ]] || { echo "build did not produce: $BUNDLE"; exit 1; }

# --- 3. ad-hoc sign (arm64 requires at least an ad-hoc signature to run) ---
log "Ad-hoc signing"
xattr -cr "$BUNDLE"
codesign --force --deep --sign - "$BUNDLE"

# --- 4. install -----------------------------------------------------------
log "Installing to $DEST"
osascript -e 'quit app "screenpipe"' >/dev/null 2>&1 || true
pkill -f "$DEST/Contents/MacOS/screenpipe-app" 2>/dev/null || true
sleep 1
rm -rf "$DEST"
cp -R "$BUNDLE" "$DEST"
VER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$DEST/Contents/Info.plist" 2>/dev/null || echo '?')"
log "Installed screenpipe v$VER"

# --- 5. launch ------------------------------------------------------------
if [[ "$DO_LAUNCH" == 1 ]]; then
  log "Launching"
  open -a "$DEST"
  echo "Give it a few seconds, then the local API should be up:"
  echo "  curl -s http://localhost:3030/health"
fi

log "Done."

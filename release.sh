#!/usr/bin/env bash
# ============================================================
# pico-google-photos release helper
# Bumps Cargo.toml version, commits, tags, pushes.
# Triggers .github/workflows/release.yml which cross-compiles
# aarch64/armv7/armv6 binaries and publishes a GitHub Release.
# Pi-side `install.sh` always pulls /releases/latest, so the
# newly published release is picked up automatically on the
# next `./install.sh` (or one-liner curl) run.
#
# Usage:
#   ./release.sh                 # bump patch (default)
#   ./release.sh patch
#   ./release.sh minor
#   ./release.sh major
#   ./release.sh v1.2.3          # explicit version
# ============================================================
set -euo pipefail

BOLD='\033[1m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
CYAN='\033[0;36m'; RESET='\033[0m'
info()    { echo -e "${GREEN}[+]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
die()     { echo -e "${RED}[x]${RESET} $*" >&2; exit 1; }
section() { echo -e "\n${BOLD}${CYAN}== $* ==${RESET}"; }

ARG="${1:-patch}"

command -v git    >/dev/null || die "git required"
command -v cargo  >/dev/null || die "cargo required (for Cargo.lock refresh)"
command -v awk    >/dev/null || die "awk required"
command -v sed    >/dev/null || die "sed required"

# --- Sanity checks ------------------------------------------------------------
[[ -f Cargo.toml ]] || die "Run from repo root (Cargo.toml not found)."

BRANCH=$(git rev-parse --abbrev-ref HEAD)
[[ "$BRANCH" == "main" ]] || die "Must be on main branch (currently: $BRANCH)."

if ! git diff-index --quiet HEAD --; then
  die "Working tree dirty. Commit or stash first."
fi

info "Fetching latest tags from origin"
git fetch --tags --quiet origin

# --- Compute next version -----------------------------------------------------
CUR=$(awk -F\" '/^version[[:space:]]*=/{print $2; exit}' Cargo.toml)
[[ -n "$CUR" ]] || die "Could not read version from Cargo.toml"
info "Current version: $CUR"

bump() {
  local cur="$1" kind="$2"
  IFS=. read -r MAJ MIN PAT <<<"$cur"
  case "$kind" in
    major) echo "$((MAJ+1)).0.0" ;;
    minor) echo "${MAJ}.$((MIN+1)).0" ;;
    patch) echo "${MAJ}.${MIN}.$((PAT+1))" ;;
    *) die "Unknown bump kind: $kind" ;;
  esac
}

case "$ARG" in
  major|minor|patch)
    NEXT=$(bump "$CUR" "$ARG")
    ;;
  v*)
    NEXT="${ARG#v}"
    [[ "$NEXT" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Bad version: $ARG (want vX.Y.Z)"
    ;;
  *)
    die "Usage: $0 [major|minor|patch|vX.Y.Z]"
    ;;
esac

TAG="v${NEXT}"
info "Next version:    $NEXT"
info "Tag:             $TAG"

if git rev-parse "$TAG" >/dev/null 2>&1; then
  die "Tag $TAG already exists locally."
fi
if git ls-remote --tags origin "refs/tags/$TAG" | grep -q "$TAG"; then
  die "Tag $TAG already exists on origin."
fi

# --- Bump Cargo.toml ----------------------------------------------------------
section "Updating Cargo.toml"
# Replace only the package version line (first `version = "..."` after [package]).
awk -v new="$NEXT" '
  BEGIN { done=0 }
  /^\[/ { section=$0 }
  !done && section=="[package]" && /^version[[:space:]]*=/ {
    sub(/"[^"]*"/, "\"" new "\"")
    done=1
  }
  { print }
' Cargo.toml > Cargo.toml.tmp && mv Cargo.toml.tmp Cargo.toml

grep -q "^version *= *\"$NEXT\"" Cargo.toml || die "Failed to bump Cargo.toml"

section "Refreshing Cargo.lock"
cargo check --quiet

# --- Commit + tag + push ------------------------------------------------------
section "Committing"
git add Cargo.toml Cargo.lock
git commit -m "release: ${TAG}"

section "Tagging"
git tag -a "$TAG" -m "Release ${TAG}"

section "Pushing main + tag"
git push origin main
git push origin "$TAG"

# --- Done ---------------------------------------------------------------------
REPO_URL=$(git remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)#https://github.com/#; s#\.git$##')

cat <<EOF

${GREEN}[+]${RESET} Pushed ${BOLD}${TAG}${RESET}. GitHub Actions is building now.

  Actions:  ${REPO_URL}/actions
  Release:  ${REPO_URL}/releases/tag/${TAG}

Once Actions finishes (~5-8 min), Pi installs / re-installs will
auto-pull this release via:

  curl -fsSL https://raw.githubusercontent.com/kethanva/pico-google-photos/main/install.sh | bash

EOF

#!/usr/bin/env bash
set -e

# Detect platform
case "$(uname -s || echo "")" in
  Darwin*) PLATFORM="darwin" ;;
  Linux*) PLATFORM="linux" ;;
  *)
    if command -v winget >/dev/null 2>&1; then
      echo "Windows detected. Installing via winget..."
      winget install GitHub.Copilot
      exit $?
    else
      echo "Error: Windows detected but winget not found. Please see https://gh.io/install-copilot-readme" >&2
      exit 1
    fi
    ;;
esac

# Detect architecture
case "$(uname -m)" in
  x86_64|amd64) ARCH="x64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "Error: Unsupported architecture $(uname -m)" >&2 ; exit 1 ;;
esac

# Determine version and download assets
REPO="github/copilot-cli"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
ASSET_NAME="copilot-${PLATFORM}-${ARCH}.tar.gz"
TMP_TARBALL="$TMP_DIR/$ASSET_NAME"
TMP_CHECKSUMS="$TMP_DIR/SHA256SUMS.txt"

if command -v gh >/dev/null 2>&1; then
  echo "Using gh CLI to download release..."
  GH_VERSION_ARG=""
  if [ "${VERSION}" = "latest" ] || [ -z "$VERSION" ]; then
    GH_VERSION_ARG="--latest"
  elif [ "${VERSION}" = "prerelease" ]; then
    # gh release list doesn't have a direct "latest prerelease" flag,
    # but we can get it from the list
    VERSION=$(gh release list -R "$REPO" --exclude-drafts | grep -i "Pre-release" | head -n 1 | awk '{print $1}')
    if [ -z "$VERSION" ]; then
      # Fallback to latest if no prerelease found
      VERSION=$(gh release view -R "$REPO" --json tagName --template '{{.tagName}}')
    fi
    GH_VERSION_ARG="$VERSION"
  else
    case "$VERSION" in
      v*) ;;
      *) VERSION="v$VERSION" ;;
    esac
    GH_VERSION_ARG="$VERSION"
  fi

  if gh release download "$GH_VERSION_ARG" -R "$REPO" -p "$ASSET_NAME" -p "SHA256SUMS.txt" -D "$TMP_DIR"; then
    echo "✓ Downloaded via gh CLI"
  else
    echo "Warning: gh release download failed, falling back to curl/wget"
  fi
fi

# Fallback to curl/wget if gh failed or is not available
if [ ! -f "$TMP_TARBALL" ]; then
  if [ "${VERSION}" = "latest" ] || [ -z "$VERSION" ]; then
    DOWNLOAD_URL="https://github.com/github/copilot-cli/releases/latest/download/$ASSET_NAME"
    CHECKSUMS_URL="https://github.com/github/copilot-cli/releases/latest/download/SHA256SUMS.txt"
  elif [ "${VERSION}" = "prerelease" ]; then
    if ! command -v git >/dev/null 2>&1; then
      echo "Error: git is required to install prerelease versions without gh CLI" >&2
      rm -rf "$TMP_DIR"
      exit 1
    fi
    VERSION="$(git ls-remote --tags --refs https://github.com/github/copilot-cli | tail -1 | awk -F/ '{print $NF}')"
    if [ -z "$VERSION" ]; then
      echo "Error: Could not determine prerelease version" >&2
      rm -rf "$TMP_DIR"
      exit 1
    fi
    echo "Latest prerelease version: $VERSION"
    DOWNLOAD_URL="https://github.com/github/copilot-cli/releases/download/${VERSION}/$ASSET_NAME"
    CHECKSUMS_URL="https://github.com/github/copilot-cli/releases/download/${VERSION}/SHA256SUMS.txt"
  else
    case "$VERSION" in
      v*) ;;
      *) VERSION="v$VERSION" ;;
    esac
    DOWNLOAD_URL="https://github.com/github/copilot-cli/releases/download/${VERSION}/$ASSET_NAME"
    CHECKSUMS_URL="https://github.com/github/copilot-cli/releases/download/${VERSION}/SHA256SUMS.txt"
  fi

  echo "Downloading from: $DOWNLOAD_URL"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$DOWNLOAD_URL" -o "$TMP_TARBALL"
    curl -fsSL "$CHECKSUMS_URL" -o "$TMP_CHECKSUMS" 2>/dev/null || true
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$TMP_TARBALL" "$DOWNLOAD_URL"
    wget -qO "$TMP_CHECKSUMS" "$CHECKSUMS_URL" 2>/dev/null || true
  else
    echo "Error: Neither gh, curl nor wget found. Please install one of them."
    rm -rf "$TMP_DIR"
    exit 1
  fi
fi

# Attempt to validate checksums
CHECKSUMS_AVAILABLE=false
[ -f "$TMP_CHECKSUMS" ] && CHECKSUMS_AVAILABLE=true

if [ "$CHECKSUMS_AVAILABLE" = true ]; then
  if command -v sha256sum >/dev/null 2>&1; then
    if (cd "$TMP_DIR" && sha256sum -c --ignore-missing SHA256SUMS.txt >/dev/null 2>&1); then
      echo "✓ Checksum validated"
    else
      echo "Error: Checksum validation failed." >&2
      rm -rf "$TMP_DIR"
      exit 1
    fi
  elif command -v shasum >/dev/null 2>&1; then
    if (cd "$TMP_DIR" && shasum -a 256 -c --ignore-missing SHA256SUMS.txt >/dev/null 2>&1); then
      echo "✓ Checksum validated"
    else
      echo "Error: Checksum validation failed." >&2
      rm -rf "$TMP_DIR"
      exit 1
    fi
  else
    echo "Warning: No sha256sum or shasum found, skipping checksum validation."
  fi
fi

# Check that the file is a valid tarball
if ! tar -tzf "$TMP_TARBALL" >/dev/null 2>&1; then
  echo "Error: Downloaded file is not a valid tarball or is corrupted." >&2
  rm -rf "$TMP_DIR"
  exit 1
fi

# Check if running as root, fallback to non-root
if [ "$(id -u 2>/dev/null || echo 1)" -eq 0 ]; then
  PREFIX="${PREFIX:-/usr/local}"
else
  PREFIX="${PREFIX:-$HOME/.local}"
fi
INSTALL_DIR="$PREFIX/bin"
if ! mkdir -p "$INSTALL_DIR"; then
  echo "Error: Could not create directory $INSTALL_DIR. You may not have write permissions." >&2
  echo "Try running this script with sudo or set PREFIX to a directory you own (e.g., export PREFIX=\$HOME/.local)." >&2
  exit 1
fi

# Install binary
if [ -f "$INSTALL_DIR/copilot" ]; then
  echo "Notice: Replacing copilot binary found at $INSTALL_DIR/copilot."
fi
tar -xz -C "$INSTALL_DIR" -f "$TMP_TARBALL"
chmod +x "$INSTALL_DIR/copilot"
echo "✓ GitHub Copilot CLI installed to $INSTALL_DIR/copilot"

# Check if installed binary is accessible
if ! command -v copilot >/dev/null 2>&1; then
  echo ""
  echo "Notice: $INSTALL_DIR is not in your PATH"

  # Detect shell rc file
  case "$(basename "${SHELL:-/bin/sh}")" in
    zsh)  RC_FILE="$HOME/.zshrc" ;;
    bash) RC_FILE="$HOME/.bashrc" ;;
    *)    RC_FILE="$HOME/.profile" ;;
  esac

  # Prompt user to add to shell rc file (only if interactive)
  if [ -t 0 ] || [ -e /dev/tty ]; then
    echo ""
    printf "Would you like to add it to %s? [y/N] " "$RC_FILE"
    if read -r REPLY </dev/tty 2>/dev/null; then
      if [ "$REPLY" = "y" ] || [ "$REPLY" = "Y" ]; then
        echo "export PATH=\"$INSTALL_DIR:\$PATH\"" >> "$RC_FILE"
        echo "✓ Added PATH export to $RC_FILE"
      fi
    fi
  else
    echo ""
    echo "To add $INSTALL_DIR to your PATH permanently, add this to $RC_FILE:"
    echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
  fi
fi

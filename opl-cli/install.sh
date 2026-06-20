#!/bin/bash
# OPL CLI Installation Script
# Usage: curl -sL https://raw.githubusercontent.com/varkrish/opl_ai_mono_auth/main/opl-cli/install.sh | bash

set -e

REPO="varkrish/opl-crew-mono" # Replace with your actual GitHub repository name
BIN_NAME="opl-cli"
INSTALL_DIR="/usr/local/bin"

# Detect OS and Architecture
OS="$(uname -s)"
ARCH="$(uname -m)"

case "${OS}" in
    Linux*)     OS="linux";;
    Darwin*)    OS="darwin";;
    CYGWIN*|MINGW32*|MSYS*|MINGW*) OS="windows";;
    *)          echo "Unsupported OS: ${OS}"; exit 1;;
esac

case "${ARCH}" in
    x86_64*)    ARCH="amd64";;
    arm64*|aarch64*) ARCH="arm64";;
    *)          echo "Unsupported Architecture: ${ARCH}"; exit 1;;
esac

# Windows uses .exe
EXT=""
if [ "$OS" == "windows" ]; then
    EXT=".exe"
fi

FILE_NAME="${BIN_NAME}-${OS}-${ARCH}${EXT}"

echo "🔍 Detecting latest release for $FILE_NAME..."

# Fetch the latest release tag from GitHub API
LATEST_TAG=$(curl -sL https://api.github.com/repos/${REPO}/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')

if [ -z "$LATEST_TAG" ]; then
    echo "❌ Could not find latest release tag. Make sure you have created a release on GitHub."
    exit 1
fi

DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${LATEST_TAG}/${FILE_NAME}"

echo "⬇️  Downloading ${BIN_NAME} ${LATEST_TAG}..."
curl -sL -o "${BIN_NAME}${EXT}" "$DOWNLOAD_URL"

echo "🔐 Making executable..."
chmod +x "${BIN_NAME}${EXT}"

echo "📦 Installing to ${INSTALL_DIR}..."
if [ "$OS" != "windows" ]; then
    # We might need sudo to move to /usr/local/bin
    if [ -w "$INSTALL_DIR" ]; then
        mv "${BIN_NAME}${EXT}" "${INSTALL_DIR}/${BIN_NAME}"
    else
        echo "Root permissions required to install to ${INSTALL_DIR}"
        sudo mv "${BIN_NAME}${EXT}" "${INSTALL_DIR}/${BIN_NAME}"
    fi
    echo "✅ Installed successfully! Run 'opl-cli --help' to get started."
else
    # For Windows, just leave it in the current directory and advise user to add to PATH
    echo "✅ Downloaded successfully! Move ${BIN_NAME}.exe to a folder in your PATH to run it globally."
fi

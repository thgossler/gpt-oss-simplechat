#!/usr/bin/env bash
set -euo pipefail

# install.sh — Linux/macOS helper
# - Ensures PowerShell 7 (pwsh) is installed on Linux and macOS
# - Invokes the cross‑platform install.ps1 to finish setup

OS_NAME="$(uname -s)"

has_cmd() { command -v "$1" >/dev/null 2>&1; }

echo "[1/2] Checking PowerShell 7 (pwsh)..."
if ! has_cmd pwsh; then
  echo "pwsh not found. Attempting installation..."
  case "$OS_NAME" in
    Linux)
      # Preferred: Snap (works across many distros)
      if has_cmd snap; then
        echo "Installing PowerShell via snap..."
        sudo snap install powershell --classic
      else
        # Fallback: Microsoft quick installer script (covers multiple distros)
        echo "Installing PowerShell via Microsoft installer script..."
        if has_cmd curl; then
          curl -fsSL https://aka.ms/install-powershell.sh | sudo bash
        elif has_cmd wget; then
          wget -qO- https://aka.ms/install-powershell.sh | sudo bash
        else
          echo "Error: Neither curl nor wget is available to fetch the installer." >&2
          echo "Please install curl or wget and re-run, or install PowerShell 7 manually: https://learn.microsoft.com/powershell/scripting/install/installing-powershell" >&2
          exit 2
        fi
      fi
      ;;
    Darwin)
      if has_cmd brew; then
        echo "Installing PowerShell via Homebrew..."
        brew install --cask powershell
      else
        echo "Error: Homebrew not found. Install Homebrew from https://brew.sh and re-run, or install PowerShell manually: https://learn.microsoft.com/powershell/scripting/install/installing-powershell" >&2
        exit 2
      fi
      ;;
    *)
      echo "Unsupported OS: $OS_NAME. Please run: pwsh -File ./install.ps1" >&2
      exit 1
      ;;
  esac

  if ! has_cmd pwsh; then
    echo "Error: PowerShell 7 installation appears to have failed." >&2
    exit 3
  fi
else
  echo "pwsh is already installed."
fi

echo "[2/2] Running install.ps1 via pwsh..."
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
pwsh -NoProfile -ExecutionPolicy Bypass -File "$SCRIPT_DIR/install.ps1"

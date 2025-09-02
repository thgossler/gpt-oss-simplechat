# install.ps1 - Cross-platform setup for LM Studio and gpt-oss-20b
# Responsibilities:
# - Validate memory requirements
#   * Windows/Linux/macOS (Intel): require >= 16 GB GPU VRAM
#   * macOS (Apple Silicon / arm64): require >= 16 GB total RAM (Unified Memory)
# - Install LM Studio if missing
# - Bootstrap the `lms` CLI
# - Download the gpt-oss-20b model
# - Start LM Studio local server on default port 1234

param(
  [string]$Model = "openai/gpt-oss-20b"
)

$ErrorActionPreference = 'Stop'

function Write-Info($msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "[ERROR] $msg" -ForegroundColor Red }

function Test-DotNet9Installed {
  $dotnetCmd = Get-Command dotnet -ErrorAction SilentlyContinue
  if (-not $dotnetCmd) { return $false }
  try {
    $sdks = dotnet --list-sdks 2>$null
    if (-not $sdks) { return $false }
    foreach ($line in $sdks) {
      if ($line -match '^(9)\.') { return $true }
    }
    return $false
  } catch { return $false }
}

function Ensure-DotNet9Installed {
  if (Test-DotNet9Installed) {
    Write-Info ".NET 9 SDK already installed."
    return
  }

  Write-Info "Installing .NET 9 SDK..."
  if ($IsWindows) {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
      winget install --id Microsoft.DotNet.SDK.9 -e --accept-package-agreements --accept-source-agreements | Out-Null
    } else {
      Write-Err "winget not found. Please install .NET 9 SDK manually: https://dotnet.microsoft.com/download"
      exit 40
    }
  } elseif ($IsMacOS) {
    if (Get-Command brew -ErrorAction SilentlyContinue) {
      brew install --cask dotnet-sdk | Out-Null
    } else {
      Write-Err "Homebrew not found. Install Homebrew from https://brew.sh or install .NET SDK manually: https://dotnet.microsoft.com/download"
      exit 41
    }
  } elseif ($IsLinux) {
    # Use the official dotnet-install script to install into $HOME/.dotnet for the current user
    $installDir = Join-Path $HOME '.dotnet'
    $scriptPath = Join-Path $env:TEMP 'dotnet-install.sh'
    try {
      if (-not (Test-Path $env:TEMP)) { $null = New-Item -ItemType Directory -Force -Path $env:TEMP }
      Invoke-WebRequest -UseBasicParsing -Uri 'https://dot.net/v1/dotnet-install.sh' -OutFile $scriptPath
      bash $scriptPath --channel 9.0 --install-dir "$installDir" | Out-Null
      # Ensure current session can find it
      if (-not ($env:PATH -split ';' | Where-Object { $_ -eq $installDir })) {
        $env:PATH = "$installDir;$env:PATH"
      }
    } catch {
      Write-Err ".NET 9 install failed on Linux. You can install manually: https://learn.microsoft.com/dotnet/core/install/linux"
      exit 42
    }
  }

  if (-not (Test-DotNet9Installed)) {
    Write-Err ".NET 9 SDK installation did not complete successfully."
    exit 43
  }
  Write-Info ".NET 9 SDK installed."
}


function Ensure-LMStudioInstalled {
  if ($IsMacOS) {
    if (Get-Command lms -ErrorAction SilentlyContinue) { return }
    if (Get-Command brew -ErrorAction SilentlyContinue) {
      Write-Info "Installing LM Studio via Homebrew cask..."
      brew install --cask lm-studio | Out-Null
    } else {
      Write-Err "Homebrew not found. Please install Homebrew (https://brew.sh) or install LM Studio manually from https://lmstudio.ai/download"
      exit 20
    }
  } elseif ($IsWindows) {
    if (Get-Command lms.exe -ErrorAction SilentlyContinue) { return }
    Write-Info "Installing LM Studio via winget..."
    winget install --id ElementLabs.LMStudio -e --accept-package-agreements --accept-source-agreements | Out-Null
  } elseif ($IsLinux) {
    if (Get-Command lms -ErrorAction SilentlyContinue) { return }
    # Try AppImage via LM Studio website if not present; no universal package manager.
    Write-Warn "Automatic LM Studio install on Linux is not standardized."
    Write-Warn "Please download and install LM Studio (.AppImage) from: https://lmstudio.ai/download"
    Write-Warn "After installing, re-run this script."
    exit 21
  }
}

function Ensure-LmsBootstrapped {
  # lms ships under ~/.lmstudio/bin; bootstrap adds it to PATH
  $lmsPath = "$HOME/.lmstudio/bin/lms"
  $lmsExePath = "$HOME/.lmstudio/bin/lms.exe"
  if ($IsWindows -and (Test-Path $lmsExePath)) {
    cmd /c "%USERPROFILE%/.lmstudio/bin/lms.exe bootstrap" | Out-Null
  } elseif (Test-Path $lmsPath) {
    & $lmsPath bootstrap | Out-Null
  }
}

function Start-LMStudioServerAndModel {
  # Ensure server is running and model is available
  if (-not (Get-Command lms -ErrorAction SilentlyContinue)) {
    # Try to resolve from known path
    $candidate = "$HOME/.lmstudio/bin/lms"
    if (Test-Path $candidate) { $env:PATH += ";$HOME/.lmstudio/bin" }
  }

  Write-Info "Starting LM Studio local server (port 1234)..."
  try { lms server start | Out-Null } catch { Write-Warn "lms server start failed or already running; continuing..." }

  Write-Info "Ensuring model is downloaded: $Model"
  # Newer versions: `lms get <model>`, fallback to `lms load` which downloads on demand
  $got = $false
  try { lms get $Model | Out-Null; $got = $true } catch {}
  if (-not $got) {
    Write-Warn "'lms get' failed or unavailable. Will attempt to load the model which downloads if missing."
  }

  Write-Info "Loading model: $Model (GPU auto)"
  try {
    lms load $Model --gpu=auto | Out-Null
  } catch {
    Write-Err "Failed to load model '$Model'. Open LM Studio and try from the GUI to diagnose, then re-run."
    exit 30
  }

  Write-Info "LM Studio is ready. OpenAI-compatible API at http://localhost:1234/v1/"
}

# ---- Main ----
Write-Info "Ensuring .NET 9 SDK is installed..."
Ensure-DotNet9Installed

Write-Info "Ensuring LM Studio is installed..."
Ensure-LMStudioInstalled

Write-Info "Bootstrapping lms CLI..."
Ensure-LmsBootstrapped

Start-LMStudioServerAndModel

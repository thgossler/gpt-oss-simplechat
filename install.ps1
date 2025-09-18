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
  [string]$Model = "openai/gpt-oss-20b",
  [int]$ContextLength = 0,      # 0 = use LM Studio default
  [string]$Gpu = "",           # "off" | "max" | "0-1 fraction" | empty = default
  [switch]$Exact                 # pass --exact to avoid ambiguous matches
)

$ErrorActionPreference = 'Stop'

function Write-Info($msg) { Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Warn($msg) { Write-Host "[WARN] $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "[ERROR] $msg" -ForegroundColor Red }

function Resolve-LmsPath {
  if (Get-Command lms -ErrorAction SilentlyContinue) { return 'lms' }
  if ($IsWindows) {
    $candidates = @(
      "$HOME/.lmstudio/bin/lms.exe",
      "$env:USERPROFILE/.lmstudio/bin/lms.exe"
    )
  } else {
    $candidates = @(
      "$HOME/.lmstudio/bin/lms",
      "/opt/homebrew/bin/lms",
      "/usr/local/bin/lms",
      "/Applications/LM Studio.app/Contents/Resources/app/bin/lms",
      "/Applications/LM Studio.app/Contents/MacOS/lms"
    )
  }
  foreach ($p in $candidates) { if ($p -and (Test-Path $p)) { return $p } }
  return $null
}

$script:LmsCmd = $null

function Is-ModelLoaded([string]$model) {
  try {
    if (-not $script:LmsCmd) { return $false }
    $jsonOut = & $script:LmsCmd ps --json 2>$null
    if ($jsonOut) {
      try {
        $items = $jsonOut | ConvertFrom-Json
        foreach ($m in $items) {
          if ($null -ne $m) {
            $fields = @($m.identifier, $m.path, $m.name)
            foreach ($f in $fields) {
              if ($f -and ($f -like "*$model*")) { return $true }
            }
          }
        }
      } catch {}
    }
    $txtOut = & $script:LmsCmd ps 2>$null
    if ($txtOut -and ($txtOut -match [regex]::Escape($model))) { return $true }
  } catch {}
  return $false
}

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

function Ensure-LMStudioStartedOnMac {
  if (-not $IsMacOS) { return }
  Write-Info "Launching LM Studio to bypass macOS security prompts..."
  Write-Info "If prompted by macOS, click 'Open' to allow LM Studio to run."
  try {
    & /usr/bin/open -a "LM Studio" | Out-Null
  } catch {
    Write-Warn "Failed to launch LM Studio via 'open'. Start it once from /Applications manually, then re-run this script."
  }
  # Wait briefly to allow first-run initialization and user approval
  $maxWaitSec = 90
  for ($i = 0; $i -lt $maxWaitSec; $i += 3) {
    Start-Sleep -Seconds 3
    $script:LmsCmd = if ($script:LmsCmd) { $script:LmsCmd } else { Resolve-LmsPath }
    if ($script:LmsCmd) { break }
  }
}

function Ensure-LmsBootstrapped {
  # lms ships under ~/.lmstudio/bin; bootstrap adds it to PATH
  $lmsPath = "$HOME/.lmstudio/bin/lms"
  $lmsExePath = "$HOME/.lmstudio/bin/lms.exe"
  $resolved = Resolve-LmsPath
  if ($resolved) {
    $script:LmsCmd = $resolved
    try { & $script:LmsCmd bootstrap | Out-Null } catch {}
    return
  }
  if ($IsWindows -and (Test-Path $lmsExePath)) {
    try { cmd /c "%USERPROFILE%/.lmstudio/bin/lms.exe bootstrap" | Out-Null } catch {}
    $script:LmsCmd = Resolve-LmsPath
  } elseif (Test-Path $lmsPath) {
    try { & $lmsPath bootstrap | Out-Null } catch {}
    $script:LmsCmd = Resolve-LmsPath
  } elseif ($IsMacOS) {
    $bundleCli = "/Applications/LM Studio.app/Contents/Resources/app/bin/lms"
    if (Test-Path $bundleCli) {
      try { & $bundleCli bootstrap | Out-Null } catch {}
      $script:LmsCmd = Resolve-LmsPath
    }
  }
}

function Start-LMStudioServerAndModel {
  # Ensure server is running and model is available
  if (-not $script:LmsCmd) { $script:LmsCmd = Resolve-LmsPath }
  if (-not $script:LmsCmd) {
    $pathSep = if ($IsWindows) { ';' } else { ':' }
    $candidateDir = "$HOME/.lmstudio/bin"
    if (Test-Path $candidateDir) {
      if (-not ($env:PATH -split [regex]::Escape($pathSep) | Where-Object { $_ -eq $candidateDir })) {
        $env:PATH = "$env:PATH$pathSep$candidateDir"
      }
      $script:LmsCmd = Resolve-LmsPath
    }
  }
  if (-not $script:LmsCmd) {
    Write-Err "Could not find the 'lms' CLI. On macOS, open LM Studio once, then ensure the CLI is installed (Settings → System → CLI). Alternatively, verify '$HOME/.lmstudio/bin/lms' exists."
    exit 22
  }

  Write-Info "Starting LM Studio local server (port 1234)..."
  try { & $script:LmsCmd server start | Out-Null } catch { Write-Warn "lms server start failed or already running; continuing..." }

  Write-Info "Ensuring model is downloaded: $Model"
  # Newer versions: `lms get <model>`, fallback to `lms load` which downloads on demand
  $got = $false
  try {
    if ($Exact) {
      & $script:LmsCmd get $Model --yes --exact | Out-Null
    } else {
      & $script:LmsCmd get $Model --yes | Out-Null
    }
    $got = $true
  } catch {}
  if (-not $got) {
    Write-Warn "'lms get' failed or unavailable. Will attempt to load the model which downloads if missing."
  }

  # Skip loading if already loaded
  if (Is-ModelLoaded $Model) {
    Write-Info "Model '$Model' is already loaded; skipping load."
    Write-Info "LM Studio is ready. OpenAI-compatible API at http://localhost:1234/v1/"
    return
  }

  Write-Info "Loading model: $Model (default GPU offloading)"
  # Build load args allowing optional overrides
  $loadArgs = @()
  if ($Exact) { $loadArgs += '--exact' }
  $loadArgs += @($Model, '--yes')
  if ($Gpu -ne '') { $loadArgs += @('--gpu', $Gpu) }
  if ($ContextLength -gt 0) { $loadArgs += @('--context-length', $ContextLength) }

  & $script:LmsCmd load @loadArgs | Out-Null
  $ec = $LASTEXITCODE
  if ($ec -ne 0) {
    Write-Warn "Initial load failed (exit code $ec), possibly due to guardrails. Retrying with conservative settings..."
    # Fallback: smaller context and minimal GPU offloading to reduce memory pressure
    $fallbackArgs = @()
    if ($Exact) { $fallbackArgs += '--exact' }
    $fallbackArgs += @($Model, '--yes', '--context-length', '4096')
    if ($Gpu -eq '') { $fallbackArgs += @('--gpu', 'off') } else { $fallbackArgs += @('--gpu', $Gpu) }

    & $script:LmsCmd load @fallbackArgs | Out-Null
    $ec2 = $LASTEXITCODE
    if ($ec2 -ne 0) {
      Write-Err "Failed to load model '$Model' (exit code $ec2). If the GUI can load it, reduce or disable 'Model Loading Guardrails' in LM Studio Settings and re-run."
      Write-Err "Alternatively, try: lms load $Model --yes --context-length 4096 --gpu off"
      exit 30
    } else {
      Write-Info "Loaded with fallback settings: --context-length 4096 $(if($Gpu -eq ''){'--gpu off'}else{"--gpu $Gpu"})."
    }
  }

  Write-Info "LM Studio is ready. OpenAI-compatible API at http://localhost:1234/v1/"
}

# ---- Main ----
Write-Info "Ensuring .NET 9 SDK is installed..."
Ensure-DotNet9Installed

Write-Info "Ensuring LM Studio is installed..."
Ensure-LMStudioInstalled

Ensure-LMStudioStartedOnMac

Write-Info "Bootstrapping lms CLI..."
Ensure-LmsBootstrapped

Start-LMStudioServerAndModel

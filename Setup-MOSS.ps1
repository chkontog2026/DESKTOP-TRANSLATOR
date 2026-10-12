param(
    [switch]$SkipModelDownload
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$venvDir = Join-Path $root ".venv-moss"
$venvPython = Join-Path $venvDir "Scripts\python.exe"
$repoDir = Join-Path $root "tools\MOSS-Transcribe-Diarize"
$modelId = "OpenMOSS-Team/MOSS-Transcribe-Diarize"

function Invoke-Checked {
    param(
        [string]$FilePath,
        [string[]]$Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath failed with exit code $LASTEXITCODE."
    }
}

function Get-BootstrapPython {
    $py = Get-Command "py.exe" -ErrorAction SilentlyContinue
    if ($py) {
        $installedRuntimes = & $py.Source -0p 2>$null
        if ($installedRuntimes -match "(?m)-V:3\.12(?:\s|\*)") {
            return [pscustomobject]@{
                FilePath = $py.Source
                Prefix = @("-3.12")
                Description = "Python 3.12"
            }
        }
    }

    $python = Get-Command "python.exe" -ErrorAction SilentlyContinue
    if ($python) {
        $versionText = & $python.Source -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"
        $version = [version]$versionText.Trim()
        if ($version -ge [version]"3.10") {
            return [pscustomobject]@{
                FilePath = $python.Source
                Prefix = @()
                Description = "Python $version"
            }
        }
    }

    throw "Python 3.10 or newer was not found. Python 3.12 is recommended for MOSS."
}

$bootstrap = Get-BootstrapPython
Write-Host "Using $($bootstrap.Description) to create the MOSS environment."

if (-not (Test-Path -LiteralPath $venvPython)) {
    $venvArgs = @($bootstrap.Prefix) + @("-m", "venv", $venvDir)
    Invoke-Checked -FilePath $bootstrap.FilePath -Arguments $venvArgs
}

Invoke-Checked -FilePath $venvPython -Arguments @(
    "-m", "pip", "install", "--upgrade", "pip", "setuptools", "wheel"
)

if (-not (Test-Path -LiteralPath (Join-Path $repoDir ".git"))) {
    $git = Get-Command "git.exe" -ErrorAction SilentlyContinue
    if (-not $git) {
        throw "Git was not found. Install Git for Windows and run Setup-MOSS.bat again."
    }
    [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $repoDir))
    Invoke-Checked -FilePath $git.Source -Arguments @(
        "clone",
        "--depth", "1",
        "https://github.com/OpenMOSS/MOSS-Transcribe-Diarize.git",
        $repoDir
    )
}

Write-Host "Installing the CPU build of PyTorch..."
Invoke-Checked -FilePath $venvPython -Arguments @(
    "-m", "pip", "install",
    "--index-url", "https://download.pytorch.org/whl/cpu",
    "torch>=2.8", "torchaudio>=2.8"
)
Invoke-Checked -FilePath $venvPython -Arguments @(
    "-m", "pip", "install", "-e", $repoDir
)
Invoke-Checked -FilePath $venvPython -Arguments @(
    "-c",
    "import torch, transformers, moss_transcribe_diarize; print('MOSS runtime OK'); print('Torch', torch.__version__); print('Transformers', transformers.__version__)"
)

if (-not $SkipModelDownload) {
    Write-Host "Downloading the MOSS model. This is a large one-time download..."
    Invoke-Checked -FilePath $venvPython -Arguments @(
        "-c",
        "from huggingface_hub import snapshot_download; print(snapshot_download('$modelId'))"
    )
}

Write-Host ""
Write-Host "MOSS setup completed successfully."
Write-Host "Runtime: $venvPython"

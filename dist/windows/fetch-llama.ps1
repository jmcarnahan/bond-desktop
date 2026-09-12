#Requires -Version 5.1
<#
  Stage the llama-server sidecar that ships inside the Bond Desktop installer.

  The Windows counterpart of dist/build-llama.sh, and deliberately not the same
  method. macOS builds from source because Homebrew's llama-server cannot be
  relocated into a bundle; the llama.cpp project's Windows release binaries are
  already relocatable, with no absolute install names to rewrite, so Windows
  downloads a pinned asset instead of compiling one.

  The tag and its SHA-256 are LITERALS below, for the same reason
  build-llama.sh's are: the digest was measured by hand once at pin time and
  every fetch is checked against it. A mismatch means the asset changed under
  the tag - investigate, do not wave it through.

  The tag MUST equal LLAMA_TAG in dist/build-llama.sh. One llama.cpp per
  release, both platforms; `make dist-check` has a row that compares them.

  DESIGN SKELETON - never executed. There is no Windows machine on this
  project yet. See dist/windows/README.md -> The sidecar.
#>
[CmdletBinding()]
param(
  # Where the staged tree goes. bond.iss reads it as MyLlamaDir = stage\llama.
  [string] $Dest = (Join-Path $PSScriptRoot 'stage\llama')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Measured 2026-09-11 against
# https://github.com/ggml-org/llama.cpp/releases/download/b10896/llama-b10896-bin-win-vulkan-x64.zip
# (31,661,471 bytes). Vulkan rather than CUDA/ROCm/SYCL: one 32 MB asset covers
# NVIDIA, AMD and Intel with no vendor runtime to install.
$LlamaTag    = 'b10896'
$LlamaSha256 = '0ca7f1ae2edd1d4a822789f70148a167a02de393005a8f034a76c799592de92d'
$LlamaAsset  = "llama-$LlamaTag-bin-win-vulkan-x64.zip"
$LlamaUrl    = "https://github.com/ggml-org/llama.cpp/releases/download/$LlamaTag/$LlamaAsset"

# Exactly what the app needs, and nothing else. llama-server.exe is a ~9 KB
# launcher; the server itself is llama-server-impl.dll. ggml-vulkan.dll is the
# GPU backend and the ggml-cpu-*.dll set is the fallback ggml picks from at
# load time when no Vulkan device is usable. Not shipped: llama-cli.exe,
# llama-bench.exe and every other tool, their *-impl.dll, ggml-rpc.dll and
# ggml-rpc-server.exe - every shipped binary is one that has to be signed.
# vulkan-1.dll is deliberately absent from the zip and must stay absent: the
# Vulkan loader comes with the GPU driver.
$Ship = @(
  'llama-server.exe',
  'llama-server-impl.dll',
  'llama.dll',
  'llama-common.dll',
  'mtmd.dll',
  'ggml.dll',
  'ggml-base.dll',
  'ggml-vulkan.dll',
  'libomp.dll',
  'LICENSE-LLVM-OpenMP'
)
$ShipGlobs = @('ggml-cpu-*.dll')

# The stamp carries the tag AND a digest of THIS SCRIPT, so editing the
# allowlist invalidates a staged tree exactly the way bumping the tag does.
$scriptHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $PSCommandPath).Hash.ToLower()
$PinStamp   = "$LlamaTag $($scriptHash.Substring(0, 16))"
$Pin        = Join-Path $Dest '.pin'

if ((Test-Path -LiteralPath $Pin) -and
    (([string](Get-Content -LiteralPath $Pin -Raw)).Trim() -eq $PinStamp) -and
    (Test-Path -LiteralPath (Join-Path $Dest 'llama-server.exe'))) {
  Write-Host "  llama.cpp $LlamaTag already staged in $Dest (delete .pin to force)"
  exit 0
}

# Windows PowerShell 5.1 still defaults to SSL3/TLS1.0, which github.com
# refuses. pwsh 7 ignores this and it is harmless there.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$work = Join-Path ([IO.Path]::GetTempPath()) ("bond-llama-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
try {
  $part = Join-Path $work "$LlamaAsset.part"
  Write-Host "==> downloading $LlamaAsset"
  $ProgressPreference = 'SilentlyContinue'  # 5.1 renders progress glacially
  Invoke-WebRequest -Uri $LlamaUrl -OutFile $part -UseBasicParsing

  $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $part).Hash
  if ($got -ine $LlamaSha256) {
    Remove-Item -LiteralPath $part -Force
    # throw, not Write-Error + exit: under ErrorActionPreference Stop the
    # Write-Error is already terminating and the exit would never run.
    throw "SHA-256 mismatch for $LlamaAsset`n  want $LlamaSha256`n  got  $($got.ToLower())"
  }
  Write-Host "  sha256 ok"

  # The zip is flat - no top-level directory - so it expands into a scratch
  # directory and the allowlist is copied out by name.
  $zip = Join-Path $work $LlamaAsset
  Rename-Item -LiteralPath $part -NewName $LlamaAsset
  $unpacked = Join-Path $work 'unpacked'
  Expand-Archive -LiteralPath $zip -DestinationPath $unpacked -Force

  if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Recurse -Force }
  New-Item -ItemType Directory -Path $Dest -Force | Out-Null

  $staged = 0
  foreach ($name in $Ship) {
    $src = Join-Path $unpacked $name
    if (-not (Test-Path -LiteralPath $src)) {
      throw "$name is not in $LlamaAsset - the asset's contents changed under tag $LlamaTag"
    }
    Copy-Item -LiteralPath $src -Destination $Dest -Force
    $staged++
  }
  foreach ($glob in $ShipGlobs) {
    $matched = @(Get-ChildItem -Path (Join-Path $unpacked $glob) -File -ErrorAction SilentlyContinue)
    if ($matched.Count -eq 0) {
      throw "no files matching $glob in $LlamaAsset - the CPU backends are not optional"
    }
    foreach ($file in $matched) {
      Copy-Item -LiteralPath $file.FullName -Destination $Dest -Force
      $staged++
    }
  }

  Set-Content -LiteralPath $Pin -Value $PinStamp -NoNewline
  # Where-Object rather than -Exclude: -Exclude only applies when the path
  # itself names the contents (dir\*), and that is easy to get wrong silently.
  Get-ChildItem -LiteralPath $Dest -File | Where-Object { $_.Name -ne '.pin' } | Sort-Object Name |
    ForEach-Object { Write-Host ("  {0,-28} {1,10:N0} bytes" -f $_.Name, $_.Length) }
  Write-Host "==> staged $staged file(s) from llama.cpp $LlamaTag into $Dest"
}
finally {
  Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

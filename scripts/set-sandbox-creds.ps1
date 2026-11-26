param(
    [string]$FilePath = "",
    [string]$Region = "us-east-1"
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""

if ($FilePath -ne "") {
    if (-not (Test-Path -Path $FilePath)) {
        throw "File kredensial tidak ditemukan: $FilePath"
    }
    $raw = Get-Content -Path $FilePath -Raw -Encoding UTF8
} else {
    $raw = Get-Clipboard -Raw
}

if ([string]::IsNullOrWhiteSpace($raw)) {
    throw "Clipboard kosong. Copy isi 'AWS Details -> AWS CLI' dari Vocareum/AWS Academy dulu, lalu jalankan ulang script ini."
}

$trimmed = $raw.Trim()
if ($trimmed -notmatch "aws_access_key_id\s*=" -or $trimmed -notmatch "aws_secret_access_key\s*=" -or $trimmed -notmatch "aws_session_token\s*=" ) {
    throw "Isi clipboard tidak mengandung blok kredensial AWS CLI lengkap (aws_access_key_id, aws_secret_access_key, aws_session_token)."
}

# Normalize header to [default] so aws CLI works without --profile
if ($trimmed -notmatch "(?m)^\[default\]\s*$") {
    $trimmed = "[default]`r`n" + $trimmed
}

$awsDir = Join-Path $env:USERPROFILE ".aws"
if (-not (Test-Path -Path $awsDir)) {
    New-Item -ItemType Directory -Path $awsDir -Force | Out-Null
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$credPath = Join-Path $awsDir "credentials"
$cfgPath = Join-Path $awsDir "config"

[System.IO.File]::WriteAllText($credPath, ($trimmed + "`r`n"), $utf8NoBom)

$cfgBody = @"
[default]
region = $Region
output = json
"@
[System.IO.File]::WriteAllText($cfgPath, ($cfgBody + "`r`n"), $utf8NoBom)

Write-Host "[OK] Kredensial Sandbox disimpan ke $credPath (di luar repo Git)." -ForegroundColor Green
Write-Host "[INFO] Memverifikasi koneksi STS..." -ForegroundColor Cyan

$identityRaw = aws sts get-caller-identity --output json
if ($LASTEXITCODE -ne 0) {
    throw "Verifikasi STS gagal. Pastikan sesi Sandbox berstatus hijau (Start Lab) dan token belum kedaluwarsa."
}

$identity = $identityRaw | ConvertFrom-Json
Write-Host "[PASS] Terhubung ke AWS Account: $($identity.Account) | ARN: $($identity.Arn)" -ForegroundColor Green

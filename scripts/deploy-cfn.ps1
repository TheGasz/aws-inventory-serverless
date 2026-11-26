param(
    [string]$Region = "us-east-1",
    [string]$StackName = "inventory-track-c-stack",
    [string]$TableName = "InventoryItems",
    [string]$FunctionName = "inventory-crud-handler",
    [string]$ApiName = "inventory-http-api",
    [string]$LabRoleName = "LabRole",
    [int]$LogRetentionDays = 7
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$templateFile = Join-Path $repoRoot "infra\template.yaml"
$lambdaFile = Join-Path $repoRoot "lambda\lambda_function.py"
$zipPath = Join-Path ([System.IO.Path]::GetTempPath()) ("inv_cfn_" + [guid]::NewGuid().ToString("N") + ".zip")
$apiUrlFile = Join-Path $repoRoot ".last_api_url.txt"

if (-not (Test-Path -Path $templateFile)) { throw "Template tidak ditemukan: $templateFile" }
if (-not (Test-Path -Path $lambdaFile)) { throw "Lambda source tidak ditemukan: $lambdaFile" }

Write-Host "=== [1/3] Deploy CloudFormation Stack ($StackName) ===" -ForegroundColor Cyan
aws cloudformation deploy `
    --stack-name $StackName `
    --template-file $templateFile `
    --region $Region `
    --no-fail-on-empty-changeset `
    --parameter-overrides `
        "TableName=$TableName" `
        "FunctionName=$FunctionName" `
        "ApiName=$ApiName" `
        "LabRoleName=$LabRoleName" `
        "LogRetentionDays=$LogRetentionDays"
if ($LASTEXITCODE -ne 0) {
    throw "CloudFormation deploy gagal. Jika Sandbox memblokir CloudFormation, gunakan .\scripts\deploy.ps1."
}

Write-Host "`n=== [2/3] Upload Kode Asli lambda/lambda_function.py + frontend/index.html ===" -ForegroundColor Cyan
if (Test-Path -Path $zipPath) { Remove-Item -Path $zipPath -Force }
$frontendFile = Join-Path $repoRoot "frontend\index.html"
$bundleFiles = @($lambdaFile)
if (Test-Path -Path $frontendFile) { $bundleFiles += $frontendFile }
Compress-Archive -Path $bundleFiles -DestinationPath $zipPath -Force
$zipArg = "fileb://" + ($zipPath -replace "\\", "/")

aws lambda update-function-code --function-name $FunctionName --zip-file $zipArg --region $Region | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Gagal mengunggah kode Lambda." }
aws lambda wait function-updated-v2 --function-name $FunctionName --region $Region
if ($LASTEXITCODE -ne 0) { throw "Timeout menunggu Lambda selesai update." }

Write-Host "`n=== [3/3] Ambil Invoke URL dari Stack Outputs ===" -ForegroundColor Cyan
$stackRaw = aws cloudformation describe-stacks --stack-name $StackName --region $Region --output json
if ($LASTEXITCODE -ne 0) { throw "Gagal membaca output CloudFormation." }
$outputs = ($stackRaw | ConvertFrom-Json).Stacks[0].Outputs
$invokeUrl = ($outputs | Where-Object { $_.OutputKey -eq "ApiInvokeUrl" } | Select-Object -First 1).OutputValue

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($apiUrlFile, $invokeUrl, $utf8NoBom)

Write-Host "`n============================================================" -ForegroundColor Green
Write-Host " CLOUDFORMATION DEPLOY SELESAI!" -ForegroundColor Green
Write-Host " Invoke URL : $invokeUrl" -ForegroundColor White
Write-Host " Langkah lanjut: .\scripts\seed_and_test.ps1" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Green

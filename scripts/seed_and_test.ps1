param(
    [string]$ApiUrl = "",
    [bool]$KeepSeedItem = $true,
    [string]$OutputFile = "docs\evidence\04-api-crud-output.txt"
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$apiUrlFile = Join-Path $repoRoot ".last_api_url.txt"

if ([string]::IsNullOrWhiteSpace($ApiUrl)) {
    if (-not (Test-Path -Path $apiUrlFile)) {
        throw "ApiUrl tidak diberikan dan file $apiUrlFile belum ada. Jalankan .\scripts\deploy.ps1 dulu."
    }
    $ApiUrl = (Get-Content -Path $apiUrlFile -Raw -Encoding UTF8).Trim()
}
$ApiUrl = $ApiUrl.TrimEnd("/")

if ([System.IO.Path]::IsPathRooted($OutputFile)) {
    $resolvedOut = $OutputFile
} else {
    $resolvedOut = Join-Path $repoRoot $OutputFile
}
$outDir = Split-Path -Path $resolvedOut -Parent
if (-not (Test-Path -Path $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

Start-Transcript -Path $resolvedOut -Force | Out-Null
try {
    Write-Host "Target API URL: $ApiUrl"
    Write-Host "Timestamp UTC : $((Get-Date).ToUniversalTime().ToString('o'))"

    Write-Host "`n=== 1. HEALTH CHECK (GET /health) ==="
    $health = Invoke-RestMethod -Method Get -Uri "$ApiUrl/health"
    if ($health.status -ne "healthy" -or $health.dynamodb -ne "connected") {
        throw "Health check gagal: $($health | ConvertTo-Json -Compress)"
    }
    $health | ConvertTo-Json -Depth 5

    if ($KeepSeedItem) {
        Write-Host "`n=== 2A. SEED ITEM (POST /items - disimpan di DynamoDB untuk bukti) ==="
        $seedBody = @{
            sku        = "LAP-001"
            name       = "ThinkPad T14 Gen 4"
            category   = "Electronics"
            quantity   = 12
            unit_price = 15500000
            location   = "Rack-A1"
        } | ConvertTo-Json
        $seedCreated = Invoke-RestMethod -Method Post -Uri "$ApiUrl/items" -ContentType "application/json" -Body $seedBody
        $seedCreated | ConvertTo-Json -Depth 5
    }

    Write-Host "`n=== 2B. CREATE TEST ITEM (POST /items) ==="
    $createBody = @{
        sku        = "MON-002"
        name       = "Dell 27 UltraSharp"
        category   = "Electronics"
        quantity   = 5
        unit_price = 4200000
        location   = "Rack-B2"
    } | ConvertTo-Json
    $created = Invoke-RestMethod -Method Post -Uri "$ApiUrl/items" -ContentType "application/json" -Body $createBody
    $created | ConvertTo-Json -Depth 5
    $itemId = $created.item_id
    if ([string]::IsNullOrWhiteSpace($itemId)) { throw "item_id kosong pada respons POST /items." }

    Write-Host "`n=== 3. READ ALL ITEMS (GET /items) ==="
    $all = Invoke-RestMethod -Method Get -Uri "$ApiUrl/items"
    $all | ConvertTo-Json -Depth 5
    if ($all.count -lt 1) { throw "GET /items mengembalikan count < 1." }

    Write-Host "`n=== 4. READ ONE ITEM (GET /items/$itemId) ==="
    $one = Invoke-RestMethod -Method Get -Uri "$ApiUrl/items/$itemId"
    $one | ConvertTo-Json -Depth 5
    if ($one.sku -ne "MON-002") { throw "SKU hasil GET /items/{id} tidak cocok." }

    Write-Host "`n=== 5. UPDATE ITEM (PUT /items/$itemId) ==="
    $updateBody = @{
        quantity = 8
        location = "Rack-B1"
    } | ConvertTo-Json
    $updated = Invoke-RestMethod -Method Put -Uri "$ApiUrl/items/$itemId" -ContentType "application/json" -Body $updateBody
    $updated | ConvertTo-Json -Depth 5
    if ($updated.quantity -ne 8 -or $updated.location -ne "Rack-B1") {
        throw "PUT /items/{id} gagal memperbarui field."
    }

    Write-Host "`n=== 6. NEGATIVE TESTS (Harus 400 Bad Request untuk quantity 3.5 & -1) ==="
    foreach ($badQty in @(3.5, -1)) {
        $gotError = $false
        try {
            $badBody = @{ sku = "BAD-1"; name = "Invalid"; quantity = $badQty; unit_price = 1000 } | ConvertTo-Json
            $null = Invoke-RestMethod -Method Post -Uri "$ApiUrl/items" -ContentType "application/json" -Body $badBody
        } catch {
            $gotError = $true
            Write-Host "Expected 400 for quantity=$badQty -> $($_.Exception.Message)"
        }
        if (-not $gotError) { throw "Seharusnya gagal 400 untuk quantity=$badQty!" }
    }

    Write-Host "`n=== 7. DELETE TEST ITEM (DELETE /items/$itemId) ==="
    $deleted = Invoke-RestMethod -Method Delete -Uri "$ApiUrl/items/$itemId"
    $deleted | ConvertTo-Json -Depth 5
    if ($deleted.deleted -ne $itemId) { throw "Respons DELETE tidak sesuai." }

    Write-Host "`n=== 8. VERIFY DELETED 404 (GET /items/$itemId) ==="
    $got404 = $false
    try {
        $null = Invoke-RestMethod -Method Get -Uri "$ApiUrl/items/$itemId"
    } catch {
        $got404 = $true
        Write-Host "Expected 404 after delete -> $($_.Exception.Message)"
    }
    if (-not $got404) { throw "Item terhapus masih dapat dibaca!" }

    Write-Host "`n[PASS] SELURUH SIKLUS HEALTH -> CRUD -> NEGATIVE CHECKS BERHASIL!" -ForegroundColor Green
} finally {
    Stop-Transcript | Out-Null
}

Write-Host "[SAVED] Bukti output tersimpan di: $resolvedOut" -ForegroundColor Cyan

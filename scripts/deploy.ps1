param(
    [string]$Region = "us-east-1",
    [string]$TableName = "InventoryItems",
    [string]$FunctionName = "inventory-crud-handler",
    [string]$ApiName = "inventory-http-api",
    [string]$LabRoleName = "LabRole",
    [int]$LogRetentionDays = 7
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$lambdaFile = Join-Path $repoRoot "lambda\lambda_function.py"
$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("inv_deploy_" + [guid]::NewGuid().ToString("N"))
$zipPath = Join-Path $tmpDir "lambda_function.zip"
$apiUrlFile = Join-Path $repoRoot ".last_api_url.txt"

if (-not (Test-Path -Path $lambdaFile)) {
    throw "File Lambda tidak ditemukan: $lambdaFile"
}

New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-JsonTemp {
    param(
        [string]$Name,
        [object]$Object
    )
    $filePath = Join-Path $tmpDir $Name
    $json = ConvertTo-Json -InputObject $Object -Depth 10 -Compress
    [System.IO.File]::WriteAllText($filePath, $json, $utf8NoBom)
    return ("file://" + ($filePath -replace "\\", "/"))
}

function Test-AwsResource {
    param([scriptblock]$Probe)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $Probe *> $null
        return ($LASTEXITCODE -eq 0)
    } finally {
        $ErrorActionPreference = $prev
    }
}

try {
    Write-Host "=== [1/8] Verifikasi Kredensial AWS & Region ($Region) ===" -ForegroundColor Cyan
    $idRaw = aws sts get-caller-identity --output json
    if ($LASTEXITCODE -ne 0) {
        throw "Gagal memanggil STS. Jalankan .\scripts\set-sandbox-creds.ps1 terlebih dahulu."
    }
    $accountId = ($idRaw | ConvertFrom-Json).Account
    $roleArn = "arn:aws:iam::${accountId}:role/${LabRoleName}"
    Write-Host "[OK] Account ID: $accountId | Role: $roleArn" -ForegroundColor Green

    Write-Host "`n=== [2/8] Provision DynamoDB Table ($TableName, On-Demand) ===" -ForegroundColor Cyan
    $tableExists = Test-AwsResource { aws dynamodb describe-table --table-name $TableName --region $Region }
    if ($tableExists) {
        Write-Host "[SKIP] Tabel '$TableName' sudah ada." -ForegroundColor Yellow
    } else {
        $attrFile = Write-JsonTemp "ddb_attr.json" @(@{ AttributeName = "item_id"; AttributeType = "S" })
        $keyFile = Write-JsonTemp "ddb_key.json" @(@{ AttributeName = "item_id"; KeyType = "HASH" })
        aws dynamodb create-table `
            --table-name $TableName `
            --attribute-definitions $attrFile `
            --key-schema $keyFile `
            --billing-mode PAY_PER_REQUEST `
            --region $Region | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Gagal membuat tabel DynamoDB '$TableName'." }
        Write-Host "[WAIT] Menunggu tabel '$TableName' aktif..."
        aws dynamodb wait table-exists --table-name $TableName --region $Region
        if ($LASTEXITCODE -ne 0) { throw "Timeout menunggu tabel '$TableName' aktif." }
        Write-Host "[OK] Tabel '$TableName' aktif." -ForegroundColor Green
    }

    Write-Host "`n=== [3/8] Provision CloudWatch Log Group & Retention ($LogRetentionDays hari) ===" -ForegroundColor Cyan
    $logGroupName = "/aws/lambda/$FunctionName"
    $lgRaw = aws logs describe-log-groups --log-group-name-prefix $logGroupName --region $Region --output json
    if ($LASTEXITCODE -ne 0) { throw "Gagal membaca CloudWatch Log Groups." }
    $lgMatch = ($lgRaw | ConvertFrom-Json).logGroups | Where-Object { $_.logGroupName -eq $logGroupName }
    if (-not $lgMatch) {
        aws logs create-log-group --log-group-name $logGroupName --region $Region
        if ($LASTEXITCODE -ne 0) { throw "Gagal membuat Log Group '$logGroupName'." }
    }
    aws logs put-retention-policy --log-group-name $logGroupName --retention-in-days $LogRetentionDays --region $Region
    if ($LASTEXITCODE -ne 0) { throw "Gagal mengatur retention CloudWatch Logs." }
    Write-Host "[OK] Log Group '$logGroupName' siap (retention $LogRetentionDays hari)." -ForegroundColor Green

    Write-Host "`n=== [4/8] Package & Deploy AWS Lambda ($FunctionName) ===" -ForegroundColor Cyan
    if (Test-Path -Path $zipPath) { Remove-Item -Path $zipPath -Force }
    Compress-Archive -Path $lambdaFile -DestinationPath $zipPath -Force
    $zipArg = "fileb://" + ($zipPath -replace "\\", "/")
    $envFile = Write-JsonTemp "lambda_env.json" @{
        Variables = @{
            TABLE_NAME = $TableName
            LOG_LEVEL  = "INFO"
        }
    }

    $fnExists = Test-AwsResource { aws lambda get-function --function-name $FunctionName --region $Region }
    if ($fnExists) {
        Write-Host "[UPDATE] Memperbarui kode dan konfigurasi Lambda '$FunctionName'..."
        aws lambda update-function-code --function-name $FunctionName --zip-file $zipArg --region $Region | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Gagal update kode Lambda." }
        aws lambda wait function-updated-v2 --function-name $FunctionName --region $Region
        if ($LASTEXITCODE -ne 0) { throw "Timeout menunggu update kode Lambda." }

        aws lambda update-function-configuration `
            --function-name $FunctionName `
            --runtime python3.12 `
            --handler lambda_function.lambda_handler `
            --timeout 10 `
            --memory-size 128 `
            --environment $envFile `
            --region $Region | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Gagal update konfigurasi Lambda." }
        aws lambda wait function-updated-v2 --function-name $FunctionName --region $Region
        if ($LASTEXITCODE -ne 0) { throw "Timeout menunggu update konfigurasi Lambda." }
    } else {
        Write-Host "[CREATE] Membuat fungsi Lambda '$FunctionName' dengan role '$LabRoleName'..."
        $createdOk = Test-AwsResource {
            aws lambda create-function `
                --function-name $FunctionName `
                --runtime python3.12 `
                --architectures x86_64 `
                --role $roleArn `
                --handler lambda_function.lambda_handler `
                --zip-file $zipArg `
                --timeout 10 `
                --memory-size 128 `
                --environment $envFile `
                --region $Region
        }
        if (-not $createdOk) {
            $hasVoclabs = Test-AwsResource { aws sts get-caller-identity --profile voclabs }
            if ($hasVoclabs) {
                Write-Host "[INFO] Mencoba create-function menggunakan profile 'voclabs' (PassRole)..." -ForegroundColor Yellow
                aws lambda create-function `
                    --profile voclabs `
                    --function-name $FunctionName `
                    --runtime python3.12 `
                    --architectures x86_64 `
                    --role $roleArn `
                    --handler lambda_function.lambda_handler `
                    --zip-file $zipArg `
                    --timeout 10 `
                    --memory-size 128 `
                    --environment $envFile `
                    --region $Region | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Gagal membuat fungsi Lambda '$FunctionName' (baik default maupun voclabs)." }
            } else {
                throw "Gagal membuat fungsi Lambda '$FunctionName'."
            }
        }
        aws lambda wait function-active-v2 --function-name $FunctionName --region $Region
        if ($LASTEXITCODE -ne 0) { throw "Timeout menunggu Lambda aktif." }
    }
    $lambdaInfo = (aws lambda get-function-configuration --function-name $FunctionName --region $Region --output json) | ConvertFrom-Json
    $lambdaArn = $lambdaInfo.FunctionArn
    Write-Host "[OK] Lambda siap: $lambdaArn" -ForegroundColor Green

    Write-Host "`n=== [5/8] Provision HTTPS Entrypoint (API Gateway HTTP API v2 / Fallback Lambda Function URL) ===" -ForegroundColor Cyan
    $corsFile = Write-JsonTemp "apigw_cors.json" @{
        AllowOrigins = @("*")
        AllowMethods = @("GET", "POST", "PUT", "DELETE", "OPTIONS")
        AllowHeaders = @("content-type")
    }

    $apiGwAllowed = $false
    $apiId = ""
    if (Test-AwsResource { aws apigatewayv2 get-apis --region $Region }) {
        $apisRaw = aws apigatewayv2 get-apis --region $Region --output json
        $existingApi = ($apisRaw | ConvertFrom-Json).Items | Where-Object { $_.Name -eq $ApiName } | Select-Object -First 1
        if ($existingApi) {
            $apiId = $existingApi.ApiId
            $apiGwAllowed = Test-AwsResource { aws apigatewayv2 update-api --api-id $apiId --cors-configuration $corsFile --region $Region }
        } else {
            $prev = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            $createdApiRaw = aws apigatewayv2 create-api `
                --name $ApiName `
                --protocol-type HTTP `
                --cors-configuration $corsFile `
                --region $Region `
                --output json 2>$null
            $apiCreateExit = $LASTEXITCODE
            $ErrorActionPreference = $prev
            if ($apiCreateExit -eq 0 -and $createdApiRaw) {
                $apiId = ($createdApiRaw | ConvertFrom-Json).ApiId
                $apiGwAllowed = $true
            }
        }
    }

    if ($apiGwAllowed) {
        Write-Host "[OK] API Gateway HTTP API aktif: $apiId" -ForegroundColor Green

        Write-Host "`n=== [6/8] Setup Lambda Proxy 2.0 Integration & 6 Routes ===" -ForegroundColor Cyan
        $intRaw = aws apigatewayv2 get-integrations --api-id $apiId --region $Region --output json
        if ($LASTEXITCODE -ne 0) { throw "Gagal membaca integrations." }
        $existingInt = ($intRaw | ConvertFrom-Json).Items | Where-Object { $_.IntegrationUri -eq $lambdaArn } | Select-Object -First 1
        if ($existingInt) {
            $integrationId = $existingInt.IntegrationId
        } else {
            $createdIntRaw = aws apigatewayv2 create-integration `
                --api-id $apiId `
                --integration-type AWS_PROXY `
                --integration-uri $lambdaArn `
                --payload-format-version 2.0 `
                --region $Region `
                --output json
            if ($LASTEXITCODE -ne 0) { throw "Gagal membuat Lambda integration." }
            $integrationId = ($createdIntRaw | ConvertFrom-Json).IntegrationId
        }

        $routesRaw = aws apigatewayv2 get-routes --api-id $apiId --region $Region --output json
        if ($LASTEXITCODE -ne 0) { throw "Gagal membaca routes." }
        $existingRoutes = @{}
        foreach ($r in ($routesRaw | ConvertFrom-Json).Items) {
            $existingRoutes[$r.RouteKey] = $r.RouteId
        }

        $requiredRoutes = @(
            "GET /health",
            "POST /items",
            "GET /items",
            "GET /items/{id}",
            "PUT /items/{id}",
            "DELETE /items/{id}"
        )
        $targetRef = "integrations/$integrationId"
        foreach ($rk in $requiredRoutes) {
            if ($existingRoutes.ContainsKey($rk)) {
                Write-Host "  [SKIP] Route sudah ada: $rk"
            } else {
                aws apigatewayv2 create-route --api-id $apiId --route-key $rk --target $targetRef --region $Region | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Gagal membuat route '$rk'." }
                Write-Host "  [OK] Route dibuat: $rk" -ForegroundColor Green
            }
        }

        Write-Host "`n=== [7/8] Setup Stage '$default' (Auto-Deploy + Throttle 10 RPS / Burst 20) ===" -ForegroundColor Cyan
        $throttleFile = Write-JsonTemp "stage_throttle.json" @{
            ThrottlingRateLimit  = 10
            ThrottlingBurstLimit = 20
        }
        $stageExists = Test-AwsResource { aws apigatewayv2 get-stage --api-id $apiId --stage-name '$default' --region $Region }
        if ($stageExists) {
            aws apigatewayv2 update-stage `
                --api-id $apiId `
                --stage-name '$default' `
                --auto-deploy `
                --default-route-settings $throttleFile `
                --region $Region | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Gagal update stage default." }
        } else {
            aws apigatewayv2 create-stage `
                --api-id $apiId `
                --stage-name '$default' `
                --auto-deploy `
                --default-route-settings $throttleFile `
                --region $Region | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Gagal membuat stage default." }
        }

        Write-Host "`n=== [8/8] Pasang Resource-Based Policy (API Gateway -> Lambda Invoke) ===" -ForegroundColor Cyan
        $stmtId = "apigw-invoke-inventory"
        $null = Test-AwsResource { aws lambda remove-permission --function-name $FunctionName --statement-id $stmtId --region $Region }
        $sourceArn = "arn:aws:execute-api:${Region}:${accountId}:${apiId}/*/*"
        aws lambda add-permission `
            --function-name $FunctionName `
            --statement-id $stmtId `
            --action lambda:InvokeFunction `
            --principal apigateway.amazonaws.com `
            --source-arn $sourceArn `
            --region $Region | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Gagal menambahkan permission invoke ke Lambda." }

        $invokeUrl = "https://${apiId}.execute-api.${Region}.amazonaws.com"
    } else {
        Write-Host "[INFO] API Gateway v2 dibatasi di Sandbox ini -> otomatis menggunakan Lambda Function URL (HTTPS Payload 2.0)." -ForegroundColor Yellow

        Write-Host "`n=== [6/8] Konfigurasi Lambda Function URL & CORS ===" -ForegroundColor Cyan
        $fnCorsFile = Write-JsonTemp "fnurl_cors.json" @{
            AllowOrigins = @("*")
            AllowMethods = @("GET", "POST", "PUT", "DELETE")
            AllowHeaders = @("content-type")
        }
        $fnUrlExists = Test-AwsResource { aws lambda get-function-url-config --function-name $FunctionName --region $Region }
        if ($fnUrlExists) {
            $fnUrlRaw = aws lambda update-function-url-config `
                --function-name $FunctionName `
                --auth-type NONE `
                --cors $fnCorsFile `
                --region $Region `
                --output json
        } else {
            $fnUrlRaw = aws lambda create-function-url-config `
                --function-name $FunctionName `
                --auth-type NONE `
                --cors $fnCorsFile `
                --region $Region `
                --output json
        }
        if ($LASTEXITCODE -ne 0) { throw "Gagal membuat/memperbarui Lambda Function URL." }
        $invokeUrl = (($fnUrlRaw | ConvertFrom-Json).FunctionUrl).TrimEnd("/")

        Write-Host "`n=== [7/8] Konfigurasi Public Invoke Permission untuk Function URL ===" -ForegroundColor Cyan
        $fnStmtId = "fn-url-public"
        $null = Test-AwsResource { aws lambda remove-permission --function-name $FunctionName --statement-id $fnStmtId --region $Region }
        aws lambda add-permission `
            --function-name $FunctionName `
            --statement-id $fnStmtId `
            --action lambda:InvokeFunctionUrl `
            --principal "*" `
            --function-url-auth-type NONE `
            --region $Region | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Gagal menambahkan permission InvokeFunctionUrl." }

        $fnInvokeStmtId = "fn-url-invoke-public"
        $null = Test-AwsResource { aws lambda remove-permission --function-name $FunctionName --statement-id $fnInvokeStmtId --region $Region }
        aws lambda add-permission `
            --function-name $FunctionName `
            --statement-id $fnInvokeStmtId `
            --action lambda:InvokeFunction `
            --principal "*" `
            --invoked-via-function-url `
            --region $Region | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Gagal menambahkan permission InvokeFunction untuk Function URL." }

        Write-Host "`n=== [8/8] Verifikasi Konfigurasi Endpoint HTTPS ===" -ForegroundColor Cyan
        Write-Host "[OK] Lambda Function URL siap: $invokeUrl" -ForegroundColor Green
    }

    [System.IO.File]::WriteAllText($apiUrlFile, $invokeUrl, $utf8NoBom)

    Write-Host "`n============================================================" -ForegroundColor Green
    Write-Host " DEPLOY TRACK C SELESAI & SIAP DIPAKAI!" -ForegroundColor Green
    Write-Host " Invoke URL : $invokeUrl" -ForegroundColor White
    Write-Host " Disimpan   : $apiUrlFile" -ForegroundColor Gray
    Write-Host " Langkah lanjut: .\scripts\seed_and_test.ps1" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Green
} finally {
    if (Test-Path -Path $tmpDir) {
        Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

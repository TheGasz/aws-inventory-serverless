param(
    [string]$Region = "us-east-1",
    [string]$StackName = "inventory-track-c-stack",
    [string]$TableName = "InventoryItems",
    [string]$FunctionName = "inventory-crud-handler",
    [string]$ApiName = "inventory-http-api"
)

$ErrorActionPreference = "Stop"
$env:AWS_PAGER = ""

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

Write-Host "=== Cleanup Resource Track C di Region $Region ===" -ForegroundColor Cyan

$stackExists = Test-AwsResource { aws cloudformation describe-stacks --stack-name $StackName --region $Region }
if ($stackExists) {
    Write-Host "[DELETE] Menghapus CloudFormation stack '$StackName'..."
    aws cloudformation delete-stack --stack-name $StackName --region $Region
    aws cloudformation wait stack-delete-complete --stack-name $StackName --region $Region
    Write-Host "[OK] Stack '$StackName' terhapus." -ForegroundColor Green
    return
}

$apisRaw = aws apigatewayv2 get-apis --region $Region --output json
if ($LASTEXITCODE -eq 0) {
    $apis = ($apisRaw | ConvertFrom-Json).Items | Where-Object { $_.Name -eq $ApiName }
    foreach ($api in $apis) {
        Write-Host "[DELETE] Menghapus HTTP API '$ApiName' ($($api.ApiId))..."
        aws apigatewayv2 delete-api --api-id $api.ApiId --region $Region
    }
}

$fnExists = Test-AwsResource { aws lambda get-function --function-name $FunctionName --region $Region }
if ($fnExists) {
    Write-Host "[DELETE] Menghapus Lambda '$FunctionName'..."
    aws lambda delete-function --function-name $FunctionName --region $Region
}

$logGroupName = "/aws/lambda/$FunctionName"
$lgRaw = aws logs describe-log-groups --log-group-name-prefix $logGroupName --region $Region --output json
if ($LASTEXITCODE -eq 0) {
    $lgMatch = ($lgRaw | ConvertFrom-Json).logGroups | Where-Object { $_.logGroupName -eq $logGroupName }
    if ($lgMatch) {
        Write-Host "[DELETE] Menghapus Log Group '$logGroupName'..."
        aws logs delete-log-group --log-group-name $logGroupName --region $Region
    }
}

$tableExists = Test-AwsResource { aws dynamodb describe-table --table-name $TableName --region $Region }
if ($tableExists) {
    Write-Host "[DELETE] Menghapus Tabel DynamoDB '$TableName'..."
    aws dynamodb delete-table --table-name $TableName --region $Region | Out-Null
    aws dynamodb wait table-not-exists --table-name $TableName --region $Region
}

Write-Host "[DONE] Cleanup selesai." -ForegroundColor Green


param(
    [string]$StackName = "sis3-dev",
    [string]$Region = "us-east-1",
    [ValidateSet("dev", "staging", "prod")]
    [string]$Environment = "dev"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-Aws {
    param([string[]]$Arguments)

    $result = & aws @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "AWS CLI command failed: aws $($Arguments -join ' ')"
    }
    return $result
}

function Deploy-Stack {
    param(
        [string]$ImageTag,
        [int]$DesiredCount
    )

    Write-Host "`nDeploying CloudFormation stack..." -ForegroundColor Cyan

    Invoke-Aws @(
        "cloudformation", "deploy",
        "--template-file", "infrastructure/template.yaml",
        "--stack-name", $StackName,
        "--region", $Region,
        "--capabilities", "CAPABILITY_IAM",
        "--parameter-overrides",
        "Environment=$Environment",
        "ImageTag=$ImageTag",
        "DesiredCount=$DesiredCount",
        "ContainerPort=8080",
        "LogRetentionDays=7",
        "--no-fail-on-empty-changeset"
    ) | Out-Host
}

Write-Host "=== SIS 3 Deployment ===" -ForegroundColor Green
Write-Host "Stack: $StackName"
Write-Host "Region: $Region"

# 1. Check required tools
foreach ($tool in @("aws", "docker", "git")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "$tool is not installed or not available in PATH."
    }
}

# 2. Check AWS authentication
Write-Host "`nChecking AWS identity..." -ForegroundColor Cyan
Invoke-Aws @("sts", "get-caller-identity", "--region", $Region) |
    Out-Host

# 3. Check Docker
Write-Host "`nChecking Docker..." -ForegroundColor Cyan
& docker info | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Docker Desktop is not running."
}

# 4. Get Git commit SHA
$ImageTag = (& git rev-parse --short HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($ImageTag)) {
    throw "Could not determine Git commit SHA."
}

Write-Host "Image tag: $ImageTag" -ForegroundColor Yellow

# 5. Check whether the stack exists
Write-Host "`nChecking CloudFormation stack..." -ForegroundColor Cyan
& aws cloudformation describe-stacks `
    --stack-name $StackName `
    --region $Region 2>$null | Out-Null

$StackExists = ($LASTEXITCODE -eq 0)

if (-not $StackExists) {
    Write-Host "Stack does not exist. Creating it..." -ForegroundColor Yellow
    Deploy-Stack -ImageTag $ImageTag -DesiredCount 0
}

# 6. Get ECR repository URI
$OutputsJson = Invoke-Aws @(
    "cloudformation", "describe-stacks",
    "--stack-name", $StackName,
    "--region", $Region,
    "--query", "Stacks[0].Outputs",
    "--output", "json"
)

$Outputs = $OutputsJson | ConvertFrom-Json
$EcrUri = ($Outputs | Where-Object OutputKey -eq "EcrRepositoryUri").OutputValue
$AlbDns = ($Outputs | Where-Object OutputKey -eq "AlbDnsName").OutputValue
$ClusterName = ($Outputs | Where-Object OutputKey -eq "EcsClusterName").OutputValue
$ServiceName = ($Outputs | Where-Object OutputKey -eq "EcsServiceName").OutputValue

if ([string]::IsNullOrWhiteSpace($EcrUri)) {
    throw "ECR repository URI was not found in CloudFormation outputs."
}

$RepositoryName = ($EcrUri -split "/")[-1]
$Registry = ($EcrUri -split "/")[0]
$ImageUri = "${EcrUri}:${ImageTag}"

Write-Host "ECR: $EcrUri" -ForegroundColor Gray

# 7. Check whether this immutable image tag already exists
Write-Host "`nChecking ECR image..." -ForegroundColor Cyan

$ImageCount = Invoke-Aws @(
    "ecr", "list-images",
    "--repository-name", $RepositoryName,
    "--filter", "tagStatus=TAGGED",
    "--query", "length(imageIds[?imageTag=='$ImageTag'])",
    "--output", "text",
    "--region", $Region
)

$ImageExists = ([int]$ImageCount -gt 0)

if (-not $ImageExists) {

    # Point the task definition to the new tag, with service stopped.
    Write-Host "Image tag not found. Preparing stack..." -ForegroundColor Yellow
    Deploy-Stack -ImageTag $ImageTag -DesiredCount 0

    # Authenticate Docker to ECR
    Write-Host "`nLogging in to ECR..." -ForegroundColor Cyan
    Invoke-Aws @(
        "ecr", "get-login-password",
        "--region", $Region
    ) | & docker login --username AWS --password-stdin $Registry

    if ($LASTEXITCODE -ne 0) {
        throw "Docker login to ECR failed."
    }

    # Build image
    Write-Host "`nBuilding Docker image..." -ForegroundColor Cyan
    & docker build -t $ImageUri ./app

    if ($LASTEXITCODE -ne 0) {
        throw "Docker build failed."
    }

    # Push image
    Write-Host "`nPushing image to ECR..." -ForegroundColor Cyan
    & docker push $ImageUri

    if ($LASTEXITCODE -ne 0) {
        throw "Docker push failed."
    }
}
else {
    Write-Host "Image already exists. Skipping build and push." -ForegroundColor Yellow
}

# 8. Start ECS service
Write-Host "`nStarting ECS service..." -ForegroundColor Cyan
Deploy-Stack -ImageTag $ImageTag -DesiredCount 1

# 9. Wait until ECS service is stable
Write-Host "`nWaiting for ECS service to become stable..." -ForegroundColor Cyan

Invoke-Aws @(
    "ecs", "wait", "services-stable",
    "--cluster", $ClusterName,
    "--services", $ServiceName,
    "--region", $Region
) | Out-Host

# 10. Check application health
$HealthUrl = "http://$AlbDns/health"
Write-Host "`nChecking application health: $HealthUrl" -ForegroundColor Cyan

$Healthy = $false

for ($attempt = 1; $attempt -le 12; $attempt++) {
    try {
        $response = Invoke-WebRequest -Uri $HealthUrl -TimeoutSec 10 -UseBasicParsing

        if ($response.StatusCode -eq 200) {
            $Healthy = $true
            Write-Host $response.Content
            break
        }
    }
    catch {
        Write-Host "Attempt $attempt/12: application is not ready yet."
        Start-Sleep -Seconds 10
    }
}

if (-not $Healthy) {
    throw "Application health check failed: $HealthUrl"
}

# 11. Final summary
Write-Host "`n====================================" -ForegroundColor Green
Write-Host "DEPLOYMENT SUCCESSFUL" -ForegroundColor Green
Write-Host "====================================" -ForegroundColor Green
Write-Host "Stack:     $StackName"
Write-Host "Region:    $Region"
Write-Host "Image tag: $ImageTag"
Write-Host "ECR:       $ImageUri"
Write-Host "App URL:   http://$AlbDns"
Write-Host "Health:    $HealthUrl"
Write-Host "====================================" -ForegroundColor Green

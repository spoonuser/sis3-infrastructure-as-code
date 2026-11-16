Write-Host "Checking AWS CLI..."
aws --version
if ($LASTEXITCODE -ne 0) { throw "AWS CLI not found" }

Write-Host "Checking AWS identity..."
aws sts get-caller-identity
if ($LASTEXITCODE -ne 0) { throw "AWS credentials are not configured" }

Write-Host "Checking Docker client/server..."
docker version
if ($LASTEXITCODE -ne 0) { throw "Docker Engine is not running. Start Docker Desktop and wait for Engine running." }

Write-Host "All checks passed."

param(
  [string]$ProjectId = "carecast-v2",
  [string]$Region = "us-central1",
  [string]$ApiService = "care-cast-api-v2",
  [string]$WebAppUrl = "https://carecast-v2.web.app",
  [string]$ApiBaseUrl = "https://care-cast-api-v2-524384697116.us-central1.run.app",
  [string]$CareCastRelease = "",
  [string]$WebappRelease = "",
  [string]$ApiRelease = "",
  [switch]$SkipLocalBuild,
  [switch]$SkipWebDeploy,
  [switch]$SkipApiDeploy
)

$ErrorActionPreference = "Stop"

if (-not $env:ANTHROPIC_API_KEY) {
  throw "ANTHROPIC_API_KEY is not set in this PowerShell session."
}

if (-not $env:CRON_SECRET) {
  throw "CRON_SECRET is not set in this PowerShell session. Set it with: `$env:CRON_SECRET = 'your-secret'"
}

if (-not $env:ADMIN_UIDS -and -not $env:ADMIN_EMAILS) {
  throw "At least one of ADMIN_UIDS or ADMIN_EMAILS must be set. Set with: `$env:ADMIN_UIDS = 'uid1,uid2'"
}

if (-not $env:GMAIL_USER) {
  throw "GMAIL_USER is not set. Set with: `$env:GMAIL_USER = 'you@gmail.com'"
}

if (-not $env:GMAIL_APP_PASSWORD) {
  throw "GMAIL_APP_PASSWORD is not set. Set with: `$env:GMAIL_APP_PASSWORD = '16-char-app-password'"
}

if (-not $env:GOOGLE_CLIENT_ID) {
  throw "GOOGLE_CLIENT_ID is not set in this PowerShell session."
}

if (-not $env:GOOGLE_CLIENT_SECRET) {
  throw "GOOGLE_CLIENT_SECRET is not set in this PowerShell session."
}


function Invoke-Checked([string]$Command, [string]$ErrorMessage) {
  Invoke-Expression $Command
  if ($LASTEXITCODE -ne 0) {
    throw $ErrorMessage
  }
}

function Assert-NoLocalhostApiInDist([string]$DistPath) {
  $matches = Select-String -Path (Join-Path $DistPath "assets\*.js") -Pattern "http://localhost:8080/api" -SimpleMatch -ErrorAction SilentlyContinue
  if ($matches) {
    throw "Web build contains hardcoded localhost API URL. Clear VITE_API_URL in shell and rebuild."
  }
}

function Assert-ApiDeploymentHealth(
  [string]$ServiceUrl,
  [string]$ExpectedRelease,
  [string]$ExpectedRevision
) {
  $timestamp = Get-Date -Format yyyyMMddHHmmss
  $healthUrl = "$ServiceUrl/health?ts=$timestamp"

  Write-Host "Verifying API deployment health: $healthUrl" -ForegroundColor Cyan
  $health = Invoke-RestMethod -Uri $healthUrl -Method Get

  if ($health.release -ne $ExpectedRelease) {
    throw "API deploy verification failed. Expected release '$ExpectedRelease' but /health returned '$($health.release)'."
  }

  if ($health.revision -ne $ExpectedRevision) {
    throw "API deploy verification failed. Expected revision '$ExpectedRevision' but /health returned '$($health.revision)'."
  }

  Write-Host "API deployment verified: release $($health.release), revision $($health.revision)" -ForegroundColor Green
}

$webappRevision = (git -C ./care-cast-webapp rev-parse --short=12 HEAD).Trim()
$apiRevision = (git -C ./care-cast-api rev-parse --short=12 HEAD).Trim()
$buildTime = (Get-Date).ToUniversalTime().ToString("o")
$defaultRelease = (Get-Date).ToString("yyyy.MM.dd") + "-a"

if (-not $CareCastRelease) {
  $CareCastRelease = $defaultRelease
}

if (-not $WebappRelease) {
  $WebappRelease = $CareCastRelease
}

if (-not $ApiRelease) {
  $ApiRelease = $CareCastRelease
}

Write-Host "Deploy revisions:" -ForegroundColor Cyan
Write-Host "  CareCast release: $CareCastRelease" -ForegroundColor Cyan
Write-Host "  Webapp release:   $WebappRelease" -ForegroundColor Cyan
Write-Host "  API release:      $ApiRelease" -ForegroundColor Cyan
Write-Host "  Webapp: $webappRevision" -ForegroundColor Cyan
Write-Host "  API:    $apiRevision" -ForegroundColor Cyan

$envVars = @(
  "NODE_ENV=production"
  "CARECAST_RELEASE=$CareCastRelease"
  "WEBAPP_BASE_URL=$WebAppUrl"
  "API_BASE_URL=$ApiBaseUrl"
  "FIREBASE_STORAGE_BUCKET=carecast-v2.firebasestorage.app"
  "FIREBASE_MEDIA_STORAGE_FOLDER_NAME=family_photos"
  "FIREBASE_THUMBNAIL_STORAGE_FOLDER_NAME=thumbnails"
  "FIREBASE_QR_STORAGE_FOLDER_NAME=qr_codes"
  "ANTHROPIC_API_KEY=$($env:ANTHROPIC_API_KEY)"
  "CRON_SECRET=$($env:CRON_SECRET)"
  "ADMIN_UIDS=$($env:ADMIN_UIDS)"
  "ADMIN_EMAILS=$($env:ADMIN_EMAILS)"
  "GMAIL_USER=$($env:GMAIL_USER)"
  "GMAIL_APP_PASSWORD=$($env:GMAIL_APP_PASSWORD)"
  "GOOGLE_CLIENT_ID=$($env:GOOGLE_CLIENT_ID)"
  "GOOGLE_CLIENT_SECRET=$($env:GOOGLE_CLIENT_SECRET)"
  "GOOGLE_REDIRECT_URI=https://care-cast-api-v2-524384697116.us-central1.run.app/api/auth/google/gcoauth2callback"
  "CARECAST_API_RELEASE=$ApiRelease"
  "CARECAST_API_REVISION=$apiRevision"
  "CARECAST_API_BUILD_TIME=$buildTime"
  "CARECAST_WEBAPP_RELEASE=$WebappRelease"
  "CARECAST_WEBAPP_REVISION=$webappRevision"
  "CARECAST_WEBAPP_BUILD_TIME=$buildTime"
) -join ","

if (-not $SkipLocalBuild) {
  Write-Host "Running local API build check (TypeScript compile)..." -ForegroundColor Cyan
  Push-Location ./care-cast-api
  Invoke-Checked "npm run build" "Local API build failed."
  Pop-Location

  Write-Host "Building webapp (dist) for Firebase Hosting..." -ForegroundColor Cyan
  Push-Location ./care-cast-webapp
  if (Test-Path Env:VITE_API_URL) {
    Write-Host "Clearing shell VITE_API_URL for production build safety..." -ForegroundColor Yellow
    Remove-Item Env:VITE_API_URL -ErrorAction SilentlyContinue
  }
  $env:VITE_CARECAST_RELEASE = $CareCastRelease
  $env:VITE_CARECAST_WEBAPP_RELEASE = $WebappRelease
  $env:VITE_CARECAST_WEBAPP_REVISION = $webappRevision
  $env:VITE_CARECAST_WEBAPP_BUILD_TIME = $buildTime
  Invoke-Checked "npm run build" "Webapp build failed."
  Assert-NoLocalhostApiInDist -DistPath (Join-Path (Get-Location) "dist")
  Remove-Item Env:VITE_CARECAST_RELEASE -ErrorAction SilentlyContinue
  Remove-Item Env:VITE_CARECAST_WEBAPP_RELEASE -ErrorAction SilentlyContinue
  Remove-Item Env:VITE_CARECAST_WEBAPP_REVISION -ErrorAction SilentlyContinue
  Remove-Item Env:VITE_CARECAST_WEBAPP_BUILD_TIME -ErrorAction SilentlyContinue
  Pop-Location
} else {
  Write-Host "Skipping local builds (--SkipLocalBuild)." -ForegroundColor Yellow
}

if (-not $SkipApiDeploy) {
  Write-Host "Deploying API to Cloud Run (build + deploy from source)..." -ForegroundColor Cyan
  & "${env:ProgramFiles(x86)}\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd" run deploy $ApiService `
    --project $ProjectId `
    --source ./care-cast-api `
    --region $Region `
    --set-env-vars $envVars `
    --service-account "firebase-adminsdk-fbsvc@carecast-v2.iam.gserviceaccount.com" `
    --no-invoker-iam-check

  if ($LASTEXITCODE -ne 0) {
    throw "Cloud Run API deploy failed."
  }

  Write-Host "Routing Cloud Run traffic to the latest API revision..." -ForegroundColor Cyan
  & "${env:ProgramFiles(x86)}\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd" run services update-traffic $ApiService `
    --project $ProjectId `
    --region $Region `
    --to-latest

  if ($LASTEXITCODE -ne 0) {
    throw "Cloud Run API traffic update failed."
  }

  $apiServiceUrl = (& "${env:ProgramFiles(x86)}\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd" run services describe $ApiService `
    --project $ProjectId `
    --region $Region `
    --format "value(status.url)").Trim()

  if (-not $apiServiceUrl) {
    throw "Could not determine Cloud Run API service URL for deployment verification."
  }

  Assert-ApiDeploymentHealth `
    -ServiceUrl $apiServiceUrl `
    -ExpectedRelease $ApiRelease `
    -ExpectedRevision $apiRevision
} else {
  Write-Host "Skipping API deploy (--SkipApiDeploy)." -ForegroundColor Yellow
}

if (-not $SkipWebDeploy) {
  Write-Host "Deploying webapp to Firebase Hosting..." -ForegroundColor Cyan

  # Auth uses firebase CLI cached credentials from 'firebase login'.
  # If this fails with an auth error, run: firebase logout && firebase login
  # Deploy from the repo root using the "app" target defined in firebase.json + .firebaserc.
  # Do NOT cd into care-cast-webapp — that firebase.json has no target/site field and
  # conflicts with the root .firebaserc, causing "Assertion failed: resolving hosting target".
  firebase deploy --only hosting:app --project $ProjectId
  if ($LASTEXITCODE -ne 0) {
    throw "Firebase hosting deploy failed."
  }
} else {
  Write-Host "Skipping webapp deploy (--SkipWebDeploy)." -ForegroundColor Yellow
}

Write-Host "Done. Verify: $WebAppUrl" -ForegroundColor Green

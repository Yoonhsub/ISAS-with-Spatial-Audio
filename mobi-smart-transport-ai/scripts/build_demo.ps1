param(
  [Parameter(Mandatory=$true)][ValidateSet('passenger','driver')][string]$App,
  [Parameter(Mandatory=$true)][string]$DefinesFile,
  [Parameter(Mandatory=$true)][string]$Output,
  [string]$Flutter='flutter',
  [string]$BackendUrl='https://mobi-api-882602390759.asia-northeast3.run.app',
  [string]$ProjectId='mobi-smart-transport'
)
$ErrorActionPreference='Stop'
$version = & $Flutter --version --machine | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $version.frameworkVersion -ne '3.41.9') {throw 'Use Flutter 3.41.9 for the checked Android/Gradle toolchain'}
$repoRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$definesPath=(Resolve-Path -LiteralPath $DefinesFile).Path
$config=Get-Content -LiteralPath $definesPath -Raw | ConvertFrom-Json
foreach ($key in @('MOBI_FIREBASE_API_KEY','MOBI_FIREBASE_APP_ID','MOBI_FIREBASE_MESSAGING_SENDER_ID','MOBI_FIREBASE_PROJECT_ID')) {
  if (-not $config.$key -or $config.$key -match '[<>]') {throw "Missing Firebase app setting: $key"}
}
if ($config.MOBI_FIREBASE_PROJECT_ID -ne $ProjectId) {throw 'Both apps must use the same Firebase project'}
if ($config.MOBI_API_BASE_URL -and $config.MOBI_API_BASE_URL -ne $BackendUrl) {throw 'Backend URL mismatch'}
if ($BackendUrl -notmatch '^https://[^/]+/?$') {throw 'Use an HTTPS backend origin'}
if ($App -eq 'passenger' -and $config.MOBI_FIREBASE_APP_ID -notmatch '^1:[0-9]+:android:') {throw 'Passenger needs the registered Android app ID'}
if ($App -eq 'driver' -and ($config.MOBI_FIREBASE_APP_ID -notmatch '^1:[0-9]+:web:' -or -not $config.MOBI_FIREBASE_AUTH_DOMAIN)) {throw 'Driver needs the registered web app configuration'}
$allowed=@('MOBI_API_BASE_URL','MOBI_FIREBASE_API_KEY','MOBI_FIREBASE_APP_ID','MOBI_FIREBASE_MESSAGING_SENDER_ID','MOBI_FIREBASE_PROJECT_ID','MOBI_FIREBASE_AUTH_DOMAIN')
foreach ($name in $config.PSObject.Properties.Name) {
  if ($name -notin $allowed) {throw "Unexpected build setting: $name"}
}
$destination=[IO.Path]::GetFullPath($Output)
New-Item -ItemType Directory -Force -Path $destination | Out-Null
$arguments=@('build',$(if($App -eq 'driver'){'web'}else{'apk'}),'--release',
  '--target=lib/main.dart',"--dart-define-from-file=$definesPath","--dart-define=MOBI_API_BASE_URL=$BackendUrl")
if ($App -eq 'driver') {$arguments += "--output=$destination"}
else {$arguments += '--target-platform=android-arm64'}
Push-Location (Join-Path $repoRoot "apps/${App}_app")
try {
  & $Flutter @arguments
  if ($LASTEXITCODE -ne 0) {throw "$App build failed"}
  if ($App -eq 'passenger') {Copy-Item -LiteralPath 'build/app/outputs/flutter-apk/app-release.apk' -Destination (Join-Path $destination 'MOBI_Finals_승객.apk')}
} finally {Pop-Location}
Write-Output "$App build prepared: $destination"

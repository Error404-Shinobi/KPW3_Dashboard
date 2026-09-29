# Upload the project to the Linux server with scp.
# No bash required - uses the OpenSSH client built into Windows.
#
#   .\deploy.ps1 -Server root@1.2.3.4
#   .\deploy.ps1 -Server root@1.2.3.4 -RemoteDir /opt/kindle-dashboard
#
# Deliberately excludes: .venv (huge), .env (secrets stay local), __pycache__, preview.png

param(
    [Parameter(Mandatory = $true)]
    [string]$Server,

    [string]$RemoteDir = "/opt/kindle-dashboard"
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command scp -ErrorAction SilentlyContinue)) {
    Write-Host "scp not found. Install the OpenSSH client:" -ForegroundColor Yellow
    Write-Host "  Settings -> Apps -> Optional features -> Add 'OpenSSH Client'" -ForegroundColor Yellow
    exit 1
}

$src = Split-Path -Parent $MyInvocation.MyCommand.Path

$files = @(
    "server/main.py",
    "server/control.py",
    "server/render.py",
    "server/fontutil.py",
    "server/envutil.py",
    "server/preview_cli.py",
    "server/probe_minimax.py",
    "server/requirements.txt",
    "server/config.yaml",
    "server/.env.example",
    "server/sources/__init__.py",
    "server/sources/weather.py",
    "server/sources/token_usage.py",
    "kindle/dashboard.sh",
    "kindle/exitdash.sh",
    "kindle/stopdash.sh",
    "kindle/runme.sh",
    "kindle/install.sh",
    "deploy_hotfix.sh",
    "deploy_control.sh",
    "tests/test_control_e2e.sh",
    "docs/nginx.md",
    "docs/pitfalls.md",
    "docs/jailbreak.md",
    "docs/hotfix-remaining-percent.md",
    "README.md"
)

Write-Host "Creating remote directories on $Server ..."
ssh $Server "mkdir -p $RemoteDir/server/sources $RemoteDir/kindle $RemoteDir/tests $RemoteDir/docs"

$ok = 0
foreach ($f in $files) {
    $local = Join-Path $src $f
    if (Test-Path $local) {
        scp $local "${Server}:${RemoteDir}/$f" | Out-Null
        $ok++
        Write-Host "  sent $f"
    }
    else {
        Write-Host "  SKIP $f (not found)" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "Uploaded $ok files to ${Server}:${RemoteDir}" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps on the server:"
Write-Host "  ssh $Server"
Write-Host "  cd $RemoteDir/server"
Write-Host "  cp .env.example .env && vi .env          # put your Subscription Key here"
Write-Host "  python3 -m venv .venv"
Write-Host "  .venv/bin/pip install -r requirements.txt"
Write-Host "  sudo apt install fonts-noto-cjk          # no CJK font = tofu boxes"
Write-Host "  .venv/bin/python probe_minimax.py        # verify MiniMax reachability"

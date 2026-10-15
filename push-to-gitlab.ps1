# Pushes the kong-gateway repo to the self-hosted GitLab (find-or-create project, then push).
# All secrets via env vars; nothing is written to disk.
#   $env:GL_URL='http://172.20.1.52:PORT'   # base, no trailing slash
#   $env:GL_TOKEN='glpat-...'               # PAT with api scope (or read+write repo)
#   $env:GL_GROUP='group-name'              # group path/name or numeric id
#   $env:GL_PROJECT='kong-gateway'          # default
#   powershell -ExecutionPolicy Bypass -File push-to-gitlab.ps1
$ErrorActionPreference = 'Stop'
$base    = $env:GL_URL.TrimEnd('/')
$token   = $env:GL_TOKEN
$group   = $env:GL_GROUP
$project = if ($env:GL_PROJECT) { $env:GL_PROJECT } else { 'kong-gateway' }
if (-not $token -or -not $group) { throw 'Set GL_TOKEN and GL_GROUP (and GL_URL) env vars' }

function Gl([string]$method, [string]$path, [object]$body = $null) {
    $uri = "$base/api/v4$path"
    $hdr = @{ 'Authorization' = "Bearer $token" }
    if ($null -ne $body) {
        $json = $body | ConvertTo-Json -Depth 5
        return Invoke-RestMethod -Uri $uri -Method $method -Headers $hdr -Body $json -ContentType 'application/json'
    }
    return Invoke-RestMethod -Uri $uri -Method $method -Headers $hdr
}

$ver = Gl 'GET' '/version'
Write-Host "GitLab $($ver.major).$($ver.minor) reachable at $base"

# resolve group id
if ($group -match '^\d+$') { $gid = [int]$group }
else { $gid = (Gl 'GET' "/groups/$([uri]::EscapeDataString($group))").id }
Write-Host "group id: $gid"

# find or create project
$found = $null
try { $found = (Gl 'GET' "/projects?search=$([uri]::EscapeDataString($project))&per_page=100" |
        Where-Object { $_.path -eq $project -and $_.namespace.id -eq $gid }) | Select-Object -First 1 } catch {}
if ($found) { $p = $found; Write-Host "project exists: $($p.web_url)" }
else {
    $p = Gl 'POST' '/projects' @{ name = $project; path = $project; namespace_id = $gid; visibility = 'private'; default_branch = 'main' }
    Write-Host "created project: $($p.web_url)"
}

# git push over HTTPS (token in URL, transient); then strip creds from stored remote
$hostPath = $p.web_url -replace '^(https?://)', ''   # e.g. group/project
$pushUrl  = "$base/git/oauth2:$token@$hostPath.git"
$repo     = Split-Path -Parent $MyInvocation.MyCommand.Path
Push-Location $repo
try { git remote set-url origin $pushUrl } catch { git remote add origin $pushUrl }
git push -u origin main
$rc = $LASTEXITCODE
# persist a clean, credential-free remote
git remote set-url origin "$base/$hostPath.git"
Pop-Location
if ($rc -eq 0) { Write-Host "PUSHED kong-gateway -> $($p.web_url)" } else { throw "git push failed (rc=$rc)" }

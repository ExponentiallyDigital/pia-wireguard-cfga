<#
.SYNOPSIS
    Upgrades GitHub Actions 'uses:' references to the SHA of their latest release.
.DESCRIPTION
    For each action found in .github/workflows/*.yml:
      1. Looks up the latest release tag via the GitHub API
      2. Resolves that tag to a full commit SHA
      3. Rewrites in-place as:  owner/repo@<sha>  # v<latest>
    Already-pinned SHAs are re-evaluated against the latest release and
    updated if a newer version is available.
    Local './' actions are always skipped.
.PARAMETER WorkflowDir
    Path to the workflows folder. Default: .github/workflows
.PARAMETER Token
    GitHub PAT. Defaults to $env:GITHUB_TOKEN if not supplied.
.PARAMETER WhatIf
    Dry-run — prints changes without writing any files.
.EXAMPLE
    .\pin-actions-latest.ps1 -WhatIf
    .\pin-actions-latest.ps1
    .\pin-actions-latest.ps1 -Token ghp_xxxx
#>
param(
    [string]$WorkflowDir = ".github/workflows",
    [string]$Token       = $env:GITHUB_TOKEN,
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $Token) {
    Write-Warning "No GitHub token found. Set `$env:GITHUB_TOKEN or pass -Token."
}

$headers = @{ "User-Agent" = "pin-actions-latest-ps1" }
if ($Token) { $headers["Authorization"] = "Bearer $Token" }

$latestTagCache = @{}
$shaCache       = @{}

function Get-LatestTag {
    param([string]$Action)
    if ($latestTagCache.ContainsKey($Action)) { return $latestTagCache[$Action] }

    # Try releases/latest first (most actions use proper releases)
    try {
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Action/releases/latest" `
                                 -Headers $headers -ErrorAction Stop
        $latestTagCache[$Action] = $rel.tag_name
        return $rel.tag_name
    } catch {}

    # Fall back to tags list (some actions only publish tags, not releases)
    try {
        $tags = Invoke-RestMethod -Uri "https://api.github.com/repos/$Action/tags?per_page=1" `
                                  -Headers $headers -ErrorAction Stop
        if ($tags.Count -gt 0) {
            $latestTagCache[$Action] = $tags[0].name
            return $tags[0].name
        }
    } catch {}

    Write-Warning "  Could not find any release or tag for $Action — skipping."
    return $null
}

function Get-CommitSha {
    param([string]$Action, [string]$Ref)
    $key = "$Action@$Ref"
    if ($shaCache.ContainsKey($key)) { return $shaCache[$key] }

    try {
        # /commits/{ref} resolves branch names, tags, and tag objects uniformly
        $commit = Invoke-RestMethod -Uri "https://api.github.com/repos/$Action/commits/$Ref" `
                                    -Headers $headers -ErrorAction Stop
        $shaCache[$key] = $commit.sha
        return $commit.sha
    } catch {
        Write-Warning "  Could not resolve SHA for $Action@$Ref — skipping. ($_)"
        return $null
    }
}

$files = Get-ChildItem -Path $WorkflowDir -Filter "*.yml" -File -ErrorAction Stop

foreach ($file in $files) {
    $lines       = Get-Content $file.FullName
    $newLines    = [System.Collections.Generic.List[string]]::new()
    $fileChanged = $false

    foreach ($line in $lines) {
        if ($line -match '^(\s*(?:-\s*)?uses:\s*)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_./-]+)?)@([^\s#]+)(\s*#.*)?$') {
            $prefix = $Matches[1]
            $action = $Matches[2]

            # Skip local reusable workflows
            if ($action -like "./*") {
                $newLines.Add($line)
                continue
            }

            # Split owner/repo from any subpath (e.g. github/codeql-action/upload-sarif)
            $parts = $action -split '/', 3
            $repo  = $parts[0] + '/' + $parts[1]

            $latestTag = Get-LatestTag -Action $repo
            if ($null -eq $latestTag) {
                $newLines.Add($line)
                continue
            }

            $sha = Get-CommitSha -Action $repo -Ref $latestTag
            if ($null -eq $sha) {
                $newLines.Add($line)
                continue
            }

            $newLine = "$prefix$action@$sha  # $latestTag"

            if ($newLine -ne $line) {
                $currentRef = $Matches[3]
                Write-Host ("  {0,-45} {1} -> {2}  ({3})" -f $action, $currentRef, $latestTag, $sha.Substring(0,12) + "...")
                $fileChanged = $true
            }
            $newLines.Add($newLine)
        } else {
            $newLines.Add($line)
        }
    }

    if ($fileChanged) {
        Write-Host "[$($file.Name)]" -ForegroundColor Cyan
        if (-not $WhatIf) {
            $newLines | Set-Content $file.FullName -Encoding UTF8
        }
    }
}

if ($WhatIf) {
    Write-Host "`n[WhatIf] No files were written." -ForegroundColor Yellow
} else {
    Write-Host "`nDone." -ForegroundColor Green
}
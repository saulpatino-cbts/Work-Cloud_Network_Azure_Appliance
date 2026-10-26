[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Repo,

    [string]$Branch = "main",

    [ValidateSet("dev", "prod")]
    [string]$Environment = "dev",

    [string]$SubscriptionId,

    [string]$AppDisplayName,

    [switch]$SkipAzureSetup,

    # Your Azure region. No default on purpose, so no region is ever assumed for
    # you. Pass -BootstrapLocation, or leave it blank and the script will ask.
    # Azure regions: https://learn.microsoft.com/azure/reliability/regions-list
    [string]$BootstrapLocation = "",

    # Short lowercase code for your region (e.g. eus for eastus), used in resource
    # names. No default on purpose. Pass -BootstrapRegionShort, or leave it blank
    # and the script will ask.
    [string]$BootstrapRegionShort = "",

    [string]$ReportDirectory = ".reports/bootstrap",

    [switch]$SkipBootstrapDispatch,

    [switch]$ForceInteractive,

    [System.Security.SecureString]$DockerHubToken
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([string]$Message)
    Write-Host "    [OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "    [!] $Message" -ForegroundColor Yellow
}

function Write-Info {
    param([string]$Message)
    Write-Host "    [INFO] $Message" -ForegroundColor DarkCyan
}

function Assert-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "$Name CLI not found. Install it and rerun this script."
    }
}

function ConvertFrom-SecureStringToPlainText {
    param([System.Security.SecureString]$Value)
    if (-not $Value -or $Value.Length -eq 0) { return "" }
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

function Read-MaskedSecretValue {
    param(
        [string]$Prompt,
        [switch]$Required
    )

    while ($true) {
        if ((Get-Command Read-Host).Parameters.ContainsKey("MaskInput")) {
            $plain = Read-Host $Prompt -MaskInput
            if (-not [string]::IsNullOrWhiteSpace($plain)) {
                return ConvertTo-SecureString -String $plain -AsPlainText -Force
            }
        } else {
            $secure = Read-Host $Prompt -AsSecureString
            if ($secure -and $secure.Length -gt 0) {
                return $secure
            }
        }

        if (-not $Required) {
            return $null
        }
        Write-Warn "$Prompt is required."
    }
}

function Initialize-AzLogin {
    [CmdletBinding()]
    param()

    Write-Step "Checking Azure CLI session"
    $account = Invoke-AzJson -Arguments @("account", "show")
    if ($account) {
        Write-Ok "Azure CLI is already signed in as $($account.name) ($($account.id))"
        return $account
    }

    Write-Warn "Azure CLI is not currently signed in. Starting interactive login..."
    & az login --use-device-code
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI login failed. Re-run the script after signing in."
    }

    $account = Invoke-AzJson -Arguments @("account", "show")
    if (-not $account) {
        throw "Azure CLI login completed but no account context is available yet."
    }

    return $account
}

function Select-AzSubscription {
    [CmdletBinding()]
    param([object]$CurrentAccount)

    $accounts = Invoke-AzJson -Arguments @("account", "list")
    if (-not $accounts -or $accounts.Count -eq 0) {
        throw "No Azure subscriptions are available. Sign in with az login first."
    }

    if ($SubscriptionId) {
        $selected = $accounts | Where-Object { $_.id -eq $SubscriptionId -or $_.name -eq $SubscriptionId } | Select-Object -First 1
        if ($selected) {
            Write-Ok "Using requested subscription: $($selected.name) ($($selected.id))"
            return $selected
        }
        throw "Requested subscription '$SubscriptionId' was not found in the current Azure account context."
    }

    if ($accounts.Count -eq 1) {
        $selected = $accounts[0]
        Write-Ok "Using the only available subscription: $($selected.name) ($($selected.id))"
        return $selected
    }

    $selected = $null
    if ($CurrentAccount -and $CurrentAccount.id) {
        $selected = $accounts | Where-Object { $_.id -eq $CurrentAccount.id } | Select-Object -First 1
    }
    if (-not $selected) {
        $selected = $accounts | Where-Object { $_.isDefault -eq $true } | Select-Object -First 1
    }
    if (-not $selected) {
        $selected = $accounts[0]
    }

    Write-Host "Available Azure subscriptions:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $accounts.Count; $i++) {
        $a = $accounts[$i]
        $marker = if ($selected -and $a.id -eq $selected.id) { " [default]" } else { "" }
        Write-Host "  [$i] $($a.name) ($($a.id))  tenant=$($a.tenantId)$marker"
    }

    while ($true) {
        $defaultLabel = if ($selected) { "$($selected.name) / $($selected.id)" } else { "none" }
        $choice = Read-Host "Select a subscription by number, or type the subscription ID/name (default: $defaultLabel)"
        if ([string]::IsNullOrWhiteSpace($choice) -and $selected) {
            return $selected
        }

        $selected = $accounts | Where-Object { $_.id -eq $choice -or $_.name -eq $choice }
        if ($selected) {
            return $selected[0]
        }

        if ($choice -match '^\d+$' -and [int]$choice -ge 0 -and [int]$choice -lt $accounts.Count) {
            return $accounts[[int]$choice]
        }

        Write-Warn "That selection was not found. Enter a number or the exact subscription ID/name."
    }
}

function New-RandomBase64 {
    param([int]$Bytes = 32)
    $buffer = New-Object byte[] $Bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($buffer)
        return [Convert]::ToBase64String($buffer)
    } finally {
        $rng.Dispose()
    }
}

# Break-glass local admin password hashing. PBKDF2-HMAC-SHA256 via .NET's
# built-in Rfc2898DeriveBytes — no external module needed, and the exact same
# algorithm/params are reproduced in apps/cna-web/lib/local-admin.ts (Node's
# crypto.pbkdf2Sync) so the two sides agree on the stored hash format without
# sharing code. Format: "pbkdf2$sha256$210000$<saltBase64>$<hashBase64>".
function ConvertTo-Pbkdf2Hash {
    param([Parameter(Mandatory = $true)][string]$PlainText)

    $iterations = 210000
    $saltBytes = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($saltBytes)
    } finally {
        $rng.Dispose()
    }

    $deriveBytes = [System.Security.Cryptography.Rfc2898DeriveBytes]::new(
        $PlainText,
        $saltBytes,
        $iterations,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256
    )
    try {
        $hashBytes = $deriveBytes.GetBytes(32)
    } finally {
        $deriveBytes.Dispose()
    }

    $saltB64 = [Convert]::ToBase64String($saltBytes)
    $hashB64 = [Convert]::ToBase64String($hashBytes)
    return "pbkdf2`$sha256`$$iterations`$$saltB64`$$hashB64"
}

function Format-ValuePreview {
    param(
        [string]$Value,
        [int]$KeepTail = 5
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return "(empty)"
    }

    if ($Value.Length -le 10) {
        return $Value
    }

    $tail = [Math]::Min($KeepTail, $Value.Length)
    return ("*" * ($Value.Length - $tail)) + $Value.Substring($Value.Length - $tail)
}

function Read-TextValue {
    param(
        [string]$Name,
        [string]$Prompt,
        [string]$Default = "",
        [switch]$Required
    )

    $preview = if ($Default -ne "") { " [current: $(Format-ValuePreview -Value $Default)]" } else { "" }
    $label = "$Prompt$preview"
    while ($true) {
        $value = Read-Host $label
        if ([string]::IsNullOrWhiteSpace($value)) {
            if (-not [string]::IsNullOrWhiteSpace($Default)) {
                return $Default.Trim()
            }
            $value = $Default
        }
        if (-not $Required -or -not [string]::IsNullOrWhiteSpace($value)) {
            return $value.Trim()
        }
        Write-Warn "$Name is required."
    }
}

function Read-YesNo {
    param(
        [string]$Prompt,
        [bool]$DefaultYes = $false
    )

    $suffix = if ($DefaultYes) { " [Y/n]" } else { " [y/N]" }
    while ($true) {
        $answer = Read-Host "$Prompt$suffix"
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $DefaultYes
        }

        switch -Regex ($answer.Trim()) {
            '^(y|yes)$' { return $true }
            '^(n|no)$' { return $false }
            default { Write-Warn "Enter yes or no." }
        }
    }
}

function Read-SecretValue {
    [CmdletBinding()]
    param(
        [string]$Name,
        [string]$Description,
        [bool]$Exists,
        [int]$GenerateBytes = 0,
        [switch]$Required
    )

    if ($Exists) {
        return $null
    }

    if ($GenerateBytes -gt 0) {
        return New-RandomBase64 -Bytes $GenerateBytes
    }

    if (-not $Required) {
        return $null
    }

    while ($true) {
        $secure = Read-Host "Paste value for $Name" -AsSecureString
        $plain = ConvertFrom-SecureStringToPlainText -Value $secure
        if (-not [string]::IsNullOrWhiteSpace($plain) -or -not $Required) {
            return $plain
        }
        Write-Warn "$Name is required."
    }
}

function Invoke-Gh {
    param([string[]]$Arguments)
    & gh @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "gh $($Arguments -join ' ') failed."
    }
}

function Start-GitHubWorkflow {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$RepoName,
        [string]$Workflow,
        [string]$Ref = "main",
        [hashtable]$Inputs = @{}
    )

    $workflowArgs = @("workflow", "run", $Workflow, "--repo", $RepoName, "--ref", $Ref)
    foreach ($entry in $Inputs.GetEnumerator()) {
        $workflowArgs += @("-f", "$($entry.Key)=$($entry.Value)")
    }

    if ($PSCmdlet.ShouldProcess($RepoName, "dispatch workflow $Workflow")) {
        Invoke-Gh -Arguments $workflowArgs
    }
}

function Get-GitHubWorkflowState {
    param(
        [string]$RepoName,
        [string]$Workflow
    )

    $workflowId = & gh api "repos/$RepoName/actions/workflows/$Workflow" --jq .id 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($workflowId)) {
        return ""
    }

    $listOutput = & gh workflow list --repo $RepoName --all 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($listOutput)) {
        return ""
    }

    foreach ($line in @($listOutput -split "`r?`n")) {
        $columns = @($line -split "`t")
        if ($columns.Count -ge 3 -and $columns[2] -eq [string]$workflowId) {
            return [string]$columns[1]
        }
    }

    return ""
}

function Enable-GitHubWorkflowIfDisabled {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$RepoName,
        [string]$Workflow
    )

    $state = Get-GitHubWorkflowState -RepoName $RepoName -Workflow $Workflow
    if ($state -eq "active") {
        Write-Ok "Workflow is active: $Workflow"
        return $true
    }

    if ($state -ne "disabled_manually") {
        Write-Warn "Workflow $Workflow state is '$state'; attempting enable before dispatch."
    } else {
        Write-Warn "Workflow $Workflow is disabled; enabling it so bootstrap can be dispatched."
    }

    if ($PSCmdlet.ShouldProcess($RepoName, "enable workflow $Workflow")) {
        & gh workflow enable $Workflow --repo $RepoName
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Failed to enable workflow $Workflow."
            return $false
        }
    }

    $state = Get-GitHubWorkflowState -RepoName $RepoName -Workflow $Workflow
    if ($state -eq "active") {
        Write-Ok "Enabled workflow: $Workflow"
        return $true
    }

    Write-Warn "Workflow $Workflow is still not active; current state: '$state'."
    return $false
}

function Test-DockerHubCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Namespace,

        [Parameter(Mandatory = $true)]
        [string]$Token
    )

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Warn "Docker CLI not found; skipping local Docker Hub login validation. Workflow 100 will validate DOCKERHUB_NAMESPACE and DOCKERHUB_TOKEN."
        return
    }

    $Token | docker login docker.io --username $Namespace --password-stdin 1>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Docker Hub credential validation failed for namespace '$Namespace'. Provide an organization access token with repository read/write access."
    }

    docker logout docker.io 1>$null 2>$null
    Write-Ok "Docker Hub credentials validated for namespace $Namespace"
}

function Read-DockerHubSecretValues {
    [CmdletBinding()]
    param(
        [string]$Namespace,
        [bool]$TokenExists
    )

    if ($TokenExists -and -not $ForceInteractive) {
        Write-Info "Keeping existing DOCKERHUB_TOKEN secret"
        return @{
            Token = $null
        }
    }

    if ([string]::IsNullOrWhiteSpace($Namespace)) {
        throw "DOCKERHUB_NAMESPACE is required before Docker Hub token setup."
    }

    Write-Info "DOCKERHUB_NAMESPACE is used for Docker Hub authentication and image paths."
    Write-Info "Only DOCKERHUB_TOKEN is saved to GitHub Secrets; DOCKERHUB_NAMESPACE is saved as a GitHub Variable."
    Write-Info "Provide an organization access token with read/write access using -DockerHubToken or paste it when prompted."

    $tokenValue = ConvertFrom-SecureStringToPlainText -Value $DockerHubToken
    if ([string]::IsNullOrWhiteSpace($tokenValue)) {
        $secureToken = Read-MaskedSecretValue -Prompt "Paste Docker Hub organization access token for DOCKERHUB_TOKEN" -Required

        if ($null -eq $secureToken) {
            throw "Docker Hub organization access token is required."
        }

        $tokenValue = ConvertFrom-SecureStringToPlainText -Value $secureToken
    } else {
        Write-Info "Using supplied Docker Hub token for DOCKERHUB_TOKEN"
    }

    if ([string]::IsNullOrWhiteSpace($tokenValue)) {
        throw "DOCKERHUB_TOKEN is required."
    }

    Test-DockerHubCredential -Namespace $Namespace -Token $tokenValue

    return @{
        Token = $tokenValue
    }
}

function Read-DockerHubNamespace {
    [CmdletBinding()]
    param(
        [string]$ExistingValue
    )

    return Get-DesiredTextValue `
        -Name "DOCKERHUB_NAMESPACE" `
        -ExistingValue $ExistingValue `
        -DefaultValue "" `
        -PromptIfMissing
}

function Get-DesiredTextValue {
    [CmdletBinding()]
    param(
        [string]$Name,
        [string]$ExistingValue,
        [string]$DefaultValue = "",
        [switch]$PromptIfMissing
    )

    if (-not [string]::IsNullOrWhiteSpace($ExistingValue)) {
        Write-Info "Keeping existing $Name = $ExistingValue"
        return $ExistingValue.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($DefaultValue)) {
        Write-Info "Using derived $Name = $DefaultValue"
        return $DefaultValue.Trim()
    }

    if ($PromptIfMissing) {
        return Read-TextValue -Name $Name -Prompt $Name -Required
    }

    return ""
}

function Invoke-AzJson {
    param([string[]]$Arguments)
    $json = & az @Arguments -o json 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
        return $null
    }
    return $json | ConvertFrom-Json
}

function Set-GitHubSecret {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$Name,
        [string]$Value,
        [string]$RepoName,
        # When set, writes an environment-scoped secret (gh secret set --env <name>)
        # instead of a repository-level secret. Used so per-environment deploy SPs
        # supply a different AZURE_CLIENT_ID in the dev/prod/hub GitHub environments.
        [string]$EnvironmentName = ""
    )
    if ($null -eq $Value) { return $false }
    $scopeLabel = if ([string]::IsNullOrWhiteSpace($EnvironmentName)) { "repo" } else { "env:$EnvironmentName" }
    if ($PSCmdlet.ShouldProcess("$RepoName ($scopeLabel)", "set GitHub secret $Name")) {
        if ([string]::IsNullOrWhiteSpace($EnvironmentName)) {
            $Value | gh secret set $Name --repo $RepoName | Out-Null
        } else {
            $Value | gh secret set $Name --repo $RepoName --env $EnvironmentName | Out-Null
        }
        if ($LASTEXITCODE -ne 0) { throw "Failed to set GitHub secret $Name ($scopeLabel)." }
    }
    return $true
}

function Remove-GitHubSecretIfExists {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$Name,
        [string]$RepoName,
        [hashtable]$ExistingSecrets
    )

    if (-not $ExistingSecrets.ContainsKey($Name)) {
        return $false
    }

    if ($PSCmdlet.ShouldProcess($RepoName, "delete legacy GitHub secret $Name")) {
        & gh secret delete $Name --repo $RepoName
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to delete legacy GitHub secret $Name."
        }
    }

    Write-Ok "Deleted legacy GitHub secret: $Name"
    return $true
}

function Set-GitHubVariable {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$Name,
        [string]$Value,
        [string]$RepoName
    )
    if ($null -eq $Value) { return $false }
    if ($PSCmdlet.ShouldProcess($RepoName, "set GitHub variable $Name")) {
        Invoke-Gh -Arguments @("variable", "set", $Name, "--repo", $RepoName, "--body", $Value)
    }
    return $true
}

function New-GitHubAppViaManifest {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$AppName,
        [string]$RepoName,
        [string]$HomepageUrl,
        [int[]]$TryPorts = @(3000, 3001, 3002, 8080, 8081)
    )

    $port = $null
    foreach ($candidatePort in $TryPorts) {
        try {
            $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $candidatePort)
            $listener.Start()
            $listener.Stop()
            $port = $candidatePort
            break
        } catch {
            continue
        }
    }

    if (-not $port) {
        throw "No available local port in [$($TryPorts -join ', ')]. Free a port and retry."
    }

    $callbackUrl = "http://localhost:$port/callback"
    $state = [System.Guid]::NewGuid().ToString("N")

    $manifestObj = [ordered]@{
        name = $AppName
        url = $HomepageUrl
        redirect_url = $callbackUrl
        public = $false
        default_permissions = [ordered]@{
            contents = "read"
            metadata = "read"
            actions = "write"
            actions_variables = "write"
            # Required for github_actions_environment_variable (POST
            # /repos/{owner}/{repo}/environments/{env}/variables) — separate
            # from actions_variables, which only covers repo-scoped variables.
            # Missing this causes "403 Resource not accessible by integration"
            # on environment-scoped Terraform variable writes (dev/prod
            # workload main.tf).
            environments = "write"
        }
        default_events = @()
    }

    $manifestJson = $manifestObj | ConvertTo-Json -Compress -Depth 5
    $manifestHtmlSafe = $manifestJson -replace '&','&amp;' -replace '"','&quot;'

    $launchHtml = @"
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>Creating CNA App...</title></head>
<body style="font-family:sans-serif;padding:2em;background:#0d1117;color:#e6edf3">
  <h2 style="color:#58a6ff">Creating GitHub App: $AppName</h2>
  <p>Submitting the app manifest to GitHub. A pre-filled creation form will open next.</p>
  <p style="color:#8b949e">Click <strong style="color:#3fb950">Create GitHub App</strong> on the GitHub page to continue.</p>
  <form id="f" action="https://github.com/settings/apps/new" method="post">
    <input type="hidden" name="state" value="$state" />
    <input type="hidden" name="manifest" value="$manifestHtmlSafe" />
  </form>
  <script>document.getElementById('f').submit();</script>
</body>
</html>
"@

    $successHtml = @"
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><title>CNA App Created</title></head>
<body style="font-family:sans-serif;padding:2em;background:#0d1117;color:#e6edf3">
  <h2 style="color:#3fb950">&#x2705; $AppName created successfully</h2>
  <p>You can close this tab and return to the terminal.</p>
</body>
</html>
"@

    $http = [System.Net.HttpListener]::new()
    $http.Prefixes.Add("http://localhost:$port/")
    $http.Start()

    Write-Host ""
    Write-Host "  Opening browser for GitHub App creation." -ForegroundColor Cyan
    Write-Host "  App name    : $AppName" -ForegroundColor White
    Write-Host "  Permissions : Contents(read) · Metadata(read) · Actions(write) · Variables(write) · Environments(write)" -ForegroundColor White
    # NOTE: "Variables" maps to the GitHub App manifest permission key 'actions_variables', not 'variables'.
    Write-Host "  Repo scope  : $RepoName" -ForegroundColor White
    Write-Host ""
    Write-Host "  What you will see in the browser:" -ForegroundColor White
    Write-Host "    • A pre-filled 'Register new GitHub App' form on github.com" -ForegroundColor DarkGray
    Write-Host "    • Click the green 'Create GitHub App' button to continue" -ForegroundColor DarkGray
    Write-Host "    • The script captures the app credentials automatically after creation" -ForegroundColor DarkGray
    Write-Host ""

    if (-not $PSCmdlet.ShouldProcess($AppName, "open browser for GitHub App manifest flow")) {
        $http.Stop()
        Write-Warn "WhatIf: would serve manifest form on http://localhost:$port/ and open browser"
        return $null
    }

    Start-Process "http://localhost:$port/"
    Write-Host "  Waiting for GitHub callback on port $port (3-minute timeout)..." -ForegroundColor DarkGray

    $callbackData = [hashtable]::Synchronized(@{ Code = $null; State = $null; Error = $null })
    $launchHtmlCopy = $launchHtml
    $successHtmlCopy = $successHtml

    $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable('http', $http)
    $runspace.SessionStateProxy.SetVariable('callbackData', $callbackData)
    $runspace.SessionStateProxy.SetVariable('launchHtml', $launchHtmlCopy)
    $runspace.SessionStateProxy.SetVariable('successHtml', $successHtmlCopy)

    $powerShell = [System.Management.Automation.PowerShell]::Create()
    $powerShell.Runspace = $runspace
    $null = $powerShell.AddScript({
        function Send-Html {
            param($ctx, $body, [int]$status = 200)
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
            $ctx.Response.StatusCode = $status
            $ctx.Response.ContentType = 'text/html; charset=utf-8'
            $ctx.Response.ContentLength64 = $bytes.Length
            $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
            $ctx.Response.OutputStream.Close()
        }

        try {
            while ($true) {
                $ctx = $http.GetContext()
                $path = $ctx.Request.Url.AbsolutePath

                if ($path -eq '/') {
                    Send-Html $ctx $launchHtml
                    continue
                }

                if ($path -eq '/callback') {
                    $queryValues = @{}
                    foreach ($pair in (($ctx.Request.Url.Query.TrimStart('?')) -split '&')) {
                        if ([string]::IsNullOrWhiteSpace($pair)) { continue }
                        $kv = $pair -split '=', 2
                        $key = [Uri]::UnescapeDataString($kv[0])
                        $value = if ($kv.Count -gt 1) { [Uri]::UnescapeDataString($kv[1]) } else { "" }
                        $queryValues[$key] = $value
                    }
                    $callbackData.Code = $queryValues['code']
                    $callbackData.State = $queryValues['state']
                    Send-Html $ctx $successHtml
                    break
                }

                $ctx.Response.StatusCode = 404
                $ctx.Response.Close()
            }
        } catch {
            $callbackData.Error = $_.Exception.Message
        }
    })

    $handle = $powerShell.BeginInvoke()
    $deadline = [DateTime]::UtcNow.AddMinutes(3)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($handle.IsCompleted -or $null -ne $callbackData.Code) {
            break
        }
        Start-Sleep -Milliseconds 300
    }

    $http.Stop()
    $powerShell.Dispose()
    $runspace.Close()

    if ($callbackData.Error) {
        throw "Listener error: $($callbackData.Error)"
    }

    $code = $callbackData.Code
    $retState = $callbackData.State
    if ([string]::IsNullOrWhiteSpace($code)) {
        throw "No callback code received within 3 minutes. Re-run the script and click 'Create GitHub App' promptly."
    }
    if ($retState -ne $state) {
        throw "State mismatch in GitHub callback. Re-run the script."
    }

    Write-Step "Exchanging code for GitHub App credentials"
    $responseJson = & gh api `
        -X POST `
        "app-manifests/$code/conversions" `
        -H "Accept: application/vnd.github+json" `
        -H "X-GitHub-Api-Version: 2022-11-28"
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($responseJson)) {
        throw "GitHub App manifest conversion failed. Ensure 'gh auth login' has been completed for an account that can create GitHub Apps."
    }
    $response = $responseJson | ConvertFrom-Json

    if (-not $response.id -or -not $response.pem) {
        throw "GitHub API did not return App ID or PEM key. Response: $($response | ConvertTo-Json -Depth 3)"
    }

    Write-Ok "GitHub App created: $($response.name) (ID: $([string]$response.id))"
    return [pscustomobject]@{
        AppId = [string]$response.id
        PrivateKey = [string]$response.pem
        Name = [string]$response.name
        Slug = [string]$response.slug
    }
}

function Get-GitHubAppInstallationByName {
    param(
        [string]$AppName,
        [string]$AppSlug
    )

    $json = & gh api "user/installations" --paginate 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
        return $null
    }

    $installations = @($json | ConvertFrom-Json)
    foreach ($installation in $installations) {
        foreach ($item in @($installation.installations)) {
            $matchesName = -not [string]::IsNullOrWhiteSpace($AppName) -and $item.app_slug -eq ($AppName.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
            $matchesSlug = -not [string]::IsNullOrWhiteSpace($AppSlug) -and $item.app_slug -eq $AppSlug
            if ($matchesName -or $matchesSlug) {
                return [pscustomobject]@{
                    AppId          = [string]$item.app_id
                    AppSlug        = [string]$item.app_slug
                    InstallationId = [string]$item.id
                }
            }
        }
    }

    return $null
}

function Get-GitHubAppInstallationId {
    param(
        [string]$AppId,
        [string]$RepoName
    )

    if (-not [string]::IsNullOrWhiteSpace($RepoName)) {
        $repoInstallId = & gh api "repos/$RepoName/installation" --jq "select(.app_id == $AppId) | .id" 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($repoInstallId)) {
            return [string]$repoInstallId.Trim()
        }
    }

    $installId = & gh api "user/installations" --jq ".installations[] | select(.app_id == $AppId) | .id" 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($installId)) {
        return $null
    }

    return [string]$installId.Trim()
}

function ConvertTo-Base64Url {
    param([byte[]]$Bytes)

    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-GitHubAppJwt {
    param(
        [string]$AppId,
        [string]$PemText
    )

    $now = [DateTimeOffset]::UtcNow
    $header = @{ alg = "RS256"; typ = "JWT" } | ConvertTo-Json -Compress
    $payload = @{
        iat = $now.AddSeconds(-60).ToUnixTimeSeconds()
        exp = $now.AddMinutes(9).ToUnixTimeSeconds()
        iss = $AppId
    } | ConvertTo-Json -Compress

    $encodedHeader = ConvertTo-Base64Url -Bytes ([System.Text.Encoding]::UTF8.GetBytes($header))
    $encodedPayload = ConvertTo-Base64Url -Bytes ([System.Text.Encoding]::UTF8.GetBytes($payload))
    $unsignedToken = "$encodedHeader.$encodedPayload"

    $rsa = [System.Security.Cryptography.RSA]::Create()
    try {
        $rsa.ImportFromPem($PemText)
        $signature = $rsa.SignData(
            [System.Text.Encoding]::UTF8.GetBytes($unsignedToken),
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
        )
    } finally {
        $rsa.Dispose()
    }

    return "$unsignedToken.$(ConvertTo-Base64Url -Bytes $signature)"
}

function Get-GitHubAppRepositoryInstallationId {
    param(
        [string]$AppId,
        [string]$PemText,
        [string]$RepoName
    )

    if ([string]::IsNullOrWhiteSpace($PemText)) {
        return $null
    }

    try {
        $jwt = New-GitHubAppJwt -AppId $AppId -PemText $PemText
        $response = Invoke-RestMethod `
            -Uri "https://api.github.com/repos/$RepoName/installation" `
            -Method Get `
            -Headers @{
                Authorization = "Bearer $jwt"
                Accept = "application/vnd.github+json"
                "X-GitHub-Api-Version" = "2022-11-28"
            }
        if ($response.app_id -eq [int64]$AppId -and $response.id) {
            return [string]$response.id
        }
    } catch {
        return $null
    }

    return $null
}

function Wait-GitHubAppInstallation {
    [CmdletBinding()]
    param(
        [string]$AppId,
        [string]$AppSlug,
        [string]$RepoName,
        [string]$PemText,
        [int]$TimeoutMinutes = 3
    )

    $installUrl = "https://github.com/apps/$AppSlug/installations/new"
    Write-Step "Installing GitHub App on repository"
    Write-Host "  Opening browser for GitHub App installation." -ForegroundColor Cyan
    Write-Host "  Repo scope  : $RepoName" -ForegroundColor White
    Write-Host "  Install URL : $installUrl" -ForegroundColor White
    Write-Host "  Select 'Only select repositories' and choose this repo only." -ForegroundColor Yellow
    Write-Host "  The script will confirm installation using the GitHub App private key captured during creation." -ForegroundColor DarkGray
    Write-Host ""
    Start-Process $installUrl

    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    while ([DateTime]::UtcNow -lt $deadline) {
        $installId = Get-GitHubAppRepositoryInstallationId -AppId $AppId -PemText $PemText -RepoName $RepoName
        if ([string]::IsNullOrWhiteSpace($installId)) {
            $installId = Get-GitHubAppInstallationId -AppId $AppId -RepoName $RepoName
        }
        if (-not [string]::IsNullOrWhiteSpace($installId)) {
            Write-Ok "GitHub App installation confirmed: $installId"
            return $installId
        }
        Start-Sleep -Seconds 5
    }

    throw "GitHub App installation was not confirmed within $TimeoutMinutes minutes. Re-run the script after installing it on the repository."
}

function Get-ExistingGitHubSecretNames {
    param([string]$RepoName)
    $names = @{}
    $json = & gh secret list --repo $RepoName --json name 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) { return $names }
    foreach ($item in ($json | ConvertFrom-Json)) {
        $names[$item.name] = $true
    }
    return $names
}

function Get-ExistingGitHubVariableValues {
    param([string]$RepoName)
    $values = @{}
    $json = & gh variable list --repo $RepoName --json name,value 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) { return $values }
    foreach ($item in ($json | ConvertFrom-Json)) {
        $values[$item.name] = [string]$item.value
    }
    return $values
}

function Get-SafeFederatedCredentialName {
    param([string]$RepoName, [string]$Label)
    $name = "cna-$($RepoName -replace '[^A-Za-z0-9-]', '-')-$($Label -replace '[^A-Za-z0-9-]', '-')"
    if ($name.Length -gt 120) {
        return $name.Substring(0, 120)
    }
    return $name
}

function Get-GitHubEnvironments {
    param([string]$RepoName)

    $json = & gh api "repos/$RepoName/environments" --jq '.environments[].name' 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) {
        return @()
    }

    return @($json -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
}

function Confirm-GitHubEnvironment {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$RepoName,
        [string]$EnvironmentName,
        # When set, configure the environment with a required-reviewer protection
        # rule (manual approval gate). Used for the 'hub' environment that gates
        # the prod apply job in workflow 211. Reviewers are GitHub login names
        # (users); they are resolved to numeric IDs via the API.
        [string[]]$RequiredReviewers = @()
    )

    $existingEnvironments = Get-GitHubEnvironments -RepoName $RepoName
    $alreadyExists = $existingEnvironments -contains $EnvironmentName

    # Build the PUT body. A bare PUT (no body) creates an unprotected environment;
    # supplying reviewers adds a required-reviewer gate. PUT is idempotent, so we
    # re-apply the protection even if the environment already exists.
    if ($RequiredReviewers.Count -gt 0) {
        $reviewerObjects = @()
        foreach ($login in $RequiredReviewers) {
            $userId = (& gh api "users/$login" --jq '.id' 2>$null)
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($userId)) {
                Write-Warn "Could not resolve reviewer '$login' to a user id; skipping that reviewer."
                continue
            }
            $reviewerObjects += @{ type = "User"; id = [int]$userId }
        }
        if ($reviewerObjects.Count -eq 0) {
            throw "No required reviewers could be resolved for environment '$EnvironmentName'. Provide valid GitHub logins."
        }
        $body = @{ reviewers = $reviewerObjects } | ConvertTo-Json -Depth 5 -Compress

        if ($PSCmdlet.ShouldProcess($RepoName, "configure GitHub environment $EnvironmentName with required reviewers")) {
            $bodyFile = [System.IO.Path]::GetTempFileName()
            try {
                Set-Content -Path $bodyFile -Value $body -Encoding UTF8
                # Don't use Invoke-Gh here: required-reviewer protection rules are a
                # plan/repo-type-gated feature. On a private user-owned repo (even
                # GitHub Pro), GitHub rejects the rule with HTTP 422. Capture the
                # call instead of throwing so we can degrade to an unprotected
                # environment rather than aborting the whole bootstrap.
                $putOutput = & gh api -X PUT "repos/$RepoName/environments/$EnvironmentName" --input $bodyFile 2>&1
                $putExit = $LASTEXITCODE
            }
            finally {
                Remove-Item -Path $bodyFile -Force -ErrorAction SilentlyContinue
            }

            if ($putExit -ne 0) {
                $putText = ($putOutput | Out-String)
                if ($putText -match '422' -or $putText -match 'billing plan' -or $putText -match 'protection rule') {
                    Write-Warn "GitHub refused the required-reviewer protection rule for '$EnvironmentName' (HTTP 422)."
                    Write-Warn "Required reviewers need GitHub Team/Enterprise or a public repo; GitHub Pro does not enable them on a private personal repo."
                    Write-Warn "Falling back to creating '$EnvironmentName' WITHOUT an approval gate. The prod apply job will NOT pause for manual approval until the repo is moved to a Team org or made public."
                    if ($PSCmdlet.ShouldProcess($RepoName, "create GitHub environment $EnvironmentName (unprotected fallback)")) {
                        Invoke-Gh -Arguments @("api", "-X", "PUT", "repos/$RepoName/environments/$EnvironmentName") | Out-Null
                    }
                    Write-Ok "Created GitHub environment (unprotected): $EnvironmentName"
                    return (-not $alreadyExists)
                }
                throw "Failed to configure environment '$EnvironmentName' with required reviewers: $putText"
            }
        }
        Write-Ok "Configured GitHub environment with required reviewers: $EnvironmentName"
        return (-not $alreadyExists)
    }

    if ($alreadyExists) {
        Write-Ok "GitHub environment exists: $EnvironmentName"
        return $false
    }

    if ($PSCmdlet.ShouldProcess($RepoName, "create GitHub environment $EnvironmentName")) {
        Invoke-Gh -Arguments @("api", "-X", "PUT", "repos/$RepoName/environments/$EnvironmentName") | Out-Null
    }
    Write-Ok "Created GitHub environment: $EnvironmentName"
    return $true
}

function Write-BootstrapReport {
    [CmdletBinding()]
    param(
        [string]$Path,
        [object]$Account,
        [string]$RepoName,
        [string]$BranchName,
        [string]$EnvironmentName,
        [string]$AppDisplayName,
        [string]$AppId,
        [string]$TenantId,
        [string[]]$GitHubEnvironments,
        [string]$WorkloadResourceGroup,
        [string]$WorkloadResourceGroupStatus,
        [string]$TfstateResourceGroup,
        [string]$TfstateResourceGroupStatus,
        [string]$TfstateStorageAccount,
        [string]$TfstateStorageAccountStatus,
        [string]$TfstateContainer,
        [string]$TfstateContainerStatus,
        [string]$TfstateStorageRoleStatus,
        [string]$GitHubAppName,
        [string]$GitHubAppId,
        [string]$GitHubAppSlug,
        [string]$GitHubAppInstallationId,
        [string]$GitHubAppStatus,
        [int]$SecretsSet,
        [int]$SecretsKept,
        [int]$VariablesSet,
        [string[]]$CreatedGitHubEnvironments,
        [string[]]$OidcSubjectClaims,
        [string]$BootstrapLocation,
        [string]$BootstrapRegionShort,
        # Only set when a NEW local admin password was generated this run
        # (null when LOCAL_ADMIN_PASSWORD already existed and was kept as-is).
        # This is the ONLY place the plaintext is ever written down.
        [string]$LocalAdminPassword = $null
    )

    $reportDir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($reportDir)) {
        New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
    }

    $createdEnvsText = if ($CreatedGitHubEnvironments.Count -gt 0) { ($CreatedGitHubEnvironments -join ", ") } else { "none" }
    $credentialsText = if ($OidcSubjectClaims.Count -gt 0) { ($OidcSubjectClaims -join "`n") } else { "none" }
    $localAdminSection = if (-not [string]::IsNullOrWhiteSpace($LocalAdminPassword)) {
        @"

## Local Admin Credential (SHOWN ONCE — SAVE NOW)

Password: $LocalAdminPassword

This is the ONLY time this password is displayed. It is not stored anywhere
in plaintext — only its hash lives in the LOCAL_ADMIN_PASSWORD GitHub secret.
Use it to sign in at /local-admin only if Entra ID SSO is ever unavailable.
To rotate it later, delete the LOCAL_ADMIN_PASSWORD GitHub secret and
re-run this script.
"@
    } else {
        ""
    }

    $content = @"
# CNA Bootstrap Report

- Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')
- Repository: $RepoName
- Branch: $BranchName
- Environment: $EnvironmentName
- Azure subscription: $($Account.name) ($($Account.id))
- Azure tenant: $TenantId
- Entra app display name: $AppDisplayName
- Entra app client ID: $AppId
- GitHub App name: $GitHubAppName
- GitHub App status: $GitHubAppStatus
- GitHub App ID: $GitHubAppId
- GitHub App slug: $GitHubAppSlug
- GitHub App installation ID: $GitHubAppInstallationId
- Bootstrap location: $BootstrapLocation
- Bootstrap region short: $BootstrapRegionShort

## GitHub Integration

| Item | Value |
| --- | --- |
| GitHub environments present | $(@($GitHubEnvironments) -join ", ") |
| GitHub environments ensured | $createdEnvsText |
| Federated credential subjects | $(($OidcSubjectClaims.Count)) |
| GitHub App status | $GitHubAppStatus |
| GitHub App installation | $GitHubAppInstallationId |
| Secrets written | ``$SecretsSet`` |
| Secrets kept/skipped | ``$SecretsKept`` |
| Variables written | ``$VariablesSet`` |

## Azure Resources

| Resource | Value |
| --- | --- |
| Workload RG | ``$WorkloadResourceGroup`` (``$WorkloadResourceGroupStatus``) |
| Tfstate RG | ``$TfstateResourceGroup`` (``$TfstateResourceGroupStatus``) |
| Tfstate storage account | ``$TfstateStorageAccount`` (``$TfstateStorageAccountStatus``) |
| Tfstate container | ``$TfstateContainer`` (``$TfstateContainerStatus``) |
| Tfstate storage role | ``$TfstateStorageRoleStatus`` |
$localAdminSection
## Federated Credentials

$credentialsText

## CAF / Naming Notes

- Workload and platform resources stay in the CAF-style workload RG: ``$WorkloadResourceGroup``
- Terraform state remains in a separate CAF-named backend RG: ``$TfstateResourceGroup``
- GitHub OIDC subjects are created for the selected branch and GitHub environments
- GitHub App creation follows the manifest flow and scopes the installation to this repository

## Next Steps

1. Run workflow `100-validate-prereqs.yml`.
2. Run workflow `200-build-images.yml`.
3. Run workflow `210-deploy.yml`.
"@

    Set-Content -Path $Path -Value $content -Encoding UTF8
    Write-Ok "Wrote bootstrap report: $Path"
}

function Add-GitHubFederatedCredential {
    param(
        [string]$AppId,
        [string]$Name,
        [string]$Subject
    )

    $issuer = "https://token.actions.githubusercontent.com"
    $existingJson = & az ad app federated-credential list --id $AppId -o json 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($existingJson)) {
        $existingCredentials = @($existingJson | ConvertFrom-Json)
        $existingByName = $existingCredentials | Where-Object { $_.name -eq $Name } | Select-Object -First 1
        if ($existingByName) {
            Write-Ok "Federated credential exists: $Name"
            return
        }

        $existingBySubject = $existingCredentials | Where-Object {
            $_.issuer -eq $issuer -and $_.subject -eq $Subject
        } | Select-Object -First 1
        if ($existingBySubject) {
            Write-Ok "Federated credential subject exists: $Subject ($($existingBySubject.name))"
            return
        }
    }

    $credential = @{
        name      = $Name
        issuer    = $issuer
        subject   = $Subject
        audiences = @("api://AzureADTokenExchange")
    } | ConvertTo-Json -Compress

    $credentialFile = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -Path $credentialFile -Value $credential -Encoding UTF8
        $credentialArg = "@$credentialFile"
        & az ad app federated-credential create --id $AppId --parameters "$credentialArg" --output none
        if ($LASTEXITCODE -ne 0) { throw "Failed to create federated credential $Name." }
        Write-Ok "Created federated credential: $Name"
    }
    finally {
        Remove-Item -Path $credentialFile -Force -ErrorAction SilentlyContinue
    }
}

function New-DeployServicePrincipal {
    # Ensures (idempotently, by display name) an Entra app registration + service
    # principal used purely as a GitHub OIDC DEPLOY identity, and assigns the given
    # roles at the given scope. Returns the app (client) id. Separate from the
    # NextAuth OAuth app — these never hold a client secret.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$DisplayName,
        [string[]]$Roles,
        [string]$Scope
    )

    $existingApp = & az ad app list --display-name $DisplayName --query "[0].appId" -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($existingApp)) {
        $deployAppId = $existingApp.Trim()
        Write-Ok "Using existing deploy app: $DisplayName ($deployAppId)"
    } else {
        if ($PSCmdlet.ShouldProcess($DisplayName, "create deploy app registration")) {
            $deployAppId = (& az ad app create --display-name $DisplayName --query appId -o tsv).Trim()
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($deployAppId)) {
                throw "Failed to create deploy app registration: $DisplayName."
            }
        }
        Write-Ok "Created deploy app: $DisplayName ($deployAppId)"
    }

    $sp = & az ad sp list --filter "appId eq '$deployAppId'" --query "[0].id" -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sp)) {
        if ($PSCmdlet.ShouldProcess($deployAppId, "create service principal")) {
            & az ad sp create --id $deployAppId --output none
            if ($LASTEXITCODE -ne 0) { throw "Failed to create service principal for $DisplayName." }
            Start-Sleep -Seconds 10
        }
        Write-Ok "Created service principal: $DisplayName"
    } else {
        Write-Ok "Service principal exists: $DisplayName"
    }

    foreach ($role in $Roles) {
        $assignment = & az role assignment list --assignee $deployAppId --role $role --scope $Scope --query "[0].id" -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($assignment)) {
            Write-Ok "Role already assigned to ${DisplayName}: $role"
            continue
        }
        if ($PSCmdlet.ShouldProcess($Scope, "assign $role to $DisplayName ($deployAppId)")) {
            & az role assignment create --role $role --assignee $deployAppId --scope $Scope --output none
            if ($LASTEXITCODE -ne 0) { throw "Failed to assign $role to $DisplayName." }
        }
        Write-Ok "Assigned role to ${DisplayName}: $role"
    }

    return $deployAppId
}

function Add-DeployFederatedCredentials {
    # Creates federated credentials on a deploy SP from an EXPLICIT allow-list of
    # OIDC subjects (never enumerates GitHub environments, so a stray 'copilot'
    # environment is never credentialed). Each entry is @{ Label = "..."; Subject = "..." }.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$AppId,
        [string]$RepoName,
        [object[]]$SubjectMap
    )

    foreach ($cred in $SubjectMap) {
        $credentialName = Get-SafeFederatedCredentialName -RepoName $RepoName -Label $cred.Label
        if ($PSCmdlet.ShouldProcess($AppId, "ensure GitHub OIDC federated credential for $($cred.Subject)")) {
            Add-GitHubFederatedCredential -AppId $AppId -Name $credentialName -Subject $cred.Subject
        }
    }
}

function Get-AvailableStorageAccountName {
    [CmdletBinding()]
    param(
        [string]$BaseName,
        [string]$ResourceGroupName
    )

    $candidate = ($BaseName.ToLowerInvariant() -replace '[^a-z0-9]', '')
    if ($candidate.Length -gt 24) {
        $candidate = $candidate.Substring(0, 24)
    }

    for ($i = 0; $i -lt 20; $i++) {
        $name = if ($i -eq 0) {
            $candidate
        } else {
            $suffix = "{0:x2}" -f $i
            $prefixLength = [Math]::Min(24 - $suffix.Length, $candidate.Length)
            $candidate.Substring(0, $prefixLength) + $suffix
        }

        $existingId = & az storage account show --name $name --resource-group $ResourceGroupName --query id -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($existingId)) {
            return $name
        }

        $nameAvailable = & az storage account check-name --name $name --query nameAvailable -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and $nameAvailable -eq "true") {
            return $name
        }
    }

    throw "Unable to find an available storage account name derived from '$BaseName'."
}

function Confirm-ResourceGroup {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$SubscriptionId,
        [string]$Location,
        [string]$ResourceGroupName,
        [string]$PurposeLabel
    )

    $exists = & az group exists --name $ResourceGroupName --subscription $SubscriptionId --output tsv
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to determine whether resource group '$ResourceGroupName' exists."
    }

    if ($exists -ne "true") {
        if ($PSCmdlet.ShouldProcess($ResourceGroupName, "create $PurposeLabel resource group")) {
            & az group create --name $ResourceGroupName --location $Location --subscription $SubscriptionId --output none
            if ($LASTEXITCODE -ne 0) { throw "Failed to create resource group '$ResourceGroupName'." }
        }
        Write-Ok "Created $PurposeLabel resource group: $ResourceGroupName"
        return "created"
    } else {
        Write-Ok "$PurposeLabel resource group exists: $ResourceGroupName"
        return "existing"
    }
}

function Confirm-CnaCustomRole {
    # Idempotently creates a custom RBAC role definition for permissions that
    # have no narrow built-in role equivalent (e.g. PostgreSQL Flexible Server
    # control plane — Azure has no granular built-in role for it, confirmed
    # against the Azure built-in roles reference). AssignableScopes is the
    # subscription so the definition can be referenced by name from a
    # RG-scoped role assignment; the definition itself grants nothing until
    # assigned somewhere.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$Name,
        [string]$Description,
        [string[]]$Actions,
        [string]$SubscriptionScope
    )

    $existing = & az role definition list --name $Name --scope $SubscriptionScope --query "[0].roleName" -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($existing)) {
        Write-Ok "Custom role exists: $Name"
        return
    }

    $definition = @{
        Name             = $Name
        IsCustom         = $true
        Description      = $Description
        Actions          = $Actions
        NotActions       = @()
        DataActions      = @()
        NotDataActions   = @()
        AssignableScopes = @($SubscriptionScope)
    } | ConvertTo-Json -Depth 5

    $definitionFile = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -Path $definitionFile -Value $definition -Encoding UTF8
        if ($PSCmdlet.ShouldProcess($Name, "create custom role definition")) {
            & az role definition create --role-definition $definitionFile --output none
            if ($LASTEXITCODE -ne 0) { throw "Failed to create custom role '$Name'." }
        }
        Write-Ok "Created custom role: $Name"
    }
    finally {
        Remove-Item -Path $definitionFile -Force -ErrorAction SilentlyContinue
    }
}

function Remove-CnaRoleAssignmentIfExists {
    # Revokes a legacy broad role assignment once a narrower replacement is in
    # place. Used to shrink Dev/Prod SPs from subscription-scope
    # Contributor/User Access Administrator down to RG-scoped least-privilege
    # roles without leaving the old grant behind alongside the new one.
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$AssigneeAppId,
        [string]$RoleName,
        [string]$Scope
    )

    $assignmentId = & az role assignment list --assignee $AssigneeAppId --role $RoleName --scope $Scope --query "[0].id" -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($assignmentId)) {
        return
    }
    if ($PSCmdlet.ShouldProcess($Scope, "remove legacy $RoleName assignment for $AssigneeAppId")) {
        & az role assignment delete --ids $assignmentId --output none
        if ($LASTEXITCODE -ne 0) { throw "Failed to remove legacy role assignment $RoleName for $AssigneeAppId." }
    }
    Write-Ok "Removed legacy subscription-scope $RoleName from $AssigneeAppId"
}

function Confirm-NetworkWatcherAccess {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$SubscriptionId,
        [string]$Location,
        [string]$EnvClientId
    )

    Write-Step "Ensuring Network Watcher access for the environment deploy SP"
    # Azure auto-provisions one Network Watcher per region (NetworkWatcher_<region>
    # in NetworkWatcherRG) when the first VNet appears. The observability module
    # reads that watcher and parents the VNet flow log under it, so 211's plan and
    # apply need Microsoft.Network/networkWatchers read+write in NetworkWatcherRG —
    # outside the workload RG every env-SP role is scoped to. Ensure the RG and the
    # regional watcher exist (pre-creating matches Azure's own naming), then grant
    # Network Contributor scoped to just that RG.
    $exists = & az group exists --name "NetworkWatcherRG" --subscription $SubscriptionId --output tsv
    if ($exists -ne "true") {
        if ($PSCmdlet.ShouldProcess("NetworkWatcherRG", "create resource group")) {
            & az group create --name "NetworkWatcherRG" --location $Location --subscription $SubscriptionId --output none
            if ($LASTEXITCODE -ne 0) { throw "Failed to create NetworkWatcherRG." }
        }
        Write-Ok "Created NetworkWatcherRG"
    } else {
        Write-Ok "NetworkWatcherRG exists"
    }

    if ($PSCmdlet.ShouldProcess($Location, "enable Network Watcher")) {
        & az network watcher configure --locations $Location --enabled true --resource-group "NetworkWatcherRG" --subscription $SubscriptionId --output none 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "Could not pre-enable Network Watcher for $Location; Azure will auto-create it with the first VNet."
        } else {
            Write-Ok "Network Watcher enabled for $Location"
        }
    }

    $envObjectId = & az ad sp show --id $EnvClientId --query id --output tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($envObjectId)) {
        Write-Warn "Could not resolve environment deploy SP object ID for $EnvClientId. Grant Network Contributor on NetworkWatcherRG manually or re-run."
        return
    }
    $scope = "/subscriptions/$SubscriptionId/resourceGroups/NetworkWatcherRG"
    $assignmentCount = & az role assignment list `
        --assignee-object-id $envObjectId `
        --scope $scope `
        --subscription $SubscriptionId `
        --query "[?roleDefinitionName=='Network Contributor'] | length(@)" `
        --output tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and $assignmentCount -eq "0") {
        if ($PSCmdlet.ShouldProcess("NetworkWatcherRG", "assign Network Contributor to environment deploy SP")) {
            & az role assignment create `
                --role "Network Contributor" `
                --assignee-object-id $envObjectId `
                --assignee-principal-type ServicePrincipal `
                --scope $scope `
                --subscription $SubscriptionId `
                --output none
            if ($LASTEXITCODE -ne 0) { throw "Failed to assign Network Contributor on NetworkWatcherRG to the environment deploy SP." }
        }
        Write-Ok "Assigned Network Contributor on NetworkWatcherRG to environment deploy SP"
    } else {
        Write-Ok "Environment deploy SP already has Network Contributor on NetworkWatcherRG"
    }
}

function Confirm-TfstateBackendResources {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$SubscriptionId,
        [string]$Location,
        [string]$ResourceGroupName,
        [string]$StorageAccountName,
        [string]$ContainerName,
        [string]$ClientId,
        [string]$EnvClientId = ""
    )

    Write-Step "Ensuring Terraform backend prerequisites"
    $resourceGroupStatus = Confirm-ResourceGroup -SubscriptionId $SubscriptionId -Location $Location -ResourceGroupName $ResourceGroupName -PurposeLabel "tfstate"

    $storageId = & az storage account show --name $StorageAccountName --resource-group $ResourceGroupName --subscription $SubscriptionId --query id -o tsv 2>$null
    $storageAccountStatus = "existing"
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($storageId)) {
        if ($PSCmdlet.ShouldProcess($StorageAccountName, "create tfstate storage account")) {
            & az storage account create `
                --name $StorageAccountName `
                --resource-group $ResourceGroupName `
                --subscription $SubscriptionId `
                --location $Location `
                --sku Standard_LRS `
                --min-tls-version TLS1_2 `
                --allow-blob-public-access false `
                --https-only true `
                --output none
            if ($LASTEXITCODE -ne 0) { throw "Failed to create tfstate storage account '$StorageAccountName'." }
        }
        Write-Ok "Created tfstate storage account: $StorageAccountName"
        $storageAccountStatus = "created"
        $storageId = & az storage account show --name $StorageAccountName --resource-group $ResourceGroupName --subscription $SubscriptionId --query id -o tsv
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($storageId)) {
            throw "Failed to resolve storage account ID for '$StorageAccountName' after creation."
        }
    } else {
        Write-Ok "Tfstate storage account exists: $StorageAccountName"
    }

    $accountKey = & az storage account keys list `
        --resource-group $ResourceGroupName `
        --subscription $SubscriptionId `
        --account-name $StorageAccountName `
        --query "[0].value" `
        --output tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($accountKey)) {
        throw "Failed to read storage account key for '$StorageAccountName'."
    }

    & az storage container show --name $ContainerName --account-name $StorageAccountName --account-key $accountKey --output none 2>$null
    $containerStatus = "existing"
    if ($LASTEXITCODE -ne 0) {
        if ($PSCmdlet.ShouldProcess($ContainerName, "create tfstate blob container")) {
            & az storage container create --name $ContainerName --account-name $StorageAccountName --account-key $accountKey --output none
            if ($LASTEXITCODE -ne 0) { throw "Failed to create tfstate blob container '$ContainerName'." }
        }
        Write-Ok "Created tfstate blob container: $ContainerName"
        $containerStatus = "created"
    } else {
        Write-Ok "Tfstate blob container exists: $ContainerName"
    }

    $storageRoleStatus = "unknown"
    $clientObjectId = & az ad sp show --id $ClientId --query id --output tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($clientObjectId)) {
        $assignmentCount = & az role assignment list `
            --assignee-object-id $clientObjectId `
            --scope $storageId `
            --subscription $SubscriptionId `
            --query "[?roleDefinitionName=='Storage Blob Data Contributor'] | length(@)" `
            --output tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and $assignmentCount -eq "0") {
            if ($PSCmdlet.ShouldProcess($StorageAccountName, "assign Storage Blob Data Contributor to CI identity")) {
                & az role assignment create `
                    --role "Storage Blob Data Contributor" `
                    --assignee-object-id $clientObjectId `
                    --assignee-principal-type ServicePrincipal `
                    --scope $storageId `
                    --subscription $SubscriptionId `
                    --output none
                if ($LASTEXITCODE -ne 0) { throw "Failed to assign Storage Blob Data Contributor on '$StorageAccountName'." }
            }
            Write-Ok "Assigned Storage Blob Data Contributor to CI identity"
            $storageRoleStatus = "created"
        } else {
            Write-Ok "CI identity already has Storage Blob Data Contributor on tfstate storage"
            $storageRoleStatus = "existing"
        }
    } else {
        Write-Warn "Could not resolve service principal object ID for $ClientId. Workflow 000 may need to assign storage RBAC itself."
    }

    # The ENVIRONMENT deploy SP also needs the tfstate storage account: 211's
    # plan/apply jobs (and the drift workflows) run under environment:<env> and
    # `terraform init` must read the account and list its keys for the azurerm
    # backend. The env SP's roles are RG-scoped to the WORKLOAD resource group,
    # which does not cover this account in the -tfstate RG — under the old
    # subscription-wide Contributor this was invisible, and the least-privilege
    # shrink exposed it (terraform init failed with storageAccounts/read
    # AuthorizationFailed). Storage Account Contributor scoped to just this
    # account provides control-plane read + listKeys and nothing broader.
    if (-not [string]::IsNullOrWhiteSpace($EnvClientId)) {
        $envObjectId = & az ad sp show --id $EnvClientId --query id --output tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($envObjectId)) {
            $envAssignmentCount = & az role assignment list `
                --assignee-object-id $envObjectId `
                --scope $storageId `
                --subscription $SubscriptionId `
                --query "[?roleDefinitionName=='Storage Account Contributor'] | length(@)" `
                --output tsv 2>$null
            if ($LASTEXITCODE -eq 0 -and $envAssignmentCount -eq "0") {
                if ($PSCmdlet.ShouldProcess($StorageAccountName, "assign Storage Account Contributor to environment deploy SP")) {
                    & az role assignment create `
                        --role "Storage Account Contributor" `
                        --assignee-object-id $envObjectId `
                        --assignee-principal-type ServicePrincipal `
                        --scope $storageId `
                        --subscription $SubscriptionId `
                        --output none
                    if ($LASTEXITCODE -ne 0) { throw "Failed to assign Storage Account Contributor on '$StorageAccountName' to the environment deploy SP." }
                }
                Write-Ok "Assigned Storage Account Contributor on tfstate storage to environment deploy SP"
            } else {
                Write-Ok "Environment deploy SP already has Storage Account Contributor on tfstate storage"
            }
        } else {
            Write-Warn "Could not resolve environment deploy SP object ID for $EnvClientId. Terraform init in 211 will fail until Storage Account Contributor is granted on '$StorageAccountName' manually."
        }
    }

    return [pscustomobject]@{
        ResourceGroupStatus  = $resourceGroupStatus
        StorageAccountStatus  = $storageAccountStatus
        ContainerStatus       = $containerStatus
        StorageRoleStatus     = $storageRoleStatus
    }
}

if (-not $PSBoundParameters.ContainsKey('Environment')) {
    # This script bootstraps exactly ONE environment per run — it never
    # creates/touches both the Dev and Prod deploy service principals in the
    # same invocation, so a stray run can't widen or duplicate the other
    # environment's identity. Run it again with the other choice (or
    # -Environment prod/dev) to bootstrap the other one.
    Write-Step "Selecting target environment"
    $Environment = $null
    while (-not $Environment) {
        $envChoice = (Read-Host "Which environment are you bootstrapping? [D]evelopment / [P]roduction").Trim()
        if ($envChoice -match '^(d|dev|development)$') { $Environment = "dev" }
        elseif ($envChoice -match '^(p|prod|production)$') { $Environment = "prod" }
        else { Write-Warn "Enter 'Development' or 'Production' (or d/p)." }
    }
    Write-Ok "Target environment: $Environment"
}

Write-Step "Checking local prerequisites"
Assert-Command "gh"
if (-not $SkipAzureSetup) {
    Assert-Command "az"
}

if (-not $Repo) {
    $Repo = (& gh repo view --json nameWithOwner -q .nameWithOwner 2>$null)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Repo)) {
        $Repo = Read-TextValue -Name "Repo" -Prompt "GitHub repo in owner/name format" -Required
    }
}
Write-Ok "GitHub repo: $Repo"

if (-not $AppDisplayName) {
    $AppDisplayName = "CNA Assessment Tool"
    Write-Info "Using default Entra app display name: $AppDisplayName"
}

Invoke-Gh -Arguments @("auth", "status")
$existingSecrets = Get-ExistingGitHubSecretNames -RepoName $Repo
$existingVariables = Get-ExistingGitHubVariableValues -RepoName $Repo
$legacyDockerHubSecretName = "DOCKERHUB" + "_USERNAME"
$hadLegacyDockerHubSecret = $existingSecrets.ContainsKey($legacyDockerHubSecretName)
Remove-GitHubSecretIfExists -Name $legacyDockerHubSecretName -RepoName $Repo -ExistingSecrets $existingSecrets | Out-Null
$existingSecrets.Remove($legacyDockerHubSecretName)
$createdGitHubEnvironments = [System.Collections.Generic.List[string]]::new()
foreach ($environmentName in @("dev", "prod")) {
    if (Confirm-GitHubEnvironment -RepoName $Repo -EnvironmentName $environmentName) {
        $createdGitHubEnvironments.Add($environmentName) | Out-Null
    }
}

# 'hub' is the approval gate for the prod apply job in workflow 211. It must
# require a manual reviewer so prod never deploys unattended. Default the reviewer
# to the repository owner; override by setting CNA_HUB_REVIEWERS (comma-separated
# GitHub logins) in the environment before running this script.
$hubReviewers = if (-not [string]::IsNullOrWhiteSpace($env:CNA_HUB_REVIEWERS)) {
    @($env:CNA_HUB_REVIEWERS -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
} else {
    @(($Repo -split '/')[0])
}
if (Confirm-GitHubEnvironment -RepoName $Repo -EnvironmentName "hub" -RequiredReviewers $hubReviewers) {
    $createdGitHubEnvironments.Add("hub") | Out-Null
}
$githubEnvironments = Get-GitHubEnvironments -RepoName $Repo

$githubAppName = "CNA Assessment Tool"
Write-Info "Using GitHub App name: $githubAppName"
$githubAppId = ""
$githubAppSlug = ""
$githubAppInstallationId = ""
$githubAppStatus = "not-configured"
$githubAppPrivateKey = $null
$hasGitHubAppId = $existingSecrets.ContainsKey("GH_APP_ID")
$hasGitHubAppPrivateKey = $existingSecrets.ContainsKey("GH_APP_PRIVATE_KEY")
Write-Step "Creating GitHub App"
if ($hasGitHubAppId -or $hasGitHubAppPrivateKey) {
    Write-Warn "Existing GitHub App secrets were found. They will be replaced with credentials from a newly created app."
}
Write-Info "The script will create a new GitHub App named '$githubAppName'."
Write-Info "If GitHub reports that the app name is taken, delete the existing app in GitHub Developer Settings and rerun this script."
$repoUrl = "https://github.com/$Repo"
$githubApp = New-GitHubAppViaManifest -AppName $githubAppName -RepoName $Repo -HomepageUrl $repoUrl
$githubAppId = $githubApp.AppId
$githubAppSlug = $githubApp.Slug
$githubAppPrivateKey = $githubApp.PrivateKey
$githubAppInstallationId = Wait-GitHubAppInstallation -AppId $githubAppId -AppSlug $githubAppSlug -RepoName $Repo -PemText $githubAppPrivateKey
$githubAppStatus = "created"

$tenantId = ""
$resolvedSubscriptionId = ""
$resolvedSubscriptionName = ""
$appId = ""
$entraClientSecret = $null
$entraAppCreated = $false
$federatedCredentialSubjects = [System.Collections.Generic.List[string]]::new()
$bootstrapWorkloadResourceGroup = ""
$workloadResourceGroupScope = ""
$bootstrapWorkloadResourceGroupStatus = "not-run"

# Region is never assumed for you. If you did not pass -BootstrapLocation /
# -BootstrapRegionShort, ask now, before any value is used. These feed your
# resource-group names, the tfstate backend and the GitHub variables below.
Write-Step "Choosing your Azure region"
if ([string]::IsNullOrWhiteSpace($BootstrapLocation)) {
    Write-Info "Pick any region from https://learn.microsoft.com/azure/reliability/regions-list"
    $BootstrapLocation = Read-TextValue -Name "BootstrapLocation" -Prompt "Azure region (e.g. eastus)" -Required
}
if ([string]::IsNullOrWhiteSpace($BootstrapRegionShort)) {
    Write-Info "Pick a short lowercase code for that region; it goes into resource names."
    $BootstrapRegionShort = Read-TextValue -Name "BootstrapRegionShort" -Prompt "Short region code (e.g. eus for eastus)" -Required
}
Write-Ok "Region: $BootstrapLocation (short code: $BootstrapRegionShort)"

if (-not $SkipAzureSetup) {
    Write-Step "Preparing Azure OIDC app registration"
    $account = Initialize-AzLogin

    $account = Select-AzSubscription -CurrentAccount $account
    & az account set --subscription $account.id | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to switch to subscription $($account.id)."
    }
    $account = Invoke-AzJson -Arguments @("account", "show")

    $tenantId = [string]$account.tenantId
    $resolvedSubscriptionId = [string]$account.id
    $resolvedSubscriptionName = [string]$account.name
    Write-Ok "Azure subscription: $($account.name) ($resolvedSubscriptionId)"
    Write-Ok "Azure tenant: $tenantId"

    # Created here (before the deploy SPs below) rather than at its old spot
    # further down, so the Dev/Prod SP for the environment THIS run targets
    # can be scoped to this RG instead of the whole subscription. See the
    # least-privilege comment above the deploy SP creation block.
    $bootstrapWorkloadResourceGroup = "rg-cna-$Environment-$BootstrapRegionShort"
    Write-Step "Ensuring workload resource group"
    $bootstrapWorkloadResourceGroupStatus = Confirm-ResourceGroup `
        -SubscriptionId $resolvedSubscriptionId `
        -Location $BootstrapLocation `
        -ResourceGroupName $bootstrapWorkloadResourceGroup `
        -PurposeLabel "workload"
    $workloadResourceGroupScope = "/subscriptions/$resolvedSubscriptionId/resourceGroups/$bootstrapWorkloadResourceGroup"

    $existingApp = & az ad app list --display-name $AppDisplayName --query "[0].appId" -o tsv 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($existingApp)) {
        $appId = $existingApp.Trim()
        Write-Ok "Using existing app registration: $AppDisplayName ($appId)"
    } else {
        if ($PSCmdlet.ShouldProcess($AppDisplayName, "create Entra app registration")) {
            $appId = (& az ad app create --display-name $AppDisplayName --query appId -o tsv).Trim()
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($appId)) {
                throw "Failed to create Entra app registration."
            }
        }
        # A freshly created app invalidates BOTH stored halves of the NextAuth
        # identity: the CNA_ENTRA_CLIENT_ID variable (points at the deleted
        # app → AADSTS700016 at sign-in) and the CNA_ENTRA_CLIENT_SECRET
        # secret (credentials die with the app). Both are force-refreshed
        # below instead of following the usual keep-existing convention.
        $entraAppCreated = $true
        Write-Ok "Created app registration: $AppDisplayName ($appId)"
    }

    # The app above ($appId / $AppDisplayName, default "CNA Assessment Tool") is the
    # NextAuth OAuth app for end-user sign-in only — it keeps the redirect URI and
    # client secret below. It is NOT a deploy identity and gets no federated
    # credentials or subscription roles.
    #
    # This bootstrap is the SINGLE authoritative manager of the NextAuth redirect
    # URI (set on the application object, per Microsoft guidance — never on a
    # service principal). The deploy pipeline is least-privilege and has no Graph
    # app-management rights, so it never touches this app. See docs/adr/0003.
    #
    # Deploy OIDC uses TWO separate, least-privilege service principals per run:
    #   - Main: repo-level jobs on main (policy-gates/000/100/320) — ref:refs/heads/main
    #   - {Environment}: 211 plan/apply for the environment THIS run targets,
    #     plus (for prod only) the hub approval gate.
    # This bootstrap only ever creates/touches ONE of Dev/Prod per invocation —
    # see the environment-selection prompt above. Run it again for the other
    # environment; it will never widen or duplicate the one just created here.
    # Subjects are an explicit allow-list (never enumerated from GitHub environments),
    # so a stray auto-created 'copilot' environment is never credentialed.
    $subscriptionScope = "/subscriptions/$resolvedSubscriptionId"

    Write-Step "Creating deploy service principals (Main / $Environment)"

    # Main (shared) — repo-level jobs validate/scan and need to create the tfstate
    # backend (000). Contributor at subscription scope covers backend creation;
    # User Access Administrator is not needed for the shared identity.
    $mainAppId = New-DeployServicePrincipal -DisplayName "CNA Assessment Tool - Main" `
        -Roles @("Contributor") -Scope $subscriptionScope
    Add-DeployFederatedCredentials -AppId $mainAppId -RepoName $Repo -SubjectMap @(
        @{ Label = "cna-oidc-main"; Subject = "repo:$Repo`:ref:refs/heads/$Branch" }
    )
    $federatedCredentialSubjects.Add("repo:$Repo`:ref:refs/heads/$Branch") | Out-Null

    # {Environment} — scoped to just this environment's workload resource group
    # (created above) instead of the whole subscription. Built-in roles cover
    # every resource type Terraform manages here except PostgreSQL Flexible
    # Server, which has no narrow built-in role — see $cnaCustomRoleName.
    # Role Based Access Control Administrator replaces User Access
    # Administrator: it can create/delete role assignments (so Terraform can
    # wire up its own managed identities' RBAC) but, unlike User Access
    # Administrator, has no access to the rest of Microsoft.Authorization/*
    # (policy assignments, locks, etc).
    $cnaCustomRoleName = "CNA Terraform Workload Extras"
    Confirm-CnaCustomRole -Name $cnaCustomRoleName `
        -Description "PostgreSQL Flexible Server control plane + workload RG tag updates for CNA Terraform deploy identities. Azure has no built-in role granular to PostgreSQL Flexible Server management." `
        -Actions @(
            "Microsoft.DBforPostgreSQL/flexibleServers/*",
            "Microsoft.DBforPostgreSQL/locations/*",
            "Microsoft.Resources/subscriptions/resourceGroups/read",
            "Microsoft.Resources/subscriptions/resourceGroups/write",
            "Microsoft.Resources/deployments/*"
        ) `
        -SubscriptionScope $subscriptionScope

    $cnaWorkloadDeployRoles = @(
        "Network Contributor",
        "Storage Account Contributor",
        "Container Apps Contributor",
        # Container Apps *Jobs* (Microsoft.App/jobs/*) are a separate resource
        # type from container apps; 211's migration step creates/starts a
        # Container Apps Job and fails with AuthorizationFailed without this.
        "Container Apps Jobs Contributor",
        "Container Apps ManagedEnvironments Contributor",
        "Key Vault Contributor",
        "Cognitive Services Contributor",
        "Managed Identity Contributor",
        # Managed Identity Operator carries userAssignedIdentities/assign/action,
        # which Contributor does not: attaching the UAI to Container Apps and the
        # migrator job fails with LinkedAuthorizationFailed without it.
        "Managed Identity Operator",
        "Log Analytics Contributor",
        "Monitoring Contributor",
        "CDN Profile Contributor",
        $cnaCustomRoleName,
        "Role Based Access Control Administrator"
    )

    $envDisplayName = if ($Environment -eq "prod") { "Prod" } else { "Dev" }
    $envAppId = New-DeployServicePrincipal -DisplayName "CNA Assessment Tool - $envDisplayName" `
        -Roles $cnaWorkloadDeployRoles -Scope $workloadResourceGroupScope

    # Subscription-scope Reader on top of the RG-scoped write roles: enabling
    # Traffic Analytics on the VNet flow log validates the enabling principal
    # against a wide set of */read actions across network resource types
    # (learn.microsoft.com/azure/network-watcher/rbac-permissions#traffic-analytics)
    # and fails with TAUserDoesNotHavePermissions when they are held only at RG
    # scope. Reader is read-only everywhere; the non-read actions the same doc
    # table requires (workspace shared keys, data-collection rules/endpoints)
    # are carried by the custom role below — RG-scoped Log Analytics /
    # Monitoring Contributor proved insufficient for TA's subscription-scope
    # check (confirmed empirically on the 2026-08-28 dev rebuild: Reader alone
    # still failed TAUserDoesNotHavePermissions after propagation).
    New-DeployServicePrincipal -DisplayName "CNA Assessment Tool - $envDisplayName" `
        -Roles @("Reader") -Scope $subscriptionScope | Out-Null

    $cnaTaRoleName = "CNA Traffic Analytics Enabler"
    Confirm-CnaCustomRole -Name $cnaTaRoleName `
        -Description "Non-read actions Traffic Analytics enablement requires at subscription scope; Reader supplies the reads. See learn.microsoft.com/azure/network-watcher/rbac-permissions#traffic-analytics." `
        -Actions @(
            "Microsoft.OperationalInsights/workspaces/read",
            "Microsoft.OperationalInsights/workspaces/sharedkeys/action",
            "Microsoft.Insights/dataCollectionRules/read",
            "Microsoft.Insights/dataCollectionRules/write",
            "Microsoft.Insights/dataCollectionRules/delete",
            "Microsoft.Insights/dataCollectionEndpoints/read",
            "Microsoft.Insights/dataCollectionEndpoints/write",
            "Microsoft.Insights/dataCollectionEndpoints/delete"
        ) `
        -SubscriptionScope $subscriptionScope
    New-DeployServicePrincipal -DisplayName "CNA Assessment Tool - $envDisplayName" `
        -Roles @($cnaTaRoleName) -Scope $subscriptionScope | Out-Null

    # Shrink from any previous run's subscription-scope grant now that the
    # RG-scoped roles above are in place — otherwise this SP would accumulate
    # both the old broad grant and the new narrow one instead of replacing it.
    Remove-CnaRoleAssignmentIfExists -AssigneeAppId $envAppId -RoleName "Contributor" -Scope $subscriptionScope
    Remove-CnaRoleAssignmentIfExists -AssigneeAppId $envAppId -RoleName "User Access Administrator" -Scope $subscriptionScope

    $envSubjectMap = if ($Environment -eq "prod") {
        @(
            @{ Label = "cna-oidc-prod"; Subject = "repo:$Repo`:environment:prod" },
            @{ Label = "cna-oidc-hub"; Subject = "repo:$Repo`:environment:hub" }
        )
    } else {
        @(
            @{ Label = "cna-oidc-dev"; Subject = "repo:$Repo`:environment:dev" }
        )
    }
    Add-DeployFederatedCredentials -AppId $envAppId -RepoName $Repo -SubjectMap $envSubjectMap
    foreach ($subjectEntry in $envSubjectMap) {
        $federatedCredentialSubjects.Add($subjectEntry.Subject) | Out-Null
    }

    # Downstream code (GitHub secret/report writing) reads both variables;
    # only the one matching this run's environment is non-null, so the
    # existing "skip if blank" checks leave the other environment's
    # GitHub secret and report fields untouched.
    $devAppId = if ($Environment -eq "dev") { $envAppId } else { $null }
    $prodAppId = if ($Environment -eq "prod") { $envAppId } else { $null }

    $nextAuthUrlForRedirect = if ($existingVariables.ContainsKey("CNA_NEXTAUTH_URL")) {
        [string]$existingVariables["CNA_NEXTAUTH_URL"]
    } else {
        "none"
    }
    Write-Info "Using CNA_NEXTAUTH_URL = $nextAuthUrlForRedirect"
    if ($nextAuthUrlForRedirect -ne "none") {
        if (-not ($nextAuthUrlForRedirect -match '^https?://')) {
            throw "CNA_NEXTAUTH_URL must be 'none' or start with http:// or https://."
        }
        $redirectUri = "$($nextAuthUrlForRedirect.TrimEnd('/'))/api/auth/callback/microsoft-entra-id"
        $app = Invoke-AzJson -Arguments @("ad", "app", "show", "--id", $appId)
        $redirectUris = @($app.web.redirectUris)
        if (-not ($redirectUris -contains $redirectUri)) {
            $updatedUris = @($redirectUris + $redirectUri)
            if ($PSCmdlet.ShouldProcess($appId, "add redirect URI $redirectUri")) {
                & az ad app update --id $appId --web-redirect-uris @updatedUris --output none
                if ($LASTEXITCODE -ne 0) { throw "Failed to update redirect URI." }
            }
            Write-Ok "Added redirect URI: $redirectUri"
        } else {
            Write-Ok "Redirect URI already present: $redirectUri"
        }
    } else {
        Write-Host "    [INFO] CNA_NEXTAUTH_URL is 'none'. The first deploy (211) creates Front Door and writes the real host to the CNA_NEXTAUTH_URL repo variable via Terraform. Re-run this bootstrap after that first deploy to add the redirect URI (idempotent)."
    }
} else {
    Write-Step "Collecting Azure values without Azure setup"
    $appId = Read-TextValue -Name "AZURE_CLIENT_ID" -Prompt "Azure OIDC app registration client ID" -Required
    $tenantId = Read-TextValue -Name "AZURE_TENANT_ID" -Prompt "Azure tenant ID" -Required
    $resolvedSubscriptionId = Read-TextValue -Name "AZURE_SUBSCRIPTION_ID" -Prompt "Azure subscription ID" -Required
    $resolvedSubscriptionName = Read-TextValue -Name "AZURE_TARGET_SUBSCRIPTION_NAME" -Prompt "Azure subscription name (optional, for human-readable validation)" -Default "none"
    $nextAuthUrlForRedirect = if ($existingVariables.ContainsKey("CNA_NEXTAUTH_URL")) { [string]$existingVariables["CNA_NEXTAUTH_URL"] } else { "none" }
    # Without Azure setup we cannot create the three deploy SPs; fall back to the
    # single prompted client id for all scopes (degenerate single-SP behaviour).
    $mainAppId = $appId
    $devAppId = $appId
    $prodAppId = $appId
}

Write-Step "Collecting GitHub secret values"

if ($githubAppStatus -eq "created") {
    $secretValues = [ordered]@{}
    $secretValues["GH_APP_ID"] = $githubAppId
    $secretValues["GH_APP_PRIVATE_KEY"] = $githubAppPrivateKey
} else {
    $secretValues = [ordered]@{}
}

# $entraAppCreated forces rotation: a client secret kept from a prior app
# registration is dead the moment that app is deleted, so "keep existing"
# would seed the new app's deployment with an unusable credential.
if ($entraAppCreated -or -not $existingSecrets.ContainsKey("CNA_ENTRA_CLIENT_SECRET")) {
    if (-not $SkipAzureSetup) {
        if ($PSCmdlet.ShouldProcess($appId, "create Entra client secret for NextAuth")) {
            $entraClientSecret = (& az ad app credential reset --id $appId --append --display-name "cna-nextauth-$Environment-$(Get-Date -Format yyyyMMddHHmmss)" --years 2 --query password -o tsv).Trim()
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($entraClientSecret)) {
                throw "Failed to create Entra client secret."
            }
        }
        Write-Ok "Created Entra client secret for NextAuth"
    }
}
if ($null -eq $entraClientSecret) {
    $entraClientSecret = Read-SecretValue -Name "CNA_ENTRA_CLIENT_SECRET" -Description "Entra OAuth client secret used by NextAuth" -Exists $existingSecrets.ContainsKey("CNA_ENTRA_CLIENT_SECRET") -Required
}

# Repo-level AZURE_CLIENT_ID = the Main deploy SP. Jobs without a GitHub
# `environment:` key (211 policy-gates, 000, 100, 320) can only read repo-level
# secrets and authenticate via the ref:refs/heads/main subject, which only the
# Main SP trusts. The Dev/Prod SP client ids are written as ENVIRONMENT-scoped
# secrets below so plan/apply pick up the right identity per environment.
$secretValues["AZURE_CLIENT_ID"] = $mainAppId
$secretValues["AZURE_TENANT_ID"] = $tenantId
$secretValues["AZURE_SUBSCRIPTION_ID"] = $resolvedSubscriptionId
$secretValues["CNA_ENTRA_CLIENT_SECRET"] = $entraClientSecret
$secretValues["CNA_POSTGRES_ADMIN_PASSWORD"] = Read-SecretValue -Name "CNA_POSTGRES_ADMIN_PASSWORD" -Description "PostgreSQL admin password" -Exists $existingSecrets.ContainsKey("CNA_POSTGRES_ADMIN_PASSWORD") -GenerateBytes 18 -Required
$secretValues["CNA_NEXTAUTH_SECRET"] = Read-SecretValue -Name "CNA_NEXTAUTH_SECRET" -Description "Auth.js signing secret" -Exists $existingSecrets.ContainsKey("CNA_NEXTAUTH_SECRET") -GenerateBytes 32 -Required
$secretValues["CNA_CREDENTIAL_ENCRYPTION_KEY"] = Read-SecretValue -Name "CNA_CREDENTIAL_ENCRYPTION_KEY" -Description "base64 32-byte AES key for stored cloud credentials" -Exists $existingSecrets.ContainsKey("CNA_CREDENTIAL_ENCRYPTION_KEY") -GenerateBytes 32 -Required

# Break-glass local admin: unlike the other generated secrets above, GitHub
# never stores the plaintext password — only its PBKDF2 hash. The plaintext
# is shown exactly once in the bootstrap report below and then discarded.
# If LOCAL_ADMIN_PASSWORD already exists, this is a no-op (this script's
# established rotation UX: delete the GitHub secret and re-run to rotate).
$localAdminPlaintextPassword = $null
if (-not $existingSecrets.ContainsKey("LOCAL_ADMIN_PASSWORD")) {
    $localAdminPlaintextPassword = New-RandomBase64 -Bytes 24
    $secretValues["LOCAL_ADMIN_PASSWORD"] = ConvertTo-Pbkdf2Hash -PlainText $localAdminPlaintextPassword
} else {
    $secretValues["LOCAL_ADMIN_PASSWORD"] = $null
}
$secretValues["FRONTDOOR_CERTIFICATE_PFX_PASSWORD"] = Read-SecretValue -Name "FRONTDOOR_CERTIFICATE_PFX_PASSWORD" -Description "optional custom TLS certificate PFX password" -Exists $existingSecrets.ContainsKey("FRONTDOOR_CERTIFICATE_PFX_PASSWORD")
$secretValues["CNA_AWS_ROLE_ARN"] = Read-SecretValue -Name "CNA_AWS_ROLE_ARN" -Description "optional AWS OIDC role ARN for portal publishing" -Exists $existingSecrets.ContainsKey("CNA_AWS_ROLE_ARN")
$secretValues["CNA_PUBLISH_BUCKET"] = Read-SecretValue -Name "CNA_PUBLISH_BUCKET" -Description "optional S3 bucket for portal publishing" -Exists $existingSecrets.ContainsKey("CNA_PUBLISH_BUCKET")

Write-Step "Collecting GitHub variable values"
$storageSuffix = ($resolvedSubscriptionId -replace '[^A-Za-z0-9]', '')
if ($storageSuffix.Length -gt 6) { $storageSuffix = $storageSuffix.Substring(0, 6) }
if ([string]::IsNullOrWhiteSpace($storageSuffix)) { $storageSuffix = "state" }
$defaultTfstateStorage = "stcna$($storageSuffix.ToLowerInvariant())tfstate"
if ($defaultTfstateStorage.Length -gt 24) { $defaultTfstateStorage = $defaultTfstateStorage.Substring(0, 24) }

$resolvedDrawioMcpUrl = if ([string]::IsNullOrWhiteSpace($nextAuthUrlForRedirect) -or $nextAuthUrlForRedirect -eq "none") {
    "none"
} else {
    "$($nextAuthUrlForRedirect.TrimEnd('/'))/api/drawio-mcp"
}

$variableDefaults = [ordered]@{
    AZURE_REGION_SHORT            = $BootstrapRegionShort
    DOCKERHUB_NAMESPACE           = Read-DockerHubNamespace -ExistingValue $(if ($existingVariables.ContainsKey("DOCKERHUB_NAMESPACE")) { [string]$existingVariables["DOCKERHUB_NAMESPACE"] } else { "" })
    TFSTATE_RESOURCE_GROUP         = "rg-cna-$Environment-$BootstrapRegionShort-tfstate"
    TFSTATE_STORAGE_ACCOUNT        = $defaultTfstateStorage
    TFSTATE_CONTAINER              = "tfstate"
    AZURE_TARGET_SUBSCRIPTION_NAME = $(if ([string]::IsNullOrWhiteSpace($resolvedSubscriptionName)) { "none" } else { $resolvedSubscriptionName })
    CNA_ENTRA_CLIENT_ID            = $appId
    CNA_NEXTAUTH_URL               = $nextAuthUrlForRedirect
    CNA_AI_ENGINE_DEFAULT          = "azure-openai"
    CNA_AZURE_MCP_ENDPOINT         = "https://mcp.azure.com"
    CNA_AZURE_MCP_TRANSPORT        = "streamable-http"
    CNA_AWS_MCP_ENDPOINT           = "https://aws-mcp.us-east-1.api.aws/mcp"
    CNA_AWS_MCP_TRANSPORT          = "streamable-http"
    CNA_DRAWIO_MCP_URL             = $resolvedDrawioMcpUrl
    APPLICATION_INSIGHTS_NAME      = "none"
    KEY_VAULT_NAME                 = "none"
    FRONTDOOR_CERTIFICATE_NAME     = "none"
    FRONTDOOR_CERTIFICATE_PFX_PATH = "none"
}

$variableValues = [ordered]@{}
foreach ($entry in $variableDefaults.GetEnumerator()) {
    $exists = $existingVariables.ContainsKey($entry.Key)
    $existingValue = if ($exists) { [string]$existingVariables[$entry.Key] } else { "" }
    $variableValues[$entry.Key] = Get-DesiredTextValue -Name $entry.Key -ExistingValue $existingValue -DefaultValue ([string]$entry.Value)
}

# CNA_ENTRA_CLIENT_ID is exempt from the keep-existing convention above: this
# script just resolved (or created) the NextAuth app registration by display
# name, so $appId is authoritative. Keeping a stored value from a deleted app
# sends sign-in to a nonexistent identifier (AADSTS700016) — which is exactly
# what happened when a teardown removed the old app and the next bootstrap
# created a fresh one but "kept" the stale variable.
if (-not $SkipAzureSetup -and -not [string]::IsNullOrWhiteSpace($appId)) {
    if ([string]$variableValues["CNA_ENTRA_CLIENT_ID"] -ne $appId) {
        Write-Info "Overriding CNA_ENTRA_CLIENT_ID with resolved app id $appId (stored value was stale)"
        $variableValues["CNA_ENTRA_CLIENT_ID"] = $appId
    }
}

$dockerHubSecretValues = Read-DockerHubSecretValues `
    -Namespace ([string]$variableValues["DOCKERHUB_NAMESPACE"]) `
    -TokenExists ($existingSecrets.ContainsKey("DOCKERHUB_TOKEN") -and -not $hadLegacyDockerHubSecret)
$secretValues["DOCKERHUB_TOKEN"] = $dockerHubSecretValues.Token

if ([string]::IsNullOrWhiteSpace($bootstrapWorkloadResourceGroup)) {
    # Only reached with -SkipAzureSetup, where the early "Ensuring workload
    # resource group" step (which normally sets this) never ran.
    $bootstrapWorkloadResourceGroup = "rg-cna-$Environment-$BootstrapRegionShort"
}
$bootstrapTfstateResourceGroup = [string]$variableValues["TFSTATE_RESOURCE_GROUP"]
$bootstrapTfstateContainer = [string]$variableValues["TFSTATE_CONTAINER"]
$bootstrapTfstateStorageAccount = Get-AvailableStorageAccountName -BaseName ([string]$variableValues["TFSTATE_STORAGE_ACCOUNT"]) -ResourceGroupName $bootstrapTfstateResourceGroup
$variableValues["TFSTATE_STORAGE_ACCOUNT"] = $bootstrapTfstateStorageAccount
Write-Info "Resolved TFSTATE_STORAGE_ACCOUNT = $bootstrapTfstateStorageAccount"
$bootstrapTfstateResourceStatus = [pscustomobject]@{
    ResourceGroupStatus  = "not-run"
    StorageAccountStatus = "not-run"
    ContainerStatus      = "not-run"
    StorageRoleStatus    = "not-run"
}

Write-Step "Writing GitHub Secrets"
$setSecretCount = 0
$keptSecretCount = 0
foreach ($entry in $secretValues.GetEnumerator()) {
    if ($null -eq $entry.Value) {
        $keptSecretCount++
        Write-Host "    [KEEP/SKIP] $($entry.Key)"
        continue
    }
    if (Set-GitHubSecret -Name $entry.Key -Value $entry.Value -RepoName $Repo) {
        $setSecretCount++
        Write-Ok "Set secret: $($entry.Key)"
    }
}

# Environment-scoped AZURE_CLIENT_ID per deploy SP. A job with a GitHub
# `environment:` key reads the environment-scoped secret in preference to the
# repo-level one, so 211 plan/apply authenticate as the Dev or Prod SP while the
# repo-level value (Main SP) still serves the no-environment jobs. The hub gate
# (prod apply) authenticates as the Prod SP, so hub gets the Prod client id.
$envClientIds = [ordered]@{
    dev  = $devAppId
    prod = $prodAppId
    hub  = $prodAppId
}
foreach ($envEntry in $envClientIds.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace($envEntry.Value)) { continue }
    if (Set-GitHubSecret -Name "AZURE_CLIENT_ID" -Value $envEntry.Value -RepoName $Repo -EnvironmentName $envEntry.Key) {
        $setSecretCount++
        Write-Ok "Set env secret: AZURE_CLIENT_ID (env:$($envEntry.Key))"
    }
}

Write-Step "Writing GitHub Variables"
$setVariableCount = 0
foreach ($entry in $variableValues.GetEnumerator()) {
    if (Set-GitHubVariable -Name $entry.Key -Value $entry.Value -RepoName $Repo) {
        $setVariableCount++
        Write-Ok "Set variable: $($entry.Key) = $($entry.Value)"
    }
}

if (-not $SkipAzureSetup) {
    # Assign tfstate-blob RBAC to the MAIN deploy SP, not $appId. $appId is the
    # NextAuth OAuth app (end-user sign-in) — an app registration with no service
    # principal and no subscription roles, so `az ad sp show --id $appId` can't
    # resolve an object id and the role assignment is skipped. Workflow 000 runs
    # repo-level (no environment:), so it authenticates as the repo AZURE_CLIENT_ID
    # secret = $mainAppId. That is the identity that reads/writes the tfstate blob.
    $bootstrapTfstateResourceStatus = Confirm-TfstateBackendResources `
        -SubscriptionId $resolvedSubscriptionId `
        -Location $BootstrapLocation `
        -ResourceGroupName $bootstrapTfstateResourceGroup `
        -StorageAccountName $bootstrapTfstateStorageAccount `
        -ContainerName $bootstrapTfstateContainer `
        -ClientId $mainAppId `
        -EnvClientId $envAppId

    Confirm-NetworkWatcherAccess `
        -SubscriptionId $resolvedSubscriptionId `
        -Location $BootstrapLocation `
        -EnvClientId $envAppId
}

if (-not $SkipBootstrapDispatch) {
    Write-Step "Step 1: Run workflow 000 bootstrap"
    $bootstrapWorkflow = "000-bootstrap-backend.yml"
    $bootstrapInputs = @{
        environment              = $Environment
        location                 = $BootstrapLocation
        region_short             = $BootstrapRegionShort
        tfstate_resource_group   = $bootstrapTfstateResourceGroup
        tfstate_storage_account  = $bootstrapTfstateStorageAccount
        tfstate_container        = $bootstrapTfstateContainer
    }

    $shouldDispatchBootstrap = Read-YesNo -Prompt "Step 1: Run workflow 000-bootstrap-backend.yml for '$Environment' now?" -DefaultYes $false
    if (-not $shouldDispatchBootstrap) {
        Write-Warn "Step 1 skipped by user. Workflow 000 was not enabled or dispatched."
        Write-Host "  gh workflow run $bootstrapWorkflow --repo $Repo --ref $Branch -f environment=$Environment -f location=$BootstrapLocation -f region_short=$BootstrapRegionShort -f tfstate_resource_group=$bootstrapTfstateResourceGroup -f tfstate_storage_account=$bootstrapTfstateStorageAccount -f tfstate_container=$bootstrapTfstateContainer" -ForegroundColor White
    } elseif (Enable-GitHubWorkflowIfDisabled -RepoName $Repo -Workflow $bootstrapWorkflow) {
        try {
            Start-GitHubWorkflow -RepoName $Repo -Workflow $bootstrapWorkflow -Ref $Branch -Inputs $bootstrapInputs
            Write-Ok "Dispatched 000-bootstrap-backend.yml for environment '$Environment'"
        } catch {
            Write-Warn $_.Exception.Message
            Write-Warn "Bootstrap dispatch failed. Run manually after enabling the workflow:"
            Write-Host "  gh workflow run $bootstrapWorkflow --repo $Repo --ref $Branch -f environment=$Environment -f location=$BootstrapLocation -f region_short=$BootstrapRegionShort -f tfstate_resource_group=$bootstrapTfstateResourceGroup -f tfstate_storage_account=$bootstrapTfstateStorageAccount -f tfstate_container=$bootstrapTfstateContainer" -ForegroundColor White
        }
    } else {
        Write-Warn "Bootstrap workflow was not active, so dispatch was skipped."
        Write-Host "  gh workflow enable $bootstrapWorkflow --repo $Repo" -ForegroundColor White
    }
}

Write-BootstrapReport -Path (Join-Path $ReportDirectory "$((Get-Date).ToString('yyyyMMdd-HHmmss'))-$Environment-bootstrap-report.md") `
    -Account $account `
    -RepoName $Repo `
    -BranchName $Branch `
    -EnvironmentName $Environment `
    -AppDisplayName $AppDisplayName `
    -AppId $appId `
    -TenantId $tenantId `
    -GitHubEnvironments @($githubEnvironments) `
    -WorkloadResourceGroup $bootstrapWorkloadResourceGroup `
    -WorkloadResourceGroupStatus $bootstrapWorkloadResourceGroupStatus `
    -TfstateResourceGroup $bootstrapTfstateResourceGroup `
    -TfstateResourceGroupStatus $bootstrapTfstateResourceStatus.ResourceGroupStatus `
    -TfstateStorageAccount $bootstrapTfstateStorageAccount `
    -TfstateStorageAccountStatus $bootstrapTfstateResourceStatus.StorageAccountStatus `
    -TfstateContainer $bootstrapTfstateContainer `
    -TfstateContainerStatus $bootstrapTfstateResourceStatus.ContainerStatus `
    -TfstateStorageRoleStatus $bootstrapTfstateResourceStatus.StorageRoleStatus `
    -GitHubAppName $githubAppName `
    -GitHubAppId $githubAppId `
    -GitHubAppSlug $githubAppSlug `
    -GitHubAppInstallationId $githubAppInstallationId `
    -GitHubAppStatus $githubAppStatus `
    -SecretsSet $setSecretCount `
    -SecretsKept $keptSecretCount `
    -VariablesSet $setVariableCount `
    -CreatedGitHubEnvironments @($createdGitHubEnvironments) `
    -OidcSubjectClaims @($federatedCredentialSubjects) `
    -BootstrapLocation $BootstrapLocation `
    -BootstrapRegionShort $BootstrapRegionShort `
    -LocalAdminPassword $localAdminPlaintextPassword

Write-Step "Summary"
Write-Host "Repository:       $Repo"
Write-Host "Branch:           $Branch"
Write-Host "Environment:      $Environment"
Write-Host "App registration: $AppDisplayName ($appId)"
Write-Host "GitHub App:       $githubAppName ($githubAppStatus)"
    Write-Host "Workload RG:      $bootstrapWorkloadResourceGroup"
    Write-Host "Tfstate RG:       $bootstrapTfstateResourceGroup"
    Write-Host "Secrets set:      $setSecretCount"
    Write-Host "Secrets kept/skipped: $keptSecretCount"
    Write-Host "Variables set:    $setVariableCount"
    Write-Host "Workload RG status: $bootstrapWorkloadResourceGroupStatus"
    Write-Host "Tfstate RG status:  $($bootstrapTfstateResourceStatus.ResourceGroupStatus)"
    Write-Host "Tfstate account status: $($bootstrapTfstateResourceStatus.StorageAccountStatus)"
    Write-Host "Tfstate container status: $($bootstrapTfstateResourceStatus.ContainerStatus)"
    Write-Host "Tfstate storage role status: $($bootstrapTfstateResourceStatus.StorageRoleStatus)"
    Write-Host "GitHub envs created: $(@($createdGitHubEnvironments).Count)"
    Write-Host "GitHub App ID:    $githubAppId"
    Write-Host "GitHub App slug:  $githubAppSlug"
    Write-Host "GitHub App install: $githubAppInstallationId"
    Write-Host "OIDC subjects ensured: $(@($federatedCredentialSubjects).Count)"
Write-Host ""
Write-Host "Next steps:"
if ($SkipBootstrapDispatch) {
    Write-Host "1. Run workflow 000 to create the workload RG, provision the tfstate backend in its own RG, and import the workload RG into Terraform state using the TFSTATE_* values."
    Write-Host "2. Run workflow 100 to validate secrets, variables, OIDC, and Azure access."
    Write-Host "3. Run workflow 200, then workflow 210 for the first deployment."
} else {
    Write-Host "1. Monitor workflow 000 and confirm the bootstrap completes successfully."
    Write-Host "2. Run workflow 100 to validate secrets, variables, OIDC, and Azure access."
    Write-Host "3. Run workflow 200, then workflow 210 for the first deployment."
}

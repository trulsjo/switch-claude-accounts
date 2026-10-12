# Put in powershell profile (notepad $PROFILE), AFTER any oh-my-posh/starship init line

# 1. Core Logic: nearest .claude-account in current or ancestor folder wins
# Path of the nearest $Name in the current folder or an ancestor, or $null.
# Also used by the profile's .gh-token lookup.
function Find-UpwardFile([string]$Name) {
    $dir = (Get-Location -PSProvider FileSystem).ProviderPath
    while ($dir) {
        $file = Join-Path $dir $Name
        if (Test-Path -LiteralPath $file -PathType Leaf) { return $file }
        # Linked git worktree (e.g. ~\.herdr\worktrees\...): its .git is a file
        # "gitdir: <main>\.git\worktrees\<name>", so continue from the main checkout
        $git = Join-Path $dir '.git'
        if ((Test-Path -LiteralPath $git -PathType Leaf) -and
            "$(Get-Content -LiteralPath $git -First 1)" -match '^gitdir:\s*(.+?)[\\/]\.git[\\/]worktrees[\\/]') {
            $dir = [IO.Path]::GetFullPath($Matches[1], $dir)
            continue
        }
        $dir = Split-Path $dir -Parent   # "" after the drive root ends the loop
    }
    $null
}

function Get-ClaudeConfigContext {
    $file = Find-UpwardFile '.claude-account'
    $account = 'work'
    if ($file -and "$(Get-Content -LiteralPath $file -First 1)".Trim() -eq 'personal') { $account = 'personal' }

    if ($account -eq 'personal') {
        @{ Path = "$HOME\.claude-personal"; Type = 'Personal'; Color = 'Cyan' }
    } else {
        # $null = leave CLAUDE_CONFIG_DIR unset so Claude uses its defaults
        # (~/.claude and ~/.claude.json)
        @{ Path = $null; Type = 'Work'; Color = 'Green' }
    }
}

# 2. Main Wrapper: sets CLAUDE_CONFIG_DIR only for the duration of the call
function claude {
    $config = Get-ClaudeConfigContext
    $saved = $env:CLAUDE_CONFIG_DIR
    $env:CLAUDE_CONFIG_DIR = $config.Path   # $null removes the variable
    try {
        # claude.exe (native install) or claude.cmd (npm), whichever is on PATH
        & (Get-Command claude -CommandType Application | Select-Object -First 1) @args
    } finally {
        $env:CLAUDE_CONFIG_DIR = $saved
    }
}

# 3. Helper Function: configures the current folder
function Switch-ClaudeAccount {
    param([ValidateSet('work', 'personal')][string]$Account = 'personal')
    # Always write the marker: an explicit "work" overrides a "personal" marker further up
    Set-Content -LiteralPath (Join-Path $PWD.ProviderPath '.claude-account') -Value $Account -NoNewline
    $config = Get-ClaudeConfigContext
    Write-Host "Created marker file. This folder and subfolders now use $($config.Type)." -ForegroundColor $config.Color
}
Set-Alias -Name use-personal -Value Switch-ClaudeAccount

# 4. Prompt: oh-my-posh calls Set-PoshContext before each render (after it has
# captured $?), so the theme's "text" segment can show {{ .Env.CLAUDE_ACCOUNT }}.
# Must be an alias: its module's own empty Set-PoshContext would win over a function.
function Set-ClaudePoshContext {
    $env:CLAUDE_ACCOUNT = (Get-ClaudeConfigContext).Type
}
New-Alias -Name Set-PoshContext -Value Set-ClaudePoshContext -Scope Global -Force

# 5. GH_TOKEN: set or clear it from the nearest .gh-token before each prompt, by
# wrapping the existing prompt (oh-my-posh's, or the default) instead of replacing it.
# Guarded so re-sourcing doesn't make the wrapper call itself.
if (-not (Test-Path Function:\GhTokenInnerPrompt)) {
    ${function:GhTokenInnerPrompt} = ${function:prompt}
}

function Prompt {
    # Run the inner prompt first so it still sees the real $? / $LASTEXITCODE
    $inner = GhTokenInnerPrompt
    $tokenFile = Find-UpwardFile '.gh-token'
    if ($tokenFile) {
        $env:GH_TOKEN = "$(Get-Content -LiteralPath $tokenFile -Raw)".Trim()
    } else {
        Remove-Item env:GH_TOKEN -ErrorAction SilentlyContinue
    }
    $inner
}

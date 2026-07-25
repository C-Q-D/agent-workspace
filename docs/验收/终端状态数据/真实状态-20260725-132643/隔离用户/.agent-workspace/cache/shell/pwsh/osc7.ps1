# PaneFlow shell integration - OSC 7 CWD reporting (US-012)
# Non-destructive: wraps the existing `prompt` function so the user's
# prompt still renders. Loaded via `pwsh -NoExit -Command ". <this>"`.
# Dot-sourcing happens AFTER $PROFILE, so any user PATH mutations there
# have already run -- a one-shot prepend is sufficient. The `prompt`
# wrapper additionally re-asserts the prepend on every prompt for users
# who modify $env:PATH at runtime.

function global:__paneflow_path_prepend {
    if ([string]::IsNullOrEmpty($env:PANEFLOW_BIN_DIR)) { return }
    $sep = [System.IO.Path]::PathSeparator
    $entries = $env:PATH -split [regex]::Escape($sep) | Where-Object { $_ -ne $env:PANEFLOW_BIN_DIR }
    $env:PATH = (@($env:PANEFLOW_BIN_DIR) + $entries) -join $sep
}

function global:__paneflow_cwd_uri {
    $providerPath = (Get-Location).ProviderPath
    if ([string]::IsNullOrEmpty($providerPath)) { return $null }
    try {
        return ([System.Uri]$providerPath).AbsoluteUri
    } catch {
        return $null
    }
}

# Capture the CURRENT prompt as a ScriptBlock VALUE (snapshot) via
# `$function:prompt`, NOT `Get-Item function:prompt`. A FunctionInfo from
# Get-Item is a LIVE handle: its `.ScriptBlock` re-resolves to whatever
# `prompt` is at call time, which after we redefine `prompt` below is OUR
# wrapper -- so `& $prev.ScriptBlock` calls the wrapper again, recursing
# forever ("call depth overflow") and the prompt never renders. This bites
# hardest with Starship / oh-my-posh, which also redefine `prompt`. The
# $global:__paneflow_prompt_wrapped guard keeps a re-source from capturing
# our own wrapper as the "previous" prompt.
if (-not $global:__paneflow_prompt_wrapped) {
    $global:__paneflow_prev_prompt = $function:prompt
    function global:prompt {
        # Call the wrapped prompt FIRST, while $?/$LASTEXITCODE still reflect
        # the user's last command -- Starship / oh-my-posh read them to render
        # the exit-status segment. Our OSC 7 + PATH bookkeeping runs after.
        $__paneflow_out = if ($global:__paneflow_prev_prompt) { & $global:__paneflow_prev_prompt } else { "PS $($executionContext.SessionState.Path.CurrentLocation)> " }
        # OSC 7 with BEL terminator (matches zsh/bash/fish emitters). Use
        # [char]27 instead of `e: Windows PowerShell 5.1 treats `e as a
        # literal "e", which leaks "e]7;..." into the terminal.
        $__paneflow_cwd_uri = __paneflow_cwd_uri
        if ($__paneflow_cwd_uri) {
            [Console]::Write("$([char]27)]7;$__paneflow_cwd_uri$([char]7)")
        }
        __paneflow_path_prepend
        $__paneflow_out
    }
    $global:__paneflow_prompt_wrapped = $true
}
__paneflow_path_prepend

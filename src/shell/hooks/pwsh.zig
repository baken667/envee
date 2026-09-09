//! Hook-шаблон для pwsh.
//!
//! Содержимое перенесено байт в байт из Go-эталона
//! (internal/shell/shell.go, PwshAdapter.Init) генератором, не руками:
//! этот код исполняется в оболочке пользователя, и опечатка здесь стоит
//! дорого. Плейсхолдер {{.SelfPath}} подставляется в shell.writeInit.

pub const init_template: []const u8 =
    \\# envee shell hook for PowerShell
    \\#
    \\# Wrapping prompt is deliberate. Register-EngineEvent -SourceIdentifier
    \\# PowerShell.OnIdle runs its -Action in a separate runspace, so the $env:
    \\# assignments made there never reach your session.
    \\function global:_envee_hook {
    \\  $out = & "{{.SelfPath}}" --quiet eval pwsh 2>$null
    \\  if ($LASTEXITCODE -eq 0 -and $out) {
    \\    Invoke-Expression ($out -join "`n")
    \\  }
    \\}
    \\
    \\if (-not (Test-Path variable:global:_envee_original_prompt)) {
    \\  $global:_envee_original_prompt = $function:prompt
    \\  function global:prompt {
    \\    _envee_hook
    \\    & $global:_envee_original_prompt
    \\  }
    \\}
    \\
;

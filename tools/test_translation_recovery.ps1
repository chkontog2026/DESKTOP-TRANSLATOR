Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'Transcribe-And-Translate.ps1'
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Syntax errors' }
foreach ($node in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($node.Extent.Text))
}
$script:messages = New-Object System.Collections.Generic.List[string]
function Write-RunLog { param($Message) $script:messages.Add([string]$Message) }
function Write-RunWarning { param($Message) $script:messages.Add([string]$Message) }
function Start-Sleep { param($Seconds, $Milliseconds) if ($Milliseconds) { [Threading.Thread]::Sleep($Milliseconds) } }
$script:testFolder = Join-Path ([IO.Path]::GetTempPath()) ('translation-recovery-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($script:testFolder)
function Get-TranslationWorkerFunctionSource {
    return @'
function Invoke-OpenAITranslation {
    param($Text)
    $path = Join-Path 'FOLDER_PLACEHOLDER' ($Text + '.txt')
    $count = if (Test-Path -LiteralPath $path) { [int](Get-Content -LiteralPath $path) + 1 } else { 1 }
    Set-Content -LiteralPath $path -Value $count
    if ($Text -eq 'retry' -and $count -eq 1) { throw 'HTTP 503 system_cpu_overloaded' }
    if ($Text -eq 'permanent') { throw 'HTTP 401 invalid key' }
    if ($Text -eq 'unavailable') { throw 'HTTP 503 system_cpu_overloaded' }
    return ('translated ' + $Text)
}
'@.Replace('FOLDER_PLACEHOLDER', $script:testFolder.Replace("'", "''"))
}
function New-ItemForTest($index, $text) {
    [pscustomobject]@{ Index=$index; Mode='Text'; SourceText=$text; TargetLanguage='Greek'; Model='dummy'; ApiKey='dummy'; BaseUrl='https://example.invalid'; Provider='VNAI Pro Gemini'; EnableAutoGenderInference=$false; SubtitleContextHints=''; ChunkNumber=($index+1); ChunkCount=2 }
}
try {
    $items = @((New-ItemForTest 0 'retry'), (New-ItemForTest 1 'success'))
    $result = @(Invoke-ParallelTranslationWorkItems -WorkItems $items -MaxConcurrency 2)
    if ($result.Count -ne 2 -or $result[0].Text -ne 'translated retry' -or $result[1].Text -ne 'translated success') { throw 'Recovery/order failed' }
    if ([int](Get-Content (Join-Path $script:testFolder 'success.txt')) -ne 1) { throw 'Successful chunk was repeated' }
    if ([int](Get-Content (Join-Path $script:testFolder 'retry.txt')) -ne 2) { throw 'Failed chunk was not retried exactly once' }
    if (@($script:messages | Where-Object { $_ -eq 'Completed API chunk 1.' }).Count -ne 1) { throw 'Failed chunk was logged as completed' }
    foreach ($kind in @('permanent', 'unavailable')) {
        $caught = $false
        try { $null = Invoke-ParallelTranslationWorkItems -WorkItems @((New-ItemForTest 0 $kind)) -MaxConcurrency 2 }
        catch { $caught = $true }
        if (-not $caught) { throw 'Unrecoverable failure was ignored' }
        $expected = if ($kind -eq 'permanent') { 1 } else { 2 }
        if ([int](Get-Content (Join-Path $script:testFolder ($kind + '.txt'))) -ne $expected) { throw 'Retry bound/permanent error handling failed' }
    }
    'PASS: transient failures recovered sequentially; successes retained; order preserved; permanent errors not retried; retry count bounded; logging accurate.'
}
finally {
    foreach ($name in @('retry.txt', 'success.txt', 'permanent.txt', 'unavailable.txt')) {
        $path = Join-Path $script:testFolder $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
    }
    [IO.Directory]::Delete($script:testFolder)
}

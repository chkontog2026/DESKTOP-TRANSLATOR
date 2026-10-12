param([string]$VerifySavedConfig = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'Transcribe-And-Translate.ps1'
$parseErrors = $null
$tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Source has PowerShell syntax errors.' }
# Load functions only: never import the real .env or start a transcription.
$functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)
foreach ($function in $functions) { . ([scriptblock]::Create($function.Extent.Text)) }
function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Read-MaskedApiKeyDialog { param($Title, $Label) return $script:DialogResult }
$script:Headless = $false

# Dummy process values only. No real credentials are read, printed, or changed.
$env:OPENAI_API_KEY = 'old-openai-test'
$env:VNAIPRO_API_KEY = 'old-vnaipro-test'
$env:VNAIPRO_CLAUDE_API_KEY = 'old-vnaipro-claude-test'
$env:VNAIPRO_GEMINI_API_KEY = 'old-vnaipro-gemini-test'
$env:GEMINI_API_KEY = 'old-gemini-test'
$env:GOOGLE_API_KEY = 'old-google-test'
$env:AIPRIMETECH_API_KEY = 'old-prime-test'
$env:ANTHROPIC_AUTH_TOKEN = 'old-anthropic-test'
$env:ELEVENLABS_API_KEY = 'old-elevenlabs-test-key-123'
$providers = @('OpenAI', 'VNAI Pro', 'VNAI Pro Claude', 'VNAI Pro Gemini', 'Gemini', 'AI Prime Tech')

Assert ((Get-DefaultTranslationBaseUrl 'VNAI Pro') -eq 'https://apikey.vnaipro.app/v1') 'VNAI Pro endpoint is incorrect.'
Assert ((Get-DefaultTranslationBaseUrl 'VNAI Pro Claude') -eq 'https://apikey.vnaipro.app/v1') 'VNAI Pro Claude endpoint is incorrect.'
Assert ((Get-DefaultTranslationBaseUrl 'VNAI Pro Gemini') -eq 'https://apikey.vnaipro.app/v1') 'VNAI Pro Gemini endpoint is incorrect.'
Assert ((Get-ProviderConfigKeyName 'VNAI Pro') -ne (Get-ProviderConfigKeyName 'VNAI Pro Claude')) 'VNAI Pro GPT and Claude keys are not isolated.'
Assert ((Get-ProviderConfigKeyName 'VNAI Pro Gemini') -notin @((Get-ProviderConfigKeyName 'VNAI Pro'), (Get-ProviderConfigKeyName 'VNAI Pro Claude'), (Get-ProviderConfigKeyName 'Gemini'))) 'VNAI Pro Gemini key is not isolated.'
Assert ((Get-DefaultTranslationModel 'VNAI Pro') -eq 'gpt-5.6-sol') 'VNAI Pro default model is incorrect.'
Assert ((Get-DefaultTranslationModel 'VNAI Pro Claude') -eq 'claude-sonnet-4-6') 'VNAI Pro Claude default model is incorrect.'
Assert ((Get-DefaultTranslationModel 'VNAI Pro Gemini') -eq 'gemini-3.8-flash') 'VNAI Pro Gemini default model is incorrect.'
Assert (@(Get-TranslationModelsForProvider 'VNAI Pro') -contains 'gpt-5.6-terra') 'VNAI Pro model list is incomplete.'
Assert (@(Get-TranslationModelsForProvider 'VNAI Pro').Count -eq 2) 'VNAI Pro GPT model list has an unexpected size.'
Assert (@(Get-TranslationModelsForProvider 'VNAI Pro Claude') -contains 'claude-fable-5-1') 'VNAI Pro Claude Fable model is missing.'
Assert (@(Get-TranslationModelsForProvider 'VNAI Pro Claude') -contains 'claude-opus-4-7') 'VNAI Pro Claude Opus model is missing.'
Assert (@(Get-TranslationModelsForProvider 'VNAI Pro Claude') -contains 'claude-sonnet-4-6') 'VNAI Pro Claude Sonnet model is missing.'
Assert (@(Get-TranslationModelsForProvider 'VNAI Pro Claude').Count -eq 9) 'VNAI Pro Claude model list has an unexpected size.'
Assert (@(Get-TranslationModelsForProvider 'VNAI Pro Gemini') -contains 'gemini-3.6-flash') 'VNAI Pro Gemini model list is incomplete.'

function Invoke-RestMethod {
    param($Uri, $Headers, $Method, $TimeoutSec, $ErrorAction)
    return [pscustomobject]@{
        data = @(
            [pscustomobject]@{ id = 'gemini-live-model-a' },
            [pscustomobject]@{ id = 'gemini-live-model-b' }
        )
    }
}
$discoveredVnaiModels = @(Get-VnaiProAvailableModels -ApiKey 'dummy-vnai-gemini-key' -Provider 'VNAI Pro Gemini')
Assert (($discoveredVnaiModels -join ',') -eq 'gemini-live-model-a,gemini-live-model-b') 'VNAI model discovery did not return the key-specific models.'
function Write-RunWarning { param($Message) }
$resolvedVnaiGeminiModel = Assert-VnaiProModelAccess -ApiKey 'dummy-vnai-gemini-key' -Model 'gemini-old-model' -Provider 'VNAI Pro Gemini'
Assert ($resolvedVnaiGeminiModel -eq 'gemini-live-model-a') 'VNAI Gemini did not fall back to an assigned Gemini model.'
Remove-Item Function:\Invoke-RestMethod

Assert (-not (Test-ElevenLabsApiKeyFormat '27dac612d46a5771e1dee01ecdc7b74615190bd87f042ebce402bcd5dced6a7d')) 'An ElevenLabs key ID was accepted as a secret.'
Assert (Test-ElevenLabsApiKeyFormat 'sk_test-elevenlabs-secret-123') 'A valid sk_ API key was rejected.'
$sanitized = Protect-SensitiveApiErrorText 'Incorrect API key provided: sk-zbDco***************************************oJ35.'
Assert ($sanitized -notmatch 'sk-zbDco|oJ35') 'An API key fragment was left in the sanitized error.'
Assert ($sanitized -match '\[REDACTED_API_KEY\]') 'Sanitized API error did not contain a redaction marker.'
$workerFunctionSource = Get-TranslationWorkerFunctionSource
Assert ($workerFunctionSource -match 'function Protect-SensitiveApiErrorText') 'Parallel translation workers are missing API error sanitization.'

if ($VerifySavedConfig) {
    $script:ConfigPath = $VerifySavedConfig
    foreach ($provider in $providers) {
        $expected = 'new-' + (Get-ProviderConfigKeyName $provider) + '-test'
        Assert ((Get-TranslationApiKey $provider) -eq $expected) 'Saved key did not survive process restart.'
    }
    'PASS: saved provider keys override stale environment keys in a fresh process.'
    exit 0
}

$script:ConfigPath = Join-Path ([IO.Path]::GetTempPath()) ('translation-key-test-' + [guid]::NewGuid().ToString('N') + '.json')
try {
    Save-LocalConfig ([pscustomobject]@{ UnrelatedSetting = 'preserve-me' })
    $savedVnaiEnvironment = $env:VNAIPRO_API_KEY
    Remove-Item Env:\VNAIPRO_API_KEY -ErrorAction SilentlyContinue
    $script:DialogResult = 'new-VNAIPro-interactive-test'
    $promptedVnaiKey = Get-TranslationApiKey 'VNAI Pro'
    Assert ($promptedVnaiKey -eq $script:DialogResult) 'Missing VNAI Pro key did not use the visible masked prompt.'
    Assert ((Get-TranslationApiKey 'VNAI Pro') -eq $script:DialogResult) 'Prompted VNAI Pro key was not saved as preferred.'
    $env:VNAIPRO_API_KEY = $savedVnaiEnvironment
    'PASS: missing desktop key uses the visible masked prompt and persists locally.'
    Save-LocalConfig ([pscustomobject]@{ UnrelatedSetting = 'preserve-me' })

    foreach ($provider in $providers) {
        Save-TranslationApiKey $provider 'legacy-test'
        Assert ((Get-TranslationApiKey $provider) -ne 'legacy-test') 'Legacy environment precedence changed.'
        $script:DialogResult = 'new-' + (Get-ProviderConfigKeyName $provider) + '-test'
        $result = Read-AndSaveTranslationApiKey $provider
        Assert ($result -eq $script:DialogResult) 'Save returned unexpected result.'
        Assert ((Get-TranslationApiKey $provider) -eq $script:DialogResult) 'Selected key was not used immediately.'
    }
    Assert ((Get-LocalConfig).UnrelatedSetting -eq 'preserve-me') 'Unrelated configuration changed.'
    'PASS: independent provider keys, immediate selection, existing configuration preserved.'

    $before = [IO.File]::ReadAllText($script:ConfigPath)
    foreach ($inputValue in @($null, '', '   ')) {
        $script:DialogResult = $inputValue
        $result = Read-AndSaveTranslationApiKey 'Gemini'
        Assert ($null -eq $result) 'Cancel or empty input should not save.'
    }
    $script:DialogResult = 'invalid key with spaces'
    $rejected = $false
    try { $null = Read-AndSaveTranslationApiKey 'OpenAI' } catch { $rejected = $true }
    Assert $rejected 'Malformed input was accepted.'
    $null = Read-AndSaveTranslationApiKey 'Local NLLB'
    Assert ([IO.File]::ReadAllText($script:ConfigPath) -ceq $before) 'Cancel, invalid input, or Local NLLB changed configuration.'
    'PASS: cancellation, empty input, invalid input, and Local NLLB preserve stored keys.'

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath -VerifySavedConfig $script:ConfigPath
    Assert ($LASTEXITCODE -eq 0) 'Restart verification failed.'

    $script:DialogResult = 'sk_new-elevenlabs-test-key-123'
    $null = Read-AndSaveTranslationApiKey 'ElevenLabs Dubbing'
    Assert ((Get-ElevenLabsApiKey) -eq $script:DialogResult) 'Dubbing did not update the shared ElevenLabs key.'
    'PASS: ElevenLabs Dubbing uses the existing shared-key save flow.'
}
finally {
    if (Test-Path -LiteralPath $script:ConfigPath) { Remove-Item -LiteralPath $script:ConfigPath }
}

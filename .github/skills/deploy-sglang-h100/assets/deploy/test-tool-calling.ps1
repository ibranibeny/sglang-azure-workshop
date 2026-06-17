# Tests the public SGLang endpoint end-to-end from Windows: health, models, chat,
# and tool-calling. Run from a Windows PowerShell terminal (NOT WSL, which is
# blocked by Global Secure Access).
#
#   pwsh -File .\test-tool-calling.ps1
#   # or just:  .\test-tool-calling.ps1

$ErrorActionPreference = 'Stop'

$Base  = 'https://openai.contoso.day'
$Model = 'Qwen/Qwen3.6-35B-A3B-FP8'

# Load API key from the git-ignored secret file.
$keyFile = Join-Path $PSScriptRoot '.secrets\api_key'
if (-not (Test-Path $keyFile)) { throw "API key file not found: $keyFile (run .\00-genkey.sh first)" }
$Key = (Get-Content $keyFile -Raw).Trim()
$headers = @{ Authorization = "Bearer $Key"; 'Content-Type' = 'application/json' }

function Pass($m) { Write-Host "PASS " -ForegroundColor Green -NoNewline; Write-Host $m }
function Fail($m) { Write-Host "FAIL " -ForegroundColor Red   -NoNewline; Write-Host $m }

Write-Host "`n=== 1. Health ===" -ForegroundColor Cyan
try {
  $h = Invoke-WebRequest -Uri "$Base/health" -TimeoutSec 15 -UseBasicParsing
  if ($h.StatusCode -eq 200) { Pass "health HTTP 200" } else { Fail "health HTTP $($h.StatusCode)" }
} catch { Fail "health unreachable: $($_.Exception.Message)" }

Write-Host "`n=== 2. Models ===" -ForegroundColor Cyan
try {
  $m = Invoke-RestMethod -Uri "$Base/v1/models" -Headers $headers -TimeoutSec 15
  Pass "model id: $($m.data[0].id)"
} catch { Fail "models: $($_.Exception.Message)" }

Write-Host "`n=== 3. Basic chat ===" -ForegroundColor Cyan
$chatBody = @{
  model       = $Model
  messages    = @(@{ role = 'user'; content = 'Say exactly: HELLO_WORKS' })
  max_tokens  = 50
  temperature = 0
} | ConvertTo-Json -Depth 8
try {
  $c = Invoke-RestMethod -Uri "$Base/v1/chat/completions" -Method Post -Headers $headers -Body $chatBody -TimeoutSec 60
  Pass "chat content: $($c.choices[0].message.content)"
} catch { Fail "chat: $($_.Exception.Message)" }

Write-Host "`n=== 4. Tool calling (THE KEY TEST) ===" -ForegroundColor Cyan
$toolBody = @{
  model    = $Model
  messages = @(@{ role = 'user'; content = 'What is the weather in Jakarta? Call the get_weather tool.' })
  tools    = @(@{
      type     = 'function'
      function = @{
        name        = 'get_weather'
        description = 'Get current weather for a city'
        parameters  = @{
          type       = 'object'
          properties = @{ city = @{ type = 'string'; description = 'City name' } }
          required   = @('city')
        }
      }
    })
  tool_choice = 'auto'
  max_tokens  = 256
  temperature = 0
} | ConvertTo-Json -Depth 12
try {
  $t  = Invoke-RestMethod -Uri "$Base/v1/chat/completions" -Method Post -Headers $headers -Body $toolBody -TimeoutSec 60
  $ch = $t.choices[0]
  Write-Host "  finish_reason: $($ch.finish_reason)"
  if ($ch.message.tool_calls) {
    foreach ($tc in $ch.message.tool_calls) {
      Write-Host "  tool: $($tc.function.name)  args: $($tc.function.arguments)" -ForegroundColor Green
    }
    Pass 'TOOL_CALLING_WORKS'
  } else {
    Fail "NO tool_calls. content: $($ch.message.content)"
  }
} catch { Fail "tool call: $($_.Exception.Message)" }

Write-Host ""

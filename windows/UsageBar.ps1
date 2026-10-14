# UsageBar for Windows: Cursor and Claude usage in a thin always-on-top strip.
#
# - Strip (top center): the account that sent the latest request: blinking dot, account tag,
#   amount and two tiny vertical usage bars. Click it for the detail panel; right-click for settings.
# - Accounts are found automatically:
#     Cursor: %APPDATA%\Cursor (default) and any %USERPROFILE%\.cursor-<name> (cursor --user-data-dir)
#     Claude: %USERPROFILE%\.claude (default) and any %USERPROFILE%\.claude-<name> (CLAUDE_CONFIG_DIR)
# - Tokens are read from the official apps' own local login on every request; never written or logged.
#
#   powershell -File UsageBar.ps1 -Probe    prints every account and its usage, without the UI.

param([switch]$Probe)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Net.Http
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------------------------------------
# Strings
# ---------------------------------------------------------------------------------------------

$script:TR = (Get-UICulture).TwoLetterISOLanguageName -eq "tr" -or (Get-Culture).TwoLetterISOLanguageName -eq "tr"
function T([string]$en, [string]$tr) { if ($script:TR) { $tr } else { $en } }

$L = @{
    now          = T "now" "şimdi"
    d            = T "d" "g"
    h            = T "h" "s"
    m            = T "m" "dk"
    resetsIn     = T "resets in {0}" "{0} sonra sıfırlanır"
    cycleEndsIn  = T "cycle ends in {0}" "dönem {0} sonra biter"
    updated      = T "updated {0}" "güncellendi {0}"
    offline      = T "offline" "bağlantı yok"
    loading      = T "loading…" "yükleniyor…"
    active       = T "active" "aktif"
    hint         = T "right-click: settings" "sağ tık: ayarlar"
    refresh      = T "Refresh" "Yenile"
    openUsage    = T "Open usage dashboard" "Kullanım panelini aç"
    pinTop       = T "Move back to top center" "Üst ortaya sabitle"
    quit         = T "Quit" "Kapat"
    notFound     = T "No signed-in account found" "Giriş yapılmış hesap yok"
    noAccounts   = T "No Cursor or Claude Code login found." "Cursor ya da Claude Code girişi bulunamadı."
    noneSelected = T "No account selected. Right-click to pick some." "Hesap seçili değil. Sağ tıklayıp seçin."
    extraSpend   = T "Extra spend" "Ekstra harcama"
    team         = T "Team" "Takım"
    you          = T "You" "Sen"
    limit        = T "Limit" "Limit"
    planSpend    = T "Plan usage" "Plan kullanımı"
    included     = T "included" "dahil"
    autoMeter    = "Auto + Composer"
    apiMeter     = T "API (named models)" "API (seçili modeller)"
    cursorNoTok  = T "Sign in to Cursor first." "Önce Cursor'a giriş yapın."
    session      = T "Session (5h)" "Oturum (5 sa)"
    weekly       = T "Weekly (all models)" "Haftalık (tüm modeller)"
    weeklyOpus   = T "Weekly (Opus)" "Haftalık (Opus)"
    weeklySonnet = T "Weekly (Sonnet)" "Haftalık (Sonnet)"
    extraUsage   = T "Extra usage" "Ekstra kullanım"
    plan         = T "Plan" "Plan"
    claudeNoCred = T "No Claude Code login found. Run claude and sign in." "Claude Code girişi bulunamadı. claude çalıştırıp giriş yapın."
    claudeExpird = T "Claude login expired. Open Claude Code once to refresh it." "Claude oturumunun süresi doldu. Yenilemek için Claude Code'u bir kez açın."
    rateLimited  = T "Rate limited, showing last value. Will retry." "İstek sınırı aşıldı, son değer gösteriliyor. Tekrar denenecek."
}

$Providers = [ordered]@{
    cursor = @{ Title = "Cursor"; Url = "https://cursor.com/dashboard?tab=usage"; Poll = 15 }
    claude = @{ Title = "Claude"; Url = "https://claude.ai/settings/usage"; Poll = 60 }
}

# ---------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------

$Inv = [Globalization.CultureInfo]::InvariantCulture
$userHome = [Environment]::GetFolderPath("UserProfile")
$appData = [Environment]::GetFolderPath("ApplicationData")
if ($IsMacOS) { $appData = Join-Path $userHome "Library/Application Support" }  # dev/test only
$settingsDir = Join-Path ([Environment]::GetFolderPath("LocalApplicationData")) "UsageBar"
$settingsFile = Join-Path $settingsDir "settings.json"

function Get-Now { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0 }

function Num($v) {
    if ($null -eq $v) { return $null }
    if ($v -is [double] -or $v -is [int] -or $v -is [long] -or $v -is [decimal] -or $v -is [single]) { return [double]$v }
    $out = 0.0
    if ([double]::TryParse([string]$v, [Globalization.NumberStyles]::Float, $Inv, [ref]$out)) { return $out }
    return $null
}

function Format-Money([double]$value, [string]$currency = "USD") {
    $symbol = if ($currency -eq "USD") { '$' } else { "$currency " }
    return $symbol + $value.ToString("0.00", $Inv)
}

function Format-Countdown([double]$target) {
    $s = [int]($target - (Get-Now))
    if ($s -le 0) { return $L.now }
    $days = [math]::Floor($s / 86400)
    $hours = [math]::Floor(($s % 86400) / 3600)
    $mins = [math]::Floor(($s % 3600) / 60)
    if ($days -gt 0) { return "$days$($L.d) $hours$($L.h)" }
    if ($hours -gt 0) { return "$hours$($L.h) $mins$($L.m)" }
    return "$([math]::Max(1, $mins))$($L.m)"
}

function ConvertTo-Unix($v) {
    if ($null -eq $v) { return $null }
    if ($v -is [datetime]) { return ([DateTimeOffset]$v.ToUniversalTime()).ToUnixTimeSeconds() }
    try { return [DateTimeOffset]::Parse([string]$v, $Inv).ToUnixTimeSeconds() } catch { return $null }
}

function New-UsageError([string]$short, [string]$long, [switch]$RateLimit, $RetryAfter = $null) {
    @{ Short = $short; Long = $long; RateLimit = [bool]$RateLimit; RetryAfter = $RetryAfter }
}

# ---------------------------------------------------------------------------------------------
# Settings (selected accounts, last-used times)
# ---------------------------------------------------------------------------------------------

$script:disabled = @{}
$script:lastActive = @{}

function Read-Settings {
    if (-not (Test-Path -LiteralPath $settingsFile)) { return }
    try {
        $j = [IO.File]::ReadAllText($settingsFile) | ConvertFrom-Json
        foreach ($id in @($j.disabled)) { if ($id) { $script:disabled[[string]$id] = $true } }
        if ($j.lastActive) {
            foreach ($p in $j.lastActive.PSObject.Properties) { $script:lastActive[$p.Name] = [double](Num $p.Value) }
        }
    }
    catch { }
}

function Save-Settings {
    if ($Probe) { return }
    try {
        New-Item -ItemType Directory -Force -Path $settingsDir | Out-Null
        $data = @{ disabled = @($script:disabled.Keys); lastActive = $script:lastActive }
        [IO.File]::WriteAllText($settingsFile, ($data | ConvertTo-Json -Depth 3))
    }
    catch { }
}

function Get-LastActive([string]$id) { if ($script:lastActive.ContainsKey($id)) { $script:lastActive[$id] } else { 0.0 } }

function Set-Active([string]$id, [double]$when) {
    if ($when -le (Get-LastActive $id)) { return }
    $script:lastActive[$id] = $when
    Save-Settings
}

# ---------------------------------------------------------------------------------------------
# Account discovery
# ---------------------------------------------------------------------------------------------

function Find-Sqlite {
    $beside = Join-Path $PSScriptRoot "sqlite3.exe"
    if (Test-Path -LiteralPath $beside) { return $beside }
    $cmd = Get-Command sqlite3 -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($path in @(
        "$env:LOCALAPPDATA\Android\Sdk\platform-tools\sqlite3.exe",
        "C:\flutter\bin\cache\artifacts\android-platform-tools\sqlite3.exe"
    )) {
        if (Test-Path -LiteralPath $path) { return $path }
    }
    return $null
}
$script:sqlite = Find-Sqlite

function Read-CursorValues([string]$db, [string[]]$keys) {
    $result = @{}
    if (-not $script:sqlite -or -not (Test-Path -LiteralPath $db)) { return $result }
    $ErrorActionPreference = "Continue"
    $uri = "file:" + (($db -replace '\\', '/') -replace '%', '%25' -replace '\?', '%3f' -replace '#', '%23') + "?mode=ro"
    $list = ($keys | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ","
    try {
        $out = & $script:sqlite -separator "|" $uri "SELECT key, value FROM ItemTable WHERE key IN ($list);" 2>$null
        foreach ($line in @($out)) {
            $i = "$line".IndexOf("|")
            if ($i -gt 0) { $result["$line".Substring(0, $i)] = "$line".Substring($i + 1).Trim() }
        }
    }
    catch { }
    return $result
}

function New-Account([string]$provider, [string]$source, [bool]$isDefault, $email, [string]$name) {
    [pscustomobject]@{
        Id = "${provider}:$source"; Provider = $provider; Source = $source
        IsDefault = $isDefault; Email = $email; Name = $name
    }
}

function Get-HomeDirs([string]$prefix) {
    @(Get-ChildItem -LiteralPath $userHome -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name.StartsWith($prefix) } | Sort-Object Name)
}

function Get-CursorAccounts {
    $candidates = @()
    foreach ($d in @(Get-ChildItem -LiteralPath $appData -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name.StartsWith("Cursor") } | Sort-Object Name)) {
        $label = if ($d.Name -eq "Cursor") { "Cursor" } else { $d.Name.Substring(6).Trim(" -_".ToCharArray()) }
        $candidates += , @((Join-Path $d.FullName "User\globalStorage\state.vscdb"), $label, ($d.Name -eq "Cursor"))
    }
    foreach ($d in Get-HomeDirs ".cursor-") {
        $candidates += , @((Join-Path $d.FullName "User\globalStorage\state.vscdb"), $d.Name.Substring(8), $false)
    }

    $byKey = [ordered]@{}
    foreach ($c in $candidates) {
        $db = $c[0] -replace '\\', [IO.Path]::DirectorySeparatorChar
        if (-not (Test-Path -LiteralPath $db)) { continue }
        $values = Read-CursorValues $db @("cursorAuth/accessToken", "cursorAuth/cachedEmail")
        if (-not $values["cursorAuth/accessToken"]) { continue }
        $email = $values["cursorAuth/cachedEmail"]
        $account = New-Account "cursor" $db $c[2] $email $c[1]
        $key = if ($email) { $email } else { $db }
        if ($byKey.Contains($key)) {
            # Same login in two folders: prefer the explicitly named one (e.g. "personal" over the default).
            if ($byKey[$key].IsDefault -and -not $account.IsDefault) { $byKey[$key] = $account }
        }
        else { $byKey[$key] = $account }
    }
    return @($byKey.Values)
}

function ConvertFrom-ClaudeCredential($json) {
    $o = $json.claudeAiOauth
    if (-not $o -or -not $o.accessToken) { return $null }
    $exp = Num $o.expiresAt
    @{ Token = [string]$o.accessToken; ExpiresAt = $(if ($exp) { $exp / 1000 } else { 0 }); Plan = $o.subscriptionType }
}

function Get-ClaudeCredential([string]$dir, [bool]$isDefault) {
    $found = @()
    $file = Join-Path $dir ".credentials.json"
    if (Test-Path -LiteralPath $file) {
        try { $found += ConvertFrom-ClaudeCredential ([IO.File]::ReadAllText($file) | ConvertFrom-Json) } catch { }
    }
    if ($IsMacOS -and $isDefault) {
        # dev/test only: macOS keeps the default login in the Keychain.
        try {
            $raw = & /usr/bin/security find-generic-password -s "Claude Code-credentials" -w 2>$null
            if ($LASTEXITCODE -eq 0 -and $raw) { $found += ConvertFrom-ClaudeCredential (($raw -join "") | ConvertFrom-Json) }
        }
        catch { }
    }
    $found = @($found | Where-Object { $_ })
    if ($found.Count -eq 0) { return $null }
    return ($found | Sort-Object { $_.ExpiresAt } -Descending | Select-Object -First 1)
}

function Get-ClaudeAccounts {
    $dirs = @(, @((Join-Path $userHome ".claude"), $true))
    foreach ($d in Get-HomeDirs ".claude-") { $dirs += , @($d.FullName, $false) }
    if ($env:CLAUDE_CONFIG_DIR -and -not ($dirs | Where-Object { $_[0] -eq $env:CLAUDE_CONFIG_DIR })) {
        $dirs += , @($env:CLAUDE_CONFIG_DIR, $false)
    }

    $seen = @{}
    $accounts = @()
    foreach ($entry in $dirs) {
        $dir = $entry[0]; $isDefault = $entry[1]
        if (-not (Get-ClaudeCredential $dir $isDefault)) { continue }
        # The default dir keeps its settings next to it (~\.claude.json), custom dirs inside.
        $configFile = if ($isDefault) { Join-Path $userHome ".claude.json" } else { Join-Path $dir ".claude.json" }
        $email = $null
        if (Test-Path -LiteralPath $configFile) {
            try {
                $text = [IO.File]::ReadAllText($configFile)
                $m = [regex]::Match($text, '"oauthAccount"\s*:\s*\{[^{}]*?"emailAddress"\s*:\s*"([^"]+)"')
                if ($m.Success) { $email = $m.Groups[1].Value }
            }
            catch { }
        }
        if ($email) {
            if ($seen.ContainsKey($email)) { continue }
            $seen[$email] = $true
        }
        $leaf = Split-Path $dir -Leaf
        $name = if ($isDefault) { "Claude" } elseif ($leaf.StartsWith(".claude-")) { $leaf.Substring(8) } else { $leaf }
        $accounts += New-Account "claude" $dir $isDefault $email $name
    }
    return $accounts
}

# Claude Code writes a transcript line for every request, so its newest mtime is an exact "last used".
function Get-ClaudeLastActivity([string]$dir) {
    $projects = Join-Path $dir "projects"
    if (-not (Test-Path -LiteralPath $projects)) { return $null }
    $newest = [datetime]::MinValue
    try {
        foreach ($f in (New-Object IO.DirectoryInfo $projects).EnumerateFiles("*.jsonl", [IO.SearchOption]::AllDirectories)) {
            if ($f.LastWriteTimeUtc -gt $newest) { $newest = $f.LastWriteTimeUtc }
        }
    }
    catch { }
    if ($newest -eq [datetime]::MinValue) { return $null }
    return ([DateTimeOffset]$newest).ToUnixTimeMilliseconds() / 1000.0
}

# ---------------------------------------------------------------------------------------------
# Fetching (async HTTP so the UI never freezes) and parsing
# ---------------------------------------------------------------------------------------------

$script:http = New-Object System.Net.Http.HttpClient
$script:http.Timeout = [TimeSpan]::FromSeconds(20)

function Start-Fetch($account) {
    if ($account.Provider -eq "cursor") {
        $token = (Read-CursorValues $account.Source @("cursorAuth/accessToken"))["cursorAuth/accessToken"]
        if (-not $token) { return @{ Error = (New-UsageError $L.offline $L.cursorNoTok) } }
        $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Post), "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
        $req.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue "Bearer", $token
        $req.Content = New-Object System.Net.Http.StringContent "{}"
        $req.Content.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue "application/json"
        return @{ Task = $script:http.SendAsync($req) }
    }

    $cred = Get-ClaudeCredential $account.Source $account.IsDefault
    if (-not $cred) { return @{ Error = (New-UsageError $L.offline $L.claudeNoCred) } }
    if ($cred.ExpiresAt -gt 0 -and $cred.ExpiresAt -lt (Get-Now)) { return @{ Error = (New-UsageError $L.offline $L.claudeExpird) } }
    $req = New-Object System.Net.Http.HttpRequestMessage ([System.Net.Http.HttpMethod]::Get), "https://api.anthropic.com/api/oauth/usage"
    $req.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue "Bearer", $cred.Token
    [void]$req.Headers.TryAddWithoutValidation("anthropic-beta", "oauth-2025-04-20")
    [void]$req.Headers.TryAddWithoutValidation("User-Agent", "UsageBar/1.0")
    return @{ Task = $script:http.SendAsync($req); Plan = $cred.Plan }
}

function New-Meter([string]$label, $pct, $detail) { @{ Label = $label; Pct = $pct; Detail = $detail } }
function New-Amount([string]$label, [string]$value, [bool]$big) { @{ Label = $label; Value = $value; Big = $big } }

function ConvertFrom-CursorUsage($json) {
    $spend = $json.spendLimitUsage
    function Dollars($v) { $n = Num $v; if ($null -eq $n) { $null } else { $n / 100 } }
    $teamUsed = Dollars $spend.pooledUsed; if ($null -eq $teamUsed) { $teamUsed = 0.0 }
    $mine = Dollars $spend.individualUsed; if ($null -eq $mine) { $mine = 0.0 }
    $limit = Dollars $spend.pooledLimit; if ($null -eq $limit) { $limit = Dollars $spend.individualLimit }; if ($null -eq $limit) { $limit = 0.0 }
    $isTeam = "$($spend.limitType)" -eq "team"

    $shown = $teamUsed
    if (-not $isTeam) { $shown = if ($mine -gt 0) { $mine } else { $teamUsed } }
    $ratio = if ($limit -gt 0) { $shown / $limit } else { 0.0 }
    $headline = if ($isTeam) { "$(Format-Money $teamUsed) · $(Format-Money $mine)" } else { Format-Money $shown }

    $amounts = @()
    if ($isTeam) {
        $amounts += New-Amount "$($L.extraSpend) · $($L.team)" (Format-Money $teamUsed) $true
        $amounts += New-Amount "$($L.extraSpend) · $($L.you)" (Format-Money $mine) $true
    }
    else { $amounts += New-Amount $L.extraSpend (Format-Money $shown) $true }
    if ($limit -gt 0) { $amounts += New-Amount $L.limit (Format-Money $limit) $false }

    $plan = $json.planUsage
    $total = Num $plan.totalSpend
    if ($null -ne $total) {
        $value = Format-Money ($total / 100)
        $incl = Num $plan.limit; if ($null -eq $incl) { $incl = Num $plan.includedSpend }
        if ($null -ne $incl) { $value += " / " + (Format-Money ($incl / 100)) + " " + $L.included }
        $amounts += New-Amount $L.planSpend $value $false
    }
    $autoPct = Num $plan.autoPercentUsed
    $apiPct = Num $plan.apiPercentUsed
    $meters = @((New-Meter $L.autoMeter $autoPct $null), (New-Meter $L.apiMeter $apiPct $null))

    $footnote = $null
    $end = Num $json.billingCycleEnd
    if ($null -ne $end) { $footnote = $L.cycleEndsIn -f (Format-Countdown ($end / 1000)) }

    # Plan spend grows with nearly every request, so it is the best "just used" signal.
    $activity = $teamUsed + $mine + [double](Num $plan.totalSpend) / 100 + [double]$autoPct + [double]$apiPct
    @{ Headline = $headline; Ratio = $ratio; Meters = $meters; Amounts = $amounts; Footnote = $footnote; ActivityKey = $activity }
}

function ConvertFrom-ClaudeUsage($json, $planName) {
    function Meter($key, $label) {
        $w = $json.$key
        if (-not $w) { return $null }
        $detail = $null
        $reset = ConvertTo-Unix $w.resets_at
        if ($reset) { $detail = $L.resetsIn -f (Format-Countdown $reset) }
        New-Meter $label (Num $w.utilization) $detail
    }

    # Session + weekly always come first: they are the two strip bars.
    $session = Meter "five_hour" $L.session; if (-not $session) { $session = New-Meter $L.session $null $null }
    $weekly = Meter "seven_day" $L.weekly; if (-not $weekly) { $weekly = New-Meter $L.weekly $null $null }
    $meters = @($session, $weekly)
    $opus = Meter "seven_day_opus" $L.weeklyOpus; if ($opus) { $meters += $opus }
    $sonnet = Meter "seven_day_sonnet" $L.weeklySonnet; if ($sonnet) { $meters += $sonnet }

    # Extra (pay-as-you-go) usage, if the account has it turned on.
    $extraUsed = $null; $extraLimit = $null; $currency = "USD"
    if ($json.spend -and $json.spend.enabled -eq $true) {
        foreach ($k in "used", "limit") {
            $mny = $json.spend.$k
            $minor = if ($mny) { Num $mny.amount_minor } else { $null }
            if ($null -eq $minor) { continue }
            if ($mny.currency) { $currency = [string]$mny.currency }
            $exp = Num $mny.exponent; if ($null -eq $exp) { $exp = 2 }
            if ($k -eq "used") { $extraUsed = $minor / [math]::Pow(10, $exp) } else { $extraLimit = $minor / [math]::Pow(10, $exp) }
        }
        if ($null -eq $extraUsed) { $extraUsed = 0.0 }
    }
    elseif ($json.extra_usage -and $json.extra_usage.is_enabled -eq $true) {
        $dp = Num $json.extra_usage.decimal_places; if ($null -eq $dp) { $dp = 2 }
        $scale = [math]::Pow(10, $dp)
        if ($json.extra_usage.currency) { $currency = [string]$json.extra_usage.currency }
        $extraUsed = [double](Num $json.extra_usage.used_credits) / $scale
        $ml = Num $json.extra_usage.monthly_limit
        if ($null -ne $ml) { $extraLimit = $ml / $scale }
    }

    $sPct = [double]$session.Pct; $wPct = [double]$weekly.Pct
    $ratio = [math]::Max($sPct, $wPct) / 100
    $amounts = @()
    if ($null -ne $extraUsed) {
        $headline = Format-Money $extraUsed $currency
        $amounts += New-Amount $L.extraUsage $headline $true
        if ($extraLimit -gt 0) {
            $amounts += New-Amount $L.limit (Format-Money $extraLimit $currency) $false
            $ratio = [math]::Max($ratio, $extraUsed / $extraLimit)
        }
    }
    else { $headline = "$([math]::Round($sPct))% · $([math]::Round($wPct))%" }
    if ($planName) { $amounts += New-Amount $L.plan ((Get-Culture).TextInfo.ToTitleCase([string]$planName)) $false }

    @{ Headline = $headline; Ratio = $ratio; Meters = $meters; Amounts = $amounts; Footnote = $null
       ActivityKey = $sPct + $wPct + [double]$extraUsed * 100 }
}

# ---------------------------------------------------------------------------------------------
# Model: accounts, per-account state, polling
# ---------------------------------------------------------------------------------------------

$script:accounts = @()
$script:states = @{}
$script:lastDiscovery = 0.0

function Get-State($account) {
    if (-not $script:states.ContainsKey($account.Id)) {
        $script:states[$account.Id] = @{
            Account = $account; Snapshot = $null; Error = $null; Updated = $null; Pending = $null; Plan = $null
            LastFetch = 0.0; LastKey = $null; FlashUntil = 0.0; BackoffUntil = 0.0; BackoffStep = 0
        }
    }
    $st = $script:states[$account.Id]
    $st.Account = $account
    return $st
}

function Get-StateRatio($st) {
    if (-not $st.Snapshot) { if ($st.Error -and -not $st.Error.RateLimit) { return 1.0 } return 0.0 }
    return [double]$st.Snapshot.Ratio
}

function Get-VisibleAccounts {
    @($script:accounts | Where-Object { -not $script:disabled.ContainsKey($_.Id) } |
        Sort-Object -Property @{ Expression = { Get-LastActive $_.Id }; Descending = $true })
}

function Update-Accounts {
    $script:lastDiscovery = Get-Now
    $script:accounts = @(Get-CursorAccounts) + @(Get-ClaudeAccounts)
    # First run: until a Cursor account is seen in use, order it by its state DB's mtime.
    foreach ($a in $script:accounts) {
        if ($a.Provider -eq "cursor" -and -not $script:lastActive.ContainsKey($a.Id)) {
            $t = (Get-Item -LiteralPath $a.Source).LastWriteTimeUtc
            Set-Active $a.Id (([DateTimeOffset]$t).ToUnixTimeMilliseconds() / 1000.0)
        }
    }
}

function Update-LocalActivity {
    foreach ($a in $script:accounts) {
        if ($a.Provider -ne "claude" -or $script:disabled.ContainsKey($a.Id)) { continue }
        $t = Get-ClaudeLastActivity $a.Source
        if ($t) { Set-Active $a.Id $t }
    }
}

function Start-Refresh($account, [bool]$force) {
    $st = Get-State $account
    if ($st.Pending) { return }
    $now = Get-Now
    # Rate limited: wait it out even on a forced refresh, or we only dig the hole deeper.
    if ($now -lt $st.BackoffUntil) { return }
    if (-not $force -and $st.LastFetch -gt 0) {
        $since = $now - $st.LastFetch
        # Claude: fetch early if this account just sent a request (transcript changed).
        $usedSince = $account.Provider -eq "claude" -and (Get-LastActive $account.Id) -gt $st.LastFetch
        $due = $since -ge ($Providers[$account.Provider].Poll - 1)
        if (-not $due -and -not ($usedSince -and $since -gt 20)) { return }
    }
    $st.LastFetch = $now
    try { $r = Start-Fetch $account } catch { $r = @{ Error = (New-UsageError $L.offline $_.Exception.Message) } }
    if ($r.Error) { Set-StateError $st $r.Error }
    else { $st.Pending = $r.Task; $st.Plan = $r.Plan }
}

function Set-StateError($st, $err) {
    if ($err.RateLimit) {
        # 2, 4, 8 ... up to 30 minutes, unless the server named a time.
        $st.BackoffStep += 1
        $wait = if ($err.RetryAfter) { $err.RetryAfter } else { [math]::Min(1800, 60 * [math]::Pow(2, $st.BackoffStep)) }
        $st.BackoffUntil = (Get-Now) + $wait
    }
    # Keep the last good numbers for transient failures (rate limits, network blips).
    $st.Error = $err
}

# Collects finished HTTP requests. Returns $true if anything changed.
function Receive-Results {
    $changed = $false
    foreach ($st in @($script:states.Values)) {
        $task = $st.Pending
        if (-not $task -or -not $task.IsCompleted) { continue }
        $st.Pending = $null
        $changed = $true
        $provider = $st.Account.Provider
        try {
            if ($task.IsFaulted -or $task.IsCanceled) { throw "timeout" }
            $resp = $task.Result
            $status = [int]$resp.StatusCode
            $body = $resp.Content.ReadAsStringAsync().Result
            $retry = $null
            if ($resp.Headers.RetryAfter -and $resp.Headers.RetryAfter.Delta) { $retry = $resp.Headers.RetryAfter.Delta.Value.TotalSeconds }
            $resp.Dispose()

            if ($provider -eq "claude" -and $status -eq 401) { Set-StateError $st (New-UsageError $L.offline $L.claudeExpird); continue }
            if ($status -eq 429) { Set-StateError $st (New-UsageError "…" $L.rateLimited -RateLimit -RetryAfter $retry); continue }
            if ($status -ne 200) { Set-StateError $st (New-UsageError $L.offline "$($Providers[$provider].Title) API HTTP $status"); continue }

            $json = $body | ConvertFrom-Json
            $snap = if ($provider -eq "cursor") { ConvertFrom-CursorUsage $json } else { ConvertFrom-ClaudeUsage $json $st.Plan }
            if ($null -ne $st.LastKey -and $snap.ActivityKey -gt ($st.LastKey + 0.009)) {
                $st.FlashUntil = (Get-Now) + 8
                Set-Active $st.Account.Id (Get-Now)
            }
            $st.LastKey = $snap.ActivityKey
            $st.BackoffStep = 0
            $st.Snapshot = $snap
            $st.Error = $null
            $st.Updated = Get-Date
        }
        catch {
            Set-StateError $st (New-UsageError $L.offline $_.Exception.Message)
        }
    }
    return $changed
}

function Invoke-Tick([bool]$force) {
    if ($force -or $script:accounts.Count -eq 0 -or ((Get-Now) - $script:lastDiscovery) -gt 300) { Update-Accounts }
    Update-LocalActivity
    foreach ($a in Get-VisibleAccounts) { Start-Refresh $a $force }
}

Read-Settings

if ($Probe) {
    Update-Accounts
    Invoke-Tick $true
    foreach ($st in @($script:states.Values)) { if ($st.Pending) { try { [void]$st.Pending.Wait(25000) } catch { } } }
    [void](Receive-Results)
    $visible = Get-VisibleAccounts
    if ($visible.Count -eq 0) { Write-Output $L.noAccounts }
    foreach ($a in $visible) {
        $st = Get-State $a
        Write-Output ("[{0}] {1} {2}" -f $Providers[$a.Provider].Title, $a.Name, $a.Email)
        if ($st.Snapshot) {
            Write-Output ("    " + $st.Snapshot.Headline)
            foreach ($mt in $st.Snapshot.Meters) {
                $pct = if ($null -ne $mt.Pct) { "{0:0}%" -f $mt.Pct } else { "-" }
                Write-Output ("    {0}: {1} {2}" -f $mt.Label, $pct, $mt.Detail)
            }
        }
        if ($st.Error) { Write-Output ("    ! " + $st.Error.Long) }
    }
    exit 0
}

# ---------------------------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------------------------

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
namespace UsageBar {
  public static class Win32 {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr")]
    public static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr")]
    public static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int nIndex, IntPtr dwNewLong);
  }
}
"@

[UsageBar.Win32]::SetProcessDPIAware() | Out-Null
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({ })

$mutex = New-Object System.Threading.Mutex($false, "Local\UsageBar.Strip")
$owned = $false
try { $owned = $mutex.WaitOne(0, $false) }
catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { exit 0 }

function C([int]$red, [int]$green, [int]$blue, [int]$alpha = 255) { [System.Drawing.Color]::FromArgb($alpha, $red, $green, $blue) }

$Col = @{
    Bg = C 24 24 24; Border = C 54 54 54; Text = C 236 236 236; Secondary = C 152 152 152; Tertiary = C 112 112 112
    Track = C 58 58 58; Divider = C 46 46 46; PillBg = C 62 62 62; ActiveBg = C 30 58 98; ActiveText = C 150 196 255
    Error = C 240 110 70
}

function Get-HeatColor([double]$ratio, [int]$alpha = 255) {
    $ratio = [math]::Max(0.0, [math]::Min(1.0, $ratio))
    $stops = @(@(0.00, 82, 163, 255), @(0.45, 232, 160, 48), @(0.75, 240, 96, 48), @(1.00, 232, 64, 64))
    $i = 0
    for ($n = 0; $n -lt ($stops.Count - 1); $n++) { if ($ratio -ge $stops[$n][0]) { $i = $n } }
    $a = $stops[$i]; $b = $stops[[math]::Min($i + 1, $stops.Count - 1)]
    $span = $b[0] - $a[0]
    $t = if ($span -gt 0) { ($ratio - $a[0]) / $span } else { 0.0 }
    C ([int]($a[1] + ($b[1] - $a[1]) * $t)) ([int]($a[2] + ($b[2] - $a[2]) * $t)) ([int]($a[3] + ($b[3] - $a[3]) * $t)) $alpha
}

function Get-BlinkInterval {
    $active = @(Get-VisibleAccounts) | Select-Object -First 1
    if (-not $active) { return 980 }
    $st = Get-State $active
    if ((Get-Now) -lt $st.FlashUntil) { return 180 }
    $r = Get-StateRatio $st
    if ($r -ge 0.90) { return 240 }
    if ($r -ge 0.70) { return 380 }
    if ($r -ge 0.45) { return 620 }
    return 980
}

# --- drawing helpers ---

$script:brushes = @{}
function Get-Brush($c) {
    $k = $c.ToArgb()
    if (-not $script:brushes.ContainsKey($k)) { $script:brushes[$k] = New-Object System.Drawing.SolidBrush $c }
    return $script:brushes[$k]
}

$script:fmt = New-Object System.Drawing.StringFormat ([System.Drawing.StringFormat]::GenericTypographic)
$script:fmt.FormatFlags = [System.Drawing.StringFormatFlags]::MeasureTrailingSpaces -bor [System.Drawing.StringFormatFlags]::NoWrap
$script:wrapFmt = New-Object System.Drawing.StringFormat ([System.Drawing.StringFormat]::GenericTypographic)

$measureBitmap = New-Object System.Drawing.Bitmap 1, 1
$script:mg = [System.Drawing.Graphics]::FromImage($measureBitmap)
$script:mg.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
$script:scale = [math]::Max(1.0, $script:mg.DpiX / 96.0)
$s = $script:scale

function New-Font([string]$family, [double]$size) {
    New-Object System.Drawing.Font $family, ([single]($size * $script:scale)), ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Pixel)
}
$F = @{
    Title = New-Font "Segoe UI Semibold" 14; Head = New-Font "Segoe UI Semibold" 12.5; Text = New-Font "Segoe UI" 12.5
    Small = New-Font "Segoe UI" 11; SmallBold = New-Font "Segoe UI Semibold" 11; Big = New-Font "Segoe UI Semibold" 24
    Pill = New-Font "Segoe UI Semibold" 10.5; Strip = New-Font "Segoe UI Semibold" 13
}

function Measure-Str($g, [string]$text, $font) { $g.MeasureString($text, $font, 4000, $script:fmt) }

# Draws (when $draw) and returns the width.
function Write-Str($g, [bool]$draw, [string]$text, $font, $color, [double]$x, [double]$y) {
    $sz = Measure-Str $g $text $font
    if ($draw -and $text) { $g.DrawString($text, $font, (Get-Brush $color), [single]$x, [single]$y, $script:fmt) }
    return [double]$sz.Width
}

# Vertically centers a line of text in a row.
function Write-Row($g, [bool]$draw, [string]$text, $font, $color, [double]$x, [double]$rowY, [double]$rowH) {
    $h = (Measure-Str $g "Ag" $font).Height
    Write-Str $g $draw $text $font $color $x ($rowY + ($rowH - $h) / 2)
}

function Get-Fitted($g, [string]$text, $font, [double]$maxW) {
    if ($maxW -le 0) { return "" }
    if ((Measure-Str $g $text $font).Width -le $maxW) { return $text }
    while ($text.Length -gt 1 -and (Measure-Str $g ($text + "…") $font).Width -gt $maxW) { $text = $text.Substring(0, $text.Length - 1) }
    return $text + "…"
}

function New-RoundPath([double]$x, [double]$y, [double]$w, [double]$h, [double]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = [single]($r * 2)
    $p.AddArc([single]$x, [single]$y, $d, $d, 180, 90)
    $p.AddArc([single]($x + $w - $d), [single]$y, $d, $d, 270, 90)
    $p.AddArc([single]($x + $w - $d), [single]($y + $h - $d), $d, $d, 0, 90)
    $p.AddArc([single]$x, [single]($y + $h - $d), $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function Fill-Round($g, $color, [double]$x, [double]$y, [double]$w, [double]$h, [double]$r) {
    if ($w -le 0 -or $h -le 0) { return }
    $r = [math]::Min($r, [math]::Min($w, $h) / 2)
    if ($r -lt 0.6) { $g.FillRectangle((Get-Brush $color), [single]$x, [single]$y, [single]$w, [single]$h); return }
    $p = New-RoundPath $x $y $w $h $r
    $g.FillPath((Get-Brush $color), $p)
    $p.Dispose()
}

function Set-RoundRegion($form) {
    $p = New-RoundPath 0 0 $form.Width $form.Height ([math]::Min(8 * $script:scale, $form.Height / 2))
    $form.Region = New-Object System.Drawing.Region $p
    $p.Dispose()
}

function Draw-Frame($g, $form) {
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $g.Clear($Col.Bg)
    $p = New-RoundPath 0 0 ($form.Width - 1) ($form.Height - 1) ([math]::Min(8 * $script:scale, ($form.Height - 1) / 2))
    $pen = New-Object System.Drawing.Pen $Col.Border, 1
    $g.DrawPath($pen, $p)
    $pen.Dispose(); $p.Dispose()
}

# --- strip: dot, tag, amount, two tiny vertical bars ---

$script:blinkOn = $true
$StripH = [int](28 * $s)

function Invoke-StripLayout($g, [bool]$draw) {
    $visible = Get-VisibleAccounts
    $active = $visible | Select-Object -First 1
    $x = 11 * $s
    $dot = 7 * $s
    if (-not $active) {
        if ($draw) { $g.FillEllipse((Get-Brush (Get-HeatColor 0 60)), [single]$x, [single](($StripH - $dot) / 2), [single]$dot, [single]$dot) }
        $x += $dot + 8 * $s
        $x += Write-Row $g $draw "UsageBar" $F.Strip $Col.Secondary $x 0 $StripH
        return [int]($x + 12 * $s)
    }
    $st = Get-State $active
    $ratio = Get-StateRatio $st
    if ($draw) {
        $alpha = if ($script:blinkOn) { 255 } else { 48 }
        $g.FillEllipse((Get-Brush (Get-HeatColor $ratio $alpha)), [single]$x, [single](($StripH - $dot) / 2), [single]$dot, [single]$dot)
    }
    $x += $dot + 8 * $s

    # Only label the strip when there is more than one account to tell apart.
    if ($visible.Count -gt 1) {
        $tw = (Measure-Str $g $active.Name $F.Pill).Width
        $ph = 16 * $s
        if ($draw) { Fill-Round $g $Col.PillBg $x (($StripH - $ph) / 2) ($tw + 10 * $s) $ph (4 * $s) }
        [void](Write-Row $g $draw $active.Name $F.Pill $Col.Text ($x + 5 * $s) 0 $StripH)
        $x += $tw + 10 * $s + 7 * $s
    }

    $text = if ($st.Snapshot) { $st.Snapshot.Headline } elseif ($st.Error) { $st.Error.Short } else { "…" }
    $x += Write-Row $g $draw $text $F.Strip $Col.Text $x 0 $StripH

    $meters = if ($st.Snapshot) { @($st.Snapshot.Meters | Select-Object -First 2) } else { @() }
    if ($meters.Count -gt 0) {
        $x += 9 * $s
        $bw = 4 * $s; $bh = 15 * $s; $by = ($StripH - $bh) / 2
        foreach ($mt in $meters) {
            if ($draw) {
                Fill-Round $g $Col.Track $x $by $bw $bh (1.5 * $s)
                if ($null -ne $mt.Pct -and $mt.Pct -gt 0) {
                    $p = [math]::Min(100, $mt.Pct) / 100
                    $fh = [math]::Max(2 * $s, $bh * $p)
                    Fill-Round $g (Get-HeatColor $p) $x ($by + $bh - $fh) $bw $fh (1.5 * $s)
                }
            }
            $x += $bw + 3 * $s
        }
    }
    return [int]($x + 9 * $s)
}

# --- panel: every account, most recently used first; the active one expanded ---

$PanelW = [int](340 * $s)
$Pad = 16 * $s

function Invoke-MeterLayout($g, [bool]$draw, $mt, [bool]$compact, [double]$y) {
    $right = $PanelW - $Pad
    $pct = if ($null -ne $mt.Pct) { "{0:0}%" -f [math]::Round($mt.Pct) } else { "–" }
    $p = if ($null -ne $mt.Pct) { [math]::Max(0, [math]::Min(100, $mt.Pct)) / 100 } else { 0 }
    if ($compact) {
        $lineH = 16 * $s
        $pw = (Measure-Str $g $pct $F.SmallBold).Width
        [void](Write-Row $g $draw $pct $F.SmallBold $Col.Text ($right - $pw) $y $lineH)
        $lw = Write-Row $g $draw $mt.Label $F.Small $Col.Text $Pad $y $lineH
        if ($mt.Detail) {
            $d = Get-Fitted $g ("· " + $mt.Detail) $F.Small ($right - $pw - $Pad - $lw - 14 * $s)
            [void](Write-Row $g $draw $d $F.Small $Col.Tertiary ($Pad + $lw + 5 * $s) $y $lineH)
        }
        $y += $lineH + 3 * $s
        $bh = 5 * $s
    }
    else {
        $lineH = 19 * $s
        $pw = (Measure-Str $g $pct $F.Head).Width
        [void](Write-Row $g $draw $pct $F.Head $Col.Text ($right - $pw) $y $lineH)
        [void](Write-Row $g $draw $mt.Label $F.Text $Col.Text $Pad $y $lineH)
        $y += $lineH + 4 * $s
        $bh = 8 * $s
    }
    if ($draw) {
        Fill-Round $g $Col.Track $Pad $y ($right - $Pad) $bh ($bh / 2)
        if ($p -gt 0) { Fill-Round $g (Get-HeatColor $p) $Pad $y ([math]::Max($bh, ($right - $Pad) * $p)) $bh ($bh / 2) }
    }
    $y += $bh
    if (-not $compact -and $mt.Detail) {
        $y += 4 * $s
        [void](Write-Row $g $draw $mt.Detail $F.Small $Col.Secondary $Pad $y (15 * $s))
        $y += 15 * $s
    }
    return $y
}

function Invoke-AccountLayout($g, [bool]$draw, $account, [bool]$isActive, [double]$y) {
    $st = Get-State $account
    $snap = $st.Snapshot
    $right = $PanelW - $Pad
    $rowH = 20 * $s

    # Header: dot, provider, account, "active" pill / headline.
    $x = $Pad
    $dot = 8 * $s
    if ($draw) { $g.FillEllipse((Get-Brush (Get-HeatColor (Get-StateRatio $st))), [single]$x, [single]($y + ($rowH - $dot) / 2), [single]$dot, [single]$dot) }
    $x += $dot + 7 * $s
    $title = $Providers[$account.Provider].Title
    $x += (Write-Row $g $draw $title $F.Head $Col.Text $x $y $rowH) + 6 * $s

    $limitX = $right
    if ($isActive) {
        $aw = (Measure-Str $g $L.active $F.Pill).Width + 12 * $s
        $limitX -= $aw + 6 * $s
    }
    elseif ($snap) {
        $hw = (Measure-Str $g $snap.Headline $F.Head).Width
        # Dimmed when the numbers are stale (e.g. rate limited).
        $hc = if ($st.Error) { $Col.Secondary } else { $Col.Text }
        [void](Write-Row $g $draw $snap.Headline $F.Head $hc ($right - $hw) $y $rowH)
        $limitX -= $hw + 10 * $s
    }
    $sub = if ($account.Name -eq $title) { [string]$account.Email } else { $account.Name }
    $sub = Get-Fitted $g $sub $F.Text ($limitX - $x)
    $x += (Write-Row $g $draw $sub $F.Text $Col.Secondary $x $y $rowH) + 6 * $s
    if ($isActive) {
        $ph = 16 * $s
        if ($draw) { Fill-Round $g $Col.ActiveBg $x ($y + ($rowH - $ph) / 2) $aw $ph ($ph / 2) }
        [void](Write-Row $g $draw $L.active $F.Pill $Col.ActiveText ($x + 6 * $s) $y $rowH)
    }
    $y += $rowH + $(if ($isActive) { 10 } else { 6 }) * $s

    if ($snap) {
        if ($isActive) {
            $big = @($snap.Amounts | Where-Object { $_.Big })
            if ($big.Count -gt 0) {
                $bx = $Pad
                foreach ($am in $big) {
                    $vw = Write-Str $g $draw $am.Value $F.Big $Col.Text $bx $y
                    $lw = Write-Str $g $draw $am.Label $F.Small $Col.Secondary $bx ($y + 32 * $s)
                    $bx += [math]::Max($vw, $lw) + 22 * $s
                }
                $y += 52 * $s
            }
            foreach ($am in @($snap.Amounts | Where-Object { -not $_.Big })) {
                $vw = (Measure-Str $g $am.Value $F.Text).Width
                [void](Write-Row $g $draw $am.Label $F.Text $Col.Secondary $Pad $y (19 * $s))
                [void](Write-Row $g $draw $am.Value $F.Text $Col.Text ($right - $vw) $y (19 * $s))
                $y += 19 * $s
            }
            $y += 8 * $s
        }
        $meters = if ($isActive) { @($snap.Meters) } else { @($snap.Meters | Select-Object -First 2) }
        $first = $true
        foreach ($mt in $meters) {
            if (-not $first) { $y += $(if ($isActive) { 12 } else { 7 }) * $s }
            $first = $false
            $y = Invoke-MeterLayout $g $draw $mt (-not $isActive) $y
        }
    }
    elseif (-not $st.Error) {
        [void](Write-Row $g $draw $L.loading $F.Text $Col.Secondary $Pad $y (18 * $s))
        $y += 18 * $s
    }

    if ($st.Error -and -not $snap) {
        $rect = New-Object System.Drawing.RectangleF ([single]$Pad), ([single]$y), ([single]($right - $Pad)), 1000
        $sz = $g.MeasureString($st.Error.Long, $F.Small, [int]($right - $Pad), $script:wrapFmt)
        if ($draw) { $g.DrawString($st.Error.Long, $F.Small, (Get-Brush $Col.Error), $rect, $script:wrapFmt) }
        $y += $sz.Height + 2 * $s
    }

    if ($isActive) {
        $y += 10 * $s
        $lineH = 15 * $s
        $note = $snap.Footnote
        if ($snap -and $st.Error) { $note = $st.Error.Long }
        $upd = if ($st.Updated) { $L.updated -f $st.Updated.ToString("HH:mm") } else { "" }
        $uw = (Measure-Str $g $upd $F.Small).Width
        [void](Write-Row $g $draw $upd $F.Small $Col.Tertiary ($right - $uw) $y $lineH)
        if ($note) {
            $note = Get-Fitted $g $note $F.Small ($right - $uw - $Pad - 10 * $s)
            [void](Write-Row $g $draw $note $F.Small $Col.Tertiary $Pad $y $lineH)
        }
        $y += $lineH
    }
    return $y
}

function Invoke-PanelLayout($g, [bool]$draw) {
    $y = $Pad
    $rowH = 22 * $s
    [void](Write-Row $g $draw "UsageBar" $F.Title $Col.Text $Pad $y $rowH)
    $hw = (Measure-Str $g $L.hint $F.Small).Width
    [void](Write-Row $g $draw $L.hint $F.Small $Col.Tertiary ($PanelW - $Pad - $hw) $y $rowH)
    $y += $rowH + 12 * $s

    $visible = Get-VisibleAccounts
    if ($visible.Count -eq 0) {
        $msg = if ($script:accounts.Count -eq 0) { $L.noAccounts } else { $L.noneSelected }
        [void](Write-Row $g $draw (Get-Fitted $g $msg $F.Text ($PanelW - 2 * $Pad)) $F.Text $Col.Secondary $Pad $y (40 * $s))
        $y += 40 * $s
    }
    for ($i = 0; $i -lt $visible.Count; $i++) {
        if ($i -gt 0) {
            $y += 13 * $s
            if ($draw) { $g.FillRectangle((Get-Brush $Col.Divider), [single]$Pad, [single]$y, [single]($PanelW - 2 * $Pad), [single][math]::Max(1, $s)) }
            $y += 13 * $s
        }
        $y = Invoke-AccountLayout $g $draw $visible[$i] ($i -eq 0) $y
    }
    return [int]($y + $Pad)
}

# --- forms ---

function Set-ToolWindow($form, [bool]$noActivate) {
    $style = [UsageBar.Win32]::GetWindowLongPtr($form.Handle, -20).ToInt64()
    $style = $style -bor 0x00000080  # WS_EX_TOOLWINDOW: no taskbar / Alt+Tab entry
    if ($noActivate) { $style = $style -bor 0x08000000 }  # WS_EX_NOACTIVATE
    [UsageBar.Win32]::SetWindowLongPtr($form.Handle, -20, [IntPtr]$style) | Out-Null
}

function New-BaseForm([string]$title) {
    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $f.ShowInTaskbar = $false
    $f.TopMost = $true
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $f.BackColor = $Col.Bg
    $f.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $f.Text = $title
    $f.GetType().GetProperty("DoubleBuffered", [Reflection.BindingFlags]"NonPublic,Instance").SetValue($f, $true, $null)
    return $f
}

$form = New-BaseForm "UsageBar"
$form.Add_HandleCreated({ Set-ToolWindow $form $true })
$form.Add_Paint({ param($sender, $e) Draw-Frame $e.Graphics $form; [void](Invoke-StripLayout $e.Graphics $true) })

$panel = New-BaseForm "UsageBar panel"
$panel.KeyPreview = $true
$panel.Add_HandleCreated({ Set-ToolWindow $panel $false })
$panel.Add_Paint({ param($sender, $e) Draw-Frame $e.Graphics $panel; [void](Invoke-PanelLayout $e.Graphics $true) })
$script:panelHiddenAt = [datetime]::MinValue
$panel.Add_Deactivate({ $panel.Hide(); $script:panelHiddenAt = Get-Date })
$panel.Add_KeyDown({ param($sender, $e) if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $panel.Hide() } })

$script:userMoved = $false

function Move-StripToTop {
    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Location = New-Object System.Drawing.Point ($area.X + [int](($area.Width - $form.Width) / 2)), ($area.Y + [int](8 * $s))
}

function Move-PanelToStrip {
    $area = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
    $x = $form.Left + [int](($form.Width - $panel.Width) / 2)
    $x = [math]::Max($area.Left + 8, [math]::Min($x, $area.Right - $panel.Width - 8))
    $y = $form.Bottom + [int](6 * $s)
    if ($y + $panel.Height -gt $area.Bottom) { $y = [math]::Max($area.Top, $form.Top - $panel.Height - [int](6 * $s)) }
    $panel.Location = New-Object System.Drawing.Point $x, $y
}

function Update-View {
    $w = Invoke-StripLayout $script:mg $false
    if ($form.ClientSize.Width -ne $w -or $form.ClientSize.Height -ne $StripH) {
        $form.ClientSize = New-Object System.Drawing.Size $w, $StripH
        Set-RoundRegion $form
        if (-not $script:userMoved) { Move-StripToTop }
    }
    $form.Invalidate()
    if ($panel.Visible) {
        $h = Invoke-PanelLayout $script:mg $false
        if ($panel.ClientSize.Height -ne $h -or $panel.ClientSize.Width -ne $PanelW) {
            $panel.ClientSize = New-Object System.Drawing.Size $PanelW, $h
            Set-RoundRegion $panel
            Move-PanelToStrip
        }
        $panel.Invalidate()
    }
}

function Show-Panel {
    $panel.ClientSize = New-Object System.Drawing.Size $PanelW, (Invoke-PanelLayout $script:mg $false)
    Set-RoundRegion $panel
    Move-PanelToStrip
    $panel.Show()
    $panel.Activate()
    Invoke-Tick $false
}

function Switch-Panel {
    if ($panel.Visible) { $panel.Hide(); return }
    # A click on the strip first deactivates (hides) the panel; don't immediately reopen it.
    if (((Get-Date) - $script:panelHiddenAt).TotalMilliseconds -lt 300) { return }
    Show-Panel
}

# Click toggles the panel, drag moves the strip.
$script:press = $null
$script:dragging = $false
$form.Add_MouseDown({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { $script:press = $e.Location; $script:dragging = $false }
})
$form.Add_MouseMove({
    param($sender, $e)
    if ($null -eq $script:press) { return }
    $dx = $e.X - $script:press.X; $dy = $e.Y - $script:press.Y
    if (-not $script:dragging -and ([math]::Abs($dx) + [math]::Abs($dy)) -gt 3) { $script:dragging = $true; $script:userMoved = $true }
    if ($script:dragging) {
        $form.Left += $dx; $form.Top += $dy
        if ($panel.Visible) { Move-PanelToStrip }
    }
})
$form.Add_MouseUp({
    param($sender, $e)
    if ($null -ne $script:press -and -not $script:dragging -and $e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Switch-Panel }
    $script:press = $null; $script:dragging = $false
})

# Right-click menu (strip and panel): pick accounts, refresh, dashboards, quit.
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.Add_Opening({
    $menu.Items.Clear()
    foreach ($key in $Providers.Keys) {
        $header = New-Object System.Windows.Forms.ToolStripMenuItem $Providers[$key].Title
        $header.Enabled = $false
        [void]$menu.Items.Add($header)
        $list = @($script:accounts | Where-Object { $_.Provider -eq $key })
        if ($list.Count -eq 0) {
            $none = New-Object System.Windows.Forms.ToolStripMenuItem $L.notFound
            $none.Enabled = $false
            [void]$menu.Items.Add($none)
        }
        foreach ($a in $list) {
            $label = if ($a.Email -and $a.Name -ne $a.Email) { "$($a.Name) · $($a.Email)" } else { $a.Name }
            $item = New-Object System.Windows.Forms.ToolStripMenuItem $label
            $item.Checked = -not $script:disabled.ContainsKey($a.Id)
            $item.Tag = $a.Id
            $item.Add_Click({
                param($sender, $e)
                $id = [string]$sender.Tag
                if ($script:disabled.ContainsKey($id)) { $script:disabled.Remove($id) } else { $script:disabled[$id] = $true }
                Save-Settings
                Invoke-Tick $false
                Update-View
            })
            [void]$menu.Items.Add($item)
        }
        $dash = New-Object System.Windows.Forms.ToolStripMenuItem $L.openUsage
        $dash.Tag = $Providers[$key].Url
        $dash.Add_Click({ param($sender, $e) Start-Process ([string]$sender.Tag) })
        [void]$menu.Items.Add($dash)
        [void]$menu.Items.Add("-")
    }
    $refresh = New-Object System.Windows.Forms.ToolStripMenuItem $L.refresh
    $refresh.Add_Click({ Invoke-Tick $true; Update-View })
    [void]$menu.Items.Add($refresh)
    $pin = New-Object System.Windows.Forms.ToolStripMenuItem $L.pinTop
    $pin.Add_Click({ $script:userMoved = $false; Move-StripToTop; if ($panel.Visible) { Move-PanelToStrip } })
    [void]$menu.Items.Add($pin)
    [void]$menu.Items.Add("-")
    $quit = New-Object System.Windows.Forms.ToolStripMenuItem $L.quit
    $quit.Add_Click({ $form.Close() })
    [void]$menu.Items.Add($quit)
    $_.Cancel = $false
})
$form.ContextMenuStrip = $menu
$panel.ContextMenuStrip = $menu

# Timers: poll every 15s (each account decides if it is due), collect HTTP results, blink.
$poll = New-Object System.Windows.Forms.Timer
$poll.Interval = 15000
$poll.Add_Tick({ try { Invoke-Tick $false; Update-View } catch { } })

$pump = New-Object System.Windows.Forms.Timer
$pump.Interval = 250
$pump.Add_Tick({ try { if (Receive-Results) { Update-View } } catch { } })

$blink = New-Object System.Windows.Forms.Timer
$blink.Interval = 700
$blink.Add_Tick({
    try {
        $next = Get-BlinkInterval
        if ($blink.Interval -ne $next) { $blink.Interval = $next }
        $script:blinkOn = -not $script:blinkOn
        $form.Invalidate()
    }
    catch { }
})

$form.Add_FormClosed({
    $poll.Stop(); $pump.Stop(); $blink.Stop()
    $panel.Close()
    [System.Windows.Forms.Application]::Exit()
})

try { Invoke-Tick $true } catch { }
Update-View
$poll.Start()
$pump.Start()
$blink.Start()
[System.Windows.Forms.Application]::Run($form)

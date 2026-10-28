<#
  sbid-daily.ps1 - Rellena automaticamente los dias de practicas e informes pendientes de sBID.
  Solo usa PowerShell (ya viene con Windows): no hay que instalar nada.

    sbid-daily.ps1              entra en sBID y rellena lo pendiente (guarda de verdad)
    sbid-daily.ps1 -DryRun      entra y muestra que rellenaria, SIN guardar nada
    sbid-daily.ps1 -Check       solo prueba el login y cuenta pendientes
    sbid-daily.ps1 -Install     lo pone en el arranque de Windows (carpeta Inicio)
    sbid-daily.ps1 -Uninstall   lo quita del arranque

  La configuracion (usuario, contrasenya, reparto...) va en config.ps1, junto a este fichero.
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$DryRun,
    [switch]$Startup,
    [switch]$Install,
    [switch]$Uninstall,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.ps1'),
    [string]$LogFile = (Join-Path $PSScriptRoot 'sbid-daily.log'),
    [string]$BaseUrl = 'https://www.empresaiformacio.org',
    [string]$Now = ''
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

function Log([string]$m) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Write-Host $line
    try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch { }
}

function Notify([string]$title, [string]$msg) {
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $n = New-Object System.Windows.Forms.NotifyIcon
        $n.Icon = [System.Drawing.SystemIcons]::Information
        $n.Visible = $true
        $n.ShowBalloonTip(8000, $title, $msg, [System.Windows.Forms.ToolTipIcon]::Info)
        Start-Sleep -Seconds 9
        $n.Dispose()
    } catch { }
}

# ---------------------------------------------------------------- instalar / quitar
if ($Install -or $Uninstall) {
    $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'sbid-daily.lnk'
    if ($Uninstall) {
        if (Test-Path $lnk) { Remove-Item $lnk }
        Write-Host 'Quitado del arranque de Windows.'
        exit 0
    }
    if (-not (Test-Path $ConfigPath)) {
        Write-Warning "Falta $ConfigPath (copia config.example.ps1 como config.ps1 y rellenalo) antes de que funcione."
    }
    $sh = New-Object -ComObject WScript.Shell
    $s = $sh.CreateShortcut($lnk)
    $s.TargetPath = (Get-Command powershell.exe).Source
    $s.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $PSCommandPath + '" -Startup'
    $s.WorkingDirectory = $PSScriptRoot
    $s.WindowStyle = 7
    $s.Save()
    Write-Host "Instalado: se ejecutara cada vez que enciendas el PC ($lnk)"
    exit 0
}

# ---------------------------------------------------------------- configuracion
if (-not (Test-Path $ConfigPath)) {
    Log "No existe $ConfigPath. Copia config.example.ps1 como config.ps1 y rellenalo."
    exit 2
}
. $ConfigPath
if (-not $Config) { Log 'config.ps1 no define $Config.'; exit 2 }

$cfg = @{
    HoursPerDay = 4; MinBlock = 0.5; MinActs = 2; MaxActs = 3; Seed = 'sbid'
    Activities = @{}; SkipWeekends = $true; SkipDates = @(); FillTodayAfter = '18:00'
    FillReports = $true; Rating = 'auto'; MaxPerRun = 60; Notify = 'changes'
    StartDelaySeconds = 45; NetworkRetries = 5; NetworkRetryDelaySeconds = 30
}
foreach ($k in $Config.Keys) { $cfg[$k] = $Config[$k] }
if ($env:SBID_USER) { $cfg.Username = $env:SBID_USER }
if ($env:SBID_PASS) { $cfg.Password = $env:SBID_PASS }
if (-not $cfg.Username -or -not $cfg.Password) { Log 'Faltan Username/Password en config.ps1.'; exit 2 }

$nowDate = if ($Now) { [datetime]::Parse($Now) } else { Get-Date }
$Inv = [Globalization.CultureInfo]::InvariantCulture
$Origin = $BaseUrl.TrimEnd('/')
$Mod = "$Origin/sBid/modules"
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36'
$script:Sess = New-Object Microsoft.PowerShell.Commands.WebRequestSession

# ---------------------------------------------------------------- HTTP
function Http([string]$url, [string]$body) {
    $p = @{ Uri = $url; WebSession = $script:Sess; UseBasicParsing = $true; UserAgent = $UA; MaximumRedirection = 6 }
    if ($PSBoundParameters.ContainsKey('body') -and $null -ne $body) {
        $p.Method = 'POST'; $p.Body = $body; $p.ContentType = 'application/x-www-form-urlencoded'
    }
    return (Invoke-WebRequest @p).Content
}

function Enc($pairs) {
    return (($pairs.Keys | ForEach-Object { [uri]::EscapeDataString([string]$_) + '=' + [uri]::EscapeDataString([string]$pairs[$_]) }) -join '&')
}

function Retry([scriptblock]$f) {
    for ($i = 0; ; $i++) {
        try { return (& $f) }
        catch {
            if ($_.Exception.Message -like 'LOGIN:*' -or $i -ge $cfg.NetworkRetries) { throw }
            Log ("Sin conexion ({0}); reintento {1}/{2}..." -f $_.Exception.Message, ($i + 1), $cfg.NetworkRetries)
            Start-Sleep -Seconds $cfg.NetworkRetryDelaySeconds
        }
    }
}

function Login {
    [void](Http "$Mod/Login?initial=yes")
    $b = [ordered]@{ idTask = ''; hashTask = ''; moduleaction = 'doLogin'; fwBrowser = 'Chrome'; username = $cfg.Username; password = $cfg.Password }
    [void](Http "$Mod/Login" (Enc $b))
    $ag = Http "$Mod/Agenda?moduleaction=show&clearBackStack=true"
    if ($ag -notmatch 'id="heading1"' -or $ag -match 'id="loginForm"') {
        throw 'LOGIN: login rechazado o pagina inesperada; revisa usuario y contrasenya.'
    }
}

function Logout { try { [void](Http "$Origin/sBid/jsp/doLogout.jsp") } catch { } }

# ---------------------------------------------------------------- lectura de paginas
function HtmlDec([string]$s) { return [System.Net.WebUtility]::HtmlDecode($s) }

function Attr([string]$tag, [string]$name) {
    $m = [regex]::Match($tag, '\b' + $name + '\s*=\s*(?:"([^"]*)"|''([^'']*)''|([^\s>]+))', 'IgnoreCase')
    if (-not $m.Success) { return $null }
    foreach ($g in 1..3) { if ($m.Groups[$g].Success) { return (HtmlDec $m.Groups[$g].Value) } }
}

function GetAgenda {
    $h = Http "$Mod/Agenda?moduleaction=show&clearBackStack=true"
    if ($h -match 'id="loginForm"') { throw 'LOGIN: la sesion ha caducado.' }
    $count = '?'
    $mc = [regex]::Match($h, 'id="heading1"[\s\S]{0,600}?badge[^>]*>\s*(\d+)')
    if ($mc.Success) { $count = $mc.Groups[1].Value }
    $seg = ''
    $start = $h.IndexOf('id="collapse1"')
    if ($start -ge 0) {
        $end = $h.IndexOf('id="collapse2"', $start)
        if ($end -lt 0) { $end = $h.Length }
        $seg = $h.Substring($start, $end - $start)
    }
    $items = @()
    foreach ($m in [regex]::Matches($seg, '<a\b[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>')) {
        $href = HtmlDec $m.Groups[1].Value
        $text = (HtmlDec (($m.Groups[2].Value -replace '<[^>]+>', ' '))) -replace '\s+', ' '
        $text = $text.Trim()
        $kind = $null
        if ($href -match 'ActivitatValoracioFct') { $kind = 'report' } elseif ($href -match 'ActivitatFct') { $kind = 'day' }
        if (-not $kind) { continue }
        $date = $null
        $md = [regex]::Match($href, '[?&]data=(\d{4})(\d{2})(\d{2})')
        if ($md.Success) { $date = Get-Date -Year $md.Groups[1].Value -Month $md.Groups[2].Value -Day $md.Groups[3].Value -Hour 0 -Minute 0 -Second 0 -Millisecond 0 }
        else {
            $mt = [regex]::Match($text, '(\d{2})/(\d{2})/(\d{4})')
            if ($mt.Success) { $date = Get-Date -Year $mt.Groups[3].Value -Month $mt.Groups[2].Value -Day $mt.Groups[1].Value -Hour 0 -Minute 0 -Second 0 -Millisecond 0 }
        }
        if ($href.StartsWith('/')) { $href = $Origin + $href }
        $items += [pscustomobject]@{ Href = $href; Text = $text; Kind = $kind; Date = $date }
    }
    return [pscustomobject]@{ Items = $items; Count = $count }
}

# Devuelve campos del formulario (como el navegador), actividades y opciones de cada select inp_*
function ParseForm([string]$html) {
    $m = [regex]::Match($html, '<form\b[^>]*id="workingForm"[^>]*>[\s\S]*?</form>', 'IgnoreCase')
    if (-not $m.Success) { throw 'Formulario no encontrado (workingForm).' }
    $form = $m.Value
    $clean = [regex]::Replace($form, '<script\b[\s\S]*?</script>|<style\b[\s\S]*?</style>|<!--[\s\S]*?-->', '', 'IgnoreCase')
    $fields = [ordered]@{}
    foreach ($i in [regex]::Matches($clean, '<input\b[^>]*>', 'IgnoreCase')) {
        $name = Attr $i.Value 'name'
        if (-not $name) { continue }
        $type = (Attr $i.Value 'type'); if (-not $type) { $type = 'text' }
        if ($type -in 'button', 'submit', 'image', 'reset', 'file') { continue }
        if ($type -in 'checkbox', 'radio' -and $i.Value -notmatch '\bchecked\b') { continue }
        $v = Attr $i.Value 'value'; if ($null -eq $v) { $v = '' }
        $fields[$name] = $v
    }
    foreach ($t in [regex]::Matches($clean, '<textarea\b([^>]*)>([\s\S]*?)</textarea>', 'IgnoreCase')) {
        $name = Attr $t.Groups[1].Value 'name'
        if ($name) { $fields[$name] = (HtmlDec $t.Groups[2].Value) }
    }
    $acts = @(); $selects = @{}
    $prevEnd = 0
    foreach ($s in [regex]::Matches($clean, '<select\b([^>]*)>([\s\S]*?)</select>', 'IgnoreCase')) {
        $name = Attr $s.Groups[1].Value 'name'
        $opts = @()
        $selVal = $null
        foreach ($o in [regex]::Matches($s.Groups[2].Value, '<option\b([^>]*)>([^<]*)', 'IgnoreCase')) {
            $ov = Attr $o.Groups[1].Value 'value'; if ($null -eq $ov) { $ov = (HtmlDec $o.Groups[2].Value).Trim() }
            $opts += [pscustomobject]@{ Value = $ov; Text = (HtmlDec $o.Groups[2].Value).Trim() }
            if ($null -eq $selVal -and $o.Groups[1].Value -match '\bselected\b') { $selVal = $ov }
        }
        if ($name) {
            $selects[$name] = $opts
            if ($s.Groups[1].Value -notmatch '\bmultiple\b') {
                if ($null -eq $selVal -and $opts.Count -gt 0) { $selVal = $opts[0].Value }
                if ($null -eq $selVal) { $selVal = '' }
                $fields[$name] = $selVal
            }
        }
        if ($name -like 'inp_*') {
            $seg = $clean.Substring($prevEnd, $s.Index - $prevEnd)
            $chunks = @(($seg -split '<[^>]+>') | ForEach-Object { ($_ -replace '\s+', ' ').Trim() } | Where-Object { $_.Length -gt 8 -and $_ -notmatch '^\d+\s*(h|min)\b' })
            $label = ''; if ($chunks.Count -gt 0) { $label = HtmlDec $chunks[$chunks.Count - 1] }
            $code = $name
            $mc = [regex]::Match($label, '^(\d+(?:\.\d+)*)\.?\s')
            if ($mc.Success) { $code = $mc.Groups[1].Value }
            $acts += [pscustomobject]@{ Name = $name; Code = $code; Label = $label }
        }
        $prevEnd = $s.Index + $s.Length
    }
    $max = $null
    $mm = [regex]::Match($clean, 'Hores m.{1,2}ximes([\s\S]{0,300})')
    if ($mm.Success) {
        $tail = $mm.Groups[1].Value -replace '<[^>]+>', ' '
        $mn = [regex]::Match($tail, '(\d+(?:[.,]\d+)?)\s*H')
        if ($mn.Success) { $max = [double]::Parse($mn.Groups[1].Value.Replace(',', '.'), $Inv) }
    }
    return [pscustomobject]@{ Fields = $fields; Acts = $acts; Selects = $selects; Max = $max }
}

# ---------------------------------------------------------------- reparto de horas
function SeedInt([string]$s) {
    $md5 = [Security.Cryptography.MD5]::Create()
    return [BitConverter]::ToInt32($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($s)), 0)
}

function PickW($rng, $list) {
    $sum = 0.0
    foreach ($a in $list) { $sum += $a.Weight }
    $r = $rng.NextDouble() * $sum
    foreach ($a in $list) { $r -= $a.Weight; if ($r -lt 0) { return $a } }
    return $list[$list.Count - 1]
}

function Distribute($rng, $acts, [double]$total, [double]$minBlock, [int]$kMin, [int]$kMax, [double]$maxPer) {
    $out = @{}
    $tq = [int][math]::Round($total / 0.25)
    $pool = @($acts | Where-Object { $_.Weight -gt 0 })
    if ($pool.Count -eq 0 -or $tq -le 0) { return $out }
    $minB = [int][math]::Min($tq, [math]::Max(1, [math]::Round($minBlock / 0.25)))
    $cap = [int][math]::Round($maxPer / 0.25)
    $kMax = [int][math]::Max(1, [math]::Min([math]::Min($kMax, $pool.Count), [math]::Floor($tq / $minB)))
    $kMin = [int][math]::Max(1, [math]::Min($kMin, $kMax))
    $k = $kMin + [int][math]::Floor($rng.NextDouble() * ($kMax - $kMin + 1))
    $left = New-Object System.Collections.ArrayList
    foreach ($a in $pool) { [void]$left.Add($a) }
    $chosen = @()
    while ($chosen.Count -lt $k) { $a = PickW $rng $left; $left.Remove($a); $chosen += $a }
    $q = @{}
    foreach ($a in $chosen) { $q[$a.Id] = $minB }
    $rest = $tq - $minB * $k
    while ($rest -gt 0) {
        $unit = 1; if ($rest -ge 2) { $unit = 2 }
        $c = @($chosen | Where-Object { ($q[$_.Id] + $unit) -le $cap })
        if ($c.Count -eq 0) { break }
        $a = PickW $rng $c
        $q[$a.Id] += $unit
        $rest -= $unit
    }
    foreach ($id in @($q.Keys)) { $out[$id] = $q[$id] * 0.25 }
    return $out
}

function Cutoff {
    $d = $nowDate.Date
    if ($cfg.FillTodayAfter) {
        $p = ([string]$cfg.FillTodayAfter).Split(':')
        $mins = [int]$p[0] * 60 + $(if ($p.Count -gt 1) { [int]$p[1] } else { 0 })
        if (($nowDate.Hour * 60 + $nowDate.Minute) -ge $mins) { $d = $d.AddDays(1) }
    }
    return $d
}

# ---------------------------------------------------------------- guardar
function SaveDay($href, $plan) {
    $f = ParseForm (Http $href)
    $p = $f.Fields
    foreach ($a in $f.Acts) { $p[$a.Name] = '0' }
    $total = 0.0
    foreach ($name in $plan.Keys) {
        $opt = $f.Selects[$name] | Where-Object { $_.Value -ne '' -and ([double]::Parse($_.Value, $Inv) -eq $plan[$name]) } | Select-Object -First 1
        if (-not $opt) { throw "No hay opcion de $($plan[$name])h en $name" }
        $p[$name] = $opt.Value
        $total += $plan[$name]
    }
    $p['moduleaction'] = 'save'
    $p['horesConsignades'] = $total.ToString('0.##', $Inv)
    try { [void](Http "$Mod/ActivitatFct" (Enc $p)); return $true } catch { Log "Error al guardar: $($_.Exception.Message)"; return $false }
}

function BestRating($opts) {
    $real = @($opts | Where-Object { $_.Value -ne '' })
    $best = $real | Where-Object { $_.Text -match 'molt adequada|muy adecuada|excel' } | Select-Object -First 1
    if ($best) { return $best }
    return $real[$real.Count - 1]
}

function SaveReport($href, $rating) {
    $f = ParseForm (Http $href)
    $p = $f.Fields
    foreach ($a in $f.Acts) {
        if (@($f.Selects[$a.Name] | Where-Object { $_.Value -eq $rating }).Count -gt 0) { $p[$a.Name] = $rating }
    }
    $p['moduleaction'] = 'save'
    try { [void](Http "$Mod/ActivitatValoracioFct" (Enc $p)); return $true } catch { Log "Error al guardar el informe: $($_.Exception.Message)"; return $false }
}

# ---------------------------------------------------------------- principal
function Tell([string]$msg, [bool]$isError) {
    $mode = $cfg.Notify
    if ($mode -eq 'none') { return }
    if ($mode -eq 'errors' -and -not $isError) { return }
    Notify 'sBID autofill' $msg
}

if ($Startup) {
    Log "Arranque: espero $($cfg.StartDelaySeconds)s a que haya red..."
    Start-Sleep -Seconds $cfg.StartDelaySeconds
}

$saved = 0; $planned = 0; $skipped = 0; $stopped = $null
try {
    Retry { Login }
    Log 'Login correcto.'
    try {
        $first = Retry { GetAgenda }
        Log "Pendientes segun la Agenda: $($first.Count)."
        if (-not $Check -and $first.Items.Count -gt 0) {
            $cutoff = Cutoff
            $skip = @{}
            $weights = $null
            for ($guard = 0; $guard -lt 2000; $guard++) {
                if (($saved + $planned) -ge $cfg.MaxPerRun) { $stopped = "tope de $($cfg.MaxPerRun) por ejecucion; seguira en la proxima"; break }
                $ag = Retry { GetAgenda }
                $it = $ag.Items | Where-Object { -not $skip.ContainsKey($_.Href) } | Select-Object -First 1
                if (-not $it) {
                    if ($ag.Items.Count -gt 0) { $stopped = 'los pendientes visibles estan todos saltados (fin de semana, fecha futura o SkipDates)' }
                    break
                }
                $dateKey = ''; if ($it.Date) { $dateKey = $it.Date.ToString('yyyy-MM-dd') }
                $late = (-not $it.Date) -or ($it.Date -ge $cutoff)
                $weekend = $cfg.SkipWeekends -and $it.Kind -eq 'day' -and $it.Date -and ($it.Date.DayOfWeek -eq 'Saturday' -or $it.Date.DayOfWeek -eq 'Sunday')
                $skipDate = $dateKey -and (@($cfg.SkipDates) -contains $dateKey)
                if ($late -or $weekend -or $skipDate -or ($it.Kind -eq 'report' -and -not $cfg.FillReports)) {
                    $skip[$it.Href] = $true; $skipped++
                    Log "Salto $($it.Text)"
                    continue
                }

                if ($it.Kind -eq 'day') {
                    $f = ParseForm (Http $it.Href)
                    if (-not $weights) {
                        $weights = @()
                        foreach ($a in $f.Acts) {
                            $w = 1.0
                            if ($cfg.Activities.Count -gt 0) { $w = 0.0; if ($cfg.Activities.ContainsKey($a.Code)) { $w = [double]$cfg.Activities[$a.Code] } }
                            if ($w -gt 0) { $weights += [pscustomobject]@{ Id = $a.Name; Code = $a.Code; Weight = $w } }
                        }
                        if ($weights.Count -eq 0) { throw 'Ninguna actividad coincide con Activities de config.ps1.' }
                    }
                    $total = [double]$cfg.HoursPerDay
                    if ($f.Max -and $f.Max -lt $total) { $total = $f.Max }
                    $maxPer = $total; if ($f.Max) { $maxPer = $f.Max }
                    $rng = New-Object System.Random (SeedInt "$($cfg.Seed):$dateKey")
                    $plan = Distribute $rng $weights $total ([double]$cfg.MinBlock) ([int]$cfg.MinActs) ([int]$cfg.MaxActs) $maxPer
                    $summary = (($plan.Keys | Sort-Object | ForEach-Object { $id = $_; '{0}:{1}h' -f ($weights | Where-Object { $_.Id -eq $id }).Code, $plan[$id].ToString('0.##', $Inv) }) -join ' ')
                    if ($DryRun) { $skip[$it.Href] = $true; $planned++; Log "[dry-run] $dateKey -> $summary"; continue }
                    $ok = SaveDay $it.Href $plan
                    $after = Retry { GetAgenda }
                    if (-not $ok -or @($after.Items | Where-Object { $_.Href -eq $it.Href }).Count -gt 0) { $stopped = "sBID no ha aceptado $($it.Text)"; break }
                    $saved++
                    Log "Guardado $dateKey -> $summary"
                }
                else {
                    $f = ParseForm (Http $it.Href)
                    $first = @($f.Selects.Keys | Where-Object { $_ -like 'inp_*' } | Select-Object -First 1)
                    $opts = @(); if ($first.Count -gt 0) { $opts = $f.Selects[$first[0]] }
                    $rating = $null
                    if ($cfg.Rating -eq 'auto') { $rating = BestRating $opts } else { $rating = $opts | Where-Object { $_.Value -eq [string]$cfg.Rating } | Select-Object -First 1 }
                    if (-not $rating) { throw 'No encuentro la valoracion elegida en el informe.' }
                    if ($DryRun) { $skip[$it.Href] = $true; $planned++; Log "[dry-run] informe $dateKey -> $($rating.Text)"; continue }
                    $ok = SaveReport $it.Href $rating.Value
                    $after = Retry { GetAgenda }
                    if (-not $ok -or @($after.Items | Where-Object { $_.Href -eq $it.Href }).Count -gt 0) { $stopped = "sBID no ha aceptado $($it.Text)"; break }
                    $saved++
                    Log "Informe $dateKey -> $($rating.Text)"
                }
            }
        }
    }
    finally { Logout }

    $sufijo = ''; if ($stopped) { $sufijo = " Parado: $stopped" }
    Log "Hecho: $saved guardados, $planned simulados, $skipped saltados.$sufijo"
    if ($stopped) { Tell "Parado: $stopped" $true }
    elseif ($saved -gt 0) { Tell "$saved tareas registradas en sBID." $false }
    elseif ($cfg.Notify -eq 'all') { Tell 'Nada pendiente.' $false }
}
catch {
    $msg = $_.Exception.Message
    Log "ERROR: $msg"
    Tell $msg $true
    exit 1
}

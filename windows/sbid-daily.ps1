<#
  sbid-daily.ps1 - Rellena automaticamente los dias de practicas e informes pendientes de sBID.
  Solo usa PowerShell (ya viene con Windows): no hay que instalar nada.

    sbid-daily.ps1              entra en sBID y rellena lo pendiente (guarda de verdad)
    sbid-daily.ps1 -DryRun      entra y muestra que rellenaria, SIN guardar nada
    sbid-daily.ps1 -Check       solo prueba el login y cuenta pendientes
    sbid-daily.ps1 -Ui          igual, con panel de colores en la consola
    sbid-daily.ps1 -UiDemo      ensenya el panel con datos de mentira (no entra en sBID)
    sbid-daily.ps1 -Install     lo pone en el arranque de Windows (carpeta Inicio), con panel
    sbid-daily.ps1 -Install -Hidden   igual pero sin ventana
    sbid-daily.ps1 -Uninstall   lo quita del arranque

  La configuracion (usuario, contrasenya, reparto...) va en config.ps1, junto a este fichero.
#>
[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$DryRun,
    [switch]$Startup,
    [switch]$Ui,
    [switch]$NoUi,
    [switch]$UiDemo,
    [switch]$Hidden,
    [switch]$Install,
    [switch]$Uninstall,
    [string]$ConfigPath = '',
    [string]$LogFile = '',
    [string]$BaseUrl = 'https://www.empresaiformacio.org',
    [string]$Now = ''
)

$ErrorActionPreference = 'Stop'
# $PSScriptRoot llega vacio en los valores por defecto de param() con rutas relativas (-File .\x.ps1)
$ScriptPath = $MyInvocation.MyCommand.Path
$ScriptDir = Split-Path -Parent $ScriptPath
if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptDir 'config.ps1' }
if (-not $LogFile -and -not $UiDemo) { $LogFile = Join-Path $ScriptDir 'sbid-daily.log' }
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

# ---------------------------------------------------------------- panel de consola
$script:saved = 0; $script:planned = 0; $script:skipped = 0
$script:UiOn = $false
$script:UiW = 68
$script:Spin = '|', '/', '-', '\'
$script:UiS = @{
    Status = 'Iniciando...'; Kind = 'run'; User = ''; Pending = 0; Footer = ''; Tick = 0
    Recent = (New-Object System.Collections.ArrayList); Started = (Get-Date); MaxPerRun = 60
}

function Seg([string]$t, [string]$c) { return [pscustomobject]@{ T = $t; C = $c } }

function Ui-Init {
    if ([Console]::IsOutputRedirected) { return }
    try {
        [Console]::OutputEncoding = [Text.Encoding]::UTF8
        $cols = $script:UiW + 2
        cmd /c "mode con: cols=$cols lines=25" | Out-Null
        $raw = $Host.UI.RawUI
        $raw.WindowTitle = 'sBID autofill'
        $raw.BackgroundColor = 'Black'
        $raw.ForegroundColor = 'Gray'
        Clear-Host
        [Console]::CursorVisible = $false
        $script:UiOn = $true
    } catch { $script:UiOn = $false }
}

function Ui-Frame {
    $u = $script:UiS
    $w = $script:UiW
    $h = [string][char]0x2500; $v = [string][char]0x2502
    $tl = [string][char]0x250C; $tr = [string][char]0x2510; $bl = [string][char]0x2514; $br = [string][char]0x2518
    $full = [string][char]0x2588; $empty = [string][char]0x2591
    $f = New-Object System.Collections.ArrayList

    $title = '  sBID autofill'
    $clock = (Get-Date).ToString('dd/MM/yyyy HH:mm') + '  '
    $gap = $w - 2 - $title.Length - $clock.Length
    [void]$f.Add(@((Seg ($tl + ($h * ($w - 2)) + $tr) 'DarkCyan')))
    [void]$f.Add(@((Seg $v 'DarkCyan'), (Seg $title 'Cyan'), (Seg (' ' * $gap) 'Gray'), (Seg $clock 'DarkGray'), (Seg $v 'DarkCyan')))
    [void]$f.Add(@((Seg ($bl + ($h * ($w - 2)) + $br) 'DarkCyan')))
    [void]$f.Add(@((Seg '' 'Gray')))

    $col = 'Cyan'; $mark = $script:Spin[$u.Tick % 4]
    if ($u.Kind -eq 'done') { $col = 'Green'; $mark = '+' }
    elseif ($u.Kind -eq 'warn') { $col = 'Yellow'; $mark = '!' }
    elseif ($u.Kind -eq 'err') { $col = 'Red'; $mark = 'x' }
    [void]$f.Add(@((Seg '  Estado      ' 'DarkGray'), (Seg "$mark " $col), (Seg $u.Status $col)))
    [void]$f.Add(@((Seg '  Usuario     ' 'DarkGray'), (Seg $u.User 'White')))
    [void]$f.Add(@((Seg '  Pendientes  ' 'DarkGray'), (Seg ([string]$u.Pending).PadRight(8) 'White'),
            (Seg 'Registrados ' 'DarkGray'), (Seg ([string]$script:saved).PadRight(6) 'Green'),
            (Seg 'Simulados ' 'DarkGray'), (Seg ([string]$script:planned).PadRight(6) 'Cyan'),
            (Seg 'Saltados ' 'DarkGray'), (Seg ([string]$script:skipped) 'Yellow')))
    [void]$f.Add(@((Seg '' 'Gray')))

    $goal = [math]::Min($u.Pending, $u.MaxPerRun + $script:skipped)
    $doneN = $script:saved + $script:planned + $script:skipped
    $frac = 0.0
    if ($u.Kind -eq 'done') { $frac = 1.0 } elseif ($goal -gt 0) { $frac = [math]::Min(1.0, $doneN / $goal) }
    $bar = 44
    $n = [int][math]::Floor($frac * $bar)
    $barCol = 'Cyan'; if ($frac -ge 1) { $barCol = 'Green' }
    [void]$f.Add(@((Seg '  ' 'Gray'), (Seg ($full * $n) $barCol), (Seg ($empty * ($bar - $n)) 'DarkGray'),
            (Seg ('  {0,3}%' -f [int][math]::Round($frac * 100)) 'White')))
    [void]$f.Add(@((Seg '' 'Gray')))
    [void]$f.Add(@((Seg '  Actividad' 'DarkGray')))

    $rows = 9
    $recent = @($u.Recent)
    if ($recent.Count -gt $rows) { $recent = $recent[($recent.Count - $rows)..($recent.Count - 1)] }
    for ($i = 0; $i -lt $rows; $i++) {
        if ($i -lt $recent.Count) {
            $r = $recent[$i]
            $t = $r.T; $max = $w - 6
            if ($t.Length -gt $max) { $t = $t.Substring(0, $max - 1) + '~' }
            [void]$f.Add(@((Seg '   ' 'Gray'), (Seg ($r.M + ' ') $r.C), (Seg $t $r.C)))
        } else { [void]$f.Add(@((Seg '' 'Gray'))) }
    }
    [void]$f.Add(@((Seg '' 'Gray')))
    [void]$f.Add(@((Seg ('  ' + $u.Footer) 'DarkGray')))
    return $f
}

function Ui-Render {
    if (-not $script:UiOn) { return }
    try {
        $script:UiS.Tick++
        $Host.UI.RawUI.CursorPosition = New-Object System.Management.Automation.Host.Coordinates 0, 0
        foreach ($segs in (Ui-Frame)) {
            $len = 0
            foreach ($s in $segs) { Write-Host $s.T -NoNewline -ForegroundColor $s.C; $len += $s.T.Length }
            $pad = $script:UiW - $len
            if ($pad -gt 0) { Write-Host (' ' * $pad) -NoNewline }
            Write-Host ''
        }
    } catch { $script:UiOn = $false }
}

function Ui-Set([string]$status, [string]$kind = 'run') {
    $script:UiS.Status = $status
    $script:UiS.Kind = $kind
    Ui-Render
}

# Espera $secs segundos; en modo panel muestra la cuenta atras y una tecla la salta.
function Wait-Ui([int]$secs, [string]$label) {
    if (-not $script:UiOn) { if ($secs -gt 0) { Start-Sleep -Seconds $secs }; return }
    for ($i = $secs; $i -gt 0; $i--) {
        $script:UiS.Footer = "$label $i s   (pulsa una tecla para saltar)"
        Ui-Render
        for ($k = 0; $k -lt 10; $k++) {
            $key = $false
            try { $key = [Console]::KeyAvailable } catch { }
            if ($key) { [void][Console]::ReadKey($true); $script:UiS.Footer = ''; return }
            Start-Sleep -Milliseconds 100
        }
    }
    $script:UiS.Footer = ''
    Ui-Render
}

function Ui-Finish([string]$kind, [string]$status, [int]$secs) {
    if (-not $script:UiOn) { return }
    Ui-Set $status $kind
    Wait-Ui $secs 'Se cierra en'
    try { [Console]::CursorVisible = $true } catch { }
}

function Log([string]$m, [string]$level = 'info') {
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    if ($LogFile) { try { Add-Content -Path $LogFile -Value $line -Encoding UTF8 } catch { } }
    $marks = @{ ok = '+'; warn = '!'; err = 'x'; dry = '~'; skip = '-'; info = '.' }
    $cols = @{ ok = 'Green'; warn = 'Yellow'; err = 'Red'; dry = 'Cyan'; skip = 'DarkGray'; info = 'Gray' }
    if ($script:UiOn) {
        [void]$script:UiS.Recent.Add([pscustomobject]@{ M = $marks[$level]; C = $cols[$level]; T = $m })
        Ui-Render
    } else {
        Write-Host $line -ForegroundColor $cols[$level]
    }
}

if ($UiDemo) {
    $LogFile = ''
    Ui-Init
    if (-not $script:UiOn) { Write-Host 'El panel necesita una consola real (no redirigida).'; exit 1 }
    $script:UiS.User = 'alumne'
    Ui-Set 'Esperando a que haya red...'
    Wait-Ui 3 'Empieza en'
    Ui-Set 'Conectando con sBID...'; Start-Sleep -Seconds 1
    Log 'Login correcto.' 'ok'
    $script:UiS.Pending = 30
    $d = Get-Date '2026-06-01'
    for ($i = 0; $i -lt 20; $i++) {
        if ($d.DayOfWeek -eq 'Saturday' -or $d.DayOfWeek -eq 'Sunday') {
            $script:skipped++; Log ("Salto {0:dd/MM/yyyy}: fin de semana" -f $d) 'skip'
        } else {
            Ui-Set ("Registrando dia {0:yyyy-MM-dd}..." -f $d)
            Start-Sleep -Milliseconds 450
            $script:saved++
            Log ("Guardado {0:yyyy-MM-dd} -> 1.5:2h 2.4:1.5h 1.4:0.5h" -f $d) 'ok'
        }
        if ($i -eq 11) { Ui-Set 'Valorando informe 2026-06-30...'; Start-Sleep -Milliseconds 450; $script:saved++; Log 'Informe 2026-06-30 -> MOLT ADEQUADA' 'ok' }
        $d = $d.AddDays(1)
    }
    Ui-Finish 'done' ("Completado: {0} registrados" -f $script:saved) 5
    exit 0
}

function Notify([string]$title, [string]$msg) {
    if ($script:UiOn) { return }
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
    if ($Hidden) {
        $s.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ScriptPath + '" -Startup -NoUi'
        $s.WindowStyle = 7
    } else {
        $s.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $ScriptPath + '" -Startup'
        $s.WindowStyle = 1
    }
    $s.WorkingDirectory = $ScriptDir
    $s.Save()
    Write-Host "Instalado: se ejecutara cada vez que enciendas el PC ($lnk)"
    if (-not $Hidden) { Write-Host 'Se abrira una ventana con el panel de progreso y se cerrara sola al terminar. (Sin ventana: -Install -Hidden)' }
    exit 0
}

# ---------------------------------------------------------------- configuracion
if (($Startup -and -not $NoUi) -or $Ui) { Ui-Init }

if (-not (Test-Path $ConfigPath)) {
    Log "No existe $ConfigPath. Copia config.example.ps1 como config.ps1 y rellenalo." 'err'
    Ui-Finish 'err' 'Falta config.ps1' 60
    exit 2
}
. $ConfigPath
if (-not $Config) { Log 'config.ps1 no define $Config.' 'err'; Ui-Finish 'err' 'config.ps1 sin $Config' 60; exit 2 }

$cfg = @{
    HoursPerDay = 4; MinBlock = 0.5; MinActs = 2; MaxActs = 3; Seed = 'sbid'
    Activities = @{}; SkipWeekends = $true; SkipDates = @(); FillTodayAfter = '18:00'
    FillReports = $true; Rating = 'auto'; MaxPerRun = 60; Notify = 'changes'
    StartDelaySeconds = 45; NetworkRetries = 5; NetworkRetryDelaySeconds = 30
    UiCloseSeconds = 6; UiErrorCloseSeconds = 60
}
foreach ($k in $Config.Keys) { $cfg[$k] = $Config[$k] }
if ($env:SBID_USER) { $cfg.Username = $env:SBID_USER }
if ($env:SBID_PASS) { $cfg.Password = $env:SBID_PASS }
if ($cfg.PasswordProtected -and -not $cfg.Password) {
    # contrasenya cifrada por setup.ps1 con DPAPI: solo se puede descifrar con esta cuenta de Windows en este PC
    try {
        $sec = ConvertTo-SecureString ([string]$cfg.PasswordProtected)
        $cfg.Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    } catch {
        Log 'No puedo descifrar PasswordProtected (otra cuenta de Windows u otro PC?). Ejecuta 0-configurar.bat otra vez.' 'err'
        Ui-Finish 'err' 'No puedo descifrar la contrasenya; ejecuta 0-configurar.bat' $cfg.UiErrorCloseSeconds
        exit 2
    }
}
if (-not $cfg.Username -or -not $cfg.Password) {
    Log 'Faltan Username/Password en config.ps1.' 'err'
    Ui-Finish 'err' 'Faltan Username/Password en config.ps1' $cfg.UiErrorCloseSeconds
    exit 2
}
$script:UiS.User = $cfg.Username
$script:UiS.MaxPerRun = [int]$cfg.MaxPerRun

$nowDate = if ($Now) { [datetime]::Parse($Now) } else { Get-Date }
$Inv = [Globalization.CultureInfo]::InvariantCulture
$Origin = $BaseUrl.TrimEnd('/')
$Mod = "$Origin/sBid/modules"
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36'
# Cliente de sBID (HTTP, login, agenda, formularios)
. (Join-Path $ScriptDir 'sbid-lib.ps1')

function Retry([scriptblock]$f) {
    for ($i = 0; ; $i++) {
        try { return (& $f) }
        catch {
            if ($_.Exception.Message -like 'LOGIN:*' -or $i -ge $cfg.NetworkRetries) { throw }
            Log ("Sin conexion ({0}); reintento {1}/{2}..." -f $_.Exception.Message, ($i + 1), $cfg.NetworkRetries) 'warn'
            Ui-Set 'Sin conexion, esperando para reintentar...'
            Wait-Ui $cfg.NetworkRetryDelaySeconds 'Reintento en'
            Ui-Set 'Reintentando...'
        }
    }
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
    try { [void](Http "$Mod/ActivitatFct" (Enc $p)); return $true } catch { Log "Error al guardar: $($_.Exception.Message)" 'err'; return $false }
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
    try { [void](Http "$Mod/ActivitatValoracioFct" (Enc $p)); return $true } catch { Log "Error al guardar el informe: $($_.Exception.Message)" 'err'; return $false }
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
    Ui-Set 'Esperando a que haya red...'
    Wait-Ui ([int]$cfg.StartDelaySeconds) 'Empieza en'
}

$stopped = $null
try {
    Ui-Set 'Conectando con sBID...'
    Retry { Login }
    Log 'Login correcto.' 'ok'
    try {
        Ui-Set 'Leyendo pendientes...'
        $agenda0 = Retry { GetAgenda }
        $pn = 0; [void][int]::TryParse([string]$agenda0.Count, [ref]$pn)
        $script:UiS.Pending = $pn
        Log "Pendientes segun la Agenda: $($agenda0.Count)."
        if (-not $Check -and $agenda0.Items.Count -gt 0) {
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
                    Log "Salto $($it.Text)" 'skip'
                    continue
                }

                if ($it.Kind -eq 'day') {
                    Ui-Set "Registrando dia $dateKey..."
                    $f = ParseForm (Http $it.Href)
                    if (-not $weights) {
                        $weights = @()
                        foreach ($a in $f.Acts) {
                            $w = 1.0
                            if ($cfg.Activities.Count -gt 0) { $w = 0.0; if ($cfg.Activities.ContainsKey($a.Code)) { $w = [double]$cfg.Activities[$a.Code] } }
                            if ($w -gt 0) { $weights += [pscustomobject]@{ Id = $a.Name; Code = $a.Code; Weight = $w } }
                        }
                        if ($weights.Count -eq 0) { throw 'Ninguna actividad coincide con Activities de config.ps1 (ejecuta 0-configurar.bat).' }
                        $known = @($f.Acts | ForEach-Object { $_.Code })
                        $gone = @($cfg.Activities.Keys | Where-Object { $known -notcontains $_ })
                        if ($gone.Count -gt 0) { Log ('Activities de config.ps1 que ya no existen en tu plan: ' + ($gone -join ', ') + ' (ejecuta 0-configurar.bat)') 'warn' }
                    }
                    $total = [double]$cfg.HoursPerDay
                    if ($f.Max -and $f.Max -lt $total) { $total = $f.Max }
                    $maxPer = $total; if ($f.Max) { $maxPer = $f.Max }
                    $rng = New-Object System.Random (SeedInt "$($cfg.Seed):$dateKey")
                    $plan = Distribute $rng $weights $total ([double]$cfg.MinBlock) ([int]$cfg.MinActs) ([int]$cfg.MaxActs) $maxPer
                    $summary = (($plan.Keys | Sort-Object | ForEach-Object { $id = $_; '{0}:{1}h' -f ($weights | Where-Object { $_.Id -eq $id }).Code, $plan[$id].ToString('0.##', $Inv) }) -join ' ')
                    if ($DryRun) { $skip[$it.Href] = $true; $planned++; Log "[dry-run] $dateKey -> $summary" 'dry'; continue }
                    $ok = SaveDay $it.Href $plan
                    $after = Retry { GetAgenda }
                    if (-not $ok -or @($after.Items | Where-Object { $_.Href -eq $it.Href }).Count -gt 0) { $stopped = "sBID no ha aceptado $($it.Text)"; break }
                    $saved++
                    Log "Guardado $dateKey -> $summary" 'ok'
                }
                else {
                    Ui-Set "Valorando informe $dateKey..."
                    $f = ParseForm (Http $it.Href)
                    $inpNames = @($f.Selects.Keys | Where-Object { $_ -like 'inp_*' } | Select-Object -First 1)
                    $opts = @(); if ($inpNames.Count -gt 0) { $opts = $f.Selects[$inpNames[0]] }
                    $rating = $null
                    if ($cfg.Rating -eq 'auto') { $rating = BestRating $opts } else { $rating = $opts | Where-Object { $_.Value -eq [string]$cfg.Rating } | Select-Object -First 1 }
                    if (-not $rating) { throw 'No encuentro la valoracion elegida en el informe.' }
                    if ($DryRun) { $skip[$it.Href] = $true; $planned++; Log "[dry-run] informe $dateKey -> $($rating.Text)" 'dry'; continue }
                    $ok = SaveReport $it.Href $rating.Value
                    $after = Retry { GetAgenda }
                    if (-not $ok -or @($after.Items | Where-Object { $_.Href -eq $it.Href }).Count -gt 0) { $stopped = "sBID no ha aceptado $($it.Text)"; break }
                    $saved++
                    Log "Informe $dateKey -> $($rating.Text)" 'ok'
                }
            }
        }
    }
    finally { Ui-Set 'Cerrando sesion...'; Logout }

    $sufijo = ''; if ($stopped) { $sufijo = " Parado: $stopped" }
    Log "Hecho: $saved guardados, $planned simulados, $skipped saltados.$sufijo" $(if ($stopped) { 'warn' } else { 'info' })
    if ($stopped) {
        Tell "Parado: $stopped" $true
        Ui-Finish 'warn' "Parado: $stopped" ([int]$cfg.UiErrorCloseSeconds)
    }
    else {
        if ($saved -gt 0) { Tell "$saved tareas registradas en sBID." $false }
        elseif ($cfg.Notify -eq 'all') { Tell 'Nada pendiente.' $false }
        $final = 'Todo al dia: nada pendiente'
        if ($saved -gt 0) { $final = "Completado: $saved registrados" } elseif ($planned -gt 0) { $final = "Simulacion completada: $planned" }
        Ui-Finish 'done' $final ([int]$cfg.UiCloseSeconds)
    }
}
catch {
    $msg = $_.Exception.Message
    Log "ERROR: $msg" 'err'
    Tell $msg $true
    Ui-Finish 'err' $msg ([int]$cfg.UiErrorCloseSeconds)
    exit 1
}

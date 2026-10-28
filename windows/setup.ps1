<#
  setup.ps1 - Asistente de configuracion de sbid-autofill (Windows, solo PowerShell).

  Te pide usuario y contrasenya de sBID, entra, LEE LAS ACTIVIDADES REALES DE TU PLAN y te deja
  elegir cuales rellenar (y con que peso), las horas por dia, dias a saltar, etc. Escribe config.ps1
  y, si quieres, lanza una simulacion y deja el arranque automatico instalado.
  Se puede volver a ejecutar cuando quieras (p. ej. si cambia tu plan de actividades).

  Para pruebas automaticas acepta SBID_USER / SBID_PASS (entorno), SBID_SETUP_KEYS (teclas separadas
  por comas) y SBID_SETUP_INPUT (respuestas separadas por |).
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [string]$BaseUrl = 'https://www.empresaiformacio.org'
)

$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
$ScriptPath = $MyInvocation.MyCommand.Path
$ScriptDir = Split-Path -Parent $ScriptPath
if (-not $ConfigPath) { $ConfigPath = Join-Path $ScriptDir 'config.ps1' }
$Inv = [Globalization.CultureInfo]::InvariantCulture
$interactive = -not [Console]::IsOutputRedirected

# ---------------------------------------------------------------- entrada (con ganchos para tests)
$script:Keys = New-Object System.Collections.Queue
if ($env:SBID_SETUP_KEYS) { foreach ($k in ($env:SBID_SETUP_KEYS -split ',')) { if ($k.Trim()) { $script:Keys.Enqueue($k.Trim()) } } }
$script:Inputs = New-Object System.Collections.Queue
if ($null -ne $env:SBID_SETUP_INPUT) { foreach ($i in ($env:SBID_SETUP_INPUT -split '\|')) { $script:Inputs.Enqueue($i) } }

function Read-Key {
    if ($script:Keys.Count -gt 0) {
        return [pscustomobject]@{ Key = [ConsoleKey]([string]$script:Keys.Dequeue()); KeyChar = [char]0 }
    }
    try { return [Console]::ReadKey($true) }
    catch { throw 'Este asistente necesita una consola interactiva (abrelo con 0-configurar.bat).' }
}

function Ask([string]$prompt, [string]$default = '') {
    $hint = ''; if ($default -ne '') { $hint = " [$default]" }
    if ($script:Inputs.Count -gt 0) {
        $a = [string]$script:Inputs.Dequeue()
        Write-Host ("  {0}{1}: {2}" -f $prompt, $hint, $a) -ForegroundColor DarkGray
    } else {
        Write-Host '  ' -NoNewline
        $a = Read-Host ($prompt + $hint)
    }
    if ($a.Trim() -eq '') { return $default }
    return $a.Trim()
}

function AskYN([string]$prompt, [bool]$default = $true) {
    $d = 'S/n'; if (-not $default) { $d = 's/N' }
    $a = Ask "$prompt ($d)" ''
    if ($a -eq '') { return $default }
    return ($a -match '^(s|si|y|yes)$')
}

function AskPassword {
    if ($env:SBID_PASS) { return $env:SBID_PASS }
    Write-Host '  ' -NoNewline
    $s = Read-Host 'Contrasenya de sBID (no se ve al escribir)' -AsSecureString
    return [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))
}

function Norm([string]$s) {
    $d = $s.Normalize([Text.NormalizationForm]::FormD)
    return ([regex]::Replace($d, '\p{Mn}', '')).ToLowerInvariant()
}

function Title([string]$t) {
    Write-Host ''
    Write-Host ("  " + $t) -ForegroundColor Cyan
    Write-Host ("  " + ('-' * $t.Length)) -ForegroundColor DarkCyan
}
function Info([string]$t) { Write-Host ("  " + $t) -ForegroundColor Gray }
function Good([string]$t) { Write-Host ("  + " + $t) -ForegroundColor Green }
function Bad([string]$t) { Write-Host ("  x " + $t) -ForegroundColor Red }

# ---------------------------------------------------------------- cliente de sBID
$cfg = @{ Username = ''; Password = ''; NetworkRetries = 0 }
$Origin = $BaseUrl.TrimEnd('/')
$Mod = "$Origin/sBid/modules"
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36'
$SetupLog = Join-Path $ScriptDir 'sbid-setup.log'
function Log([string]$m, [string]$level = 'info') {
    try { Add-Content -Path $SetupLog -Value ('[{0}] {1}' -f (Get-Date -Format 's'), $m) -Encoding UTF8 } catch { }
}
. (Join-Path $ScriptDir 'sbid-lib.ps1')

# ---------------------------------------------------------------- lista de actividades (flechas)
function Select-Activities($acts, $preselect) {
    $n = $acts.Count
    $sel = New-Object 'bool[]' $n
    $wt = New-Object 'int[]' $n
    for ($i = 0; $i -lt $n; $i++) { $wt[$i] = 1; if ($preselect -contains $i) { $sel[$i] = $true; $wt[$i] = 3 } }
    $width = 110; $rows = [math]::Min($n, 16)
    if ($interactive) {
        try {
            $width = [Console]::WindowWidth - 1
            $rows = [math]::Min([math]::Min($n, 20), [math]::Max(5, [Console]::WindowHeight - 10))
        } catch { }
    }
    $height = $rows + 4
    $pos = 0; $top = 0; $msg = ''
    if ($interactive) {
        # reserva el hueco; despues cada Draw sube $height lineas (relativo: aguanta el scroll de la consola)
        Write-Host ("`n" * $height) -NoNewline
        try { [Console]::CursorVisible = $false } catch { }
    }

    function Put([string]$text, [string]$fg = 'Gray', [string]$bg = 'Black') {
        $t = $text; if ($t.Length -gt $width) { $t = $t.Substring(0, $width) }
        Write-Host $t -NoNewline -ForegroundColor $fg -BackgroundColor $bg
        if ($t.Length -lt $width) { Write-Host (' ' * ($width - $t.Length)) -NoNewline -BackgroundColor $bg }
        Write-Host ''
    }

    function Draw {
        if (-not $interactive) { return }
        [Console]::SetCursorPosition(0, [Math]::Max(0, [Console]::CursorTop - $height))
        Put '  Flechas arriba/abajo = moverte    Espacio = marcar/desmarcar    Izq/Der = peso (1-5)' 'Cyan'
        Put '  A = marcar todas    N = ninguna    Enter = continuar    Esc = cancelar' 'DarkCyan'
        Put ''
        for ($r = 0; $r -lt $rows; $r++) {
            $i = $top + $r
            if ($i -ge $n) { Put ''; continue }
            $mark = '[ ]'; if ($sel[$i]) { $mark = '[x]' }
            $dots = ('#' * $wt[$i]) + ('-' * (5 - $wt[$i]))
            $label = $acts[$i].Label -replace '^\d+(\.\d+)*\.?\s*', ''
            $lead = ('  {0} [{1}] {2,-5} ' -f $mark, $dots, $acts[$i].Code)
            $room = $width - $lead.Length
            if ($label.Length -gt $room) { $label = $label.Substring(0, [math]::Max(0, $room - 1)) + '~' }
            $fg = 'Gray'; if ($sel[$i]) { $fg = 'Green' }
            if ($i -eq $pos) { Put ($lead + $label) 'White' 'DarkCyan' } else { Put ($lead + $label) $fg }
        }
        $cnt = @($sel | Where-Object { $_ }).Count
        $status = ('  Marcadas: {0} de {1}    (actividad {2}/{3})  {4}' -f $cnt, $n, ($pos + 1), $n, $msg)
        Put $status 'Yellow'
    }

    while ($true) {
        Draw
        $k = Read-Key
        $msg = ''
        switch ([string]$k.Key) {
            'UpArrow' { if ($pos -gt 0) { $pos-- } }
            'DownArrow' { if ($pos -lt $n - 1) { $pos++ } }
            'PageUp' { $pos = [math]::Max(0, $pos - $rows) }
            'PageDown' { $pos = [math]::Min($n - 1, $pos + $rows) }
            'Home' { $pos = 0 }
            'End' { $pos = $n - 1 }
            'Spacebar' { $sel[$pos] = -not $sel[$pos] }
            'LeftArrow' { if ($wt[$pos] -gt 1) { $wt[$pos]-- } }
            'RightArrow' { if ($wt[$pos] -lt 5) { $wt[$pos]++ }; $sel[$pos] = $true }
            'A' { for ($i = 0; $i -lt $n; $i++) { $sel[$i] = $true } }
            'N' { for ($i = 0; $i -lt $n; $i++) { $sel[$i] = $false } }
            'Escape' {
                if ($interactive) { try { [Console]::CursorVisible = $true } catch { } }
                throw 'CANCEL'
            }
            'Enter' {
                if (@($sel | Where-Object { $_ }).Count -eq 0) { $msg = '<- marca al menos una actividad' }
                else {
                    if ($interactive) { try { [Console]::CursorVisible = $true } catch { } }
                    $out = @()
                    for ($i = 0; $i -lt $n; $i++) { if ($sel[$i]) { $out += [pscustomobject]@{ Code = $acts[$i].Code; Label = $acts[$i].Label; Weight = $wt[$i] } } }
                    return $out
                }
            }
        }
        if ($pos -lt $top) { $top = $pos }
        if ($pos -ge $top + $rows) { $top = $pos - $rows + 1 }
    }
}

# ---------------------------------------------------------------- validaciones
function Parse-SkipDates([string]$text) {
    $dates = New-Object System.Collections.ArrayList; $bad = @()
    foreach ($tok in ($text -split '[,; ]+' | Where-Object { $_ })) {
        $parts = $tok -split '\.\.'
        $d1 = [datetime]::MinValue; $d2 = [datetime]::MinValue
        $ok1 = [datetime]::TryParseExact($parts[0], 'yyyy-MM-dd', $Inv, 'None', [ref]$d1)
        if ($parts.Count -eq 1) {
            if ($ok1) { [void]$dates.Add($d1.ToString('yyyy-MM-dd')) } else { $bad += $tok }
        } elseif ($parts.Count -eq 2 -and $ok1 -and [datetime]::TryParseExact($parts[1], 'yyyy-MM-dd', $Inv, 'None', [ref]$d2) -and $d2 -ge $d1 -and ($d2 - $d1).Days -le 400) {
            for ($d = $d1; $d -le $d2; $d = $d.AddDays(1)) { [void]$dates.Add($d.ToString('yyyy-MM-dd')) }
        } else { $bad += $tok }
    }
    return [pscustomobject]@{ Dates = @($dates | Sort-Object -Unique); Bad = $bad }
}

function Q([string]$s) { return "'" + ($s -replace "'", "''") + "'" }
function Num([double]$d) { return $d.ToString('0.##', $Inv) }

# ================================================================ PROGRAMA
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
if ($interactive) { try { cmd /c 'mode con: cols=120 lines=45' | Out-Null } catch { } }
if ($interactive) { Clear-Host }
Write-Host ''
Write-Host '  sBID autofill - asistente de configuracion' -ForegroundColor Cyan
Write-Host '  Lee tu plan de actividades real y deja todo listo en un par de minutos.' -ForegroundColor DarkGray

if (Test-Path $ConfigPath) {
    Write-Host ''
    Info "Ya existe $ConfigPath. Si sigues, se guardara una copia como config.ps1.bak."
    if (-not (AskYN 'Continuar' $true)) { Info 'Sin cambios.'; return }
}

# ---- 1. credenciales y login
Title '1. Tu cuenta de sBID'
$user = $env:SBID_USER
$pass = $env:SBID_PASS
$fromEnv = [bool]($user -and $pass)
$logged = $false
for ($try = 1; $try -le 2 -and -not $logged; $try++) {
    if (-not $fromEnv) {
        $user = Ask 'Usuario de sBID' ''
        if (-not $user) { Bad 'El usuario no puede estar vacio.'; $try--; continue }
        $pass = AskPassword
    }
    $cfg.Username = $user; $cfg.Password = $pass
    $script:Cookies.Clear(); $script:Trace.Clear()
    Info 'Entrando en sBID...'
    try { Login; $logged = $true; Good 'Login correcto.' }
    catch {
        if ($_.Exception.Message -like 'LOGIN:*') {
            Bad 'No he podido entrar: usuario o contrasenya incorrectos (o sBID ha cambiado su web).'
            Log ($_.Exception.Message)
            if ($fromEnv -or $try -ge 2) { Info "Detalles tecnicos en $SetupLog"; exit 1 }
            Info 'Prueba otra vez (no insistas muchas veces: sBID podria bloquear la cuenta).'
        } else {
            Bad ("No hay conexion con sBID: " + $_.Exception.Message)
            exit 1
        }
    }
}

# ---- 2. leer lo que tiene este usuario
Title '2. Leyendo tus datos en sBID'
$ag = GetAgenda
$pendiente = $ag.Count
$dayHref = ($ag.Items | Where-Object { $_.Kind -eq 'day' } | Select-Object -First 1).Href
if (-not $dayHref) { $dayHref = $ag.AnyDay }
if (-not $dayHref) {
    Bad 'No encuentro ningun dia de actividad en tu Agenda (ni pendiente ni de hoy), asi que no puedo leer tus actividades.'
    Info 'Vuelve a ejecutar este asistente cuando tengas algun dia pendiente.'
    Logout; exit 1
}
$dayHtml = Http $dayHref
$form = ParseForm $dayHtml
if ($form.Acts.Count -eq 0) { Bad 'No he encontrado actividades en el formulario del dia.'; Logout; exit 1 }

$flat = ($dayHtml -replace '(?is)<script.*?</script>|<style.*?</style>|<[^>]+>', ' ') -replace '\s+', ' '
$flat = [System.Net.WebUtility]::HtmlDecode($flat)
$estudi = ''; $empresa = ''; $periode = ''
$m1 = [regex]::Match($flat, 'Estudi:\s*(.+?)\s+Empresa:\s*(.+?)\s+Centre de Treball'); if ($m1.Success) { $estudi = $m1.Groups[1].Value; $empresa = $m1.Groups[2].Value }
$m2 = [regex]::Match($flat, "Per.odes? de l.acord:\s*(.+?)\s+Hores m"); if ($m2.Success) { $periode = $m2.Groups[1].Value }
if ($estudi) { Info "Estudio:     $estudi" }
if ($empresa) { Info "Empresa:     $empresa" }
if ($periode) { Info "Periodo:     $periode" }
$maxTxt = 'sin limite detectado'; if ($form.Max) { $maxTxt = (Num $form.Max) + ' h' }
Info "Max. por dia: $maxTxt"
Info "Actividades:  $($form.Acts.Count) en tu plan"
Info "Pendientes:   $pendiente"

$ratingOpts = @()
$repHref = ($ag.Items | Where-Object { $_.Kind -eq 'report' } | Select-Object -First 1).Href
if ($repHref) {
    try {
        $rf = ParseForm (Http $repHref)
        $first = @($rf.Selects.Keys | Where-Object { $_ -like 'inp_*' } | Select-Object -First 1)
        if ($first.Count -gt 0) { $ratingOpts = @($rf.Selects[$first[0]] | Where-Object { $_.Value -ne '' }) }
    } catch { }
}
Logout

# ---- 3. actividades
Title '3. Actividades a rellenar'
Info 'Te ensenyo las actividades de TU plan. Marca las que de verdad has hecho; el peso (1-5)'
Info 'es la frecuencia relativa: mas peso = mas horas de media.'
Info 'Si quieres, escribe palabras para dejarlas preseleccionadas (ej: seguretat, base de dades, documentacio).'
$kw = Ask 'Palabras clave (Enter = ninguna)' ''
$pre = @()
if ($kw) {
    $ks = @($kw -split ',' | ForEach-Object { Norm $_.Trim() } | Where-Object { $_ })
    for ($i = 0; $i -lt $form.Acts.Count; $i++) {
        $nl = Norm $form.Acts[$i].Label
        if (@($ks | Where-Object { $nl.Contains($_) }).Count -gt 0) { $pre += $i }
    }
    Info "$($pre.Count) actividades coinciden y quedan marcadas con peso 3."
}
try { $chosen = Select-Activities $form.Acts $pre }
catch { if ($_.Exception.Message -eq 'CANCEL') { Write-Host ''; Info 'Cancelado, no se ha cambiado nada.'; return } else { throw } }
Good ("{0} actividades elegidas." -f $chosen.Count)

# ---- 4. horas y reparto
Title '4. Horas y reparto'
$defHours = 4; if ($form.Max) { $defHours = $form.Max }
$hours = $defHours
$ah = Ask 'Horas por dia' (Num $defHours)
$tmp = 0.0
if ([double]::TryParse($ah.Replace(',', '.'), 'Float', $Inv, [ref]$tmp) -and $tmp -gt 0) { $hours = [math]::Round($tmp * 4) / 4 } else { Info "No lo entiendo; uso $(Num $defHours) h." }
if ($form.Max -and $hours -gt $form.Max) { Info "sBID solo admite $(Num $form.Max) h por dia; lo dejo en ese maximo."; $hours = $form.Max }

$minBlock = 0.5
$ab = Ask 'Minimo de horas por actividad cada dia' (Num $minBlock)
if ([double]::TryParse($ab.Replace(',', '.'), 'Float', $Inv, [ref]$tmp) -and $tmp -ge 0.25) { $minBlock = [math]::Round($tmp * 4) / 4 }
if ($minBlock -gt $hours) { $minBlock = $hours }

$kMin = 2; $kMax = 3
$ar = Ask 'Actividades distintas por dia (minimo-maximo, ej. 2-3)' '2-3'
$mr = [regex]::Match($ar, '^(\d+)\s*-\s*(\d+)$')
if ($mr.Success) { $kMin = [int]$mr.Groups[1].Value; $kMax = [int]$mr.Groups[2].Value }
elseif ($ar -match '^\d+$') { $kMin = [int]$ar; $kMax = [int]$ar }
$maxPossible = [int][math]::Max(1, [math]::Min($chosen.Count, [math]::Floor($hours / $minBlock)))
if ($kMax -gt $maxPossible) { $kMax = $maxPossible }
if ($kMin -gt $kMax) { $kMin = $kMax }
if ($kMin -lt 1) { $kMin = 1 }

# ---- 5. calendario
Title '5. Calendario'
$skipWeekends = AskYN 'Saltar sabados y domingos' $true
$skipDates = @()
while ($true) {
    Info 'Dias que NO has ido (vacaciones, bajas, festivos): fechas AAAA-MM-DD o rangos AAAA-MM-DD..AAAA-MM-DD,'
    Info 'separados por comas. Ej: 2026-12-24..2026-12-31, 2027-01-06'
    $as = Ask 'Dias a saltar (Enter = ninguno)' ''
    $ps = Parse-SkipDates $as
    if ($ps.Bad.Count -gt 0) { Bad ('No entiendo: ' + ($ps.Bad -join ', ')); continue }
    $skipDates = $ps.Dates
    if ($skipDates.Count -gt 0) { Good ("{0} dias a saltar." -f $skipDates.Count) }
    break
}
Info 'El dia de hoy no se rellena hasta que ha pasado cierta hora (por si el PC arranca por la manana).'
$fillToday = '18:00'
while ($true) {
    $at = Ask 'Rellenar tambien HOY si el PC arranca despues de las (HH:MM, "no" = nunca)' '18:00'
    if ($at -match '^(no|nunca|n)$') { $fillToday = ''; break }
    if ($at -match '^([01]?\d|2[0-3]):[0-5]\d$') { $fillToday = $at; break }
    Bad 'Formato HH:MM (por ejemplo 18:00) o "no".'
}

# ---- 6. informes
Title '6. Informes periodicos'
$fillReports = AskYN 'Rellenar tambien los informes periodicos pendientes' $true
$rating = 'auto'
if ($fillReports -and $ratingOpts.Count -gt 0) {
    $bestIdx = $ratingOpts.Count - 1
    for ($i = 0; $i -lt $ratingOpts.Count; $i++) { if ($ratingOpts[$i].Text -match 'molt adequada|muy adecuada|excel') { $bestIdx = $i; break } }
    Info 'Valoraciones que ofrece sBID en tus informes:'
    for ($i = 0; $i -lt $ratingOpts.Count; $i++) { Info ("  {0}) {1}" -f ($i + 1), $ratingOpts[$i].Text) }
    $pick = Ask 'Valoracion para todas las tareas (numero)' ([string]($bestIdx + 1))
    $pi = 0
    if ([int]::TryParse($pick, [ref]$pi) -and $pi -ge 1 -and $pi -le $ratingOpts.Count) {
        if (($pi - 1) -ne $bestIdx) { $rating = $ratingOpts[$pi - 1].Value }
        Good ("Valoracion: " + $ratingOpts[$pi - 1].Text)
    }
}

# ---- 7. contrasenya y arranque
Title '7. Seguridad y arranque'
$protect = AskYN 'Guardar la contrasenya CIFRADA con tu cuenta de Windows (recomendado; solo funciona en este PC y usuario)' $true
$showPanel = AskYN 'Mostrar la ventana con el panel de colores al arrancar el PC (si no, va sin ventana)' $true

# ---- resumen
Title 'Resumen'
Info "Usuario:               $user"
Info ("Horas por dia:         {0}  (bloque minimo {1} h, {2}-{3} actividades/dia)" -f (Num $hours), (Num $minBlock), $kMin, $kMax)
Info ("Actividades:           " + (($chosen | ForEach-Object { "$($_.Code)x$($_.Weight)" }) -join '  '))
$swTxt = 'no'; if ($skipWeekends) { $swTxt = 'si' }
Info ("Saltar fines de semana: $swTxt;  dias a saltar: {0}" -f $skipDates.Count)
$ftTxt = 'nunca'; if ($fillToday) { $ftTxt = "si arranca despues de las $fillToday" }
Info "Rellenar hoy:          $ftTxt"
$frTxt = 'no'; if ($fillReports) { $frTxt = "si (valoracion: $rating)" }
Info "Informes:              $frTxt"
if (-not (AskYN 'Guardar esta configuracion' $true)) { Info 'Sin cambios.'; return }

# ---- escribir config.ps1
$seed = -join ((48..57 + 97..122) | Get-Random -Count 8 | ForEach-Object { [char]$_ })
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("# Generado por setup.ps1 el $(Get-Date -Format 'yyyy-MM-dd HH:mm'). Vuelve a ejecutar 0-configurar.bat para cambiarlo.")
[void]$sb.AppendLine('# Este fichero NO se sube a GitHub (.gitignore).')
[void]$sb.AppendLine('$Config = @{')
[void]$sb.AppendLine("    Username = $(Q $user)")
if ($protect) {
    $enc = ConvertFrom-SecureString (ConvertTo-SecureString $pass -AsPlainText -Force)
    [void]$sb.AppendLine("    PasswordProtected = $(Q $enc)   # cifrada con tu cuenta de Windows")
} else {
    [void]$sb.AppendLine("    Password = $(Q $pass)")
}
[void]$sb.AppendLine('')
[void]$sb.AppendLine("    HoursPerDay = $(Num $hours)")
[void]$sb.AppendLine("    MinBlock    = $(Num $minBlock)")
[void]$sb.AppendLine("    MinActs     = $kMin")
[void]$sb.AppendLine("    MaxActs     = $kMax")
[void]$sb.AppendLine("    Seed        = $(Q $seed)")
[void]$sb.AppendLine('')
[void]$sb.AppendLine('    # codigo de actividad = peso (1-5)')
[void]$sb.AppendLine('    Activities = @{')
foreach ($c in $chosen) {
    $lab = ($c.Label -replace '^\d+(\.\d+)*\.?\s*', '') -replace '\s+', ' '
    if ($lab.Length -gt 70) { $lab = $lab.Substring(0, 69) + '~' }
    [void]$sb.AppendLine(("        {0,-8} = {1}   # {2}" -f (Q $c.Code), $c.Weight, $lab))
}
[void]$sb.AppendLine('    }')
[void]$sb.AppendLine('')
[void]$sb.AppendLine('    SkipWeekends   = ' + $(if ($skipWeekends) { '$true' } else { '$false' }))
[void]$sb.AppendLine('    SkipDates      = @(' + (($skipDates | ForEach-Object { Q $_ }) -join ', ') + ')')
[void]$sb.AppendLine("    FillTodayAfter = $(Q $fillToday)   # '' = nunca")
[void]$sb.AppendLine('    FillReports    = ' + $(if ($fillReports) { '$true' } else { '$false' }))
[void]$sb.AppendLine("    Rating         = $(Q $rating)   # 'auto' = la valoracion mas alta")
[void]$sb.AppendLine('    MaxPerRun      = 60')
[void]$sb.AppendLine("    Notify         = 'changes'")
[void]$sb.AppendLine('    UiCloseSeconds      = 6')
[void]$sb.AppendLine('    UiErrorCloseSeconds = 60')
[void]$sb.AppendLine('}')

if (Test-Path $ConfigPath) { Copy-Item $ConfigPath "$ConfigPath.bak" -Force }
[IO.File]::WriteAllText($ConfigPath, $sb.ToString(), (New-Object Text.UTF8Encoding($true)))
Good "Guardado: $ConfigPath"

# ---- simulacion e instalacion
$daily = Join-Path $ScriptDir 'sbid-daily.ps1'
Title 'Ultimos pasos'
if (AskYN 'Quieres ver una SIMULACION ahora (entra en sBID pero no guarda nada)' $true) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $daily -DryRun -ConfigPath $ConfigPath -BaseUrl $BaseUrl
}
if (AskYN 'Instalar el arranque automatico con Windows ahora' $true) {
    if ($showPanel) { & powershell -NoProfile -ExecutionPolicy Bypass -File $daily -Install -ConfigPath $ConfigPath }
    else { & powershell -NoProfile -ExecutionPolicy Bypass -File $daily -Install -Hidden -ConfigPath $ConfigPath }
} else {
    Info 'Cuando quieras: 2-instalar.bat (o quitar.bat para desinstalar).'
}
Write-Host ''
Good 'Listo. Si cambia tu plan de actividades, vuelve a ejecutar 0-configurar.bat.'

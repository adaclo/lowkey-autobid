# sbid-lib.ps1 - cliente de sBID compartido por sbid-daily.ps1 y setup.ps1 (se carga con punto: . .sbid-lib.ps1).
# Necesita definidos antes: $Origin, $Mod, $UA, $cfg (Username/Password) y la funcion Log.

Add-Type -AssemblyName System.Net.Http
$script:Cookies = [ordered]@{}   # cookies a mano: asi se ven todas las respuestas, tambien las de redireccion
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.AllowAutoRedirect = $false
$handler.UseCookies = $false
$handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
$script:Client = New-Object System.Net.Http.HttpClient($handler)
$script:Client.Timeout = [TimeSpan]::FromSeconds(60)

# ---------------------------------------------------------------- HTTP
$script:Referer = "$Origin/sBid/"
$script:LastResp = $null

function Http([string]$url, [string]$body) {
    $method = 'GET'; $send = $null
    if ($PSBoundParameters.ContainsKey('body') -and $null -ne $body) { $method = 'POST'; $send = $body }
    for ($hop = 0; $hop -lt 8; $hop++) {
        $req = New-Object System.Net.Http.HttpRequestMessage -ArgumentList (New-Object System.Net.Http.HttpMethod $method), $url
        [void]$req.Headers.TryAddWithoutValidation('User-Agent', $UA)
        [void]$req.Headers.TryAddWithoutValidation('Accept', 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8')
        [void]$req.Headers.TryAddWithoutValidation('Accept-Language', 'ca,es;q=0.9,en;q=0.8')
        [void]$req.Headers.TryAddWithoutValidation('Referer', $script:Referer)
        if ($script:Cookies.Count -gt 0) {
            [void]$req.Headers.TryAddWithoutValidation('Cookie', (($script:Cookies.Keys | ForEach-Object { $_ + '=' + $script:Cookies[$_] }) -join '; '))
        }
        if ($method -eq 'POST') {
            [void]$req.Headers.TryAddWithoutValidation('Origin', $Origin)
            $req.Content = New-Object System.Net.Http.StringContent -ArgumentList $send, ([Text.Encoding]::UTF8)
            $req.Content.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue 'application/x-www-form-urlencoded'
        }
        $resp = $script:Client.SendAsync($req).GetAwaiter().GetResult()
        $status = [int]$resp.StatusCode

        $vals = $null
        $setck = ''
        if ($resp.Headers.TryGetValues('Set-Cookie', [ref]$vals)) {
            foreach ($sc in $vals) {
                $first = ($sc -split ';')[0]
                $i = $first.IndexOf('=')
                if ($i -gt 0) {
                    $name = $first.Substring(0, $i).Trim()
                    $val = $first.Substring($i + 1)
                    $dead = ($val -eq '') -or ($sc -match '(?i);\s*max-age=0') -or ($sc -match '(?i)expires=\w{3},\s*\d{2}[ -]\w{3}[ -](19[0-9]{2}|200[0-9])')
                    if ($dead) { $script:Cookies.Remove($name) } else { $script:Cookies[$name] = $val }
                    $mv = $val; if ($mv.Length -gt 3) { $mv = $mv.Substring(0, 3) + '..' }
                    $flag = ''; if ($dead) { $flag = ' (BORRADA)' }
                    $setck += " $name=$mv$flag;"
                }
            }
        }

        $loc = $null
        if ($status -ge 300 -and $status -lt 400 -and $resp.Headers.Location) { $loc = $resp.Headers.Location.ToString() }
        $bytes = $resp.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        $text = [Text.Encoding]::UTF8.GetString($bytes)
        $kind = 'otra'
        if ($text -match 'id="loginForm"') { $kind = 'LOGINFORM' } elseif ($text -match 'id="heading1"') { $kind = 'agenda' }
        $short = ([uri]$url).AbsolutePath -replace '^/sBid/', ''
        $cn = ($script:Cookies.Keys) -join '+'
        [void]$script:Trace.Add(('{0} {1} -> {2} {3}B {4} jar={5} set-cookie=[{6}]{7}' -f $method, $short, $status, $bytes.Length, $kind, $cn, $setck.Trim(), $(if ($loc) { " location=$loc" } else { '' })))
        $script:LastResp = [pscustomobject]@{ Uri = $url; Status = $status; Len = $bytes.Length }
        $resp.Dispose()

        if ($loc) {
            $url = (New-Object System.Uri (New-Object System.Uri $url), $loc).AbsoluteUri
            $method = 'GET'; $send = $null
            continue
        }
        if ($status -ge 400) { throw "HTTP $status en $short" }
        return $text
    }
    throw 'Demasiadas redirecciones'
}
$script:Trace = New-Object System.Collections.ArrayList

# Deja en el log lo necesario para entender por que sBID no reconoce la sesion (sin contrasenyas)
function Diag([string]$what, [string]$html) {
    try {
        $txt = ($html -replace '(?is)<script.*?</script>|<style.*?</style>|<[^>]+>', ' ') -replace '\s+', ' '
        if ($txt.Length -gt 120) { $txt = $txt.Substring(0, 120) }
        $lr = $script:LastResp
        Log ("Diagnostico ({0}): url={1} status={2} bytes={3} cookies=[{4}] texto='{5}'" -f $what, $lr.Uri, $lr.Status, $lr.Len, (($script:Cookies.Keys) -join '+'), $txt) 'warn'
        foreach ($t in $script:Trace) { Log ("  rastro: $t") 'warn' }
    } catch { }
}

function Enc($pairs) {
    return (($pairs.Keys | ForEach-Object { [uri]::EscapeDataString([string]$_) + '=' + [uri]::EscapeDataString([string]$pairs[$_]) }) -join '&')
}

function Login {
    $script:Referer = "$Origin/sBid/"
    [void](Http "$Mod/Login?initial=yes")
    $b = [ordered]@{ idTask = ''; hashTask = ''; moduleaction = 'doLogin'; fwBrowser = 'Chrome'; username = $cfg.Username; password = $cfg.Password }
    $script:Referer = "$Mod/Login?initial=yes"
    [void](Http "$Mod/Login" (Enc $b))
    $script:Referer = "$Origin/sBid/"
    $ag = Http "$Mod/Agenda?moduleaction=show&clearBackStack=true"
    if ($ag -notmatch 'id="heading1"' -or $ag -match 'id="loginForm"') {
        Diag 'login' $ag
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
    if ($h -match 'id="loginForm"') {
        Diag 'agenda' $h
        throw 'LOGIN: la sesion ha caducado.'
    }
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
    $any = $null
    $ma = [regex]::Match($h, 'href="([^"]*ActivitatFct?moduleaction=show[^"]*)"')
    if ($ma.Success) { $any = HtmlDec $ma.Groups[1].Value; if ($any.StartsWith('/')) { $any = $Origin + $any } }
    return [pscustomobject]@{ Items = $items; Count = $count; AnyDay = $any }
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


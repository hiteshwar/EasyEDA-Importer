<#
.SYNOPSIS
    EasyEDA / LCSC part fetcher + converter for the Altium "EasyEDA Importer" script.

.DESCRIPTION
    Downloads the symbol, footprint and 3D STEP model of an LCSC part from the
    public EasyEDA API and converts them into a simple, integer-only text file
    (<LCSC>.part.txt) that the Altium DelphiScript (EasyEDA_Importer.pas) turns
    into a SchLib symbol, a PcbLib footprint and a 3D body.

    Works with the PowerShell 5.1 that ships with Windows 10/11 - nothing to install.

    This file is a line-by-line port of ee_convert.py (the tested reference).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File ee_fetch.ps1 -Lcsc C2040
    powershell -NoProfile -ExecutionPolicy Bypass -File ee_fetch.ps1 -SelfTest
#>
[CmdletBinding()]
param(
    [string]$Lcsc = '',
    [string]$OutDir = '',
    [string]$InputJson = '',      # convert a saved API response instead of downloading
    [switch]$NoModel,             # skip 3D model download
    [switch]$SelfTest             # run the converter against tests\*.raweasy.json
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$Inv = [System.Globalization.CultureInfo]::InvariantCulture
$U = 1000.0   # cmil (1/100 mil) per EasyEDA unit (1 unit = 10 mil)

$LAYER_MAP = @{
    '1' = 'TOP'; '2' = 'BOTTOM'; '3' = 'TOPOVERLAY'; '4' = 'BOTTOMOVERLAY'
    '5' = 'TOPPASTE'; '6' = 'BOTTOMPASTE'; '7' = 'TOPSOLDER'; '8' = 'BOTTOMSOLDER'
    '10' = 'MECH1'; '11' = 'MULTI'; '12' = 'MECH15'; '13' = 'MECH13'; '14' = 'MECH14'
    '15' = 'MECH15'; '99' = 'MECH9'; '100' = 'MECH10'; '101' = 'MECH11'
}
$REGION_LAYERS = @('1', '2', '3', '4')
# EasyEDA pin type -> Altium TPinElectrical ordinal
$PIN_ELEC = @{ '0' = 4; '1' = 0; '2' = 2; '3' = 1; '4' = 7 }

$script:Out = New-Object 'System.Collections.Generic.List[string]'

# ---------------------------------------------------------------- helpers ---
function ToNum([object]$s, [double]$default = 0.0) {
    if ($null -eq $s) { return $default }
    if ($s -is [double] -or $s -is [int] -or $s -is [decimal] -or $s -is [long]) { return [double]$s }
    $v = 0.0
    if ([double]::TryParse(([string]$s).Trim(), [System.Globalization.NumberStyles]::Float, $Inv, [ref]$v)) {
        if ([double]::IsNaN($v)) { return $default }
        return $v
    }
    return $default
}
function RoundI([double]$v) { return ([long][math]::Floor($v + 0.5)).ToString($Inv) }
function Clean([object]$s) {
    if ($null -eq $s) { return '' }
    return ([string]$s).Replace("`t", ' ').Replace("`r", ' ').Replace("`n", ' ').Trim()
}
function GetAt($arr, [int]$i, [string]$default = '') {
    if ($null -ne $arr -and $i -lt $arr.Length) { return [string]$arr[$i] }
    return $default
}
function IsShown([string]$s) {
    $t = ''
    if ($null -ne $s) { $t = $s.Trim().ToLowerInvariant() }
    if ($t -eq '0' -or $t -eq 'false' -or $t -eq 'hide' -or $t -eq 'none') { return 0 }
    return 1
}
function JGet($d, [string]$key) {
    # JavaScriptSerializer returns Dictionary[string,object]; its IDictionary.Contains is an
    # explicit interface method that PowerShell 5.1 cannot call, so use ContainsKey instead.
    if ($null -ne $d -and $d -is [System.Collections.IDictionary] -and $d.ContainsKey($key)) { return $d[$key] }
    return $null
}
# EasyEDA internal c_para fields that are not useful as Altium parameters
$PARAM_SKIP = @('PRE', 'NAME', 'NAMEALIAS', 'PACKAGE', 'CONTRIBUTOR', 'SPICEPRE', 'SPICESYMBOLNAME', 'TIMESTAMP', 'LINK')
# Parameter-name key: upper case, letters and digits only
function NormKey([object]$k) { return [regex]::Replace(([string]$k).ToUpperInvariant(), '[^A-Z0-9]', '') }

# EasyEDA sometimes sends nested objects as JSON text instead of objects
function AsDict($v) {
    if ($null -eq $v) { return @{} }
    if ($v -is [System.Collections.IDictionary]) { return $v }
    if ($v -is [string] -and $v.Trim().StartsWith('{')) {
        try { $d = ParseJson $v; if ($d -is [System.Collections.IDictionary]) { return $d } } catch { }
    }
    return @{}
}
function OrElse($a, $b) {
    if ($null -eq $a -or [string]::IsNullOrEmpty([string]$a)) { return $b }
    return $a
}
function Mod360([double]$a) { $m = $a % 360.0; if ($m -lt 0) { $m += 360.0 }; return $m }
function IsNone([string]$s) { $t = $s.ToLowerInvariant(); return ($t -eq 'none' -or $t -eq '') }
function Emit([string[]]$rec) { $script:Out.Add(($rec -join "`t")) }
function Deg([double]$r) { return $r * (180.0 / [math]::PI) }
function Rad([double]$d) { return $d * ([math]::PI / 180.0) }

function New-Json {
    Add-Type -AssemblyName System.Web.Extensions
    $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
    $js.MaxJsonLength = [int]::MaxValue
    $js.RecursionLimit = 1000
    return $js
}
$script:Json = $null
function ParseJson([string]$text) {
    if ($null -eq $script:Json) { $script:Json = New-Json }
    return $script:Json.DeserializeObject($text)
}

# --------------------------------------------------------------- geometry ---
# SVG endpoint -> centre parameterisation (circular arcs, x-rotation 0)
function SvgArcCenter([double]$x1, [double]$y1, [double]$rx, [double]$ry, [int]$large, [int]$sweep, [double]$x2, [double]$y2) {
    if ($rx -eq 0 -or $ry -eq 0) { return $null }
    $r = [math]::Abs($rx)
    $dx2 = ($x1 - $x2) / 2.0
    $dy2 = ($y1 - $y2) / 2.0
    $d2 = $dx2 * $dx2 + $dy2 * $dy2
    if ($d2 -eq 0) { return $null }
    if ($d2 -gt $r * $r) { $r = [math]::Sqrt($d2) }
    $sign = 1.0
    if ($large -eq $sweep) { $sign = -1.0 }
    $sq = ($r * $r - $d2) / $d2
    $coef = $sign * [math]::Sqrt([math]::Max($sq, 0.0))
    $cx = $coef * $dy2 + ($x1 + $x2) / 2.0
    $cy = - $coef * $dx2 + ($y1 + $y2) / 2.0
    return , @($cx, $cy, $r)
}

# returns @(cx, cy, r, aStart, aEnd) in EasyEDA units (centre) and Altium Y-up angles
function ArcRecord([double]$sx, [double]$sy, [double]$ex, [double]$ey, [double]$rx, [double]$ry, [int]$large, [int]$sweep) {
    $c = SvgArcCenter $sx $sy $rx $ry $large $sweep $ex $ey
    if ($null -eq $c) { return $null }
    $cx = $c[0]; $cy = $c[1]; $r = $c[2]
    $a1 = Mod360 (Deg ([math]::Atan2( - ($sy - $cy), $sx - $cx)))
    $a2 = Mod360 (Deg ([math]::Atan2( - ($ey - $cy), $ex - $cx)))
    if ($sweep -ne 0) { return , @($cx, $cy, $r, $a2, $a1) }
    return , @($cx, $cy, $r, $a1, $a2)
}

function TokenizePath([string]$path) {
    $list = New-Object 'System.Collections.Generic.List[string]'
    if ([string]::IsNullOrEmpty($path)) { return , $list.ToArray() }
    foreach ($m in [regex]::Matches($path, '[MmLlHhVvAaZzCcQqSsTt]|-?\d*\.?\d+(?:[eE][-+]?\d+)?')) { $list.Add($m.Value) }
    return , $list.ToArray()
}

# Small SVG path interpreter. Returns list of @{Pts = List[double[]]; Closed = bool}
function PathToPolylines([string]$path) {
    $toks = TokenizePath $path
    $out = New-Object 'System.Collections.Generic.List[object]'
    $pts = New-Object 'System.Collections.Generic.List[double[]]'
    $cx = 0.0; $cy = 0.0; $sx0 = 0.0; $sy0 = 0.0
    $i = 0; $cmd = $null
    $n = $toks.Length
    while ($i -lt $n) {
        $t = $toks[$i]
        if ($t -cmatch '^[A-Za-z]$') {
            $cmd = $t; $i++
            if ($cmd -ceq 'Z' -or $cmd -ceq 'z') {
                if ($pts.Count -gt 0) { $out.Add(@{ Pts = $pts; Closed = $true }) }
                $pts = New-Object 'System.Collections.Generic.List[double[]]'
                $cx = $sx0; $cy = $sy0
                continue
            }
        }
        if ($null -eq $cmd) { $i++; continue }
        $rel = ($cmd -cmatch '^[a-z]$')
        $uc = $cmd.ToUpperInvariant()
        $need = @{ 'M' = 2; 'L' = 2; 'H' = 1; 'V' = 1; 'A' = 7; 'C' = 6; 'Q' = 4; 'S' = 4; 'T' = 2 }[$uc]
        if ($null -eq $need) { $i++; continue }
        if ($i + $need -gt $n) { break }
        $vals = New-Object 'double[]' $need
        $bad = $false
        for ($k = 0; $k -lt $need; $k++) {
            $tok = $toks[$i + $k]
            if ($tok -cmatch '^[A-Za-z]$') { $bad = $true; break }
            $vals[$k] = ToNum $tok
        }
        if ($bad) { break }
        $i += $need
        switch ($uc) {
            'M' {
                $x = $vals[0]; $y = $vals[1]
                if ($rel) { $x += $cx; $y += $cy }
                if ($pts.Count -gt 1) { $out.Add(@{ Pts = $pts; Closed = $false }) }
                $pts = New-Object 'System.Collections.Generic.List[double[]]'
                $pts.Add([double[]]@($x, $y))
                $cx = $x; $cy = $y; $sx0 = $x; $sy0 = $y
                if ($rel) { $cmd = 'l' } else { $cmd = 'L' }
            }
            'L' {
                $x = $vals[0]; $y = $vals[1]
                if ($rel) { $x += $cx; $y += $cy }
                $pts.Add([double[]]@($x, $y)); $cx = $x; $cy = $y
            }
            'H' {
                $x = $vals[0]; if ($rel) { $x += $cx }
                $pts.Add([double[]]@($x, $cy)); $cx = $x
            }
            'V' {
                $y = $vals[0]; if ($rel) { $y += $cy }
                $pts.Add([double[]]@($cx, $y)); $cy = $y
            }
            'A' {
                $rx = $vals[0]; $ry = $vals[1]
                $la = [int][math]::Truncate($vals[3]); $sw = [int][math]::Truncate($vals[4])
                $x = $vals[5]; $y = $vals[6]
                if ($rel) { $x += $cx; $y += $cy }
                $c = SvgArcCenter $cx $cy $rx $ry $la $sw $x $y
                if ($null -ne $c) {
                    $ccx = $c[0]; $ccy = $c[1]; $r = $c[2]
                    $a1 = [math]::Atan2($cy - $ccy, $cx - $ccx)
                    $a2 = [math]::Atan2($y - $ccy, $x - $ccx)
                    $da = $a2 - $a1
                    if ($sw -ne 0) { while ($da -le 0) { $da += 2 * [math]::PI } }
                    else { while ($da -ge 0) { $da -= 2 * [math]::PI } }
                    $segs = [math]::Max(2, [int][math]::Truncate([math]::Abs($da) / (2 * [math]::PI) * 36))
                    for ($k = 1; $k -le $segs; $k++) {
                        $a = $a1 + $da * $k / $segs
                        $pts.Add([double[]]@(($ccx + $r * [math]::Cos($a)), ($ccy + $r * [math]::Sin($a))))
                    }
                } else {
                    $pts.Add([double[]]@($x, $y))
                }
                $cx = $x; $cy = $y
            }
            'C' {
                $x = $vals[4]; $y = $vals[5]
                if ($rel) { $x += $cx; $y += $cy }
                $pts.Add([double[]]@($x, $y)); $cx = $x; $cy = $y
            }
            { $_ -eq 'Q' -or $_ -eq 'S' } {
                $x = $vals[2]; $y = $vals[3]
                if ($rel) { $x += $cx; $y += $cy }
                $pts.Add([double[]]@($x, $y)); $cx = $x; $cy = $y
            }
            'T' {
                $x = $vals[0]; $y = $vals[1]
                if ($rel) { $x += $cx; $y += $cy }
                $pts.Add([double[]]@($x, $y)); $cx = $x; $cy = $y
            }
        }
    }
    if ($pts.Count -gt 1) { $out.Add(@{ Pts = $pts; Closed = $false }) }
    return , $out
}

function ParsePoints([string]$s) {
    $res = New-Object 'System.Collections.Generic.List[double[]]'
    if ([string]::IsNullOrEmpty($s)) { return , $res }
    $parts = $s.Replace(',', ' ').Split([char[]]@(' ', "`t", "`r", "`n", "`f", "`v"), [System.StringSplitOptions]::RemoveEmptyEntries)
    for ($k = 0; $k + 1 -lt $parts.Length; $k += 2) {
        $res.Add([double[]]@((ToNum $parts[$k]), (ToNum $parts[$k + 1])))
    }
    return , $res
}

# Returns index of first token matching any of $names, or -1
function IndexOfTok($toks, [string[]]$names) {
    for ($k = 0; $k -lt $toks.Length; $k++) { foreach ($nm in $names) { if ($toks[$k] -ceq $nm) { return $k } } }
    return -1
}

# Parses "M sx sy A rx ry rot la sw ex ey" -> @(sx,sy,ex,ey,rx,ry,la,sw) or $null
function ParseArcPath([string]$path, [switch]$UpperFirst) {
    $toks = TokenizePath $path
    if ($UpperFirst) {
        $mi = IndexOfTok $toks @('M'); if ($mi -lt 0) { $mi = IndexOfTok $toks @('m') }
        $ai = IndexOfTok $toks @('A'); if ($ai -lt 0) { $ai = IndexOfTok $toks @('a') }
    } else {
        $mi = IndexOfTok $toks @('M', 'm')
        $ai = IndexOfTok $toks @('A', 'a')
    }
    if ($mi -lt 0 -or $ai -lt 0 -or $ai + 7 -ge $toks.Length -or $mi + 2 -ge $toks.Length) { return $null }
    foreach ($q in @(($mi + 1), ($mi + 2), ($ai + 1), ($ai + 2), ($ai + 4), ($ai + 5), ($ai + 6), ($ai + 7))) {
        if ($toks[$q] -cmatch '^[A-Za-z]$') { return $null }
    }
    $sx = ToNum $toks[$mi + 1]; $sy = ToNum $toks[$mi + 2]
    $rx = ToNum $toks[$ai + 1]; $ry = ToNum $toks[$ai + 2]
    $la = [int][math]::Truncate((ToNum $toks[$ai + 4])); $sw = [int][math]::Truncate((ToNum $toks[$ai + 5]))
    $ex = ToNum $toks[$ai + 6]; $ey = ToNum $toks[$ai + 7]
    if ($toks[$ai] -ceq 'a') { $ex += $sx; $ey += $sy }
    return , @($sx, $sy, $ex, $ey, $rx, $ry, $la, $sw)
}

# ----------------------------------------------------------------- symbol ---
# Origin (EasyEDA units) chosen so the first pin's hot-spot lands on a 100 mil grid
function Get-SymbolOrigin($ds) {
    $head = JGet $ds 'head'
    $hx = ToNum (JGet $head 'x'); $hy = ToNum (JGet $head 'y')
    $sh = JGet $ds 'shape'
    if ($null -ne $sh) {
        foreach ($s in $sh) {
            if ($s -and ([string]$s).StartsWith('P~')) {
                $p0 = ([string]$s).Split([string[]]@('^^'), [System.StringSplitOptions]::None)[0].Split('~')
                $px = ToNum (GetAt $p0 4); $py = ToNum (GetAt $p0 5)
                return , @(($px - 10.0 * [math]::Floor(($px - $hx) / 10.0 + 0.5)), ($py - 10.0 * [math]::Floor(($py - $hy) / 10.0 + 0.5)))
            }
        }
    }
    return , @($hx, $hy)
}

function Convert-Symbol($ds, $origin) {
    $shapes = @()
    $sh = JGet $ds 'shape'
    if ($null -ne $sh) { $shapes = @($sh | Where-Object { $_ }) }
    if ($null -eq $origin) { $origin = Get-SymbolOrigin $ds }
    $ox = [double]$origin[0]; $oy = [double]$origin[1]
    $ToX = { param($v) ($v - $ox) * $U }
    $ToY = { param($v) - ($v - $oy) * $U }

    foreach ($s0 in $shapes) {
        $s = [string]$s0
        $kind = $s.Split('~')[0]
        switch -CaseSensitive ($kind) {
            'P' {
                $segStr = $s.Split([string[]]@('^^'), [System.StringSplitOptions]::None)
                $seg = @(); foreach ($sp in $segStr) { $seg += , ($sp.Split('~')) }
                $st = $seg[0]
                $hotX = ToNum (GetAt $st 4); $hotY = ToNum (GetAt $st 5)
                $elec = 4
                $et = GetAt $st 2 '0'
                if ($PIN_ELEC.ContainsKey($et)) { $elec = $PIN_ELEC[$et] }
                $path = ''
                if ($seg.Length -gt 2) { $path = GetAt $seg[2] 0 }
                $polys = PathToPolylines $path
                $length = 10.0
                $dx = -1.0; $dy = 0.0
                if ($polys.Count -gt 0 -and $polys[0].Pts.Count -ge 2) {
                    $pa = $polys[0].Pts[0]; $pb = $polys[0].Pts[$polys[0].Pts.Count - 1]
                    $da = [math]::Sqrt(($pa[0] - $hotX) * ($pa[0] - $hotX) + ($pa[1] - $hotY) * ($pa[1] - $hotY))
                    $db = [math]::Sqrt(($pb[0] - $hotX) * ($pb[0] - $hotX) + ($pb[1] - $hotY) * ($pb[1] - $hotY))
                    if ($da -le $db) { $dx = $pb[0] - $pa[0]; $dy = $pb[1] - $pa[1] }
                    else { $dx = $pa[0] - $pb[0]; $dy = $pa[1] - $pb[1] }
                    $length = [math]::Sqrt($dx * $dx + $dy * $dy)
                } else {
                    $rot = [int](((([int][math]::Truncate((ToNum (GetAt $st 6)))) % 360) + 360) % 360)
                    switch ($rot) {
                        0 { $dx = -1.0; $dy = 0.0 }
                        90 { $dx = 0.0; $dy = 1.0 }
                        180 { $dx = 1.0; $dy = 0.0 }
                        270 { $dx = 0.0; $dy = -1.0 }
                        default { $dx = 1.0; $dy = 0.0 }
                    }
                }
                if ([math]::Abs($dx) -ge [math]::Abs($dy)) {
                    if ($dx -gt 0) { $orient = 180 } else { $orient = 0 }
                } else {
                    if ($dy -gt 0) { $orient = 90 } else { $orient = 270 }
                }
                if ($length -le 0) { $length = 10.0 }
                switch ($orient) {
                    0 { $bx = $hotX - $length; $by = $hotY }
                    180 { $bx = $hotX + $length; $by = $hotY }
                    90 { $bx = $hotX; $by = $hotY + $length }
                    default { $bx = $hotX; $by = $hotY - $length }
                }
                $nameSeg = @(); $numSeg = @(); $dotSeg = @(); $clkSeg = @()
                if ($seg.Length -gt 3) { $nameSeg = $seg[3] }
                if ($seg.Length -gt 4) { $numSeg = $seg[4] }
                if ($seg.Length -gt 5) { $dotSeg = $seg[5] }
                if ($seg.Length -gt 6) { $clkSeg = $seg[6] }
                $name = GetAt $nameSeg 4
                $des = OrElse (GetAt $numSeg 4) (GetAt $st 3)
                $showName = 1; if ($nameSeg.Length -gt 0) { $showName = IsShown (GetAt $nameSeg 0 '1') }
                $showDes = 1; if ($numSeg.Length -gt 0) { $showDes = IsShown (GetAt $numSeg 0 '1') }
                $dot = 0; if ($dotSeg.Length -gt 0) { $dot = IsShown (GetAt $dotSeg 0 '0') }
                $clk = 0; if ($clkSeg.Length -gt 0) { $clk = IsShown (GetAt $clkSeg 0 '0') }
                Emit @('SPIN', (RoundI (& $ToX $bx)), (RoundI (& $ToY $by)), (RoundI ($length * $U)), [string]$orient,
                    [string]$elec, [string]$showName, [string]$showDes, [string]$dot, [string]$clk,
                    (Clean $des), (Clean $name))
            }
            'R' {
                $p = $s.Split('~')
                $x = ToNum (GetAt $p 1); $y = ToNum (GetAt $p 2); $rx = ToNum (GetAt $p 3); $ry = ToNum (GetAt $p 4)
                $w = ToNum (GetAt $p 5); $h = ToNum (GetAt $p 6)
                $fill = 1; if (IsNone (GetAt $p 10 'none')) { $fill = 0 }
                Emit @('SRECT', (RoundI (& $ToX $x)), (RoundI (& $ToY ($y + $h))), (RoundI (& $ToX ($x + $w))), (RoundI (& $ToY $y)), [string]$fill,
                    (RoundI ($rx * $U)), (RoundI ($ry * $U)))
            }
            'E' {
                $p = $s.Split('~')
                $cx = ToNum (GetAt $p 1); $cy = ToNum (GetAt $p 2); $rx = ToNum (GetAt $p 3); $ry = ToNum (GetAt $p 4)
                $fill = 1; if (IsNone (GetAt $p 8 'none')) { $fill = 0 }
                Emit @('SELLIPSE', (RoundI (& $ToX $cx)), (RoundI (& $ToY $cy)), (RoundI ($rx * $U)), (RoundI ($ry * $U)), [string]$fill)
            }
            'C' {
                $p = $s.Split('~')
                $cx = ToNum (GetAt $p 1); $cy = ToNum (GetAt $p 2); $r = ToNum (GetAt $p 3)
                $fill = 1; if (IsNone (GetAt $p 7 'none')) { $fill = 0 }
                Emit @('SELLIPSE', (RoundI (& $ToX $cx)), (RoundI (& $ToY $cy)), (RoundI ($r * $U)), (RoundI ($r * $U)), [string]$fill)
            }
            'A' {
                $p = $s.Split('~')
                $a = ParseArcPath (GetAt $p 1) -UpperFirst
                if ($null -ne $a) {
                    $rec = ArcRecord $a[0] $a[1] $a[2] $a[3] $a[4] $a[5] $a[6] $a[7]
                    if ($null -ne $rec) {
                        Emit @('SARC', (RoundI (& $ToX $rec[0])), (RoundI (& $ToY $rec[1])), (RoundI ($rec[2] * $U)), (RoundI ($rec[3] * 1000)), (RoundI ($rec[4] * 1000)))
                    }
                }
            }
            { $_ -ceq 'PL' -or $_ -ceq 'PG' } {
                $p = $s.Split('~')
                $pts = ParsePoints (GetAt $p 1)
                if ($pts.Count -ge 2) {
                    $fill = 0
                    if ($kind -ceq 'PG') { $fill = 1; if (IsNone (GetAt $p 5 'none')) { $fill = 0 } }
                    $closed = '0'; if ($kind -ceq 'PG') { $closed = '1' }
                    $rec = New-Object 'System.Collections.Generic.List[string]'
                    $rec.Add('SPOLY'); $rec.Add($closed); $rec.Add([string]$fill); $rec.Add([string]$pts.Count)
                    foreach ($pt in $pts) { $rec.Add((RoundI (& $ToX $pt[0]))); $rec.Add((RoundI (& $ToY $pt[1]))) }
                    Emit $rec.ToArray()
                }
            }
            'PT' {
                $p = $s.Split('~')
                $fill = 1; if (IsNone (GetAt $p 5 'none')) { $fill = 0 }
                foreach ($pl in (PathToPolylines (GetAt $p 1))) {
                    if ($pl.Pts.Count -ge 2) {
                        $closed = '0'; $f2 = '0'
                        if ($pl.Closed) { $closed = '1'; $f2 = [string]$fill }
                        $rec = New-Object 'System.Collections.Generic.List[string]'
                        $rec.Add('SPOLY'); $rec.Add($closed); $rec.Add($f2); $rec.Add([string]$pl.Pts.Count)
                        foreach ($pt in $pl.Pts) { $rec.Add((RoundI (& $ToX $pt[0]))); $rec.Add((RoundI (& $ToY $pt[1]))) }
                        Emit $rec.ToArray()
                    }
                }
            }
            'T' {
                $p = $s.Split('~')
                $txt = GetAt $p 12
                if ($txt -and (IsShown (GetAt $p 13 '1'))) {
                    $sz = [regex]::Replace((GetAt $p 7), '[^0-9.]', '')
                    if ([string]::IsNullOrEmpty($sz)) { $sz = '7' }
                    $sizePt = ToNum $sz 7.0
                    Emit @('STEXT', (RoundI (& $ToX (ToNum (GetAt $p 2)))), (RoundI (& $ToY (ToNum (GetAt $p 3)))),
                        (RoundI ((Mod360 (360 - (ToNum (GetAt $p 4)))) * 1000)), (RoundI $sizePt), (Clean $txt))
                }
            }
        }
    }
}

# -------------------------------------------------------------- footprint ---
# Returns model info hashtable (mm, Altium frame) or $null
function Convert-Footprint($ds) {
    $head = JGet $ds 'head'
    $canvas = ([string](OrElse (JGet $ds 'canvas') '')).Split('~')
    if ($canvas.Length -gt 17 -and $canvas[16] -ne '' -and $canvas[17] -ne '') {
        $ox = ToNum $canvas[16]; $oy = ToNum $canvas[17]
    } else {
        $ox = ToNum (JGet $head 'x'); $oy = ToNum (JGet $head 'y')
    }
    $ToX = { param($v) ($v - $ox) * $U }
    $ToY = { param($v) - ($v - $oy) * $U }
    $model = $null

    $sh = JGet $ds 'shape'
    if ($null -eq $sh) {
        Emit @('WARN', 'EasyEDA returned no footprint shapes for this part')
        return $null
    }
    foreach ($s0 in $sh) {
        if (-not $s0) { continue }
        $s = [string]$s0
        $p = $s.Split('~')
        $kind = $p[0]
        switch -CaseSensitive ($kind) {
            'PAD' {
                $shape = GetAt $p 1
                $cx = ToNum (GetAt $p 2); $cy = ToNum (GetAt $p 3); $w = ToNum (GetAt $p 4); $h = ToNum (GetAt $p 5)
                $layer = GetAt $p 6
                $number = GetAt $p 8
                $holeR = ToNum (GetAt $p 9)
                $pts = ParsePoints (GetAt $p 10)
                $rot = Mod360 (ToNum (GetAt $p 11))
                $holeLen = ToNum (GetAt $p 13)
                $plated = 1
                if ((GetAt $p 15 'Y').Trim().ToUpperInvariant().StartsWith('N')) { $plated = 0 }
                $lay = 'MULTI'
                if ($layer -ceq '1') { $lay = 'TOP' } elseif ($layer -ceq '2') { $lay = 'BOTTOM' }
                if ($holeR -gt 0) { $lay = 'MULTI' }
                if ($shape -ceq 'RECT') { $ashape = 'RECT' }
                elseif ($shape -ceq 'OVAL' -or $shape -ceq 'ELLIPSE') { $ashape = 'ROUND' }
                elseif ($shape -ceq 'POLYGON' -and $pts.Count -ge 3) {
                    $a = Rad $rot
                    $minX = [double]::MaxValue; $maxX = - [double]::MaxValue; $minY = [double]::MaxValue; $maxY = - [double]::MaxValue
                    foreach ($pt in $pts) {
                        $ddx = $pt[0] - $cx; $ddy = - ($pt[1] - $cy)
                        $lx = $ddx * [math]::Cos(-$a) - $ddy * [math]::Sin(-$a)
                        $ly = $ddx * [math]::Sin(-$a) + $ddy * [math]::Cos(-$a)
                        if ($lx -lt $minX) { $minX = $lx }; if ($lx -gt $maxX) { $maxX = $lx }
                        if ($ly -lt $minY) { $minY = $ly }; if ($ly -gt $maxY) { $maxY = $ly }
                    }
                    $w = $maxX - $minX; $h = $maxY - $minY
                    $mx = ($maxX + $minX) / 2.0; $my = ($maxY + $minY) / 2.0
                    $cx += $mx * [math]::Cos($a) - $my * [math]::Sin($a)
                    $cy -= $mx * [math]::Sin($a) + $my * [math]::Cos($a)
                    $ashape = 'RECT'
                    Emit @('WARN', ('Pad {0} is a custom polygon; approximated by a {1} x {2} mil rectangle' -f (Clean $number), (RoundI ($w * 10)), (RoundI ($h * 10))))
                }
                else { $ashape = 'ROUND' }
                $holeD = $holeR * 2.0
                $slotLen = 0.0; $holeRot = 0
                if ($holeR -gt 0 -and $holeLen -gt 0 -and $holeLen -gt $holeD + 1e-6) {
                    $slotLen = $holeLen
                    if ($h -gt $w) { $holeRot = 90 }
                }
                Emit @('FPAD', (Clean $number), $ashape, (RoundI (& $ToX $cx)), (RoundI (& $ToY $cy)), (RoundI ($w * $U)), (RoundI ($h * $U)),
                    (RoundI ($rot * 1000)), $lay, (RoundI ($holeD * $U)), (RoundI ($slotLen * $U)), [string]($holeRot * 1000), [string]$plated)
            }
            'TRACK' {
                $width = ToNum (GetAt $p 1); $layer = GetAt $p 2
                if ($LAYER_MAP.ContainsKey($layer)) {
                    $al = $LAYER_MAP[$layer]
                    $pts = ParsePoints (GetAt $p 4)
                    for ($k = 0; $k -lt $pts.Count - 1; $k++) {
                        $a = $pts[$k]; $b = $pts[$k + 1]
                        Emit @('FTRACK', $al, (RoundI (& $ToX $a[0])), (RoundI (& $ToY $a[1])), (RoundI (& $ToX $b[0])), (RoundI (& $ToY $b[1])), (RoundI ($width * $U)))
                    }
                }
            }
            'RECT' {
                $x = ToNum (GetAt $p 1); $y = ToNum (GetAt $p 2); $w = ToNum (GetAt $p 3); $h = ToNum (GetAt $p 4)
                $layer = GetAt $p 5
                $sw = ToNum (GetAt $p 8) 0.0
                if ($sw -eq 0) { $sw = 0.6 }
                if ($LAYER_MAP.ContainsKey($layer)) {
                    $al = $LAYER_MAP[$layer]
                    $c = @(@($x, $y), @(($x + $w), $y), @(($x + $w), ($y + $h)), @($x, ($y + $h)), @($x, $y))
                    for ($k = 0; $k -lt 4; $k++) {
                        Emit @('FTRACK', $al, (RoundI (& $ToX $c[$k][0])), (RoundI (& $ToY $c[$k][1])), (RoundI (& $ToX $c[$k + 1][0])), (RoundI (& $ToY $c[$k + 1][1])), (RoundI ($sw * $U)))
                    }
                }
            }
            'CIRCLE' {
                $cx = ToNum (GetAt $p 1); $cy = ToNum (GetAt $p 2); $r = ToNum (GetAt $p 3); $width = ToNum (GetAt $p 4)
                $layer = GetAt $p 5
                if ($LAYER_MAP.ContainsKey($layer) -and $r -gt 0) {
                    Emit @('FARC', $LAYER_MAP[$layer], (RoundI (& $ToX $cx)), (RoundI (& $ToY $cy)), (RoundI ($r * $U)), '0', '360000', (RoundI ($width * $U)))
                }
            }
            'ARC' {
                $width = ToNum (GetAt $p 1); $layer = GetAt $p 2
                if ($LAYER_MAP.ContainsKey($layer)) {
                    $a = ParseArcPath (GetAt $p 4)
                    if ($null -ne $a) {
                        $rec = ArcRecord $a[0] $a[1] $a[2] $a[3] $a[4] $a[5] $a[6] $a[7]
                        if ($null -ne $rec) {
                            Emit @('FARC', $LAYER_MAP[$layer], (RoundI (& $ToX $rec[0])), (RoundI (& $ToY $rec[1])), (RoundI ($rec[2] * $U)),
                                (RoundI ($rec[3] * 1000)), (RoundI ($rec[4] * 1000)), (RoundI ($width * $U)))
                        }
                    }
                }
            }
            'HOLE' {
                $cx = ToNum (GetAt $p 1); $cy = ToNum (GetAt $p 2); $r = ToNum (GetAt $p 3)
                Emit @('FHOLE', (RoundI (& $ToX $cx)), (RoundI (& $ToY $cy)), (RoundI (2 * $r * $U)))
            }
            'VIA' {
                $cx = ToNum (GetAt $p 1); $cy = ToNum (GetAt $p 2); $dia = ToNum (GetAt $p 3); $hr = ToNum (GetAt $p 5)
                Emit @('FVIA', (RoundI (& $ToX $cx)), (RoundI (& $ToY $cy)), (RoundI ($dia * $U)), (RoundI (2 * $hr * $U)))
            }
            'SOLIDREGION' {
                $layer = GetAt $p 1; $path = GetAt $p 3; $rtype = GetAt $p 4
                if (($REGION_LAYERS -ccontains $layer) -and ($rtype -ceq 'solid' -or $rtype -eq '')) {
                    $al = $LAYER_MAP[$layer]
                    foreach ($pl in (PathToPolylines $path)) {
                        if ($pl.Pts.Count -ge 3) {
                            $rec = New-Object 'System.Collections.Generic.List[string]'
                            $rec.Add('FREGION'); $rec.Add($al); $rec.Add([string]$pl.Pts.Count)
                            foreach ($pt in $pl.Pts) { $rec.Add((RoundI (& $ToX $pt[0]))); $rec.Add((RoundI (& $ToY $pt[1]))) }
                            Emit $rec.ToArray()
                        }
                    }
                }
            }
            'SVGNODE' {
                try { $node = ParseJson ($s.Substring(8)) } catch { continue }
                $attrs = JGet $node 'attrs'
                if ([string](JGet $attrs 'c_etype') -cne 'outline3D' -or -not (JGet $attrs 'uuid') -or $null -ne $model) { continue }
                $co = ([string](OrElse (JGet $attrs 'c_origin') '0,0')).Split(',')
                $tx = ((ToNum (GetAt $co 0)) - $ox) * 0.254
                $ty = - ((ToNum (GetAt $co 1)) - $oy) * 0.254
                $tz = (ToNum (JGet $attrs 'z')) * 0.254
                $minX = [double]::MaxValue; $maxX = - [double]::MaxValue; $minY = [double]::MaxValue; $maxY = - [double]::MaxValue
                $any = $false
                $children = JGet $node 'childNodes'
                if ($null -ne $children) {
                    foreach ($ch in $children) {
                        foreach ($pt in (ParsePoints ([string](JGet (JGet $ch 'attrs') 'points')))) {
                            $px = ($pt[0] - $ox) * 0.254; $py = - ($pt[1] - $oy) * 0.254
                            if ($px -lt $minX) { $minX = $px }; if ($px -gt $maxX) { $maxX = $px }
                            if ($py -lt $minY) { $minY = $py }; if ($py -gt $maxY) { $maxY = $py }
                            $any = $true
                        }
                    }
                }
                if ($any) {
                    $cxm = ($minX + $maxX) / 2.0; $cym = ($minY + $maxY) / 2.0
                    if ([math]::Abs($cxm - $tx) -gt 0.1 -or [math]::Abs($cym - $ty) -gt 0.1) { $tx = $cxm; $ty = $cym }
                }
                $rot = ([string](OrElse (JGet $attrs 'c_rotation') '0,0,0')).Split(',')
                # round like the Python reference ("%.4f" / "%.3f")
                $model = @{
                    Uuid = (Clean (JGet $attrs 'uuid')); Title = (Clean (JGet $attrs 'title'))
                    Tx = (ToNum $tx.ToString('F4', $Inv)); Ty = (ToNum $ty.ToString('F4', $Inv)); Tz = (ToNum $tz.ToString('F4', $Inv))
                    Rx = (ToNum (ToNum (GetAt $rot 0)).ToString('F3', $Inv))
                    Ry = (ToNum (ToNum (GetAt $rot 1)).ToString('F3', $Inv))
                    Rz = (ToNum (ToNum (GetAt $rot 2)).ToString('F3', $Inv))
                }
            }
        }
    }
    return $model
}

# objBox = @(xmin, xmax, ymin, ymax, zmin) in mm, or $null
function Emit-Model($model, $objBox) {
    if ($null -eq $model) { return }
    $ocx = 0.0; $ocy = 0.0; $zmin = 0.0
    if ($null -ne $objBox) {
        $ocx = ($objBox[0] + $objBox[1]) / 2.0
        $ocy = ($objBox[2] + $objBox[3]) / 2.0
        $zmin = $objBox[4]
    }
    $a = Rad $model.Rz
    $offx = - $ocx * [math]::Cos($a) + $ocy * [math]::Sin($a)
    $offy = - $ocx * [math]::Sin($a) - $ocy * [math]::Cos($a)
    $mm2c = 100000.0 / 25.4
    Emit @('F3D', ($model.Uuid + '.step'), (RoundI (($model.Tx + $offx) * $mm2c)), (RoundI (($model.Ty + $offy) * $mm2c)),
        (RoundI (($model.Tz - $zmin) * $mm2c)), (RoundI ($model.Rx * 1000)), (RoundI ($model.Ry * 1000)), (RoundI ($model.Rz * 1000)))
}

function Get-ObjBox([string]$text) {
    $minX = [double]::MaxValue; $maxX = - [double]::MaxValue
    $minY = [double]::MaxValue; $maxY = - [double]::MaxValue
    $minZ = [double]::MaxValue; $any = $false
    foreach ($line in [regex]::Split($text, "\r\n|\r|\n")) {
        if ($line.StartsWith('v ')) {
            $pr = $line.Split([char[]]@(' ', "`t", "`r"), [System.StringSplitOptions]::RemoveEmptyEntries)
            if ($pr.Length -ge 4) {
                $x = ToNum $pr[1]; $y = ToNum $pr[2]; $z = ToNum $pr[3]
                if ($x -lt $minX) { $minX = $x }; if ($x -gt $maxX) { $maxX = $x }
                if ($y -lt $minY) { $minY = $y }; if ($y -gt $maxY) { $maxY = $y }
                if ($z -lt $minZ) { $minZ = $z }
                $any = $true
            }
        }
    }
    if (-not $any) { return $null }
    return , @($minX, $maxX, $minY, $maxY, $minZ)
}

function Convert-Result($result, [string]$lcscId) {
    $ds = AsDict (JGet $result 'dataStr')
    $cpara = OrElse (JGet (JGet $ds 'head') 'c_para') @{}
    $pkg = AsDict (JGet $result 'packageDetail')
    $pds = AsDict (JGet $pkg 'dataStr')
    $pcpara = OrElse (JGet (JGet $pds 'head') 'c_para') @{}
    $lcscObj = JGet $result 'lcsc'
    $lcscId = OrElse $lcscId (OrElse (JGet $lcscObj 'number') (JGet $cpara 'Supplier Part'))
    $name = OrElse (JGet $cpara 'name') (OrElse (JGet $result 'title') $lcscId)
    $fpname = OrElse (JGet $pcpara 'package') (OrElse (JGet $pkg 'title') ([string]$name + '_FP'))
    $prefix = ([string](OrElse (JGet $cpara 'pre') 'U?')).Replace('?', '')
    $mfr = [string](OrElse (JGet $cpara 'Manufacturer') '')
    $mpn = [string](OrElse (JGet $cpara 'Manufacturer Part') $name)
    $desc = OrElse (JGet $result 'description') ''
    $url = [string](OrElse (JGet $lcscObj 'url') '')
    Emit @('META', 'NAME', (Clean $name))
    Emit @('META', 'LCSC', (Clean $lcscId))
    Emit @('META', 'FOOTPRINT', (Clean $fpname))
    Emit @('META', 'PREFIX', (Clean (OrElse $prefix 'U')))
    Emit @('META', 'DESC', (Clean (OrElse $desc ($mfr + ' ' + $mpn).Trim())))
    # Parameters keep EasyEDA's own names; the Altium script renames/normalises them
    # with the user's parameter map.
    $params = New-Object 'System.Collections.Generic.List[object]'
    $params.Add(@('Manufacturer', $mfr)); $params.Add(@('Manufacturer Part', $mpn))
    $params.Add(@('Supplier', (OrElse (JGet $cpara 'Supplier') 'LCSC'))); $params.Add(@('Supplier Part', $lcscId))
    $params.Add(@('Package', $fpname)); $params.Add(@('Datasheet', $url))
    $params.Add(@('JLCPCB Part Class', (OrElse (JGet $cpara 'JLCPCB Part Class') '')))
    $params.Add(@('Value', (OrElse (JGet $cpara 'Value') '')))
    if ($cpara -is [System.Collections.IDictionary]) {
        foreach ($ck in @($cpara.Keys)) {
            $cv = $cpara[$ck]
            if ($cv -is [string] -and -not ($PARAM_SKIP -ccontains (NormKey $ck))) { $params.Add(@([string]$ck, $cv)) }
        }
    }
    $emitted = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($kv in $params) {
        $nk = NormKey $kv[0]
        if ($nk -and $emitted.Add($nk)) {
            $v = Clean $kv[1]
            if ($v -and $v -cne 'null' -and $v -cne '-') { Emit @('PARAM', (Clean $kv[0]), $v) }
        }
    }
    # multi-unit symbols (EasyEDA "subparts"): one Altium part per unit, shared origin
    $subs = New-Object 'System.Collections.Generic.List[object]'
    $spl = JGet $result 'subparts'
    if ($null -ne $spl) {
        foreach ($sp in $spl) {
            if ($sp -is [System.Collections.IDictionary]) {
                $sds = AsDict (JGet $sp 'dataStr')
                if ($null -ne (JGet $sds 'shape')) { $subs.Add($sds) }
            }
        }
    }
    if ($subs.Count -gt 0) {
        $origin = Get-SymbolOrigin $subs[0]
        for ($k = 0; $k -lt $subs.Count; $k++) {
            Emit @('SPART', [string]($k + 1))
            Convert-Symbol $subs[$k] $origin
        }
    } else {
        Convert-Symbol $ds $null
    }
    $hasPin = $false
    foreach ($ln in $script:Out) { if ($ln.StartsWith("SPIN`t")) { $hasPin = $true; break } }
    if (-not $hasPin) { Emit @('WARN', 'EasyEDA returned no symbol pins for this part') }
    return (Convert-Footprint $pds)
}

function Write-Utf8Bom([string]$path, [string]$text) {
    $enc = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($path, $text, $enc)
}

function New-WebClient {
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [System.Text.Encoding]::UTF8
    $wc.Headers.Add('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36')
    $wc.Headers.Add('Accept', 'application/json, text/javascript, */*; q=0.01')
    try {
        if ($null -ne $wc.Proxy) { $wc.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials }
    } catch { }
    return $wc
}

# ------------------------------------------------------------------ main ---
try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
} catch { }

if ($SelfTest) {
    $testDir = Join-Path $PSScriptRoot 'tests'
    $fail = 0; $count = 0
    foreach ($fx in (Get-ChildItem $testDir -Filter '*.raweasy.json')) {
        $count++
        $script:Out.Clear()
        $data = ParseJson ([System.IO.File]::ReadAllText($fx.FullName, [System.Text.Encoding]::UTF8))
        $res = JGet $data 'result'; if ($null -eq $res) { $res = $data }
        $m = Convert-Result $res ''
        Emit-Model $m $null
        $expFile = $fx.FullName -replace '\.raweasy\.json$', '.expected.txt'
        $exp = [System.IO.File]::ReadAllText($expFile, [System.Text.Encoding]::UTF8).Replace("`r", '').TrimEnd("`n").Split("`n")
        $got = $script:Out.ToArray()
        $ok = ($exp.Length -eq $got.Length)
        $firstDiff = ''
        if ($ok) {
            for ($k = 0; $k -lt $exp.Length; $k++) {
                if ($exp[$k] -cne $got[$k]) {
                    # tolerate +-1 cmil rounding differences in numeric fields
                    $ea = $exp[$k].Split("`t"); $ga = $got[$k].Split("`t")
                    $same = ($ea.Length -eq $ga.Length)
                    if ($same) {
                        for ($j = 0; $j -lt $ea.Length; $j++) {
                            if ($ea[$j] -cne $ga[$j]) {
                                $e1 = 0L; $g1 = 0L
                                $okE = [long]::TryParse($ea[$j], [System.Globalization.NumberStyles]::Integer, $Inv, [ref]$e1)
                                $okG = [long]::TryParse($ga[$j], [System.Globalization.NumberStyles]::Integer, $Inv, [ref]$g1)
                                if (-not ($okE -and $okG -and [math]::Abs($e1 - $g1) -le 1)) { $same = $false; break }
                            }
                        }
                    }
                    if (-not $same) { $ok = $false; $firstDiff = "line $($k+1)`n  expected: $($exp[$k])`n  got     : $($got[$k])"; break }
                }
            }
        } else { $firstDiff = "line count expected $($exp.Length) got $($got.Length)" }
        if ($ok) { Write-Host "PASS  $($fx.Name)" -ForegroundColor Green }
        else { $fail++; Write-Host "FAIL  $($fx.Name)  $firstDiff" -ForegroundColor Red }
    }
    Write-Host ''
    Write-Host ("{0} of {1} tests passed" -f ($count - $fail), $count)
    if ($fail -gt 0) { exit 1 } else { exit 0 }
}

# same default as the Altium script: a 'Libraries' folder next to this file
if ([string]::IsNullOrEmpty($OutDir)) { $OutDir = Join-Path $PSScriptRoot 'Libraries' }
$cacheDir = Join-Path $OutDir 'cache'
$modelDir = Join-Path $OutDir '3D'
foreach ($d in @($OutDir, $cacheDir, $modelDir)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

$Lcsc = $Lcsc.Trim().ToUpperInvariant()
if ($Lcsc -and $Lcsc -notmatch '^C\d+$') {
    if ($Lcsc -match '^\d+$') { $Lcsc = 'C' + $Lcsc }
}
$statusFile = Join-Path $cacheDir ($(if ($Lcsc) { $Lcsc } else { 'input' }) + '.status.txt')
$partFile = Join-Path $cacheDir ($(if ($Lcsc) { $Lcsc } else { 'input' }) + '.part.txt')
$logFile = Join-Path $cacheDir 'ee_fetch.log'
function Log([string]$m) {
    $line = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $m
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    Write-Host $m
}

try {
    if (Test-Path $statusFile) { Remove-Item $statusFile -Force }
    if (Test-Path $partFile) { Remove-Item $partFile -Force }

    if ($InputJson) {
        $raw = [System.IO.File]::ReadAllText($InputJson, [System.Text.Encoding]::UTF8)
    } else {
        if (-not $Lcsc) { throw 'No LCSC part number given (example: C2040).' }
        $url = "https://easyeda.com/api/products/$Lcsc/components?version=6.4.19.5"
        Log "GET $url"
        $wc = New-WebClient
        $raw = $wc.DownloadString($url)
        [System.IO.File]::WriteAllText((Join-Path $cacheDir "$Lcsc.json"), $raw, (New-Object System.Text.UTF8Encoding($false)))
    }
    $data = ParseJson $raw
    $res = JGet $data 'result'
    if ($null -eq $res) {
        if ($null -ne (JGet $data 'dataStr')) { $res = $data }
        else {
            $msg = OrElse (JGet $data 'message') 'part not found'
            throw "EasyEDA has no symbol/footprint for '$Lcsc' ($msg). Check the part number on lcsc.com / jlcpcb.com/parts."
        }
    }
    if ($null -eq (JGet $res 'packageDetail')) { throw "'$Lcsc' has a symbol but no footprint on EasyEDA." }

    $script:Out.Clear()
    $model = Convert-Result $res $Lcsc

    if ($null -ne $model -and -not $NoModel) {
        $stepPath = Join-Path $modelDir ($model.Uuid + '.step')
        $boxPath = Join-Path $modelDir ($model.Uuid + '.bbox.txt')
        $objBox = $null
        try {
            if (-not (Test-Path $stepPath) -or (Get-Item $stepPath).Length -lt 100) {
                $u2 = "https://modules.easyeda.com/qAxj6KHrDKw4blvCG8QJPs7Y/$($model.Uuid)"
                Log "GET $u2"
                (New-WebClient).DownloadFile($u2, $stepPath)
            }
            if (Test-Path $boxPath) {
                $bx = (Get-Content $boxPath -Raw).Trim().Split(' ')
                $objBox = @((ToNum $bx[0]), (ToNum $bx[1]), (ToNum $bx[2]), (ToNum $bx[3]), (ToNum $bx[4]))
            } else {
                $u3 = "https://modules.easyeda.com/3dmodel/$($model.Uuid)"
                Log "GET $u3"
                $objText = (New-WebClient).DownloadString($u3)
                $objBox = Get-ObjBox $objText
                if ($null -ne $objBox) {
                    $txt = ($objBox | ForEach-Object { $_.ToString('R', $Inv) }) -join ' '
                    Set-Content -Path $boxPath -Value $txt -Encoding ASCII
                }
            }
            if ((Get-Item $stepPath).Length -lt 100) { throw 'STEP download was empty' }
            Emit-Model $model $objBox
        } catch {
            Emit @('WARN', ('3D model could not be downloaded: ' + (Clean $_.Exception.Message)))
        }
    }

    Write-Utf8Bom $partFile (($script:Out.ToArray() -join "`r`n") + "`r`n")
    Write-Utf8Bom $statusFile ("OK`t" + $partFile + "`r`n")
    Log "OK  $Lcsc -> $partFile"
    exit 0
} catch {
    $msg = Clean $_.Exception.Message
    if ($_.Exception -is [System.Net.WebException]) {
        $msg = "Network error talking to EasyEDA: $msg. If you are behind a VPN/proxy, check that https://easyeda.com opens in a browser inside the VM."
    }
    try { Write-Utf8Bom $statusFile ("ERROR`t" + $msg + "`r`n") } catch { }
    try { Log "ERROR $msg" } catch { Write-Host "ERROR $msg" }
    exit 2
}

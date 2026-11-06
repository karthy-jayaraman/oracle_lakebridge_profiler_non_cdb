# Run the Lakebridge Oracle profiler for every database in databases.csv.
# Windows (PowerShell 5.1 or 7) version of step3b_run_profiler.sh; same rules,
# same files and columns.
#
#   $env:LB_ORACLE_PROFILER_PWD = [Net.NetworkCredential]::new('', (Read-Host 'Profiler password' -AsSecureString)).Password
#   .\step3b_run_profiler.ps1 -OutputDir C:\oracle_profiles -Databases .\databases.csv [more .csv files ...]
#
# databases.csv columns:  db_name,instance_sid,host,port   (comma-separated; columns are
#   found by the header row, in any order; a file without a header uses this order)
#   instance_sid = the SID of one instance of the database (e.g. EDW1 on RAC)
#   host         = the server / RAC node where that instance runs (not SCAN)
#   port         = listener port (blank = 1521)
# Lakebridge sends its "service_name" setting to Oracle as a SID, which only the
# listener on that node knows. One row per database is enough on RAC. Each
# database is profiled once (first row per db_name, case-insensitive). Blank
# rows, repeated header rows and rows without name/SID/host are skipped; rows
# with invalid values are reported and skipped.
#
# - One folder per database: <OutputDir>\<db_name>\
# - The extract is renamed profiler_extract_oracle_<version>_<date>_<DB>.db
# - Success = Lakebridge exits 0 and the extract's own run record says COMPLETE;
#   it is marked with a .completed file. Completed databases are skipped on a
#   re-run, failed ones are retried. Delete .completed to profile again.
# - Nothing usable is deleted: before a run, earlier complete extracts move to
#   <db>\previous\ and are put back if the run fails, stops on an error or is
#   interrupted (Ctrl-C; exit code 130 when PowerShell was started to run it, e.g. -File). An extract that another program has
#   open is left alone and that database is skipped.
#   Failed or interrupted attempts are kept as *.db.failed.<timestamp>.
# - Writes profile_report.txt per database and <OutputDir>\summary.csv
#   (one line per database; a re-run replaces that database's line).
# - The password is read from LB_ORACLE_PROFILER_PWD and never written to disk;
#   per-database connection files live in a private temp folder, removed at the end.
# - Only one run at a time per output folder (lock folder <OutputDir>\.lock).
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory = $true, Position = 0)] [string] $OutputDir,
    # one or more .csv files: -Databases a.csv b.csv  or  -Databases a.csv,b.csv
    [Parameter(Mandatory = $true, Position = 1)] [string[]] $Databases,
    [string] $ProfilerUser = 'lakebridge_profiler',                # account to connect with
    [string] $DatabricksProfile = 'DEFAULT',                       # Databricks CLI profile
    [switch] $LbDebug,                                             # pass --debug to Lakebridge
    [Parameter(ValueFromRemainingArguments = $true)] [string[]] $MoreDatabases   # the files after the first
)
# also accept comma lists (pwsh -File passes "a.csv,b.csv" as one string); a value that is
# an existing file is kept as it is, even if its name contains a comma
$Databases = @(@($Databases) + @($MoreDatabases) | ForEach-Object {
    if (Test-Path -LiteralPath "$_" -PathType Leaf) { "$_" } else { "$_" -split ',' } } |
    ForEach-Object { $_.Trim() } | Where-Object { $_ })
$ErrorActionPreference = 'Stop'
if (-not $env:LB_ORACLE_PROFILER_PWD) { throw 'Set $env:LB_ORACLE_PROFILER_PWD first' }
if (-not (Get-Command databricks -ErrorAction SilentlyContinue)) { throw 'The databricks CLI is not on PATH' }
$rxName = '^[A-Za-z0-9_$#][A-Za-z0-9_$#.-]*$'
$rxSid  = '^[A-Za-z][A-Za-z0-9_$#]*$'
$rxHost = '^[A-Za-z0-9][A-Za-z0-9._-]*$'
$rxPort = '^[0-9]{1,5}$'
if ($ProfilerUser -notmatch $rxSid) { throw "Invalid account name: $ProfilerUser" }

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
# Lakebridge's own Python already has duckdb; used to check and summarize each extract
$lbPy = if ($env:LB_PY) { $env:LB_PY } else { Join-Path $env:USERPROFILE '.databricks\labs\lakebridge\state\venv\Scripts\python.exe' }
$report = Join-Path $here 'step3b_report_extract.py'
$ErrorActionPreference = 'Continue'
$pyOk = $false
if (Test-Path -LiteralPath $lbPy) { & $lbPy -I -c 'import duckdb' 2>$null | Out-Null; $pyOk = ($LASTEXITCODE -eq 0) }
$ErrorActionPreference = 'Stop'
if (-not $pyOk) {
    throw "Cannot run Lakebridge's Python ($lbPy) with duckdb; it's needed to check each result. Install Lakebridge first (databricks labs install lakebridge), or set `$env:LB_PY to a Python that has duckdb."
}

function Invoke-Report([string] $Path, [string] $Mode) {
    # never let a Python warning/traceback stop the loop
    $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
        $out = & $lbPy -I $report $Path $Mode 2>$null
        return (@($out) -join "`n")
    } catch { return '' } finally { $ErrorActionPreference = $old }
}
function Get-Status([string] $Path) {
    $s = (Invoke-Report $Path '--status').Trim()
    if ($s) { return $s } else { return 'UNKNOWN' }
}
function Clean([object] $v) { if ($null -eq $v) { '' } else { ([string]$v).Trim().Trim('"').Trim() } }
function Stamp { Get-Date -Format 'yyyyMMddHHmmss' }
function Get-Extracts([string] $Dir) {
    @(Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -like 'profiler_extract_oracle_*' -and $_.Extension -eq '.db' })
}
$script:started = $false   # the profiler has been started for the current database
$script:moved = New-Object System.Collections.Generic.List[object]   # extracts this run moved to previous\
# put a folder back the way it was: this run's (partial) extract -> .failed,
# the extracts this run moved to previous\ back to their place; if that leaves no
# extract at the top (e.g. an earlier run was killed), the newest one in previous\
# move a file; on failure (e.g. the file is open in another program) report it and return $false
function Move-File([string] $From, [string] $To) {
    $existed = Test-Path -LiteralPath $To
    try { Move-Item -LiteralPath $From -Destination $To -ErrorAction Stop; return $true }
    catch {
        Write-Host "  warning: could not move $From to ${To}: $($_.Exception.Message)"
        # a move across file systems copies first: don't leave a second copy behind
        if (-not $existed -and (Test-Path -LiteralPath $From) -and (Test-Path -LiteralPath $To)) {
            Remove-Item -LiteralPath $To -Force -ErrorAction SilentlyContinue
        }
        return $false
    }
}
function Restore-Folder([string] $Dir) {
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) { return }
    if ($script:started) {
        foreach ($x in (Get-Extracts $Dir)) { [void](Move-File $x.FullName ($x.FullName + '.failed.' + (Stamp))) }
    }
    foreach ($m in $script:moved) {
        if ((Test-Path -LiteralPath $m.to) -and -not (Test-Path -LiteralPath $m.from)) { [void](Move-File $m.to $m.from) }
    }
    $script:moved.Clear(); $script:started = $false
    # nothing usable at the top (e.g. an earlier run was killed): bring back the newest earlier extract
    if (-not (Get-Extracts $Dir)) {
        $newest = Get-Extracts (Join-Path $Dir 'previous') | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($newest -and -not (Test-Path -LiteralPath (Join-Path $Dir $newest.Name))) { [void](Move-File $newest.FullName (Join-Path $Dir $newest.Name)) }
    }
    Remove-EmptyPrevious $Dir
}
function Remove-EmptyPrevious([string] $Dir) {
    $prev = Join-Path $Dir 'previous'
    if ((Test-Path -LiteralPath $prev) -and -not (Get-ChildItem -LiteralPath $prev -Force)) {
        Remove-Item -LiteralPath $prev -Force -ErrorAction SilentlyContinue
    }
}

# all lists -> one row per db_name (first one wins, case-insensitive). Columns are
# found by the header row (names trimmed, any order); no header = db_name,instance_sid,host,port
$seen = @{}
$rows = New-Object System.Collections.Generic.List[object]
foreach ($f in $Databases) {
    if (-not (Test-Path -LiteralPath $f)) { throw "File not found: $f" }
    $lines = @(Get-Content -LiteralPath $f | Where-Object { $_.Trim() })
    if ($lines.Count -eq 0) { continue }
    if ($lines[0] -match ';' -and $lines[0] -notmatch ',') { throw "$f looks semicolon-separated; save it as comma-separated CSV" }
    $first = @($lines[0] -split ',' | ForEach-Object { (Clean $_).ToLowerInvariant() })
    if ($first -contains 'db_name') {
        $hdr = $first; $data = @($lines | Select-Object -Skip 1)
        if ($hdr -notcontains 'instance_sid' -or $hdr -notcontains 'host') { throw "${f}: header row has no instance_sid or host column" }
    } else {
        $hdr = @('db_name', 'instance_sid', 'host', 'port'); $data = $lines
    }
    # blank or repeated header names would stop ConvertFrom-Csv; rename them
    $used = @{}
    $hdr = @(for ($i = 0; $i -lt $hdr.Count; $i++) {
        $h = $hdr[$i]; if (-not $h -or $used.ContainsKey($h)) { $h = "_col$i" }; $used[$h] = $true; $h })
    if ($data.Count -eq 0) { continue }
    foreach ($r in ($data | ConvertFrom-Csv -Header $hdr)) {
        $name = Clean $r.db_name; $sid = Clean $r.instance_sid; $h = Clean $r.host; $p = Clean $r.port
        if (-not $name -or -not $sid -or -not $h -or $name -ieq 'db_name') { continue }
        $key = $name.ToUpperInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        if (-not $p) { $p = '1521' }
        $rows.Add([pscustomobject]@{ name = $name; sid = $sid; host = $h; port = $p })
    }
}
if ($rows.Count -eq 0) { throw "No database rows found in: $($Databases -join ', ') (expected columns db_name,instance_sid,host,port)" }

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$lock = Join-Path $OutputDir '.lock'
try { New-Item -ItemType Directory -Path $lock -ErrorAction Stop | Out-Null }
catch { throw "Another run is using $OutputDir (remove $lock if no run is active)" }
# from here on the lock is ours: everything runs inside try/finally so it is always released
$cur = ''        # folder of the database being worked on right now
$failure = $null
$finished = $false
$creds = ''
try {
    $summary = Join-Path $OutputDir 'summary.csv'
    if (-not (Test-Path -LiteralPath $summary)) {
        'db_name,instance_sid,host,status,seconds,tables_with_data,empty_tables,awr_from,awr_to,awr_days,failed_steps,extract' |
            Set-Content -LiteralPath $summary -Encoding ascii
    }
    # one line per database: a re-run replaces that database's line (temp file, then moved)
    function Write-SummaryLine([string] $Name, [string] $Line) {
        $prefix = "$Name,".ToUpperInvariant()
        $lines = @(Get-Content -LiteralPath $summary)
        $keep = @($lines[0]) + @($lines | Select-Object -Skip 1 | Where-Object { -not $_.ToUpperInvariant().StartsWith($prefix) }) + @($Line)
        $keep | Set-Content -LiteralPath ($summary + '.tmp') -Encoding utf8
        Move-Item -LiteralPath ($summary + '.tmp') -Destination $summary -Force
    }
    $creds = Join-Path ([IO.Path]::GetTempPath()) ("lb_creds_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $creds | Out-Null

    foreach ($r in $rows) {
        $name = $r.name
        if ($name -notmatch $rxName) { Write-Host "skip '$name': database name may only contain letters, digits and _ `$ # . - (not starting with .)"; continue }
        if ($r.sid -notmatch $rxSid -or $r.host -notmatch $rxHost -or $r.port -notmatch $rxPort -or [int]$r.port -lt 1 -or [int]$r.port -gt 65535) {
            Write-Host "skip ${name}: invalid instance_sid '$($r.sid)', host '$($r.host)' or port '$($r.port)'"; continue
        }
        $port = [int]$r.port
        $dir = Join-Path $OutputDir $name
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $marker = Join-Path $dir '.completed'
        if (Test-Path -LiteralPath $marker) { Write-Host "skip $name (already profiled)"; continue }

        $credFile = Join-Path $creds "$name.yml"
        @"
secret_vault_type: env
oracle:
  host: "$($r.host)"
  port: $port
  service_name: "$($r.sid)"
  user: "$ProfilerUser"
  password: LB_ORACLE_PROFILER_PWD
"@ | Set-Content -LiteralPath $credFile -Encoding ascii

        # sort what's already in the folder: complete extracts are kept aside in previous\,
        # anything else (e.g. left by an interrupted run) is marked .failed
        $cur = $dir; $locked = $null; $blocked = $null
        $prev = Join-Path $dir 'previous'
        New-Item -ItemType Directory -Force -Path $prev | Out-Null
        foreach ($x in (Get-Extracts $dir)) {
            $st = Get-Status $x.FullName
            if ($st -eq 'LOCKED') { $locked = $x; break }
            if ($st -eq 'COMPLETE') {
                $t = Join-Path $prev $x.Name
                if (Test-Path -LiteralPath $t) {   # same name already kept: add a timestamp (and a counter if needed)
                    $base = Join-Path $prev ($x.BaseName + '.' + (Stamp)); $t = "$base.db"; $n = 1
                    while (Test-Path -LiteralPath $t) { $t = "$base-$n.db"; $n++ }
                }
                $script:moved.Add([pscustomobject]@{ from = $x.FullName; to = $t })   # recorded first
                if (-not (Move-File $x.FullName $t)) { $blocked = $x; break }
            } elseif (-not (Move-File $x.FullName ($x.FullName + '.failed.' + (Stamp)))) { $blocked = $x; break }
        }
        if ($locked -or $blocked) {
            if ($locked) { Write-Host "skip ${name}: $($locked.Name) is open in another program; close it and run again" }
            else { Write-Host "skip ${name}: could not move $($blocked.Name) aside (see the warning above); fix that and run again" }
            Restore-Folder $dir; $cur = ''; continue
        }

        Write-Host "profiling $name (instance $($r.sid) on $($r.host):$port) ..."
        $script:started = $true
        $start = Get-Date
        $lbArgs = @('labs', 'lakebridge', 'execute-database-profiler', '--source-tech', 'oracle',
                    '--cred-file-path', $credFile, '--output-folder', $dir, '-p', $DatabricksProfile)
        if ($LbDebug) { $lbArgs += '--debug' }
        $log = Join-Path $dir 'profiler.log'
        $ErrorActionPreference = 'Continue'
        & databricks @lbArgs 2>&1 | ForEach-Object { "$_" } | Out-File -LiteralPath $log -Encoding utf8
        $rc = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        $secs = [int]((Get-Date) - $start).TotalSeconds

        # only an extract written by this run can be at the top level now
        $extract = (Get-Extracts $dir | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
        $path = ''
        if ($extract) {
            $path = $extract.FullName
            if ($extract.Name -notlike "*_$name.db") {
                $newPath = Join-Path $dir ($extract.BaseName + "_$name.db")
                Move-Item -LiteralPath $extract.FullName -Destination $newPath -Force
                $path = $newPath
            }
        }
        $status = 'FAILED'
        if ($rc -eq 0 -and $path -and (Get-Status $path) -eq 'COMPLETE') { $status = 'OK' }
        $stats = ',,,,,'
        if ($path) {
            (Invoke-Report $path '') | Set-Content -LiteralPath (Join-Path $dir 'profile_report.txt') -Encoding utf8
            $line = (Invoke-Report $path '--csv').Split("`n")[0].Trim()
            if ($line) { $stats = $line }
        }
        if ($status -eq 'OK') {
            # from here on, an interrupt leaves this database as it is
            $cur = ''; $script:started = $false; $script:moved.Clear()
            Write-SummaryLine $name "$name,$($r.sid),$($r.host),$status,$secs,$stats,$path"
            New-Item -ItemType File -Force -Path $marker | Out-Null
            Remove-EmptyPrevious $dir
        } else {
            Restore-Folder $dir; $cur = ''
            Write-SummaryLine $name "$name,$($r.sid),$($r.host),$status,$secs,$stats,"
        }
        Write-Host "  -> $status in ${secs}s"
    }
    $finished = $true
}
catch { $failure = $_; throw }
finally {
    $interrupted = -not $finished -and -not $failure
    try {
        if ($cur) {
            if ($failure) { Write-Host "error: restoring $cur" } else { Write-Host "interrupted: restoring $cur" }
            Restore-Folder $cur
        } elseif ($interrupted) { Write-Host "interrupted" }
    } catch { Write-Host "warning: restore of $cur incomplete: $($_.Exception.Message)" }
    finally {
        if ($creds) { Remove-Item -Recurse -Force -LiteralPath $creds -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
    }
    # Ctrl-C: give the caller exit code 130 (a plain exit is ignored while PowerShell is stopping),
    # but only when this PowerShell process was started to run a script or command (pwsh [-File]
    # script, -Command ..., also through a wrapper script) and not to stay open (-NoExit,
    # -Command - reading from the keyboard/stdin); in an interactive window it would close it.
    $procArgs = @([Environment]::GetCommandLineArgs() | Select-Object -Skip 1)
    $runsSomething = $false
    for ($i = 0; $i -lt $procArgs.Count; $i++) {
        $a = $procArgs[$i]; $next = if ($i + 1 -lt $procArgs.Count) { $procArgs[$i + 1] } else { '' }
        if ($a -match '^[-/]{1,2}f(i(l(e)?)?)?$' -or ($a -match '^[-/]{1,2}(c(o(m(m(a(n(d)?)?)?)?)?)?|e(c|nc|ncodedcommand))$' -and $next -ne '-') -or
            ($a -notmatch '^(-|/[A-Za-z]+$)' -and $a -match '\.ps1$')) { $runsSomething = $true }
    }
    $noExit = @($procArgs | Where-Object { $_ -match '^[-/]{1,2}noe(x(i(t)?)?)?$' }).Count -gt 0
    if ($interrupted -and $runsSomething -and -not $noExit) { [Environment]::Exit(130) }
}
Write-Host ''
Import-Csv -LiteralPath $summary | Format-Table db_name, status, seconds, tables_with_data, empty_tables, awr_days, failed_steps -AutoSize

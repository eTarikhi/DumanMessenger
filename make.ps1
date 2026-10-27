<#
.SYNOPSIS
    Windows entry point for this repository's local CI toolchain.

.DESCRIPTION
    The pipeline lives in tool/ci/*.sh and is driven by the Makefile. That is deliberate:
    .github/workflows/ci.yml runs on ubuntu-latest, so the closest thing to CI on a Windows
    11 machine is a POSIX shell, not a reimplementation. This script is therefore a
    *dispatcher* — it finds a bash runtime, translates the path, forwards your arguments
    unchanged, and hands back the real exit code. It contains no pipeline logic of its own,
    because a second implementation of the same policy is a second thing that can drift
    from the workflow and still look green.

    Runtimes it looks for, in order:
      1. WSL2        recommended — closest to the CI runner, and the Dart SDK installs cleanly
      2. Git Bash    bundled with Git for Windows, so almost certainly already present
      3. MSYS2       if you installed it

    Exit codes are the pipeline's, propagated verbatim:
      0 every selected job ran and passed   1 something failed or could not run
      2 partial (--allow-missing-dart)     64 bad usage

.PARAMETER Task
    The make target and its arguments, e.g.:  .\make.ps1 ci
                                               .\make.ps1 push
                                               .\make.ps1 run-pipeline --job web --fast

.PARAMETER Runtime
    auto (default), wsl, or bash — force a specific runtime.

.EXAMPLE
    .\make.ps1 doctor
    Checks this machine against the toolchain CI pins.

.EXAMPLE
    .\make.ps1 ci --job web --fast
    Run one job's quick subset.

.NOTES
    If PowerShell refuses to run this file, the execution policy is blocking it:
        Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
    That is per-user and does not weaken the machine.

    Written for Windows PowerShell 5.1 (which Windows 11 ships) as well as PowerShell 7.
#>

# PositionalBinding is off and $Task declares its own position, because those two things are
# what make `.\make.ps1 doctor` mean "run the doctor target".
#
# PowerShell excludes a ValueFromRemainingArguments parameter from positional binding. Without
# `Position = 0` below, the first positional argument bound to the *next* parameter — $Runtime —
# and its ValidateSet rejected it:
#
#     .\make.ps1 doctor
#     Cannot validate argument on parameter 'Runtime'. The argument "doctor" does not belong to
#     the set "auto,wsl,bash" specified by the ValidateSet attribute.
#
# which is every documented invocation of this script failing on a machine that finally ran it,
# with an error about runtimes when the problem was the target. PositionalBinding = $false keeps
# $Runtime named-only, so a second positional argument (`--job`, `--fast`) is forwarded to bash
# instead of being offered to it.
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Task,

    [ValidateSet('auto', 'wsl', 'bash')]
    [string]$Runtime = 'auto'
)

$ErrorActionPreference = 'Stop'

# --- colours, without depending on a module ------------------------------------
function Write-Head([string]$m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Note([string]$m) { Write-Host "    $m" -ForegroundColor DarkGray }
function Write-Warn2([string]$m) { Write-Host "warning: $m" -ForegroundColor Yellow }
function Write-Err2([string]$m) { Write-Host "error: $m" -ForegroundColor Red }

# --- where am I ----------------------------------------------------------------
# $PSScriptRoot is the directory holding this script, and this script is committed at the top of
# the repository — a sibling of Makefile, tool/ and sim/ — so that directory *is* the repo root.
#
# It used to take the parent, on the strength of a comment that asserted the opposite, and every
# forwarded command then ran one directory too high. On the first real Windows 11 execution that
# looked like a runtime failure rather than an arithmetic one:
#
#     bash: line 1: /mnt/c/Users/.../Git-Clones/tool/ci/doctor.sh: No such file or directory
#     error: the wsl runtime exited with 127, which is not a pipeline verdict.
#
# The path in that message is the parent of the clone, which is the whole diagnosis.
$RepoRoot = $PSScriptRoot

# Fail here rather than in bash, because "No such file or directory" from a runtime does not say
# which of the three layers disagreed — the script's location, the path translation, or the repo.
if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot 'tool/ci/doctor.sh'))) {
    Write-Err2 "this does not look like the repository root: $RepoRoot"
    Write-Note 'make.ps1 has to sit at the top of a DumanMessenger clone, next to tool/ and sim/.'
    Write-Note 'If you copied it somewhere else, put it back and run it from there.'
    exit 64
}

function ConvertTo-MsysPath([string]$WindowsPath) {
    # C:\Users\me\repo  ->  /c/Users/me/repo
    $full = (Resolve-Path -LiteralPath $WindowsPath).Path
    if ($full -match '^([A-Za-z]):[\\](.*)$') {
        $drive = $Matches[1].ToLowerInvariant()
        $rest  = $Matches[2] -replace '\\', '/'
        return "/$drive/$rest"
    }
    return $full -replace '\\', '/'
}

# --- find a bash runtime -------------------------------------------------------
$WslExe  = $null
$BashExe = $null
$Chosen  = $null
$PosixRoot = $null

if ($Runtime -eq 'auto' -or $Runtime -eq 'wsl') {
    $cmd = Get-Command wsl.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        # wsl.exe existing is not enough — there has to be an installed distro, or every
        # invocation dies with "Windows Subsystem for Linux has no installed distributions."
        $distros = & wsl.exe -l -q 2>$null
        if ($LASTEXITCODE -eq 0 -and $distros) {
            $WslExe = $cmd.Source
            if ($Runtime -eq 'auto') { $Chosen = 'wsl' } else { $Chosen = 'wsl' }
        }
        elseif ($Runtime -eq 'wsl') {
            Write-Err2 'WSL is present but has no installed distribution.'
            Write-Note 'Install one with:  wsl --install -d Ubuntu'
            Write-Note 'Then re-run, or use:  .\make.ps1 -Runtime bash <target>'
            exit 64
        }
    }
    elseif ($Runtime -eq 'wsl') {
        Write-Err2 'WSL was requested but wsl.exe was not found.'
        Write-Note 'Enable it with:  wsl --install    (needs a reboot, then Ubuntu)'
        exit 64
    }
}

if (-not $Chosen) {
    # Git for Windows: derive bash.exe from wherever git.exe actually lives, rather than
    # guessing an install path, because winget/scoop/portable installs all differ.
    $candidates = @()
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($git) {
        # ...\Git\cmd\git.exe  ->  ...\Git\bin\bash.exe
        $gitHome = Split-Path -Parent (Split-Path -Parent $git.Source)
        $candidates += (Join-Path $gitHome 'bin\bash.exe')
        $candidates += (Join-Path $gitHome 'usr\bin\bash.exe')
    }
    $candidates += "$env:ProgramFiles\Git\bin\bash.exe"
    $candidates += "${env:ProgramFiles(x86)}\Git\bin\bash.exe"
    $candidates += "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
    $candidates += 'C:\msys64\usr\bin\bash.exe'

    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { $BashExe = $c; break }
    }

    if ($BashExe) { $Chosen = 'bash' }
}

if (-not $Chosen) {
    Write-Err2 'no bash runtime found. The CI pipeline is POSIX shell, so Windows needs one.'
    Write-Host ''
    Write-Note 'Pick either — the first is recommended:'
    Write-Note ''
    Write-Note '  1. WSL2 (closest to the ubuntu-latest runner CI uses)'
    Write-Note '       wsl --install -d Ubuntu'
    Write-Note '     then:  .\make.ps1 doctor'
    Write-Note ''
    Write-Note '  2. Git for Windows (its bash is enough; you probably have git already)'
    Write-Note '       winget install --id Git.Git -e --source winget'
    Write-Note '     then:  .\make.ps1 -Runtime bash doctor'
    Write-Note ''
    Write-Note 'Until then, the individual commands still work natively — npm, dart, git and'
    Write-Note 'gh are all Windows executables. See docs/12-cli-cheat-sheet.md for the exact'
    Write-Note 'command behind every target.'
    exit 64
}

# --- translate the repository path for that runtime ----------------------------
if ($Chosen -eq 'wsl') {
    # Ask WSL rather than assuming /mnt/c — the automount point is configurable.
    $PosixRoot = (& $WslExe -e wslpath -u "$RepoRoot" 2>$null)
    if (-not $PosixRoot) { $PosixRoot = ConvertTo-MsysPath $RepoRoot }
    $PosixRoot = "$PosixRoot".Trim()
}
else {
    $PosixRoot = ConvertTo-MsysPath $RepoRoot
}

# --- targets that map straight onto a script, for runtimes without make --------
# Git for Windows does not ship make; WSL usually has it. When make is missing these
# still work, because each is a 1:1 wrapper. The Makefile remains authoritative for
# everything else, and this table is only the subset that maps to a single script.
$ScriptTargets = [ordered]@{
    'doctor'      = 'tool/ci/doctor.sh'
    'ci'          = 'tool/ci/run-pipeline.sh'
    'ci-fast'     = 'tool/ci/run-pipeline.sh --fast'
    'web'         = 'tool/ci/run-pipeline.sh --job web'
    'dart'        = 'tool/ci/run-pipeline.sh --job dart'
    'cli-matrix'  = 'tool/ci/run-pipeline.sh --job cli-matrix'
    'probes'      = 'tool/ci/run-pipeline.sh --job probes'
    'checks'      = 'tool/ci/collect-checks.sh'
    'checks-list' = 'tool/ci/collect-checks.sh --list'
    'push'        = 'tool/ci/validate-and-push.sh'
    'push-dry'    = 'tool/ci/validate-and-push.sh --dry-run'
    'push-force'  = 'tool/ci/validate-and-push.sh --force-partial'
    'watch'       = 'tool/ci/watch.sh'
    'watch-all'   = 'tool/ci/watch.sh --all'
    'follow'      = 'tool/ci/watch.sh --follow'
    'diagnose'    = 'tool/ci/watch.sh --diagnose'
    'blockers'    = 'tool/ci/blockers.sh'
    'pr'          = 'tool/ci/pr-flow.sh'
    'daily'       = 'tool/ci/daily.sh'
    'daily-fast'  = 'tool/ci/daily.sh --fast'
    'daily-checks' = 'tool/ci/daily.sh --no-evidence'
}

# --- help ----------------------------------------------------------------------
if (-not $Task -or $Task[0] -in @('help', '-h', '--help', '/?')) {
    Write-Head 'Duman Messenger — Windows front end'
    Write-Host ''
    # Not the ternary operator: ? : is PowerShell 7 only, and Windows 11 ships 5.1.
    $RuntimeLabel = 'Git Bash / MSYS2'
    if ($Chosen -eq 'wsl') { $RuntimeLabel = 'WSL2' }
    Write-Note "runtime: $Chosen   ($RuntimeLabel)"
    Write-Note "repo:    $PosixRoot"
    Write-Host ''
    Write-Note 'Usage:  .\make.ps1 <target> [arguments]'
    Write-Note '        .\make.ps1 run-pipeline --job web --fast     (call a script directly)'
    Write-Note '        .\make.ps1 -Runtime wsl <target>             (force the runtime; -Task also works)'
    Write-Host ''
    Write-Note 'Targets (forwarded to make inside the runtime, or to the script below):'
    foreach ($k in $ScriptTargets.Keys) {
        Write-Host ("    {0,-12} {1}" -f $k, $ScriptTargets[$k]) -ForegroundColor Gray
    }
    Write-Host ''
    Write-Note 'Everything the Makefile offers also works:  .\make.ps1 install-hooks'
    Write-Note 'Full list:  docs/12-cli-cheat-sheet.md   and   docs/10-local-development-and-ci.md'
    Write-Host ''
    Write-Note 'Exit codes: 0 verified · 1 failed or incomplete · 2 partial'
    exit 0
}

# --- build the command to run inside the runtime -------------------------------
function Quote-Bash([string]$s) {
    # POSIX single-quote escaping. Single quotes only, never double: PowerShell's native
    # argument passing to wsl.exe/bash.exe can mangle embedded double quotes, and a
    # command string with none survives every layer intact.
    "'" + ($s -replace "'", "'\''") + "'"
}

$Target  = $Task[0]
$Rest    = @()
if ($Task.Count -gt 1) { $Rest = $Task[1..($Task.Count - 1)] }

# Allow calling a script by its bare name: .\make.ps1 run-pipeline --job web
$Bare = "tool/ci/$Target.sh"
if (Test-Path -LiteralPath (Join-Path $RepoRoot "tool/ci/$Target.sh")) {
    $inner = "./$Bare"
}
elseif ($ScriptTargets.Contains($Target)) {
    $inner = "./$($ScriptTargets[$Target])"
}
else {
    # Anything else goes to make, which is the authoritative target list.
    $inner = "make $(Quote-Bash $Target)"
}

foreach ($a in $Rest) { $inner += " $(Quote-Bash $a)" }

$cmd = "cd $(Quote-Bash $PosixRoot) && exec $inner"

# --- one warning worth printing once -------------------------------------------
if ($Chosen -eq 'wsl' -and $PosixRoot -like '/mnt/*') {
    # The repo is on the Windows filesystem, reached through WSL's 9P bridge. That is
    # correct and works, but file I/O is several times slower — node_modules installs and
    # vitest runs feel it. Cloning into the WSL filesystem fixes it.
    Write-Warn2 'the repo is on the Windows drive (/mnt/...), so WSL file I/O is slow.'
    Write-Note 'For faster runs, clone it inside the distro:  git clone <url> ~/DumanMessenger'
    Write-Note 'Everything still works from here; this is a performance note, not an error.'
    Write-Host ''
}

if ($env:DUMAN_CI_VERBOSE) {
    Write-Note "runtime: $Chosen"
    Write-Note "exec:    $cmd"
    Write-Host ''
}

# --- run it, and hand back the real exit code ----------------------------------
if ($Chosen -eq 'wsl') {
    & $WslExe -e bash -lc $cmd
}
else {
    & $BashExe -lc $cmd
}

$code = $LASTEXITCODE
if ($null -eq $code) { $code = 0 }

# 0/1/2/64 all carry meaning, so pass them through untouched. Anything outside that set
# means the runtime itself failed (a bad path, a missing distro, a broken bash), and
# reporting it as the pipeline's verdict would be a lie in either direction.
if ($code -notin 0, 1, 2, 64) {
    Write-Err2 "the $Chosen runtime exited with $code, which is not a pipeline verdict."
    Write-Note 'That usually means the shell or the path failed, not the build. In order of likelihood:'
    Write-Note '  127  a command was not found — inside WSL, `make` is not installed by default'
    Write-Note '         sudo apt install make      (the targets in the help list do not need it)'
    Write-Note '       ...or bash could not start, or the translated path is wrong'
    Write-Note '  126  the file was found but is not executable — `git update-index --chmod=+x tool/ci/*.sh`'
    Write-Note 'Re-run with $env:DUMAN_CI_VERBOSE = 1 to see the exact command.'
}

exit $code

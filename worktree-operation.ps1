param(
    [Parameter(Position = 0)][string]$Mode,
    [Parameter(Position = 1)][string]$Worktrunk,
    [Parameter(Position = 2)][string]$Repository,
    [Parameter(Position = 3)][string]$Target,
    [Parameter(Position = 4)][AllowEmptyString()][string]$Option,
    [Parameter(Position = 5)][string]$Receipt
)

if ($PSBoundParameters.Count -ne 6 -or $args.Count -ne 0) {
    [Console]::Error.WriteLine('Usage: worktree-operation.ps1 MODE WT REPOSITORY TARGET OPTION RECEIPT')
    exit 64
}
if ($Mode -ceq 'create') {
    $label = 'Worktree creation'
} elseif ($Mode -ceq 'remove') {
    $label = 'Worktree removal'
} else {
    [Console]::Error.WriteLine('Unknown operation: ' + $Mode)
    exit 64
}

$ErrorActionPreference = 'Stop'
# PowerShell 7 can turn native nonzero exits into exceptions. Keep the actual
# exit code instead, including when the caller has enabled that preference.
$PSNativeCommandUseErrorActionPreference = $false
$encoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $encoding
$OutputEncoding = $encoding
$status = 73
$receiptTemporary = $null
$receiptStream = $null
$pidTemporary = $null
$pidPublished = $false

function Publish-OperationFile {
    param([string]$Temporary, [string]$Destination)
    # Both files are in the same directory. Neither operation exposes a partial
    # receipt; Replace also supports a pre-existing destination on Windows.
    if ([IO.File]::Exists($Destination)) {
        [IO.File]::Replace($Temporary, $Destination, $null)
    } else {
        [IO.File]::Move($Temporary, $Destination)
    }
}

function Get-WorktreeGitPath {
    param([string]$Location, [string[]]$Arguments)
    $lines = @(& git -C $Location rev-parse @Arguments)
    if ($LASTEXITCODE -ne 0 -or $lines.Count -ne 1) {
        throw 'Refusing removal: cannot inspect the worktree repository identity.'
    }
    return [OverseerWorktreePath]::Canonical([string]$lines[0])
}

function Invoke-WorktreeRemoval {
    # Resolve physical paths, not just spelling: Git uses forward slashes while
    # Windows accepts case changes, junctions, and other aliases of a directory.
    if ($null -eq ('OverseerWorktreePath' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public static class OverseerWorktreePath {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFile(string path, uint access, uint share,
        IntPtr security, uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern uint GetFinalPathNameByHandle(SafeFileHandle handle,
        StringBuilder path, uint length, uint flags);

    public static string Canonical(string path) {
        // No requested access; share read/write/delete, and allow directories.
        using (var handle = CreateFile(Path.GetFullPath(path), 0, 7,
                IntPtr.Zero, 3, 0x02000000, IntPtr.Zero)) {
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            var buffer = new StringBuilder(512);
            uint length = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 0);
            if (length == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (length >= buffer.Capacity) {
                buffer.Capacity = checked((int)length + 1);
                length = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 0);
                if (length == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
                if (length >= buffer.Capacity) throw new IOException("Canonical path changed while resolving it.");
            }
            string result = buffer.ToString();
            if (result.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase))
                result = @"\\" + result.Substring(8);
            else if (result.StartsWith(@"\\?\", StringComparison.Ordinal))
                result = result.Substring(4);
            result = Path.GetFullPath(result);
            return result.Length > Path.GetPathRoot(result).Length
                ? result.TrimEnd('\\', '/') : result;
        }
    }
}
'@
    }

    $root = Get-WorktreeGitPath -Location $Target -Arguments @('--show-toplevel')
    $common = Get-WorktreeGitPath -Location $Repository -Arguments @('--path-format=absolute', '--git-common-dir')
    $targetCommon = Get-WorktreeGitPath -Location $Target -Arguments @('--path-format=absolute', '--git-common-dir')
    $gitDirectory = Get-WorktreeGitPath -Location $Target -Arguments @('--path-format=absolute', '--git-dir')
    $targetPath = [OverseerWorktreePath]::Canonical($Target)
    $comparison = [StringComparison]::OrdinalIgnoreCase
    if (-not [string]::Equals($root, $targetPath, $comparison) -or
        -not [string]::Equals($targetCommon, $common, $comparison) -or
        [string]::Equals($gitDirectory, $common, $comparison)) {
        throw 'Refusing removal: target is not a linked worktree of this project.'
    }

    $branchLines = @(& git -C $Target symbolic-ref --quiet --short HEAD)
    $branchStatus = $LASTEXITCODE
    $branch = ''
    if ($branchStatus -eq 0 -and $branchLines.Count -eq 1) {
        $branch = [string]$branchLines[0]
    } elseif ($branchStatus -ne 1 -or $branchLines.Count -ne 0) {
        throw 'Refusing removal: cannot inspect the worktree branch.'
    }
    if (-not [string]::Equals($branch, $Option, [StringComparison]::Ordinal)) {
        throw 'Refusing removal: the worktree branch changed after confirmation.'
    }
    $changes = @(& git -C $Target status --porcelain=v1 --untracked-files=normal)
    if ($LASTEXITCODE -ne 0) {
        throw 'Refusing removal: cannot inspect worktree cleanliness.'
    }
    if ($changes.Count -ne 0) {
        throw 'Refusing removal: worktree has uncommitted or untracked files.'
    }

    # Leave ignored-file cleanup to Worktrunk, and preserve the branch. No output
    # capture here: Worktrunk and hooks inherit the original terminal and prompts.
    & $Worktrunk -C $Repository remove --foreground --no-delete-branch -- $Target
    $script:status = $LASTEXITCODE
    if ($script:status -eq 0) {
        $exists = $true
        try {
            [void][IO.File]::GetAttributes($Target)
        } catch [IO.FileNotFoundException] {
            $exists = $false
        } catch [IO.DirectoryNotFoundException] {
            $exists = $false
        }
        if ($exists) {
            throw 'Removal returned success but the worktree path still exists.'
        }
    }
}

try {
    try {
        # IsPathRooted alone accepts drive-relative/root-relative Windows paths.
        # Require a drive-qualified path or a UNC share before touching any file.
        if ($Receipt -notmatch '^(?:[A-Za-z]:[\\/]|[\\/]{2}[^\\/]+[\\/][^\\/]+(?:[\\/]|$))') {
            throw 'The operation receipt must have an absolute path.'
        }
        $Receipt = [IO.Path]::GetFullPath($Receipt)
        if ([IO.Directory]::Exists($Receipt)) {
            throw 'The operation receipt names a directory.'
        }
        if ([IO.File]::Exists($Receipt)) {
            # Validate an existing destination without truncating it.
            $existing = [IO.File]::Open($Receipt, [IO.FileMode]::Open,
                [IO.FileAccess]::Write, [IO.FileShare]::Read)
            $existing.Dispose()
        }
        $receiptTemporary = $Receipt + '.tmp.' + [Guid]::NewGuid().ToString('N')
        $receiptStream = [IO.File]::Open($receiptTemporary, [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write, [IO.FileShare]::None)
        # Exercise the actual write before any repository mutation, and retain
        # the reserved temporary file until completion is published atomically.
        $bytes = $encoding.GetBytes("73`n")
        $receiptStream.Write($bytes, 0, $bytes.Length)
        $receiptStream.Flush($true)
        $pidTemporary = $Receipt + '.pid.tmp.' + [Guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllText($pidTemporary, [string]$PID + "`n", $encoding)
        Publish-OperationFile -Temporary $pidTemporary -Destination ($Receipt + '.pid')
        $pidTemporary = $null
        $pidPublished = $true

        $status = 1
        if ($Mode -ceq 'create') {
            # Direct native execution: literal arguments, inherited terminal,
            # hook approval intact; no --yes, --no-hooks, or output redirection.
            & $Worktrunk -C $Repository switch --create --base $Option --no-cd $Target
            $status = $LASTEXITCODE
        } else {
            # Do not capture this function's output: that would capture Worktrunk.
            Invoke-WorktreeRemoval
        }
    } catch {
        if ($pidPublished) { $status = 1 }
        [Console]::Error.WriteLine($_.Exception.Message)
    } finally {
        if ($null -ne $receiptStream) {
            try {
                $bytes = $encoding.GetBytes([string]$status + "`n")
                $receiptStream.SetLength(0)
                $receiptStream.Position = 0
                $receiptStream.Write($bytes, 0, $bytes.Length)
                $receiptStream.Flush($true)
                $receiptStream.Dispose()
                $receiptStream = $null
                Publish-OperationFile -Temporary $receiptTemporary -Destination $Receipt
                $receiptTemporary = $null
            } catch {
                [Console]::Error.WriteLine('Cannot publish completion receipt at ' + $Receipt +
                    ' (command exit ' + $status + '): ' + $_.Exception.Message)
            }
        }
    }

    [Console]::WriteLine("`n" + $label + ' command completed; review output above')
    [Console]::WriteLine('Command exit status: ' + $status)
    # Publication precedes review, so Overseer can consume the result immediately.
    # Redirected stdin must never leave automated callers waiting for a keypress.
    try {
        if (-not [Console]::IsInputRedirected) {
            [Console]::Write("`nPress Enter when you have finished reviewing this output. ")
            [void][Console]::ReadLine()
        }
    } catch {
        # Losing the terminal during review must not change the command status.
    }
} finally {
    if ($null -ne $receiptStream) { $receiptStream.Dispose() }
    foreach ($temporary in @($receiptTemporary, $pidTemporary)) {
        if ($null -ne $temporary) {
            try { [IO.File]::Delete($temporary) } catch {}
        }
    }
    # Only after attempting publication: a missing PID and missing receipt means
    # Overseer must treat the helper as no longer running, not as still pending.
    if ($pidPublished) {
        try { [IO.File]::Delete($Receipt + '.pid') } catch {}
    }
}
exit $status

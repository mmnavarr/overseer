# Test-only driver for the real Explorer picker launched by folder-picker.ps1.
# No foreground focus, global keyboard input, or unrelated process windows are used.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][int]$OwnerPid,
    [Parameter(Mandatory = $true)][ValidateSet('select', 'cancel')][string]$Action,
    [string]$Folder,
    [int]$TimeoutSeconds = 20
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$clock = [Diagnostics.Stopwatch]::StartNew()
$pickerPid = 0
$dialog = [IntPtr]::Zero
$lastState = 'Driver initialization'

try {
    if ($OwnerPid -le 0) { throw 'OwnerPid must identify the isolated Tern GUI process.' }
    if ($TimeoutSeconds -le 0) { throw 'TimeoutSeconds must be positive.' }
    $deadline = [double]$TimeoutSeconds * 1000
    $targetFolder = $null
    if ($Action -eq 'select') {
        if ([string]::IsNullOrEmpty($Folder)) { throw 'select requires -Folder with an absolute, existing directory.' }
        $targetFolder = $Folder.Replace('/', '\')
        # IsPathRooted also accepts drive-relative paths; require a drive root or UNC root.
        if ($targetFolder -notmatch '^(?:[A-Za-z]:\\|\\\\[^\\]+\\[^\\]+(?:\\|$))') {
            throw "Folder must be absolute (drive-rooted or UNC): $Folder"
        }
        $targetFolder = [IO.Path]::GetFullPath($targetFolder)
    }

    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, WindowsBase, System.Management
    Add-Type -ReferencedAssemblies @(
        [System.ComponentModel.Win32Exception].Assembly.Location,
        [System.Management.ManagementObjectSearcher].Assembly.Location,
        [System.Windows.Point].Assembly.Location,
        [System.Windows.Automation.AutomationElement].Assembly.Location,
        [System.Windows.Automation.AutomationIdentifier].Assembly.Location
    ) -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Management;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Automation;

public static class OverseerE2EPickerWindows {
    public sealed class ProcessEntry {
        public uint Pid;
        public uint ParentPid;
        public long CreationTime;
        public string Name;
    }
    public sealed class WindowEntry {
        public IntPtr Handle;
        public uint Pid;
        public string Title;
        public string Class;
        public bool Enabled;
        public override string ToString() {
            return String.Format("HWND=0x{0:X} pid={1} class={2} enabled={3} title={4}",
                Handle.ToInt64(), Pid, Class, Enabled, Title);
        }
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct PROCESSENTRY32 {
        public uint dwSize, cntUsage, th32ProcessID;
        public UIntPtr th32DefaultHeapID;
        public uint th32ModuleID, cntThreads, th32ParentProcessID;
        public int pcPriClassBase;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }
    delegate bool EnumWindowsProc(IntPtr handle, IntPtr state);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool Process32FirstW(IntPtr snapshot, ref PROCESSENTRY32 entry);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool Process32NextW(IntPtr snapshot, ref PROCESSENTRY32 entry);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetProcessTimes(IntPtr process, out long creation, out long exit, out long kernel, out long user);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc callback, IntPtr state);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumWindowsProc callback, IntPtr state);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr handle, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr handle, StringBuilder text, int capacity);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr handle, StringBuilder text, int capacity);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr handle);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr handle);
    [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr handle);
    [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr dialog, int id);
    [DllImport("user32.dll")] static extern bool IsChild(IntPtr parent, IntPtr child);
    [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr handle);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "SendMessageTimeoutW")]
    static extern IntPtr SendText(IntPtr handle, uint message, UIntPtr wparam, string text, uint flags, uint timeout, out UIntPtr result);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "SendMessageTimeoutW")]
    static extern IntPtr ReadText(IntPtr handle, uint message, UIntPtr wparam, StringBuilder text, uint flags, uint timeout, out UIntPtr result);
    [DllImport("user32.dll", SetLastError = true)] static extern bool PostMessageW(IntPtr handle, uint message, UIntPtr wparam, IntPtr lparam);

    public static void RequireDirectory(string folder, int timeoutMs) {
        bool exists = false;
        var thread = new Thread(delegate() { exists = System.IO.Directory.Exists(folder); });
        thread.IsBackground = true;
        thread.Start();
        if (!thread.Join(timeoutMs)) throw new TimeoutException("Folder accessibility check timed out: " + folder);
        if (!exists) throw new InvalidOperationException("Folder does not exist or is inaccessible: " + folder);
    }
    public static string CommandLine(uint pid, int timeoutMs) {
        string command = null;
        Exception failure = null;
        var thread = new Thread(delegate() {
            try {
                using (var search = new ManagementObjectSearcher("SELECT CommandLine FROM Win32_Process WHERE ProcessId=" + pid)) {
                    search.Options.Timeout = TimeSpan.FromMilliseconds(timeoutMs);
                    using (var rows = search.Get()) {
                        foreach (ManagementObject row in rows) {
                            using (row) { command = row["CommandLine"] as string; }
                        }
                    }
                }
            } catch (Exception error) { failure = error; }
        });
        thread.IsBackground = true;
        thread.Start();
        // WMI providers do not always honor their own query timeout. The worker only reads
        // process metadata; this join enforces the driver's deadline even for a stuck provider.
        if (!thread.Join(timeoutMs)) throw new TimeoutException("Timed out reading descendant picker command line through WMI; check WMI availability and permissions");
        if (failure != null) throw new InvalidOperationException("Cannot read descendant picker command line through WMI; check process/WMI permissions", failure);
        return command;
    }

    public static ProcessEntry[] Processes() {
        IntPtr snapshot = CreateToolhelp32Snapshot(2, 0);
        if (snapshot == new IntPtr(-1)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot enumerate picker ancestry");
        try {
            var result = new List<ProcessEntry>();
            var entry = new PROCESSENTRY32();
            entry.dwSize = (uint)Marshal.SizeOf(entry);
            if (!Process32FirstW(snapshot, ref entry)) throw new Win32Exception(Marshal.GetLastWin32Error());
            do {
                result.Add(new ProcessEntry { Pid = entry.th32ProcessID, ParentPid = entry.th32ParentProcessID, Name = entry.szExeFile });
            } while (Process32NextW(snapshot, ref entry));
            return result.ToArray();
        } finally { CloseHandle(snapshot); }
    }
    // Creation timestamps prevent a recycled PID from granting permission to touch a window.
    public static long Birth(uint pid) {
        IntPtr process = OpenProcess(0x1000, false, pid);
        if (process == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot inspect process " + pid);
        try {
            long creation, exit, kernel, user;
            if (!GetProcessTimes(process, out creation, out exit, out kernel, out user)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return creation;
        } finally { CloseHandle(process); }
    }
    static string ClassName(IntPtr handle) {
        var text = new StringBuilder(256);
        GetClassNameW(handle, text, text.Capacity);
        return text.ToString();
    }
    public static uint WindowPid(IntPtr handle) {
        uint pid;
        GetWindowThreadProcessId(handle, out pid);
        return pid;
    }
    public static WindowEntry[] Windows(uint pid) {
        var result = new List<WindowEntry>();
        EnumWindows(delegate(IntPtr handle, IntPtr state) {
            if (WindowPid(handle) == pid && IsWindowVisible(handle)) {
                var title = new StringBuilder(1024);
                // External top-level captions are read from USER's cached text, not WM_GETTEXT.
                GetWindowTextW(handle, title, title.Capacity);
                result.Add(new WindowEntry { Handle = handle, Pid = pid, Title = title.ToString(), Class = ClassName(handle), Enabled = IsWindowEnabled(handle) });
            }
            return true;
        }, IntPtr.Zero);
        return result.ToArray();
    }
    public static void VerifyAutomationPid(IntPtr handle, uint expected, int timeoutMs) {
        Exception failure = null;
        int actual = 0;
        var thread = new Thread(delegate() {
            try { actual = AutomationElement.FromHandle(handle).Current.ProcessId; }
            catch (Exception error) { failure = error; }
        });
        thread.IsBackground = true;
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        if (!thread.Join(timeoutMs)) throw new TimeoutException("UI Automation did not expose the scoped picker within its deadline; check desktop/session and elevation permissions");
        if (failure != null) throw new InvalidOperationException("Cannot inspect picker through UI Automation; run Tern and this driver on the same interactive desktop and at the same integrity level", failure);
        if (actual != expected) throw new InvalidOperationException("UI Automation process ID did not match the descendant folder-picker.ps1 process");
    }
    public static IntPtr Control(IntPtr dialog, uint pid, int id) {
        IntPtr handle = GetDlgItem(dialog, id);
        if (handle == IntPtr.Zero) return handle;
        if (WindowPid(dialog) != pid || WindowPid(handle) != pid || !IsChild(dialog, handle))
            throw new InvalidOperationException("Native control is outside the scoped picker");
        return handle;
    }
    public static string Text(IntPtr handle, int timeoutMs) {
        var text = new StringBuilder(32768);
        UIntPtr result;
        if (ReadText(handle, 0x000D, new UIntPtr((uint)text.Capacity), text, 0x23, (uint)timeoutMs, out result) == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "WM_GETTEXT failed/timed out; the picker may be hung or blocked by elevation");
        return text.ToString();
    }
    public static void SetFolder(IntPtr dialog, uint pid, string folder, int timeoutMs) {
        IntPtr edit = Control(dialog, pid, 1152);
        if (edit == IntPtr.Zero || !ClassName(edit).Equals("Edit", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Explorer folder edit control 1152 was not found (no geometry or global typing fallback is permitted)");
        if (!IsWindowVisible(edit) || !IsWindowEnabled(edit)) throw new InvalidOperationException("Explorer folder edit control is not available");
        UIntPtr result;
        if (SendText(edit, 0x000C, UIntPtr.Zero, folder, 0x23, (uint)timeoutMs, out result) == IntPtr.Zero || result == UIntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "WM_SETTEXT failed/timed out; check picker responsiveness and elevation permissions");
    }
    public static void Click(IntPtr dialog, uint pid, int id) {
        IntPtr button = Control(dialog, pid, id);
        if (button == IntPtr.Zero || !ClassName(button).Equals("Button", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Explorer native button " + id + " was not found");
        if (!IsWindowVisible(button) || !IsWindowEnabled(button)) throw new InvalidOperationException("Explorer button " + id + " is not available");
        // Never SendMessage(BM_CLICK): a modal validation warning would deadlock the caller.
        if (!PostMessageW(button, 0x00F5, UIntPtr.Zero, IntPtr.Zero))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot post native button click; check elevation permissions");
    }
    public static string Describe(IntPtr dialog, int budgetMs) {
        var result = new StringBuilder();
        var clock = Stopwatch.StartNew();
        int count = 0;
        EnumChildWindows(dialog, delegate(IntPtr handle, IntPtr state) {
            if (clock.ElapsedMilliseconds >= budgetMs || count >= 20) return false;
            if (!IsWindowVisible(handle)) return true;
            ++count;
            result.Append(" [id=").Append(GetDlgCtrlID(handle)).Append(" class=").Append(ClassName(handle)).Append(" text=");
            try { result.Append(Text(handle, Math.Max(1, Math.Min(50, budgetMs - (int)clock.ElapsedMilliseconds)))); }
            catch (Exception error) { result.Append(error.Message); }
            result.Append(']');
            return true;
        }, IntPtr.Zero);
        return result.ToString();
    }
}
'@

    function RemainingMs {
        $remaining = [int][Math]::Floor($deadline - $clock.Elapsed.TotalMilliseconds)
        if ($remaining -le 0) { throw "Timed out after $TimeoutSeconds seconds. Last state: $lastState" }
        return $remaining
    }
    function PauseForState {
        # Poll only for a concrete process/window/control state, within the shared deadline.
        Start-Sleep -Milliseconds ([Math]::Min(75, (RemainingMs)))
    }
    function DescendantPickerCandidates {
        $entries = [OverseerE2EPickerWindows]::Processes()
        $descendants = New-Object 'System.Collections.Generic.Dictionary[uint32,int64]'
        $descendants.Add([uint32]$OwnerPid, $ownerBirth)
        do {
            $changed = $false
            foreach ($entry in $entries) {
                if ($descendants.ContainsKey($entry.ParentPid) -and -not $descendants.ContainsKey($entry.Pid)) {
                    # Toolhelp parent IDs can outlive the original parent. Reject stale ancestry.
                    try { $entry.CreationTime = [OverseerE2EPickerWindows]::Birth($entry.Pid) }
                    catch { continue } # A process can disappear while taking the snapshot.
                    if ($entry.CreationTime -ge $descendants[$entry.ParentPid]) {
                        $descendants.Add($entry.Pid, $entry.CreationTime)
                        $changed = $true
                    }
                }
            }
        } while ($changed)
        @($entries | Where-Object {
            $_.Pid -ne $OwnerPid -and $descendants.ContainsKey($_.Pid) -and $_.Name -ieq 'powershell.exe'
        })
    }
    function AssertIdentity {
        if ([OverseerE2EPickerWindows]::Birth([uint32]$OwnerPid) -ne $ownerBirth) {
            throw 'OwnerPid was recycled; refusing to touch any picker.'
        }
        if ($pickerPid -ne 0) {
            if ([OverseerE2EPickerWindows]::Birth([uint32]$pickerPid) -ne $pickerBirth) {
                throw 'Picker PID was recycled; refusing to touch any window.'
            }
            if (-not (@(DescendantPickerCandidates | Where-Object { $_.Pid -eq $pickerPid }).Count)) {
                throw 'Picker is no longer a descendant of the isolated Tern owner; refusing interaction.'
            }
        }
    }
    function AssertNoModalWarning($windows) {
        $warnings = @($windows | Where-Object { $_.Class -eq '#32770' -and $_.Handle -ne $dialog })
        if ($warnings.Count -gt 0) {
            $script:lastState = "Unexpected picker warning/error: $($warnings -join '; ')"
            $details = foreach ($warning in $warnings) {
                $budget = [Math]::Min(500, (RemainingMs))
                "$warning $([OverseerE2EPickerWindows]::Describe($warning.Handle, $budget))"
            }
            throw "Picker opened an unexpected native warning/error dialog: $($details -join '; ')"
        }
    }

    if ($Action -eq 'select') {
        $lastState = "Checking literal folder accessibility: $targetFolder"
        [OverseerE2EPickerWindows]::RequireDirectory($targetFolder, (RemainingMs))
    }

    $ownerBirth = [OverseerE2EPickerWindows]::Birth([uint32]$OwnerPid)
    $lastState = "Awaiting descendant powershell.exe -File folder-picker.ps1 of owner $OwnerPid"
    while ($pickerPid -eq 0) {
        AssertIdentity
        $pickerMatches = @()
        foreach ($candidate in @(DescendantPickerCandidates)) {
            $commandLine = [OverseerE2EPickerWindows]::CommandLine($candidate.Pid, [Math]::Min(2000, (RemainingMs)))
            if ($null -eq $commandLine) { continue }
            if ([OverseerE2EPickerWindows]::Birth($candidate.Pid) -ne $candidate.CreationTime) {
                throw 'Candidate picker PID changed during command-line inspection; refusing interaction.'
            }
            # Match the -File argument, not incidental text elsewhere in a command line.
            if ($commandLine -match '(?i)(?:^|\s)-File\s+(?:"[^"\r\n]*[\\/]folder-picker\.ps1"|[^\s"]*[\\/]folder-picker\.ps1)(?:\s|$)') {
                $pickerMatches += $candidate
            }
        }
        if ($pickerMatches.Count -gt 1) { throw 'Multiple descendant folder-picker.ps1 processes found; refusing ambiguous interaction.' }
        if ($pickerMatches.Count -eq 1) {
            $pickerPid = [int]$pickerMatches[0].Pid
            $pickerBirth = $pickerMatches[0].CreationTime
            break
        }
        PauseForState
    }

    $lastState = "Awaiting Explorer folder dialog in picker pid=$pickerPid"
    while ($dialog -eq [IntPtr]::Zero) {
        [void](RemainingMs)
        AssertIdentity
        $windows = @([OverseerE2EPickerWindows]::Windows([uint32]$pickerPid))
        $pickers = @($windows | Where-Object {
            $_.Class -eq '#32770' -and $_.Title -ceq 'Choose a Git repository to add to Projects'
        })
        if ($pickers.Count -gt 1) { throw 'Multiple matching Explorer dialogs found in the picker; refusing ambiguous interaction.' }
        if ($pickers.Count -eq 1) {
            $dialog = $pickers[0].Handle
            [OverseerE2EPickerWindows]::VerifyAutomationPid($dialog, [uint32]$pickerPid, [Math]::Min(2000, (RemainingMs)))
            break
        }
        AssertNoModalWarning $windows
        $lastState = "Awaiting Explorer picker pid=$pickerPid; visible windows: $($windows -join '; ')"
        PauseForState
    }

    # Explorer can create the top-level HWND before its controls are ready.
    $buttonId = if ($Action -eq 'select') { 1 } else { 2 }
    $lastState = "Awaiting ready Explorer controls for $Action; pid=$pickerPid HWND=$dialog"
    while ($true) {
        [void](RemainingMs)
        AssertIdentity
        $windows = @([OverseerE2EPickerWindows]::Windows([uint32]$pickerPid))
        AssertNoModalWarning $windows
        if (-not [OverseerE2EPickerWindows]::IsWindow($dialog)) { throw 'Picker closed before the requested action.' }
        $button = [OverseerE2EPickerWindows]::Control($dialog, [uint32]$pickerPid, $buttonId)
        $edit = [OverseerE2EPickerWindows]::Control($dialog, [uint32]$pickerPid, 1152)
        $ready = [OverseerE2EPickerWindows]::IsWindowEnabled($dialog) -and $button -ne [IntPtr]::Zero -and
            [OverseerE2EPickerWindows]::IsWindowVisible($button)
        if ($Action -eq 'select') {
            $ready = $ready -and $edit -ne [IntPtr]::Zero -and
                [OverseerE2EPickerWindows]::IsWindowVisible($edit) -and [OverseerE2EPickerWindows]::IsWindowEnabled($edit)
        } else {
            $ready = $ready -and [OverseerE2EPickerWindows]::IsWindowEnabled($button)
        }
        if ($ready) { break }
        PauseForState
    }
    AssertIdentity
    if ($Action -eq 'select') {
        $lastState = "Setting literal folder in Explorer: $targetFolder"
        [OverseerE2EPickerWindows]::SetFolder($dialog, [uint32]$pickerPid, $targetFolder, [Math]::Min(1000, (RemainingMs)))
        $actual = [OverseerE2EPickerWindows]::Text($edit, [Math]::Min(1000, (RemainingMs)))
        if (-not [string]::Equals($actual, $targetFolder, [StringComparison]::Ordinal)) {
            throw "Explorer did not preserve the literal folder text. Expected: [$targetFolder]; actual: [$actual]"
        }
        $lastState = 'Awaiting enabled Add project button after setting the literal folder'
        while (-not [OverseerE2EPickerWindows]::IsWindowEnabled($button)) {
            [void](RemainingMs)
            AssertIdentity
            AssertNoModalWarning @([OverseerE2EPickerWindows]::Windows([uint32]$pickerPid))
            if (-not [OverseerE2EPickerWindows]::IsWindow($dialog)) { throw 'Picker closed before folder confirmation.' }
            PauseForState
        }
    }
    # Hold this exact process instance through exit, so a rapid Cancel -> Add
    # does not race the first picker's stdout/exit callback.
    $pickerProcess = [Diagnostics.Process]::GetProcessById($pickerPid)
    [void]$pickerProcess.Handle
    AssertIdentity
    [void](RemainingMs)
    [OverseerE2EPickerWindows]::Click($dialog, [uint32]$pickerPid, $buttonId)
    $lastState = "Awaiting Explorer dialog closure after $Action; pid=$pickerPid HWND=$dialog"
    while ($true) {
        [void](RemainingMs)
        # The picker process may exit immediately on closure; do not require it to survive.
        if (-not [OverseerE2EPickerWindows]::IsWindow($dialog)) { break }
        AssertIdentity
        $windows = @([OverseerE2EPickerWindows]::Windows([uint32]$pickerPid))
        AssertNoModalWarning $windows
        if ([OverseerE2EPickerWindows]::WindowPid($dialog) -ne $pickerPid) { throw 'Picker HWND was recycled before closure could be confirmed.' }
        $lastState = "Awaiting closure after $Action; visible windows: $($windows -join '; ')"
        PauseForState
    }
    $lastState = "Awaiting picker process exit after $Action; pid=$pickerPid"
    if (-not $pickerProcess.WaitForExit((RemainingMs))) { throw 'Picker dialog closed but its process did not exit.' }
    if ($pickerProcess.ExitCode -ne 0) { throw "Native picker process failed with exit code $($pickerProcess.ExitCode)." }
    $pickerProcess.Dispose()
    [Console]::WriteLine("Native Windows picker $Action completed; pid=$pickerPid dialog closed.")
    exit 0
} catch {
    [Console]::Error.WriteLine("Windows native picker driver failed: $($_.Exception.Message)")
    [Console]::Error.WriteLine("OwnerPid=$OwnerPid PickerPid=$pickerPid Action=$Action ElapsedMs=$([int]$clock.Elapsed.TotalMilliseconds) LastState=$lastState")
    [Console]::Error.WriteLine('Requires the same interactive Windows desktop and integrity level as the isolated Tern GUI. No unrelated dialogs were targeted; an unexpected picker warning is left open for test cleanup.')
    exit 1
}

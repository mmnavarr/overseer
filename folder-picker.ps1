param([Parameter(Mandatory = $true)][string]$StartFolder)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
# Windows PowerShell's FolderBrowserDialog is the legacy tree picker. Use the
# Explorer COM dialog instead, including its address bar and UNC navigation.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class OverseerFolderPicker {
    [ComImport, Guid("42F85136-DB7E-439C-85F1-E4075D135FC8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IFileDialog {
        [PreserveSig] int Show(IntPtr owner);
        void SetFileTypes(uint count, IntPtr filters);
        void SetFileTypeIndex(uint index);
        void GetFileTypeIndex(out uint index);
        void Advise(IntPtr events, out uint cookie);
        void Unadvise(uint cookie);
        void SetOptions(uint options);
        void GetOptions(out uint options);
        void SetDefaultFolder(IShellItem item);
        void SetFolder(IShellItem item);
        void GetFolder(out IShellItem item);
        void GetCurrentSelection(out IShellItem item);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetFileName(out IntPtr name);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string label);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string label);
        void GetResult(out IShellItem item);
    }

    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItem {
        void BindToHandler(IntPtr context, ref Guid handler, ref Guid iid, out IntPtr result);
        void GetParent(out IShellItem parent);
        void GetDisplayName(uint format, out IntPtr name);
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void SHCreateItemFromParsingName(string path, IntPtr context, ref Guid iid, out IShellItem item);

    public static string Choose(string startFolder) {
        var dialog = (IFileDialog)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7")));
        IShellItem start = null, result = null;
        IntPtr name = IntPtr.Zero;
        try {
            uint options;
            dialog.GetOptions(out options);
            // PICKFOLDERS | FORCEFILESYSTEM | PATHMUSTEXIST | NOCHANGEDIR.
            dialog.SetOptions(options | 0x20u | 0x40u | 0x800u | 0x8u);
            dialog.SetTitle("Choose a Git repository to add to Projects");
            dialog.SetOkButtonLabel("Add project");
            var iid = new Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE");
            SHCreateItemFromParsingName(startFolder, IntPtr.Zero, ref iid, out start);
            dialog.SetFolder(start);
            int status = dialog.Show(IntPtr.Zero);
            if (status == unchecked((int)0x800704C7)) return null; // User cancelled.
            Marshal.ThrowExceptionForHR(status);
            dialog.GetResult(out result);
            result.GetDisplayName(0x80058000u, out name); // SIGDN_FILESYSPATH.
            return Marshal.PtrToStringUni(name);
        } finally {
            if (name != IntPtr.Zero) Marshal.FreeCoTaskMem(name);
            if (result != null) Marshal.FinalReleaseComObject(result);
            if (start != null) Marshal.FinalReleaseComObject(start);
            Marshal.FinalReleaseComObject(dialog);
        }
    }
}
'@

$selected = [OverseerFolderPicker]::Choose([IO.Path]::GetFullPath($StartFolder.Replace('/', '\')))
if ($null -ne $selected) {
    [Console]::WriteLine($selected)
}

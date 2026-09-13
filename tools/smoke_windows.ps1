param([string]$Executable = "$PSScriptRoot/../build/windows/x64/runner/Release/fluent_gesture.exe")
$ErrorActionPreference = 'Stop'
$exe = (Resolve-Path -LiteralPath $Executable).Path
if (Get-Process fluent_gesture -ErrorAction SilentlyContinue) { throw 'Close existing FluentGesture instances before running the smoke test.' }
if (Get-ItemProperty -Path HKCU:\Software\Microsoft\Windows\CurrentVersion\Run -Name FluentGesture -ErrorAction SilentlyContinue) {
    throw 'Existing login-startup configuration found; smoke test will not modify it.'
}
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class GestureSmoke {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string name);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window, uint message, IntPtr wp, IntPtr lp);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll")] public static extern bool PostThreadMessage(uint thread, uint message, IntPtr wp, IntPtr lp);
    [StructLayout(LayoutKind.Sequential)] public struct Device { public IntPtr handle; public uint type; }
    [DllImport("user32.dll")] public static extern uint GetRawInputDeviceList([Out] Device[] list, ref uint count, uint size);
    [DllImport("user32.dll")] public static extern uint GetRawInputDeviceInfo(IntPtr handle, uint command, IntPtr data, ref uint size);
    public static int Touchpads() {
        uint count=0; uint stride=(uint)Marshal.SizeOf<Device>();
        if (GetRawInputDeviceList(null, ref count, stride)==uint.MaxValue) return -1;
        var list=new Device[count];
        if (GetRawInputDeviceList(list, ref count, stride)==uint.MaxValue) return -1;
        int pads=0; IntPtr info=Marshal.AllocHGlobal(32);
        try { foreach(var device in list) {
            if (device.type!=2) continue;
            uint size=32; Marshal.WriteInt32(info, 32);
            if (GetRawInputDeviceInfo(device.handle, 0x2000000b, info, ref size)!=uint.MaxValue && Marshal.ReadInt16(info,20)==13 && Marshal.ReadInt16(info,22)==5) pads++;
        }} finally { Marshal.FreeHGlobal(info); }
        return pads;
    }
}
"@
function Wait-Condition([scriptblock]$Condition, [string]$Label) {
    for ($attempt = 0; $attempt -lt 220; $attempt++) {
        if (& $Condition) { Write-Output "PASS: $Label"; return }
        Start-Sleep -Milliseconds 100
    }
    throw "FAIL: $Label"
}
$profileDir = Join-Path $PSScriptRoot '../build/smoke-profile'
New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
function Start-TestApp([bool]$HiddenStartup) {
    $start = [Diagnostics.ProcessStartInfo]::new($exe)
    $start.WorkingDirectory = Split-Path -Parent $exe
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $start.Environment['LOCALAPPDATA'] = (Resolve-Path -LiteralPath $profileDir).Path
    if ($HiddenStartup) { $start.ArgumentList.Add('--startup') }
    return [Diagnostics.Process]::Start($start)
}
$first = Start-TestApp $true
$window = [IntPtr]::Zero
try {
    Wait-Condition { $script:window = [GestureSmoke]::FindWindow('FLUTTER_RUNNER_WIN32_WINDOW', 'FluentGesture'); $script:window -ne [IntPtr]::Zero } 'native window created'
    $first.WaitForInputIdle(10000) | Out-Null
    Start-Sleep -Seconds 3
    if ([GestureSmoke]::IsWindowVisible($window)) { throw 'FAIL: --startup should stay hidden when tray is available' }
    Write-Output 'PASS: startup remains in tray'
    $second = Start-TestApp $false
    Wait-Condition { $second.HasExited } 'second launch exits'
    Write-Output "Second launch exit code: $($second.ExitCode); primary responding: $($first.Responding); window: $window"
    Wait-Condition { [GestureSmoke]::IsWindowVisible($window) } 'second launch opens existing window'
    [GestureSmoke]::PostMessage($window, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    Wait-Condition { -not [GestureSmoke]::IsWindowVisible($window) } 'close hides window'
    if ($first.HasExited) { throw 'FAIL: process exited after close' }
    Write-Output 'PASS: Flutter process stays alive after close'
    $third = Start-TestApp $false
    Wait-Condition { $third.HasExited -and [GestureSmoke]::IsWindowVisible($window) } 'reopen from another launch'
    # Invoke the same WM_COMMAND route used by the tray menu.
    # This does not emulate a physical click or use system SendInput.
    [GestureSmoke]::PostMessage($window, 0x111, [IntPtr]40003, [IntPtr]::Zero) | Out-Null
    Wait-Condition { $first.HasExited } 'tray Exit command ends application'
    Write-Output "Precision Touchpad Raw Input collections: $([GestureSmoke]::Touchpads())"
} finally {
    if (-not $first.HasExited) {
        [uint32]$processId = 0
        $thread = [GestureSmoke]::GetWindowThreadProcessId($window, [ref]$processId)
        if ($processId -eq $first.Id) { [GestureSmoke]::PostThreadMessage($thread, 0x12, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null }
        $first.WaitForExit(5000) | Out-Null
    }
    $first.Dispose()
}

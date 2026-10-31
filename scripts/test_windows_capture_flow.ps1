param([Parameter(Mandatory=$true)][string]$ExecutablePath)
# Run in the interactive Windows desktop session with a freshly started client.
# Exercises the installed Flutter/native channel path, without saving screenshots.
$ErrorActionPreference='Stop'
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class CaptureFlow {
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string c,string t);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern void keybd_event(byte key,byte scan,uint flags,UIntPtr extra);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h,uint m,IntPtr w,IntPtr l);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int cmd);
 [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr h,int index);
}
'@
function Wait-Until([scriptblock]$Condition,[string]$Failure) {
 $timer=[Diagnostics.Stopwatch]::StartNew()
 do { if(& $Condition){return}; Start-Sleep -Milliseconds 50 } while($timer.Elapsed.TotalSeconds -lt 8)
 throw $Failure
}
$app=Get-Process ClipyClone | Where-Object Path -eq ([IO.Path]::GetFullPath($ExecutablePath)) | Select-Object -First 1
if(!$app -or $app.SessionId -ne (Get-Process -Id $PID).SessionId){throw 'Start the specified client in this desktop session first.'}
$h=[CaptureFlow]::FindWindow('FLUTTER_RUNNER_WIN32_WINDOW','ClipyClone')
[uint32]$owner=0
[CaptureFlow]::GetWindowThreadProcessId($h,[ref]$owner)|Out-Null
if($owner -ne $app.Id){throw 'Window does not belong to the specified executable.'}
for($i=0;$i -lt 3;$i++) {
 # Same native routing as the registered screenshot shortcut.
 [CaptureFlow]::PostMessage($h,0x312,[IntPtr]2,[IntPtr]::Zero)|Out-Null
 Wait-Until { [CaptureFlow]::IsWindowVisible([CaptureFlow]::FindWindow('ClipyCloneScreenshotOverlay','Clipy screenshot')) } 'Screenshot overlay never appeared.'
 $overlay=[CaptureFlow]::FindWindow('ClipyCloneScreenshotOverlay','Clipy screenshot')
 if([CaptureFlow]::IsWindowVisible($h)){throw 'Main window was not hidden before capture.'}
 [CaptureFlow]::SetForegroundWindow($overlay)|Out-Null
 [CaptureFlow]::keybd_event(27,0,0,[UIntPtr]::Zero)
 [CaptureFlow]::keybd_event(27,0,2,[UIntPtr]::Zero)
 Wait-Until { [CaptureFlow]::FindWindow('ClipyCloneScreenshotOverlay','Clipy screenshot') -eq [IntPtr]::Zero -and [CaptureFlow]::IsWindowVisible($h) } 'Cancel did not restore main window.'
 Start-Sleep -Milliseconds 300 # allow Dart to release its in-progress state
}
[CaptureFlow]::PostMessage($h,0x312,[IntPtr]1,[IntPtr]::Zero)|Out-Null
Wait-Until { ([CaptureFlow]::GetWindowLongPtr($h,-16).ToInt64() -band 0x00C00000) -eq 0 } 'Quick panel did not open.'
[CaptureFlow]::PostMessage($h,0x10,[IntPtr]::Zero,[IntPtr]::Zero)|Out-Null
Wait-Until { ([CaptureFlow]::GetWindowLongPtr($h,-16).ToInt64() -band 0x00C00000) -ne 0 } 'Quick panel did not restore normal window style.'
[CaptureFlow]::ShowWindow($h,9)|Out-Null
'PASS: real Flutter/native capture start/cancel x3; quick panel open/close; process alive'

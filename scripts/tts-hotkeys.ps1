<#
.SYNOPSIS
    Makes the keyboard's media transport keys drive Claude's speech.

.DESCRIPTION
    Play/Pause toggles, Next skips forward, Previous skips back. The keys only do
    this while speech is actually playing; at every other moment they are passed
    straight through, so Spotify, YouTube and everything else keep them.

        tts-hotkeys.ps1              start listening (blocks - launch it hidden)
        tts-hotkeys.ps1 -Stop        stop the listener
        tts-hotkeys.ps1 -Status      say whether it is running

    Scope, deliberately narrow: the hook looks at three virtual-key codes and
    ignores every other key without reading it. Nothing is recorded, stored or
    sent anywhere - the only thing it can do is write 'play', 'pause' or a
    number into two files in ~/.claude.

    Why a low-level hook rather than RegisterHotKey: media keys are delivered to
    applications as WM_APPCOMMAND, and RegisterHotKey cannot claim them or, more
    importantly, give them back. A WH_KEYBOARD_LL hook can decide per keypress
    whether to consume the key or let it through, which is the whole point -
    these keys belong to the user's music player most of the time.
#>
param(
    [switch]$Stop,
    [switch]$Status,
    [switch]$Trace,
    [int]$StepMs = 10000
)

# Same folder the player uses. These two processes talk to each other entirely
# through these files, so the paths have to agree exactly.
$StateRoot   = Join-Path $env:USERPROFILE '.claude\agent-speak'
if (-not (Test-Path -LiteralPath $StateRoot)) {
    New-Item -ItemType Directory -Force -Path $StateRoot -ErrorAction SilentlyContinue | Out-Null
}
$pidFile     = Join-Path $StateRoot '.tts.pid'
$ctlFile     = Join-Path $StateRoot '.tts.ctl'
$seekFile    = Join-Path $StateRoot '.tts.seek'
$selfPidFile = Join-Path $StateRoot '.tts.hotkeys.pid'

function Get-Listener {
    if (-not (Test-Path -LiteralPath $selfPidFile)) { return $null }
    $raw = ''
    try { $raw = (Get-Content -LiteralPath $selfPidFile -TotalCount 1 -ErrorAction Stop) } catch { return $null }
    if ($raw -notmatch '^\d+$') { return $null }
    $listenerPid = [int]$raw
    try {
        $p = Get-Process -Id $listenerPid -ErrorAction Stop
        # same guard the speech lock uses: a recycled PID must not look like a
        # running listener, and a listener that died must not look alive forever
        $cmd = ''
        try { $cmd = [string](Get-CimInstance Win32_Process -Filter "ProcessId = $listenerPid" -ErrorAction Stop).CommandLine } catch { }
        if ($cmd -and $cmd -notmatch 'tts-hotkeys\.ps1') { return $null }
        return $p
    } catch { return $null }
}

if ($Status) {
    if (Get-Listener) { Write-Output 'listening' } else { Write-Output 'not running' }
    exit 0
}

if ($Stop) {
    $p = Get-Listener
    if ($p) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $selfPidFile -Force -ErrorAction SilentlyContinue
        Write-Output 'stopped'
    } else {
        Remove-Item -LiteralPath $selfPidFile -Force -ErrorAction SilentlyContinue
        Write-Output 'not running'
    }
    exit 0
}

# already listening? a second hook would act on every keypress twice
$existing = Get-Listener
if ($existing) { Write-Output 'already listening'; exit 0 }

$source = @'
using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class TtsHotkeys
{
    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN     = 0x0100;
    private const int WM_KEYUP       = 0x0101;

    private const int VK_MEDIA_PLAY_PAUSE = 0xB3;
    private const int VK_MEDIA_NEXT_TRACK = 0xB0;
    private const int VK_MEDIA_PREV_TRACK = 0xB1;

    private delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    // Rooted on purpose. The delegate is handed to unmanaged code, which does not
    // count as a reference: without this field the GC collects it and the hook
    // starts throwing once the keyboard is used.
    private static HookProc _proc;
    private static IntPtr   _hook = IntPtr.Zero;

    private static string _pidFile;
    private static string _ctlFile;
    private static string _seekFile;
    private static int    _stepMs;
    private static string _traceFile;   // null unless -Trace; logs media keys only

    // Holding a key makes Windows repeat the key-down about 30 times a second.
    // Left alone that turns one held rewind into a hundred seeks: a real press
    // logged 110 repeats in two seconds, which is 1100 seconds of rewind and
    // pins the audio at the start. So repeats are tracked and handled per key.
    private static readonly System.Collections.Generic.Dictionary<int, bool> _down =
        new System.Collections.Generic.Dictionary<int, bool>();
    private static DateTime _lastSeek = DateTime.MinValue;
    private const int SEEK_REPEAT_MS = 400;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll")]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto)]
    private static extern IntPtr GetModuleHandle(string name);

    public static void Start(string pidFile, string ctlFile, string seekFile, int stepMs, string traceFile)
    {
        _pidFile   = pidFile;
        _ctlFile   = ctlFile;
        _seekFile  = seekFile;
        _stepMs    = stepMs;
        _traceFile = traceFile;

        _proc = Callback;
        _hook = SetWindowsHookEx(WH_KEYBOARD_LL, _proc, GetModuleHandle(null), 0);
        if (_hook == IntPtr.Zero) {
            throw new InvalidOperationException("SetWindowsHookEx failed: " + Marshal.GetLastWin32Error());
        }
        Trace("hook installed handle=" + _hook.ToInt64() + " apartment=" + System.Threading.Thread.CurrentThread.GetApartmentState());
        // A low-level hook is only called on a thread that pumps messages.
        Application.Run();
        UnhookWindowsHookEx(_hook);
    }

    private static IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            int msg = (int)wParam;
            if (msg == WM_KEYDOWN || msg == WM_KEYUP)
            {
                int vk = Marshal.ReadInt32(lParam);
                if (vk == VK_MEDIA_PLAY_PAUSE || vk == VK_MEDIA_NEXT_TRACK || vk == VK_MEDIA_PREV_TRACK)
                {
                    Trace("vk=" + vk + " msg=" + msg + " active=" + SpeechActive());
                    // Only claim the key while there is speech to control. Every
                    // other time it goes to whatever the user is really playing.
                    if (SpeechActive())
                    {
                        if (msg == WM_KEYUP)
                        {
                            _down[vk] = false;
                        }
                        else
                        {
                            bool repeat = _down.ContainsKey(vk) && _down[vk];
                            _down[vk] = true;
                            try
                            {
                                if (vk == VK_MEDIA_PLAY_PAUSE)
                                {
                                    // holding play/pause must not flap between
                                    // paused and playing thirty times a second
                                    if (!repeat) Toggle();
                                }
                                else
                                {
                                    // holding skip is a legitimate way to scan, so
                                    // repeats are allowed - just not at the key
                                    // repeat rate. One step per 400ms scans at a
                                    // usable speed instead of jumping to an end.
                                    DateTime now = DateTime.UtcNow;
                                    if (!repeat || (now - _lastSeek).TotalMilliseconds >= SEEK_REPEAT_MS)
                                    {
                                        _lastSeek = now;
                                        Seek(vk == VK_MEDIA_NEXT_TRACK ? _stepMs : -_stepMs);
                                    }
                                }
                            }
                            catch { }
                        }
                        // Swallow the key-up too. The media player would otherwise
                        // still see half the keystroke and act on it.
                        return (IntPtr)1;
                    }
                }
            }
        }
        return CallNextHookEx(_hook, nCode, wParam, lParam);
    }

    private static int _traceLines = 0;

    private static void Trace(string line)
    {
        // only ever called for the three media keys, so an ordinary keystroke can
        // never reach this file even with tracing on
        if (_traceFile == null) return;
        try
        {
            // Held keys repeat ~30 times a second, so an append-only trace grows
            // startlingly fast. Start over rather than fill a disk; tracing is a
            // diagnostic for the last few presses, not an audit trail.
            if (++_traceLines > 2000)
            {
                _traceLines = 0;
                File.WriteAllText(_traceFile, "");
            }
            File.AppendAllText(_traceFile, DateTime.Now.ToString("HH:mm:ss.fff") + " " + line + Environment.NewLine);
        }
        catch { }
    }

    private static bool SpeechActive()
    {
        try
        {
            if (!File.Exists(_pidFile)) return false;
            string[] parts = ReadFirstLine(_pidFile).Split('|');
            int id;
            if (parts.Length == 0 || !int.TryParse(parts[0], out id)) return false;
            Process.GetProcessById(id);   // throws when it is gone
            return true;
        }
        catch { return false; }
    }

    private static string ReadFirstLine(string path)
    {
        // shared read: the player may be writing this file at the same moment
        using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        using (StreamReader sr = new StreamReader(fs))
        {
            string line = sr.ReadLine();
            return line == null ? "" : line.Trim();
        }
    }

    private static void Write(string path, string value)
    {
        using (FileStream fs = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.ReadWrite))
        using (StreamWriter sw = new StreamWriter(fs))
        {
            sw.Write(value);
        }
    }

    private static void Toggle()
    {
        string state = "play";
        try { if (File.Exists(_ctlFile)) state = ReadFirstLine(_ctlFile).ToLowerInvariant(); }
        catch { }
        Write(_ctlFile, state == "pause" ? "play" : "pause");
    }

    private static void Seek(int deltaMs)
    {
        int pending = 0;
        try
        {
            if (File.Exists(_seekFile)) int.TryParse(ReadFirstLine(_seekFile), out pending);
        }
        catch { }
        // deltas add up, so pressing skip three times quickly skips three steps
        Write(_seekFile, (pending + deltaMs).ToString());
    }
}
'@

# Claim the pid file BEFORE the compile below, not after. Add-Type takes about
# five seconds to build the hook class, and a status check inside that window
# used to answer 'not running' for a listener that was starting perfectly well -
# which reads as a failure and invites a second listener to be started on top.
# If the compile or the hook install fails, the finally clause clears it again.
Set-Content -LiteralPath $selfPidFile -Value "$PID" -Encoding ascii
try {
    Add-Type -TypeDefinition $source -ReferencedAssemblies 'System.Windows.Forms' -ErrorAction Stop
    $traceFile = $null
    if ($Trace) { $traceFile = Join-Path $StateRoot 'hotkeys.log' }
    [TtsHotkeys]::Start($pidFile, $ctlFile, $seekFile, $StepMs, $traceFile)
} finally {
    Remove-Item -LiteralPath $selfPidFile -Force -ErrorAction SilentlyContinue
}

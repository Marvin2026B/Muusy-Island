param(
    [switch]$StartExpanded,
    [switch]$StartSettings
)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Web.Extensions
Add-Type -AssemblyName System.Runtime.WindowsRuntime
Add-Type -AssemblyName System.Drawing
Add-Type -Path (Join-Path $PSScriptRoot "DiscordPresenceClient.cs") -ReferencedAssemblies System.Web.Extensions

$nativeThumbnailAssembly = Join-Path $PSScriptRoot "NativeMediaThumbnail.dll"
if (Test-Path -LiteralPath $nativeThumbnailAssembly) {
    [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($nativeThumbnailAssembly)) | Out-Null
}

$null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType=WindowsRuntime]
$null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties, Windows.Media.Control, ContentType=WindowsRuntime]

Add-Type -ReferencedAssemblies System.Web.Extensions @"
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

public static class IslandBridge
{
    private static readonly ConcurrentDictionary<string, object> State = CreateInitialState();
    private static readonly ConcurrentQueue<Dictionary<string, object>> Commands =
        new ConcurrentQueue<Dictionary<string, object>>();
    private static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    private static TcpListener listener;
    private static long nextId = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    private const int MaxRequestBodyBytes = 65536;
    private const int MaxHeaderBytes = 16384;
    private const int MaxHeaderCount = 64;
    private const string BridgeHeaderName = "X-YMDI-Bridge";
    private const string BridgeHeaderValue = "1.5";
    private const string BodyCharsHeaderName = "X-YMDI-Body-Chars";

    private static ConcurrentDictionary<string, object> CreateInitialState()
    {
        var state = new ConcurrentDictionary<string, object>();
        state["title"] = "YouTube Music";
        state["artist"] = "Opera GX verbinden";
        state["cover"] = "";
        state["playing"] = false;
        state["current"] = 0.0;
        state["duration"] = 0.0;
        state["queue"] = new object[0];
        state["queueSelection"] = false;
        state["liked"] = 0;
        state["sourceName"] = "YouTube Music";
        state["sourceKey"] = "youtube";
        state["at"] = 0.0;
        return state;
    }

    public static void Start()
    {
        listener = new TcpListener(IPAddress.Loopback, 8765);
        listener.Start();
        var thread = new Thread(Loop) { IsBackground = true, Name = "MusicIslandBridge" };
        thread.Start();
    }

    public static void Stop()
    {
        try { if (listener != null) listener.Stop(); } catch { }
    }

    public static IDictionary<string, object> Snapshot()
    {
        return State.ToDictionary(entry => entry.Key, entry => entry.Value);
    }

    public static void Enqueue(string action)
    {
        if (action != "prev" && action != "play" && action != "next" &&
            action != "like" && action != "dislike") return;
        var command = new Dictionary<string, object>();
        command["id"] = Interlocked.Increment(ref nextId);
        command["action"] = action;
        Commands.Enqueue(command);
        Dictionary<string, object> ignored;
        while (Commands.Count > 20) Commands.TryDequeue(out ignored);
    }

    public static bool EnqueueQueue(string token)
    {
        if (token == null || !System.Text.RegularExpressions.Regex.IsMatch(token, @"\A[a-f0-9]{16}:[1-9][0-9]{0,8}\z"))
            return false;
        var command = new Dictionary<string, object>();
        command["id"] = Interlocked.Increment(ref nextId);
        command["action"] = "queue";
        command["queueToken"] = token;
        command["expiresAt"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + 5000;
        Commands.Enqueue(command);
        Dictionary<string, object> ignored;
        while (Commands.Count > 20) Commands.TryDequeue(out ignored);
        return true;
    }

    private static bool IsAllowedExtensionOrigin(string origin)
    {
        if (String.IsNullOrWhiteSpace(origin)) return false;
        Uri parsed;
        if (!Uri.TryCreate(origin, UriKind.Absolute, out parsed)) return false;
        return parsed.Scheme.Equals("chrome-extension", StringComparison.OrdinalIgnoreCase) ||
               parsed.Scheme.Equals("opera-extension", StringComparison.OrdinalIgnoreCase);
    }

    private static bool IsAllowedCoverUrl(object value)
    {
        var raw = Convert.ToString(value);
        if (String.IsNullOrWhiteSpace(raw) || raw.Length > 4096) return false;
        Uri parsed;
        if (!Uri.TryCreate(raw, UriKind.Absolute, out parsed) ||
            !parsed.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase))
            return false;

        var host = parsed.DnsSafeHost;
        return host.Equals("googleusercontent.com", StringComparison.OrdinalIgnoreCase) ||
               host.EndsWith(".googleusercontent.com", StringComparison.OrdinalIgnoreCase) ||
               host.Equals("ggpht.com", StringComparison.OrdinalIgnoreCase) ||
               host.EndsWith(".ggpht.com", StringComparison.OrdinalIgnoreCase) ||
               host.Equals("ytimg.com", StringComparison.OrdinalIgnoreCase) ||
               host.EndsWith(".ytimg.com", StringComparison.OrdinalIgnoreCase);
    }

    private static string StatusText(int status)
    {
        switch (status)
        {
            case 200: return "OK";
            case 204: return "No Content";
            case 400: return "Bad Request";
            case 403: return "Forbidden";
            case 404: return "Not Found";
            case 405: return "Method Not Allowed";
            case 413: return "Payload Too Large";
            case 431: return "Request Header Fields Too Large";
            default: return "Error";
        }
    }

    private static void WriteResponse(
        NetworkStream stream,
        int status,
        string body,
        string origin,
        bool allowExtensionCors,
        bool allowPrivateNetwork)
    {
        body = body ?? "";
        var bytes = Encoding.UTF8.GetBytes(body);
        var headers =
            "HTTP/1.1 " + status + " " + StatusText(status) + "\r\n" +
            "Content-Type: application/json; charset=utf-8\r\n" +
            "Cache-Control: no-store\r\n" +
            "X-Content-Type-Options: nosniff\r\n";

        if (allowExtensionCors && IsAllowedExtensionOrigin(origin))
        {
            headers +=
                "Access-Control-Allow-Origin: " + origin + "\r\n" +
                "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" +
                "Access-Control-Allow-Headers: Content-Type, " + BridgeHeaderName + ", " + BodyCharsHeaderName + "\r\n" +
                "Vary: Origin\r\n";
            if (allowPrivateNetwork)
                headers += "Access-Control-Allow-Private-Network: true\r\n";
        }

        headers +=
            "Content-Length: " + bytes.Length + "\r\n" +
            "Connection: close\r\n\r\n";
        var headerBytes = Encoding.ASCII.GetBytes(headers);
        stream.Write(headerBytes, 0, headerBytes.Length);
        if (bytes.Length > 0) stream.Write(bytes, 0, bytes.Length);
        stream.Flush();
    }

    private static void Loop()
    {
        while (listener != null)
        {
            TcpClient client;
            try { client = listener.AcceptTcpClient(); }
            catch { break; }
            client.ReceiveTimeout = 2500;
            client.SendTimeout = 2500;
            var acceptedClient = client;
            var worker = new Thread(delegate()
            {
                try { Handle(acceptedClient); }
                catch { try { acceptedClient.Close(); } catch { } }
            });
            worker.IsBackground = true;
            worker.Name = "MusicIslandRequest";
            worker.Start();
        }
    }

    private static void Handle(TcpClient client)
    {
        using (client)
        using (var stream = client.GetStream())
        using (var reader = new StreamReader(stream, Encoding.UTF8, false, 4096, true))
        {
            var requestLine = reader.ReadLine();
            if (String.IsNullOrWhiteSpace(requestLine)) return;
            var requestParts = requestLine.Split(' ');
            if (requestParts.Length < 2)
            {
                WriteResponse(stream, 400, "{\"error\":\"bad request\"}", "", false, false);
                return;
            }
            var method = requestParts[0].ToUpperInvariant();
            var target = requestParts[1];
            var path = target.Split('?')[0];
            var contentLength = 0;
            var headerBytesRead = 0;
            var headerCount = 0;
            var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            string line;
            while (!String.IsNullOrEmpty(line = reader.ReadLine()))
            {
                headerBytesRead += Encoding.UTF8.GetByteCount(line) + 2;
                headerCount++;
                if (headerBytesRead > MaxHeaderBytes || headerCount > MaxHeaderCount)
                {
                    WriteResponse(stream, 431, "{\"error\":\"headers too large\"}", "", false, false);
                    return;
                }
                var separator = line.IndexOf(':');
                if (separator <= 0) continue;
                var name = line.Substring(0, separator).Trim();
                var value = line.Substring(separator + 1).Trim();
                headers[name] = value;
            }

            string rawLength;
            if (headers.TryGetValue("Content-Length", out rawLength) &&
                (!Int32.TryParse(rawLength, out contentLength) || contentLength < 0))
            {
                WriteResponse(stream, 400, "{\"error\":\"invalid content length\"}", "", false, false);
                return;
            }
            if (contentLength > MaxRequestBodyBytes)
            {
                WriteResponse(stream, 413, "{\"error\":\"payload too large\"}", "", false, false);
                return;
            }

            string origin;
            headers.TryGetValue("Origin", out origin);
            var extensionOrigin = IsAllowedExtensionOrigin(origin);
            if (method == "OPTIONS")
            {
                string requestedHeaders;
                headers.TryGetValue("Access-Control-Request-Headers", out requestedHeaders);
                var requestsBridgeHeader =
                    !String.IsNullOrWhiteSpace(requestedHeaders) &&
                    requestedHeaders.IndexOf(BridgeHeaderName, StringComparison.OrdinalIgnoreCase) >= 0;
                string privateNetwork;
                headers.TryGetValue("Access-Control-Request-Private-Network", out privateNetwork);
                if (!extensionOrigin || !requestsBridgeHeader)
                {
                    WriteResponse(stream, 403, "{\"error\":\"forbidden\"}", "", false, false);
                    return;
                }
                WriteResponse(
                    stream,
                    204,
                    "",
                    origin,
                    true,
                    String.Equals(privateNetwork, "true", StringComparison.OrdinalIgnoreCase));
                return;
            }

            string bridgeHeader;
            headers.TryGetValue(BridgeHeaderName, out bridgeHeader);
            if (!String.Equals(bridgeHeader, BridgeHeaderValue, StringComparison.Ordinal) ||
                (!String.IsNullOrWhiteSpace(origin) && !extensionOrigin))
            {
                WriteResponse(stream, 403, "{\"error\":\"forbidden\"}", "", false, false);
                return;
            }

            var status = 200;
            var body = "{}";
            if (method == "POST" && path == "/state")
            {
                string rawBodyChars;
                int bodyChars;
                headers.TryGetValue(BodyCharsHeaderName, out rawBodyChars);
                if (contentLength == 0 ||
                    !Int32.TryParse(rawBodyChars, out bodyChars) ||
                    bodyChars <= 0 ||
                    bodyChars > MaxRequestBodyBytes ||
                    bodyChars > contentLength)
                {
                    WriteResponse(stream, 400, "{\"error\":\"invalid payload length\"}", origin, extensionOrigin, false);
                    return;
                }
                var buffer = new char[bodyChars];
                var read = 0;
                while (read < bodyChars)
                {
                    var count = reader.Read(buffer, read, bodyChars - read);
                    if (count <= 0) break;
                    read += count;
                }
                Dictionary<string, object> payload;
                try
                {
                    payload = Json.Deserialize<Dictionary<string, object>>(new string(buffer, 0, read));
                }
                catch
                {
                    WriteResponse(stream, 400, "{\"error\":\"invalid json\"}", origin, extensionOrigin, false);
                    return;
                }
                if (payload != null) foreach (var entry in payload)
                {
                    if (State.ContainsKey(entry.Key))
                    {
                        if (entry.Key == "cover" &&
                            !String.IsNullOrWhiteSpace(Convert.ToString(entry.Value)) &&
                            !IsAllowedCoverUrl(entry.Value))
                            continue;
                        State[entry.Key] = entry.Value;
                    }
                }
                body = "{\"ok\":true}";
            }
            else if (method == "GET" && path == "/state")
            {
                body = Json.Serialize(Snapshot());
            }
            else if (method == "GET" && path == "/commands")
            {
                long after = 0;
                var marker = target.IndexOf("after=");
                if (marker >= 0)
                {
                    var raw = target.Substring(marker + 6).Split('&')[0];
                    Int64.TryParse(raw, out after);
                }
                body = Json.Serialize(Commands.Where(command => Convert.ToInt64(command["id"]) > after).ToArray());
            }
            else if (path == "/state" || path == "/commands")
            {
                status = 405;
                body = "{\"error\":\"method not allowed\"}";
            }
            else
            {
                status = 404;
                body = "{\"error\":\"not found\"}";
            }

            WriteResponse(stream, status, body, origin, extensionOrigin, false);
        }
    }
}

public static class AppWindowBridge
{
    private delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr hWnd);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern int GetWindowTextLength(IntPtr hWnd);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool ShowWindowAsync(IntPtr hWnd, int command);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern void SwitchToThisWindow(IntPtr hWnd, bool altTab);

    public static bool FocusFirst(int[] processIds)
    {
        if (processIds == null || processIds.Length == 0) return false;
        var ids = new HashSet<int>(processIds);
        IntPtr target = IntPtr.Zero;

        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
        {
            uint processId;
            GetWindowThreadProcessId(hWnd, out processId);
            if (ids.Contains((int)processId) && IsWindowVisible(hWnd) && GetWindowTextLength(hWnd) > 0)
            {
                target = hWnd;
                return false;
            }
            return true;
        }, IntPtr.Zero);

        if (target == IntPtr.Zero) return false;
        ShowWindowAsync(target, 9);
        if (!SetForegroundWindow(target))
        {
            SwitchToThisWindow(target, true);
        }
        return true;
    }
}

public static class IslandSystemBridge
{
    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint modifiers, uint virtualKey);

    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
}

internal enum EDataFlow
{
    Render,
    Capture,
    All
}

internal enum ERole
{
    Console,
    Multimedia,
    Communications
}

[System.Runtime.InteropServices.ComImport]
[System.Runtime.InteropServices.Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
internal class MMDeviceEnumeratorComObject
{
}

[System.Runtime.InteropServices.ComImport]
[System.Runtime.InteropServices.Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
[System.Runtime.InteropServices.InterfaceType(System.Runtime.InteropServices.ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMMDeviceEnumerator
{
    int EnumAudioEndpoints(EDataFlow dataFlow, uint stateMask, out IntPtr devices);
    int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice device);
    int GetDevice(string id, out IMMDevice device);
    int RegisterEndpointNotificationCallback(IntPtr client);
    int UnregisterEndpointNotificationCallback(IntPtr client);
}

[System.Runtime.InteropServices.ComImport]
[System.Runtime.InteropServices.Guid("D666063F-1587-4E43-81F1-B948E807363F")]
[System.Runtime.InteropServices.InterfaceType(System.Runtime.InteropServices.ComInterfaceType.InterfaceIsIUnknown)]
internal interface IMMDevice
{
    int Activate(ref Guid interfaceId, uint classContext, IntPtr activationParameters,
        [System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.IUnknown)] out object interfacePointer);
    int OpenPropertyStore(uint access, out IntPtr properties);
    int GetId([System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] out string id);
    int GetState(out uint state);
}

[System.Runtime.InteropServices.ComImport]
[System.Runtime.InteropServices.Guid("5CDF2C82-841E-4546-9722-0CF74078229A")]
[System.Runtime.InteropServices.InterfaceType(System.Runtime.InteropServices.ComInterfaceType.InterfaceIsIUnknown)]
internal interface IAudioEndpointVolume
{
    int RegisterControlChangeNotify(IntPtr notify);
    int UnregisterControlChangeNotify(IntPtr notify);
    int GetChannelCount(out uint channelCount);
    int SetMasterVolumeLevel(float level, ref Guid eventContext);
    int SetMasterVolumeLevelScalar(float level, ref Guid eventContext);
    int GetMasterVolumeLevel(out float level);
    int GetMasterVolumeLevelScalar(out float level);
    int SetChannelVolumeLevel(uint channel, float level, ref Guid eventContext);
    int SetChannelVolumeLevelScalar(uint channel, float level, ref Guid eventContext);
    int GetChannelVolumeLevel(uint channel, out float level);
    int GetChannelVolumeLevelScalar(uint channel, out float level);
    int SetMute([System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)] bool mute, ref Guid eventContext);
    int GetMute(out bool mute);
    int GetVolumeStepInfo(out uint step, out uint stepCount);
    int VolumeStepUp(ref Guid eventContext);
    int VolumeStepDown(ref Guid eventContext);
    int QueryHardwareSupport(out uint hardwareSupportMask);
    int GetVolumeRange(out float minDecibels, out float maxDecibels, out float incrementDecibels);
}

public static class IslandAudioBridge
{
    public static int AdjustMasterVolume(float delta)
    {
        IMMDeviceEnumerator enumerator = null;
        IMMDevice device = null;
        object endpointObject = null;
        try
        {
            enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
            if (enumerator.GetDefaultAudioEndpoint(EDataFlow.Render, ERole.Multimedia, out device) != 0)
                return -1;

            var interfaceId = typeof(IAudioEndpointVolume).GUID;
            if (device.Activate(ref interfaceId, 23, IntPtr.Zero, out endpointObject) != 0)
                return -1;

            var endpoint = (IAudioEndpointVolume)endpointObject;
            float current;
            if (endpoint.GetMasterVolumeLevelScalar(out current) != 0) return -1;
            var target = Math.Max(0.0f, Math.Min(1.0f, current + delta));
            var context = Guid.Empty;
            if (endpoint.SetMasterVolumeLevelScalar(target, ref context) != 0) return -1;
            return (int)Math.Round(target * 100.0f);
        }
        finally
        {
            if (endpointObject != null && System.Runtime.InteropServices.Marshal.IsComObject(endpointObject))
                System.Runtime.InteropServices.Marshal.ReleaseComObject(endpointObject);
            if (device != null && System.Runtime.InteropServices.Marshal.IsComObject(device))
                System.Runtime.InteropServices.Marshal.ReleaseComObject(device);
            if (enumerator != null && System.Runtime.InteropServices.Marshal.IsComObject(enumerator))
                System.Runtime.InteropServices.Marshal.ReleaseComObject(enumerator);
        }
    }
}
"@

# Keep the frame path compiled and let WPF/DWM pace it to the display refresh.
Add-Type -ReferencedAssemblies PresentationFramework, PresentationCore, WindowsBase, System.Xaml @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;

// Read-only Core Audio session peaks. No microphone, loopback recording or audio rerouting.
public sealed class IslandAudioMeter : IDisposable
{
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    private class DeviceEnumeratorObject { }
    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface DeviceEnumerator
    {
        [PreserveSig] int EnumAudioEndpoints(int flow, uint mask, out DeviceCollection devices);
    }
    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface DeviceCollection
    {
        [PreserveSig] int GetCount(out uint count);
        [PreserveSig] int Item(uint index, out AudioDevice device);
    }
    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface AudioDevice
    {
        [PreserveSig] int Activate(ref Guid iid, uint context, IntPtr parameters,
            [MarshalAs(UnmanagedType.IUnknown)] out object result);
    }
    [ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface SessionManager
    {
        [PreserveSig] int GetAudioSessionControl(ref Guid id, uint flags, out IntPtr control);
        [PreserveSig] int GetSimpleAudioVolume(ref Guid id, uint flags, out IntPtr volume);
        [PreserveSig] int GetSessionEnumerator(out SessionEnumerator sessions);
    }
    [ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface SessionEnumerator
    {
        [PreserveSig] int GetCount(out int count);
        [PreserveSig] int GetSession(int index, [MarshalAs(UnmanagedType.IUnknown)] out object session);
    }
    [ComImport, Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface SessionControl
    {
        [PreserveSig] int GetState(out int state);
        [PreserveSig] int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string name);
        [PreserveSig] int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string name, ref Guid context);
        [PreserveSig] int GetIconPath([MarshalAs(UnmanagedType.LPWStr)] out string path);
        [PreserveSig] int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string path, ref Guid context);
        [PreserveSig] int GetGroupingParam(out Guid group);
        [PreserveSig] int SetGroupingParam(ref Guid group, ref Guid context);
        [PreserveSig] int RegisterAudioSessionNotification(IntPtr events);
        [PreserveSig] int UnregisterAudioSessionNotification(IntPtr events);
        [PreserveSig] int GetSessionIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetSessionInstanceIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string id);
        [PreserveSig] int GetProcessId(out uint processId);
    }
    [ComImport, Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface PeakMeter
    {
        [PreserveSig] int GetPeakValue(out float peak);
    }

    private readonly System.Threading.AutoResetEvent wake = new System.Threading.AutoResetEvent(false);
    private readonly System.Threading.Thread worker;
    private volatile bool enabled, stopping, available;
    private volatile float peak;
    private volatile string source = "youtube", lastError = "";
    public float Peak { get { return peak; } }
    public bool Available { get { return available; } }
    public string LastError { get { return lastError; } }

    public IslandAudioMeter()
    {
        worker = new System.Threading.Thread(ReadLevels) { IsBackground = true, Name = "IslandAudioMeter" };
        worker.SetApartmentState(System.Threading.ApartmentState.MTA);
        worker.Start();
    }
    public void SetSource(string value)
    {
        value = (value ?? "youtube").ToLowerInvariant();
        if (source == value || stopping) return;
        source = value; peak = 0; available = false; wake.Set();
    }
    public void SetEnabled(bool value)
    {
        if (enabled == value || stopping) return;
        enabled = value;
        if (!value) peak = 0;
        wake.Set();
    }
    private static bool Matches(string app, string process)
    {
        process = process.ToLowerInvariant();
        if (app.Contains("opera")) return process == "opera";
        if (app.Contains("chrome")) return process == "chrome";
        if (app.Contains("spotify")) return process == "spotify";
        if (app.Contains("vlc") || app.Contains("videolan")) return process == "vlc";
        if (app.Contains("edge")) return process == "msedge";
        return app == "youtube" && (process == "opera" || process == "chrome" ||
            process == "msedge" || process == "firefox" || process == "brave" || process == "vivaldi");
    }
    private static void Release(object value)
    {
        if (value != null && Marshal.IsComObject(value)) Marshal.ReleaseComObject(value);
    }
    private static void Clear(System.Collections.Generic.List<PeakMeter> meters)
    {
        foreach (var meter in meters) Release(meter);
        meters.Clear();
    }
    private static void FindMeters(string app, System.Collections.Generic.List<PeakMeter> meters)
    {
        DeviceEnumerator enumerator = null;
        DeviceCollection devices = null;
        try
        {
            enumerator = (DeviceEnumerator)new DeviceEnumeratorObject();
            Marshal.ThrowExceptionForHR(enumerator.EnumAudioEndpoints(0, 1, out devices));
            uint count;
            Marshal.ThrowExceptionForHR(devices.GetCount(out count));
            for (uint deviceIndex = 0; deviceIndex < count; deviceIndex++)
            {
                AudioDevice device = null;
                object managerObject = null;
                SessionEnumerator sessions = null;
                try
                {
                    if (devices.Item(deviceIndex, out device) < 0) continue;
                    var iid = typeof(SessionManager).GUID;
                    if (device.Activate(ref iid, 23, IntPtr.Zero, out managerObject) < 0) continue;
                    if (((SessionManager)managerObject).GetSessionEnumerator(out sessions) < 0) continue;
                    int sessionCount;
                    if (sessions.GetCount(out sessionCount) < 0) continue;
                    for (int index = 0; index < sessionCount; index++)
                    {
                        object session = null;
                        try
                        {
                            if (sessions.GetSession(index, out session) < 0) continue;
                            uint processId;
                            var control = session as SessionControl;
                            if (control == null || control.GetProcessId(out processId) < 0 || processId == 0) continue;
                            string processName;
                            try { using (var process = Process.GetProcessById((int)processId)) processName = process.ProcessName; }
                            catch (ArgumentException) { continue; } // Process ended during enumeration.
                            catch (System.ComponentModel.Win32Exception) { continue; }
                            if (!Matches(app, processName)) continue;
                            var meter = session as PeakMeter;
                            if (meter != null) { meters.Add(meter); session = null; } // Transfer this RCW to the list.
                        }
                        finally { Release(session); }
                    }
                }
                finally { Release(sessions); Release(managerObject); Release(device); }
            }
        }
        finally { Release(devices); Release(enumerator); }
    }
    private void ReadLevels()
    {
        var meters = new System.Collections.Generic.List<PeakMeter>();
        var clock = Stopwatch.StartNew();
        double nextScan = 0;
        string boundSource = "";
        try
        {
            while (!stopping)
            {
                if (!enabled)
                {
                    peak = 0; available = false; Clear(meters); nextScan = 0;
                    wake.WaitOne();
                    continue;
                }
                try
                {
                    if (boundSource != source || clock.Elapsed.TotalSeconds >= nextScan)
                    {
                        Clear(meters);
                        boundSource = source;
                        FindMeters(boundSource, meters);
                        nextScan = clock.Elapsed.TotalSeconds + 3;
                    }
                    float loudest = 0;
                    bool valid = false;
                    foreach (var meter in meters)
                    {
                        float value;
                        if (meter.GetPeakValue(out value) >= 0 && !Single.IsNaN(value))
                        {
                            loudest = Math.Max(loudest, value); valid = true;
                        }
                    }
                    available = valid;
                    peak = enabled ? Math.Max(0, Math.Min(1, loudest)) : 0;
                    lastError = "";
                }
                catch (Exception error)
                {
                    peak = 0; available = false; lastError = error.Message;
                    Clear(meters); nextScan = clock.Elapsed.TotalSeconds + 3;
                }
                // Sample often enough for the compact visualizer to follow short transients.
                wake.WaitOne(20);
            }
        }
        finally { Clear(meters); wake.Dispose(); }
    }
    public void Dispose()
    {
        if (stopping) return;
        stopping = true; enabled = false; peak = 0;
        wake.Set();
        worker.Join(500);
    }
}


// One composition callback; no polling timer or PowerShell work for idle/music frames.
public sealed class IslandAnimationDriver : IDisposable
{
    [StructLayout(LayoutKind.Sequential)]
    private struct NativePoint { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    private struct MonitorInfo { public int Size; public NativeRect Monitor, Work; public uint Flags; }
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out NativePoint point);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hwnd, out NativeRect rect);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr hwnd, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);
    [DllImport("user32.dll")] private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);

    // Exact damped spring solution: the feel is independent of 60/144/180/240 Hz.
    private struct Spring
    {
        public double Value, Velocity;
        public void Step(double target, double dt)
        {
            const double decay = 14.4; // frequency 24 rad/s, damping ratio .60
            const double oscillation = 19.2;
            double offset = Value - target;
            double b = (Velocity + decay * offset) / oscillation;
            double sin = Math.Sin(oscillation * dt), cos = Math.Cos(oscillation * dt);
            double envelope = Math.Exp(-decay * dt);
            Value = target + envelope * (offset * cos + b * sin);
            Velocity = envelope * (Velocity * cos - (decay * b + oscillation * offset) * sin);
        }
        public bool Settled(double tolerance)
        {
            return Math.Abs(Value) < tolerance && Math.Abs(Velocity) < tolerance * 24;
        }
    }

    private readonly Window window;
    private readonly FrameworkElement island, details;
    private readonly RectangleGeometry progressClip;
    private readonly TextBlock timeText;
    private readonly MatrixTransform jelly;
    private readonly ScaleTransform[] mini;
    private readonly IslandAudioMeter audio = new IslandAudioMeter();
    private readonly double[] audioHistory = new double[7];
    private int audioHead;
    private double lastAudioSample;
    private readonly Stopwatch clock = Stopwatch.StartNew();
    private Spring stretchX, stretchY, lagX, lagY;
    private bool subscribed, disposed, scriptFrames, playing, visualDirty, jellyActive;
    private double lastFrame, lastLeft, lastTop, velocityX, velocityY, current, duration, mediaAt;
    private TimeSpan lastRenderingTime = TimeSpan.MinValue;
    private int displayedSecond = -1;
    private IntPtr hwnd;
    private NativePoint pointerStart;
    private NativeRect windowStart;

    public event EventHandler ScriptFrame;
    public event EventHandler DragMoved;
    public event EventHandler DragEnded;
    public bool Dragging { get; private set; }
    public bool DragCancelled { get; private set; }
    public bool DragHasMoved { get; private set; }
    public bool IsRendering { get { return subscribed; } }
    public bool IsJellyActive { get { return jellyActive; } }
    public bool ScriptFrames
    {
        get { return scriptFrames; }
        set { scriptFrames = value; UpdateSubscription(); }
    }

    public IslandAnimationDriver(Window window, FrameworkElement island, MatrixTransform jelly,
        FrameworkElement details, FrameworkElement progress, TextBlock timeText,
        ScaleTransform[] mini)
    {
        this.window = window; this.island = island; this.jelly = jelly;
        this.details = details; this.timeText = timeText;
        progressClip = (RectangleGeometry)progress.Clip;
        this.mini = mini;
        window.PreviewMouseLeftButtonUp += OnMouseUp;
        window.LostMouseCapture += OnLostCapture;
        window.PreviewKeyDown += OnKeyDown;
        window.IsVisibleChanged += OnVisibilityChanged;
        window.Deactivated += OnDeactivated;
        window.StateChanged += OnStateChanged;
    }

    public void SetAudioSource(string source) { audio.SetSource(source); }

    private void UpdateSubscription()
    {
        audio.SetEnabled(!disposed && playing && window.IsVisible && window.WindowState != WindowState.Minimized);
        bool needed = !disposed && window.IsVisible && window.WindowState != WindowState.Minimized &&
            (Dragging || jellyActive || scriptFrames || playing || visualDirty);
        if (needed == subscribed) return;
        subscribed = needed;
        if (needed)
        {
            lastFrame = clock.Elapsed.TotalSeconds;
            lastRenderingTime = TimeSpan.MinValue;
            CompositionTarget.Rendering += OnRendering;
        }
        else CompositionTarget.Rendering -= OnRendering;
    }

    public void UpdateMedia(bool isPlaying, double position, double length, double reportedAt)
    {
        playing = isPlaying;
        duration = Math.Max(0, length);
        current = Math.Max(0, position);
        if (playing && reportedAt > 0)
            current += Math.Max(0, (DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - reportedAt) / 1000.0);
        mediaAt = clock.Elapsed.TotalSeconds;
        visualDirty = true;
        UpdateSubscription();
    }

    public bool BeginDrag()
    {
        if (disposed || Dragging || Mouse.LeftButton != MouseButtonState.Pressed) return false;
        hwnd = new WindowInteropHelper(window).Handle;
        if (!GetCursorPos(out pointerStart) || !GetWindowRect(hwnd, out windowStart)) return false;
        if (!Mouse.Capture(window, CaptureMode.Element)) return false;
        DragCancelled = false; DragHasMoved = false; Dragging = true;
        lastLeft = window.Left; lastTop = window.Top;
        velocityX = velocityY = 0;
        UpdateSubscription();
        return true;
    }

    private void MoveToCursor()
    {
        NativePoint point;
        if (!GetCursorPos(out point)) { EndDrag(true); return; }
        int dx = point.X - pointerStart.X, dy = point.Y - pointerStart.Y;
        if (!DragHasMoved && Math.Abs(dx) < SystemParameters.MinimumHorizontalDragDistance &&
            Math.Abs(dy) < SystemParameters.MinimumVerticalDragDistance) return;
        DragHasMoved = true;
        NativeRect bounds;
        if (!GetWindowRect(hwnd, out bounds)) { EndDrag(true); return; }
        int x = windowStart.Left + dx, y = windowStart.Top + dy;
        if (bounds.Left == x && bounds.Top == y) return;
        // One native move per composition frame, even with a 1000+ Hz mouse.
        if (!SetWindowPos(hwnd, IntPtr.Zero, x, y, 0, 0, 0x0015)) { EndDrag(true); return; }
        var moved = DragMoved;
        if (moved != null) moved(this, EventArgs.Empty);
    }

    public void EndDrag(bool cancelled)
    {
        if (!Dragging) return;
        Dragging = false;
        DragCancelled = cancelled;
        if (cancelled) SetWindowPos(hwnd, IntPtr.Zero, windowStart.Left, windowStart.Top, 0, 0, 0x0015);
        if (Mouse.Captured == window) Mouse.Capture(null);
        velocityX = velocityY = 0;
        stretchX = stretchY = lagX = lagY = new Spring();
        jellyActive = false;
        jelly.Matrix = Matrix.Identity;
        var ended = DragEnded;
        if (ended != null) ended(this, EventArgs.Empty);
        UpdateSubscription();
    }

    public Rect GetWorkArea()
    {
        var info = new MonitorInfo { Size = Marshal.SizeOf(typeof(MonitorInfo)) };
        if (hwnd != IntPtr.Zero && GetMonitorInfo(MonitorFromWindow(hwnd, 2), ref info))
        {
            var source = PresentationSource.FromVisual(window);
            if (source != null && source.CompositionTarget != null)
            {
                var toDip = source.CompositionTarget.TransformFromDevice;
                return new Rect(toDip.Transform(new Point(info.Work.Left, info.Work.Top)),
                    toDip.Transform(new Point(info.Work.Right, info.Work.Bottom)));
            }
        }
        return SystemParameters.WorkArea;
    }

    private void OnMouseUp(object sender, MouseButtonEventArgs e)
    {
        if (!Dragging) return;
        MoveToCursor();
        EndDrag(false);
        e.Handled = true;
    }
    private void OnLostCapture(object sender, MouseEventArgs e) { if (Dragging) EndDrag(true); }
    private void OnDeactivated(object sender, EventArgs e) { if (Dragging) EndDrag(true); }
    private void OnStateChanged(object sender, EventArgs e) { UpdateSubscription(); }
    private void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (Dragging && e.Key == Key.Escape) { EndDrag(true); e.Handled = true; }
    }
    private void OnVisibilityChanged(object sender, DependencyPropertyChangedEventArgs e)
    {
        if (!window.IsVisible && Dragging) EndDrag(true);
        UpdateSubscription();
    }

    private void OnRendering(object sender, EventArgs args)
    {
        var frame = (RenderingEventArgs)args;
        if (frame.RenderingTime == lastRenderingTime) return;
        lastRenderingTime = frame.RenderingTime;
        double now = clock.Elapsed.TotalSeconds;
        double dt = Math.Max(.0001, Math.Min(.05, now - lastFrame));
        lastFrame = now;
        if (Dragging)
        {
            if (Mouse.LeftButton != MouseButtonState.Pressed) EndDrag(false);
            else MoveToCursor();
        }
        if (scriptFrames)
        {
            var callback = ScriptFrame;
            if (callback != null) callback(this, args);
        }
        if (Dragging || jellyActive) UpdateJelly(dt);
        if (playing || visualDirty || scriptFrames) UpdateVisuals(now, dt);
        UpdateSubscription();
    }

    private void UpdateJelly(double dt)
    {
        double targetX = 0, targetY = 0, targetLagX = 0, targetLagY = 0;
        if (Dragging)
        {
            double follow = 1 - Math.Exp(-20 * dt);
            velocityX += ((window.Left - lastLeft) / dt - velocityX) * follow;
            velocityY += ((window.Top - lastTop) / dt - velocityY) * follow;
            lastLeft = window.Left; lastTop = window.Top;
            double x = Math.Abs(velocityX), y = Math.Abs(velocityY);
            double speed = Math.Sqrt(x * x + y * y);
            targetX = .17 * (x - .48 * y) / (speed + 320);
            targetY = .15 * (y - .48 * x) / (speed + 320);
            targetLagX = Math.Max(-12, Math.Min(12, -velocityX * .012));
            targetLagY = Math.Max(-6, Math.Min(6, -velocityY * .006));
        }
        stretchX.Step(targetX, dt); stretchY.Step(targetY, dt);
        lagX.Step(targetLagX, dt); lagY.Step(targetLagY, dt);
        jellyActive = !(stretchX.Settled(.00015) && stretchY.Settled(.00015) &&
            lagX.Settled(.025) && lagY.Settled(.025)) ||
            Math.Abs(targetX) + Math.Abs(targetY) + Math.Abs(targetLagX) + Math.Abs(targetLagY) > .0001;
        if (!jellyActive)
        {
            stretchX = stretchY = lagX = lagY = new Spring();
            jelly.Matrix = Matrix.Identity;
        }
        else
        {
            // Use the available padding as the spring stretches, including during a morph.
            var baseScale = (ScaleTransform)((TransformGroup)island.RenderTransform).Children[0];
            double width = Math.Max(1, island.ActualWidth * baseScale.ScaleX);
            double height = Math.Max(1, island.ActualHeight * baseScale.ScaleY);
            double sx = Math.Max(.8, Math.Min(1 + stretchX.Value, (window.ActualWidth - 4) / width));
            double sy = Math.Max(.8, Math.Min(1 + stretchY.Value, (window.ActualHeight - 4) / height));
            double extraX = (width * sx - island.ActualWidth) / 2;
            double extraY = (height * sy - island.ActualHeight) / 2;
            double side = (window.ActualWidth - island.ActualWidth) / 2;
            double top = island.VerticalAlignment == VerticalAlignment.Bottom ? window.ActualHeight - island.ActualHeight - 8 : 8;
            double bottom = window.ActualHeight - island.ActualHeight - top;
            double offsetX = Math.Max(extraX - side + 2, Math.Min(lagX.Value, side - extraX - 2));
            double offsetY = Math.Max(extraY - top + 2, Math.Min(lagY.Value, bottom - extraY - 2));
            jelly.Matrix = new Matrix(sx, 0, 0, sy, offsetX, offsetY);
        }
    }

    private void UpdateVisuals(double now, double dt)
    {
        bool settling = false;
        if (now - lastAudioSample >= 1.0 / 50)
        {
            lastAudioSample = now;
            audioHead = (audioHead + 1) % audioHistory.Length;
            double peak = playing ? Math.Max(0, Math.Min(1, audio.Peak)) : 0;
            audioHistory[audioHead] = peak < .0005 ? 0 : peak;
        }

        double minPeak = Double.MaxValue, maxPeak = 0;
        for (int i = 0; i < audioHistory.Length; i++)
        {
            double sample = audioHistory[i];
            if (sample <= .0005) continue;
            minPeak = Math.Min(minPeak, sample);
            maxPeak = Math.Max(maxPeak, sample);
        }
        double peakRange = maxPeak - (minPeak == Double.MaxValue ? 0 : minPeak);
        double rangeFloor = Math.Max(.01, maxPeak * .035);

        for (int bar = 0; bar < mini.Length; bar++)
        {
            // Each bar shows a recent sample of the actual media-session peak.
            double sample = playing ? audioHistory[(audioHead - bar + audioHistory.Length) % audioHistory.Length] : 0;
            double level = 0;
            if (sample > .0005)
            {
                level = peakRange > rangeFloor
                    ? Math.Max(0, Math.Min(1, (sample - minPeak) / peakRange))
                    : Math.Sqrt(sample);
            }
            double pulse = .5 + .5 * Math.Sin(now * 8.5 - bar * 1.15);
            double pulseStrength = maxPeak > .0005 ? .16 + .10 * Math.Sqrt(maxPeak) : .10;
            double target = playing ? Math.Min(.96, .08 + .43 * level + pulseStrength * pulse) : .07;
            double smoothing = 1 - Math.Exp(-dt * (target > mini[bar].ScaleY ? 46 : 18));
            double value = mini[bar].ScaleY + (target - mini[bar].ScaleY) * smoothing;
            if (Math.Abs(value - target) < .001) value = target;
            else settling = true;
            if (mini[bar].ScaleY != value) mini[bar].ScaleY = value;
        }
        if (details.Visibility == Visibility.Visible && details.Opacity > .01)
        {
            double position = Math.Min(duration, current + (playing ? now - mediaAt : 0));
            int second = (int)Math.Max(0, Math.Floor(position));
            if (second != displayedSecond)
            {
                timeText.Text = String.Format("{0}:{1:00}", second / 60, second % 60);
                displayedSecond = second;
            }
            double width = duration > 0 ? details.ActualWidth * position / duration : 0;
            // A clip changes drawing only; animating Width would rerun layout every frame.
            if (progressClip.Rect.Width != width) progressClip.Rect = new Rect(0, 0, width, 4);
        }
        visualDirty = settling;
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        audio.Dispose();
        Dragging = false;
        if (Mouse.Captured == window) Mouse.Capture(null);
        CompositionTarget.Rendering -= OnRendering;
        subscribed = false;
        window.PreviewMouseLeftButtonUp -= OnMouseUp;
        window.LostMouseCapture -= OnLostCapture;
        window.PreviewKeyDown -= OnKeyDown;
        window.IsVisibleChanged -= OnVisibilityChanged;
        window.Deactivated -= OnDeactivated;
        window.StateChanged -= OnStateChanged;
        ScriptFrame = DragMoved = DragEnded = null;
        jelly.Matrix = Matrix.Identity;
    }
}

'@

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="YouTube Music Island"
        Width="520" Height="430"
        WindowStyle="None" ResizeMode="NoResize"
        AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" Topmost="True"
        SnapsToDevicePixels="False" UseLayoutRounding="False"
        FontFamily="Bahnschrift"
        TextOptions.TextFormattingMode="Display"
        TextOptions.TextRenderingMode="ClearType"
        RenderOptions.EdgeMode="Unspecified">
  <Window.Resources>
    <Style x:Key="QueueSongStyle" TargetType="{x:Type Button}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#CFFFFFFF"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Padding" Value="5,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type Button}">
            <Grid x:Name="SongShell" Background="{TemplateBinding Background}" ClipToBounds="True">
              <Border x:Name="SongHighlight" CornerRadius="5" Background="#26FFFFFF"
                      BorderBrush="#16FFFFFF" BorderThickness="1" Opacity="0" IsHitTestVisible="False"/>
              <ContentPresenter x:Name="SongContent" Margin="{TemplateBinding Padding}"
                                HorizontalAlignment="Stretch" VerticalAlignment="Center">
                <ContentPresenter.RenderTransform><TranslateTransform X="0"/></ContentPresenter.RenderTransform>
              </ContentPresenter>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Foreground" Value="White"/>
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="SongHighlight" Storyboard.TargetProperty="Opacity"
                                       To="1" Duration="0:0:0.14">
                        <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                      </DoubleAnimation>
                      <DoubleAnimation Storyboard.TargetName="SongContent" Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)"
                                       To="3" Duration="0:0:0.18">
                        <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                      </DoubleAnimation>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="SongHighlight" Storyboard.TargetProperty="Opacity"
                                       To="0" Duration="0:0:0.18">
                        <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                      </DoubleAnimation>
                      <DoubleAnimation Storyboard.TargetName="SongContent" Storyboard.TargetProperty="(UIElement.RenderTransform).(TranslateTransform.X)"
                                       To="0" Duration="0:0:0.18">
                        <DoubleAnimation.EasingFunction><CubicEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction>
                      </DoubleAnimation>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="SongShell" Property="Background" Value="#20FFFFFF"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="SongHighlight" Property="Background" Value="#38FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="TransportButtonStyle" TargetType="{x:Type Button}">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Foreground" Value="#EFFFFFFF"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type Button}">
            <Border x:Name="ButtonShell"
                    Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="14">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="ButtonShell" Property="Background" Value="#16FFFFFF"/>
                <Setter TargetName="ButtonShell" Property="BorderBrush" Value="#20FFFFFF"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="ButtonShell" Property="Background" Value="#2AFFFFFF"/>
                <Setter TargetName="ButtonShell" Property="BorderBrush" Value="#38FFFFFF"/>
                <Setter Property="Opacity" Value="0.82"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.32"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="PrimaryTransportButtonStyle" TargetType="{x:Type Button}">
      <Setter Property="Background" Value="#12FFFFFF"/>
      <Setter Property="BorderBrush" Value="#24FFFFFF"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type Button}">
            <Border x:Name="ButtonShell"
                    Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="26">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="ButtonShell" Property="Background" Value="#20FFFFFF"/>
                <Setter TargetName="ButtonShell" Property="BorderBrush" Value="#42FFFFFF"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="ButtonShell" Property="Background" Value="#34FFFFFF"/>
                <Setter Property="Opacity" Value="0.82"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="AppDockButtonStyle" TargetType="{x:Type Button}">
      <Setter Property="Background" Value="#0CFFFFFF"/>
      <Setter Property="BorderBrush" Value="#18FFFFFF"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type Button}">
            <Border x:Name="ButtonShell"
                    Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="12">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="ButtonShell" Property="Background" Value="#1CFFFFFF"/>
                <Setter TargetName="ButtonShell" Property="BorderBrush" Value="#32FFFFFF"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="ButtonShell" Property="Background" Value="#30FFFFFF"/>
                <Setter Property="Opacity" Value="0.82"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.38"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Grid>
    <Border x:Name="Island" Width="352" Height="74"
            HorizontalAlignment="Center" VerticalAlignment="Top" Margin="0,8,0,0"
            CornerRadius="37" BorderThickness="1"
            BorderBrush="#32FFFFFF"
            SnapsToDevicePixels="True"
            RenderTransformOrigin="0.5,0.5">
      <Border.Background>
        <SolidColorBrush x:Name="IslandFill" Color="#DA08090D"/>
      </Border.Background>
      <Border.RenderTransform>
        <TransformGroup>
          <ScaleTransform x:Name="IslandScale" ScaleX="1" ScaleY="1"/>
          <MatrixTransform x:Name="IslandJelly"/>
        </TransformGroup>
      </Border.RenderTransform>
      <Border.Effect>
        <DropShadowEffect Color="#000000" BlurRadius="19" ShadowDepth="3"
                          Opacity="0.26" RenderingBias="Performance"/>
      </Border.Effect>
      <Grid ClipToBounds="True">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="74"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>

          <!-- compact row -->
          <Grid Grid.Row="0" Margin="13,12,15,12">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="50"/>
              <ColumnDefinition Width="13"/>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="40"/>
              <ColumnDefinition Width="14"/>
              <ColumnDefinition Width="14"/>
            </Grid.ColumnDefinitions>

            <Border x:Name="CoverBorder" Grid.Column="0" Width="50" Height="50"
                    CornerRadius="15" Background="#12FFFFFF"
                    BorderBrush="#1EFFFFFF" BorderThickness="1"
                    RenderTransformOrigin="0.5,0.5">
              <Border.RenderTransform>
                <TransformGroup>
                  <ScaleTransform x:Name="CoverTrackScale" ScaleX="1" ScaleY="1"/>
                  <TranslateTransform x:Name="CoverTrackOffset"/>
                </TransformGroup>
              </Border.RenderTransform>
              <Grid>
                <TextBlock x:Name="Note" Text="&#9835;"
                           FontSize="20" Foreground="#A8FFFFFF"
                           HorizontalAlignment="Center" VerticalAlignment="Center"/>
                <Border x:Name="CoverClip" CornerRadius="14" Margin="1">
                  <Border.Background>
                    <ImageBrush x:Name="Cover" Stretch="UniformToFill"
                                AlignmentX="Center" AlignmentY="Center"/>
                  </Border.Background>
                </Border>
              </Grid>
            </Border>

            <StackPanel x:Name="TrackMetadata" Grid.Column="2" VerticalAlignment="Center"
                        RenderTransformOrigin="0.5,0.5">
              <StackPanel.RenderTransform>
                <TranslateTransform x:Name="MetadataTrackOffset"/>
              </StackPanel.RenderTransform>
              <TextBlock x:Name="TitleText" Text="YouTube Music" Foreground="#F8FFFFFF"
                         FontSize="13.5" FontWeight="SemiBold"
                         TextTrimming="CharacterEllipsis"/>
              <TextBlock x:Name="ArtistText" Text="Opera GX verbinden" Foreground="#90FFFFFF"
                         FontSize="10.5" Margin="0,3,0,0"
                         TextTrimming="CharacterEllipsis"/>
            </StackPanel>

            <Grid Grid.Column="3" Width="40" Height="34" IsHitTestVisible="False">
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
                <Rectangle Width="2.6" Height="22" RadiusX="1.3" RadiusY="1.3"
                           Fill="#80FFFFFF" Margin="1.2,0" RenderTransformOrigin="0.5,0.5">
                  <Rectangle.RenderTransform><ScaleTransform x:Name="MiniVizScale1" ScaleY="0.28"/></Rectangle.RenderTransform>
                </Rectangle>
                <Rectangle Width="2.6" Height="22" RadiusX="1.3" RadiusY="1.3"
                           Fill="#A0FFFFFF" Margin="1.2,0" RenderTransformOrigin="0.5,0.5">
                  <Rectangle.RenderTransform><ScaleTransform x:Name="MiniVizScale2" ScaleY="0.38"/></Rectangle.RenderTransform>
                </Rectangle>
                <Rectangle Width="2.6" Height="22" RadiusX="1.3" RadiusY="1.3"
                           Fill="#C8FFFFFF" Margin="1.2,0" RenderTransformOrigin="0.5,0.5">
                  <Rectangle.RenderTransform><ScaleTransform x:Name="MiniVizScale3" ScaleY="0.52"/></Rectangle.RenderTransform>
                </Rectangle>
                <Rectangle Width="2.6" Height="22" RadiusX="1.3" RadiusY="1.3"
                           Fill="#F0FFFFFF" Margin="1.2,0" RenderTransformOrigin="0.5,0.5">
                  <Rectangle.RenderTransform><ScaleTransform x:Name="MiniVizScale4" ScaleY="0.68"/></Rectangle.RenderTransform>
                </Rectangle>
                <Rectangle Width="2.6" Height="22" RadiusX="1.3" RadiusY="1.3"
                           Fill="#C8FFFFFF" Margin="1.2,0" RenderTransformOrigin="0.5,0.5">
                  <Rectangle.RenderTransform><ScaleTransform x:Name="MiniVizScale5" ScaleY="0.44"/></Rectangle.RenderTransform>
                </Rectangle>
                <Rectangle Width="2.6" Height="22" RadiusX="1.3" RadiusY="1.3"
                           Fill="#A0FFFFFF" Margin="1.2,0" RenderTransformOrigin="0.5,0.5">
                  <Rectangle.RenderTransform><ScaleTransform x:Name="MiniVizScale6" ScaleY="0.62"/></Rectangle.RenderTransform>
                </Rectangle>
                <Rectangle Width="2.6" Height="22" RadiusX="1.3" RadiusY="1.3"
                           Fill="#80FFFFFF" Margin="1.2,0" RenderTransformOrigin="0.5,0.5">
                  <Rectangle.RenderTransform><ScaleTransform x:Name="MiniVizScale7" ScaleY="0.48"/></Rectangle.RenderTransform>
                </Rectangle>
              </StackPanel>
            </Grid>

            <Path Grid.Column="5" Data="M 0,0 L 4,4 L 8,0" Stroke="#80FFFFFF"
                  StrokeThickness="1.5" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                  Width="8" Height="4" VerticalAlignment="Center" HorizontalAlignment="Center"
                  RenderTransformOrigin="0.5,0.5">
              <Path.RenderTransform>
                <RotateTransform x:Name="ChevronRotate" Angle="0"/>
              </Path.RenderTransform>
            </Path>
          </Grid>

          <!-- expanded details -->
          <Grid x:Name="Details" Grid.Row="1" Margin="24,2,24,22"
                Opacity="0" Visibility="Collapsed" IsHitTestVisible="False"
                RenderTransformOrigin="0.5,0.08">
            <Grid.RenderTransform>
              <ScaleTransform x:Name="DetailsScale" ScaleX="1" ScaleY="1"/>
            </Grid.RenderTransform>
            <Grid.RowDefinitions>
              <RowDefinition Height="4"/>
              <RowDefinition Height="18"/>
              <RowDefinition Height="60"/>
            <RowDefinition Height="46"/>
              <RowDefinition Height="84"/>
              <RowDefinition Height="58"/>
              <RowDefinition Height="18"/>
            </Grid.RowDefinitions>

            <Border Grid.Row="0" Height="4" Background="#1EFFFFFF" CornerRadius="2">
              <Border x:Name="ProgressFill" HorizontalAlignment="Stretch"
                      Background="#F2FFFFFF" CornerRadius="2">
                <Border.Clip><RectangleGeometry Rect="0,0,0,4" RadiusX="2" RadiusY="2"/></Border.Clip>
              </Border>
            </Border>

            <Grid Grid.Row="1">
              <TextBlock x:Name="CurrentText" Text="0:00" Foreground="#82FFFFFF"
                         FontSize="9.5" HorizontalAlignment="Left"/>
              <TextBlock x:Name="DurationText" Text="0:00" Foreground="#82FFFFFF"
                         FontSize="9.5" HorizontalAlignment="Right"/>
            </Grid>

            <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Center">
              <Button x:Name="PreviousButton" Width="52" Height="52"
                      Style="{StaticResource TransportButtonStyle}">
                <Grid Width="18" Height="18">
                  <Rectangle Width="2" Height="16" RadiusX="1" RadiusY="1"
                             Fill="#E8FFFFFF" HorizontalAlignment="Left" Margin="1,1,0,1"/>
                  <Path Data="M 16,1 L 5,9 L 16,17 Z" Fill="#E8FFFFFF"/>
                </Grid>
              </Button>
              <Button x:Name="MainPlay" Width="52" Height="52" Margin="20,0"
                      Style="{StaticResource PrimaryTransportButtonStyle}">
                <Path x:Name="MainPlayIcon" Data="M 1,0 L 11,7 L 1,14 Z"
                      Fill="#F4FFFFFF" Width="12" Height="14"/>
              </Button>
              <Button x:Name="NextButton" Width="52" Height="52"
                      Style="{StaticResource TransportButtonStyle}">
                <Grid Width="18" Height="18">
                  <Path Data="M 2,1 L 13,9 L 2,17 Z" Fill="#E8FFFFFF"/>
                  <Rectangle Width="2" Height="16" RadiusX="1" RadiusY="1"
                             Fill="#E8FFFFFF" HorizontalAlignment="Right" Margin="0,1,1,1"/>
                </Grid>
              </Button>
            </StackPanel>

            <Grid Grid.Row="3">
              <Button x:Name="LikeButton" Width="42" Height="42" HorizontalAlignment="Left"
                      Style="{StaticResource TransportButtonStyle}" ToolTip="Gef&#228;llt mir">
                <Grid Width="36" Height="36">
                  <Path x:Name="LikeSpark" Data="M 18,1 L 18,7 M 18,29 L 18,35 M 1,18 L 7,18 M 29,18 L 35,18 M 6,6 L 10,10 M 26,26 L 30,30 M 30,6 L 26,10 M 10,26 L 6,30"
                        Stroke="#FF68E38A" StrokeThickness="1.4" StrokeStartLineCap="Round"
                        StrokeEndLineCap="Round" Opacity="0" RenderTransformOrigin="0.5,0.5">
                    <Path.RenderTransform><ScaleTransform x:Name="LikeSparkScale" ScaleX="0.4" ScaleY="0.4"/></Path.RenderTransform>
                  </Path>
                  <Ellipse x:Name="LikePulseOuter" Width="28" Height="28" Stroke="#8868E38A"
                           StrokeThickness="1.2" Opacity="0" RenderTransformOrigin="0.5,0.5">
                    <Ellipse.RenderTransform><ScaleTransform x:Name="LikePulseOuterScale" ScaleX="0.4" ScaleY="0.4"/></Ellipse.RenderTransform>
                  </Ellipse>
                  <Ellipse x:Name="LikePulseInner" Width="22" Height="22" Stroke="#CC68E38A"
                           StrokeThickness="1.2" Opacity="0" RenderTransformOrigin="0.5,0.5">
                    <Ellipse.RenderTransform><ScaleTransform x:Name="LikePulseInnerScale" ScaleX="0.4" ScaleY="0.4"/></Ellipse.RenderTransform>
                  </Ellipse>
                  <Path x:Name="LikeIcon"
                        Data="M 7,17 H 3 V 8 H 7 M 7,8 L 11,2 C 12,2 13,3 13,4 V 7 H 18 C 19,7 19.5,8 19.2,9 L 17.5,16 C 17.3,16.7 16.7,17 16,17 H 7 Z"
                        Stroke="#B8FFFFFF" StrokeThickness="1.7" StrokeLineJoin="Round"
                        Width="20" Height="19" Stretch="Uniform" RenderTransformOrigin="0.5,0.5">
                    <Path.RenderTransform><ScaleTransform x:Name="LikeIconScale" ScaleX="1" ScaleY="1"/></Path.RenderTransform>
                  </Path>
                </Grid>
              </Button>

              <Button x:Name="DislikeButton" Width="36" Height="34" HorizontalAlignment="Right"
                      Style="{StaticResource TransportButtonStyle}" ToolTip="Gef&#228;llt mir nicht">
                <Path x:Name="DislikeIcon"
                      Data="M 7,17 H 3 V 8 H 7 M 7,8 L 11,2 C 12,2 13,3 13,4 V 7 H 18 C 19,7 19.5,8 19.2,9 L 17.5,16 C 17.3,16.7 16.7,17 16,17 H 7 Z"
                      Stroke="#B8FFFFFF" StrokeThickness="1.5" StrokeLineJoin="Round"
                      Width="20" Height="19" Stretch="Uniform"
                      RenderTransformOrigin="0.5,0.5">
                  <Path.RenderTransform><ScaleTransform ScaleY="-1"/></Path.RenderTransform>
                </Path>
              </Button>
            </Grid>

            <Grid Grid.Row="4" Margin="0,0,0,2">
              <Grid.RowDefinitions>
                <RowDefinition Height="16"/>
                <RowDefinition Height="22"/>
                <RowDefinition Height="22"/>
                <RowDefinition Height="22"/>
              </Grid.RowDefinitions>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="22"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="124"/>
              </Grid.ColumnDefinitions>

              <TextBlock Grid.Row="0" Grid.ColumnSpan="2" Text="Als N&#228;chstes"
                         Foreground="#72FFFFFF" FontSize="9.5" VerticalAlignment="Top"/>
              <TextBlock x:Name="QueueEmpty" Grid.Row="0" Grid.Column="2" Text="Queue wird geladen"
                         Foreground="#52FFFFFF" FontSize="9" TextAlignment="Right"
                         TextTrimming="CharacterEllipsis"/>

              <Button x:Name="QueueSong1" Grid.Row="1" Grid.ColumnSpan="3" IsEnabled="False"
                      Style="{StaticResource QueueSongStyle}" ToolTip="Song abspielen">
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="17"/><ColumnDefinition Width="*"/><ColumnDefinition Width="119"/></Grid.ColumnDefinitions>
                  <TextBlock Text="1" Opacity="0.45" FontSize="9.5" VerticalAlignment="Center"/>
                  <TextBlock x:Name="QueueTitle1" Grid.Column="1" FontSize="10.5" Margin="0,0,6,0"
                             VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                  <TextBlock x:Name="QueueArtist1" Grid.Column="2" Opacity="0.55" FontSize="9.5"
                             TextAlignment="Right" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                </Grid>
              </Button>

              <Button x:Name="QueueSong2" Grid.Row="2" Grid.ColumnSpan="3" IsEnabled="False"
                      Style="{StaticResource QueueSongStyle}" ToolTip="Song abspielen">
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="17"/><ColumnDefinition Width="*"/><ColumnDefinition Width="119"/></Grid.ColumnDefinitions>
                  <TextBlock Text="2" Opacity="0.45" FontSize="9.5" VerticalAlignment="Center"/>
                  <TextBlock x:Name="QueueTitle2" Grid.Column="1" FontSize="10.5" Margin="0,0,6,0"
                             VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                  <TextBlock x:Name="QueueArtist2" Grid.Column="2" Opacity="0.55" FontSize="9.5"
                             TextAlignment="Right" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                </Grid>
              </Button>

              <Button x:Name="QueueSong3" Grid.Row="3" Grid.ColumnSpan="3" IsEnabled="False"
                      Style="{StaticResource QueueSongStyle}" ToolTip="Song abspielen">
                <Grid>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="17"/><ColumnDefinition Width="*"/><ColumnDefinition Width="119"/></Grid.ColumnDefinitions>
                  <TextBlock Text="3" Opacity="0.45" FontSize="9.5" VerticalAlignment="Center"/>
                  <TextBlock x:Name="QueueTitle3" Grid.Column="1" FontSize="10.5" Margin="0,0,6,0"
                             VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                  <TextBlock x:Name="QueueArtist3" Grid.Column="2" Opacity="0.55" FontSize="9.5"
                             TextAlignment="Right" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
                </Grid>
              </Button>
            </Grid>

            <StackPanel Grid.Row="5" Orientation="Horizontal"
                        HorizontalAlignment="Center" VerticalAlignment="Center">
              <Button x:Name="AppButton1" Width="48" Height="48" Margin="3,0"
                      Style="{StaticResource AppDockButtonStyle}">
                <Grid Width="42" Height="42">
                  <Grid.RowDefinitions>
                    <RowDefinition Height="27"/>
                    <RowDefinition Height="15"/>
                  </Grid.RowDefinitions>
                  <Image x:Name="AppIcon1" Grid.Row="0" Width="19" Height="19"
                         HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  <TextBlock x:Name="AppLabel1" Grid.Row="1" Text="App 1" Width="40"
                             Foreground="#B8FFFFFF" FontSize="7.5" TextAlignment="Center"
                             TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
                </Grid>
              </Button>
              <Button x:Name="AppButton2" Width="48" Height="48" Margin="3,0"
                      Style="{StaticResource AppDockButtonStyle}">
                <Grid Width="42" Height="42">
                  <Grid.RowDefinitions>
                    <RowDefinition Height="27"/>
                    <RowDefinition Height="15"/>
                  </Grid.RowDefinitions>
                  <Image x:Name="AppIcon2" Grid.Row="0" Width="19" Height="19"
                         HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  <TextBlock x:Name="AppLabel2" Grid.Row="1" Text="App 2" Width="40"
                             Foreground="#B8FFFFFF" FontSize="7.5" TextAlignment="Center"
                             TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
                </Grid>
              </Button>
              <Button x:Name="AppButton3" Width="48" Height="48" Margin="3,0"
                      Style="{StaticResource AppDockButtonStyle}">
                <Grid Width="42" Height="42">
                  <Grid.RowDefinitions>
                    <RowDefinition Height="27"/>
                    <RowDefinition Height="15"/>
                  </Grid.RowDefinitions>
                  <Image x:Name="AppIcon3" Grid.Row="0" Width="19" Height="19"
                         HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  <TextBlock x:Name="AppLabel3" Grid.Row="1" Text="App 3" Width="40"
                             Foreground="#B8FFFFFF" FontSize="7.5" TextAlignment="Center"
                             TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
                </Grid>
              </Button>
              <Button x:Name="AppButton4" Width="48" Height="48" Margin="3,0"
                      Style="{StaticResource AppDockButtonStyle}">
                <Grid Width="42" Height="42">
                  <Grid.RowDefinitions>
                    <RowDefinition Height="27"/>
                    <RowDefinition Height="15"/>
                  </Grid.RowDefinitions>
                  <Image x:Name="AppIcon4" Grid.Row="0" Width="19" Height="19"
                         HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  <TextBlock x:Name="AppLabel4" Grid.Row="1" Text="App 4" Width="40"
                             Foreground="#B8FFFFFF" FontSize="7.5" TextAlignment="Center"
                             TextTrimming="CharacterEllipsis" VerticalAlignment="Center"/>
                </Grid>
              </Button>
              <Button x:Name="SettingsButton" Width="48" Height="48" Margin="7,0,3,0"
                      Style="{StaticResource AppDockButtonStyle}">
                <Grid Width="20" Height="20">
                  <Path Width="19" Height="19" Stretch="Uniform" Fill="Transparent" Stroke="#E8FFFFFF" StrokeThickness="1.5"
                      Data="M19.14,12.94a7.96,7.96 0 0 0 .06,-.94 7.96,7.96 0 0 0 -.06,-.94l2.03,-1.58a.5,.5 0 0 0 .12,-.64l-1.92,-3.32a.5,.5 0 0 0 -.61,-.22l-2.39,.96a7.28,7.28 0 0 0 -1.63,-.94l-.36,-2.54a.49,.49 0 0 0 -.5,-.42h-3.84a.49,.49 0 0 0 -.5,.42l-.36,2.54c-.6,.23-1.15,.55-1.63,.94l-2.39,-.96a.5,.5 0 0 0 -.61,.22L2.54,8.84a.5,.5 0 0 0 .12,.64l2.03,1.58a7.96,7.96 0 0 0 -.06,.94 7.96,7.96 0 0 0 .06,.94L2.66,14.52a.5,.5 0 0 0 -.12,.64l1.92,3.32a.5,.5 0 0 0 .61,.22l2.39,-.96c.48,.39 1.03,.71 1.63,.94l.36,2.54c.04,.24,.25,.42,.5,.42h3.84c.25,0 .46,-.18 .5,-.42l.36,-2.54c.6,-.23 1.15,-.55 1.63,-.94l2.39,.96a.5,.5 0 0 0 .61,-.22l1.92,-3.32a.5,.5 0 0 0 -.12,-.64l-2.03,-1.58z"/>
                  <Ellipse Width="7" Height="7" Stroke="#E8FFFFFF" StrokeThickness="1.5"/>
                </Grid>
              </Button>
            </StackPanel>

            <StackPanel Grid.Row="6" Orientation="Horizontal"
                        HorizontalAlignment="Center" VerticalAlignment="Bottom">
              <Ellipse x:Name="ConnectionDot" Width="5" Height="5"
                       Fill="#50FFFFFF" Margin="0,0,7,0"/>
              <TextBlock x:Name="ConnectionText" Text="Warte auf YouTube Music"
                         Foreground="#72FFFFFF" FontSize="9.5"/>
            </StackPanel>
          </Grid>
        </Grid>
      </Grid>
    </Border>
  </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)

[xml]$closeDropXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="104" Height="104"
        WindowStyle="None" ResizeMode="NoResize"
        AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" ShowActivated="False" Topmost="True"
        IsHitTestVisible="False" Focusable="False" Opacity="0"
        SnapsToDevicePixels="False" UseLayoutRounding="False">
  <Grid>
    <Border x:Name="CloseTargetShell"
            Width="68" Height="68" CornerRadius="34"
            BorderThickness="1"
            HorizontalAlignment="Center" VerticalAlignment="Center"
            RenderTransformOrigin="0.5,0.5">
      <Border.Background>
        <SolidColorBrush x:Name="CloseTargetFill" Color="#EC151518"/>
      </Border.Background>
      <Border.BorderBrush>
        <SolidColorBrush x:Name="CloseTargetBorder" Color="#34FFFFFF"/>
      </Border.BorderBrush>
      <Border.RenderTransform>
        <ScaleTransform x:Name="CloseTargetScale" ScaleX="0.88" ScaleY="0.88"/>
      </Border.RenderTransform>
      <Border.Effect>
        <DropShadowEffect Color="#000000" BlurRadius="12" ShadowDepth="4"
                          Opacity="0.32" RenderingBias="Performance"/>
      </Border.Effect>
      <Path Data="M 3,3 L 17,17 M 17,3 L 3,17"
            Width="20" Height="20" Stretch="None"
            StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
            HorizontalAlignment="Center" VerticalAlignment="Center">
        <Path.Stroke>
          <SolidColorBrush x:Name="CloseTargetGlyph" Color="#C8FFFFFF"/>
        </Path.Stroke>
      </Path>
    </Border>
  </Grid>
</Window>
"@

$closeDropReader = New-Object System.Xml.XmlNodeReader $closeDropXaml
$closeDropWindow = [System.Windows.Markup.XamlReader]::Load($closeDropReader)

$script:window          = $window
$script:island          = $window.FindName("Island")
$script:islandScale     = $window.FindName("IslandScale")
$script:details         = $window.FindName("Details")
$script:detailsScale    = $window.FindName("DetailsScale")
$script:cover           = $window.FindName("Cover")
$script:note            = $window.FindName("Note")
$script:titleText       = $window.FindName("TitleText")
$script:artistText      = $window.FindName("ArtistText")
$script:mainPlay        = $window.FindName("MainPlay")
$script:mainPlayIcon    = $window.FindName("MainPlayIcon")
$script:previousButton  = $window.FindName("PreviousButton")
$script:nextButton      = $window.FindName("NextButton")
$script:chevronRotate   = $window.FindName("ChevronRotate")
$script:progressFill    = $window.FindName("ProgressFill")
$script:currentText     = $window.FindName("CurrentText")
$script:durationText    = $window.FindName("DurationText")
$script:connectionText  = $window.FindName("ConnectionText")
$script:connectionDot   = $window.FindName("ConnectionDot")
$script:settingsButton  = $window.FindName("SettingsButton")
$script:likeButton      = $window.FindName("LikeButton")
$script:dislikeButton   = $window.FindName("DislikeButton")
$script:likeIcon        = $window.FindName("LikeIcon")
$script:likeIconScale   = $window.FindName("LikeIconScale")
$script:likeSpark       = $window.FindName("LikeSpark")
$script:likeSparkScale  = $window.FindName("LikeSparkScale")
$script:coverBorder     = $window.FindName("CoverBorder")
$script:coverTrackScale = $window.FindName("CoverTrackScale")
$script:coverTrackOffset = $window.FindName("CoverTrackOffset")
$script:trackMetadata   = $window.FindName("TrackMetadata")
$script:metadataTrackOffset = $window.FindName("MetadataTrackOffset")
$script:likePulseOuter  = $window.FindName("LikePulseOuter")
$script:likePulseOuterScale = $window.FindName("LikePulseOuterScale")
$script:likePulseInner  = $window.FindName("LikePulseInner")
$script:likePulseInnerScale = $window.FindName("LikePulseInnerScale")
$script:dislikeIcon     = $window.FindName("DislikeIcon")
$script:queueEmpty      = $window.FindName("QueueEmpty")
$script:queueButtons = @($window.FindName("QueueSong1"), $window.FindName("QueueSong2"), $window.FindName("QueueSong3"))
$script:queueTitles     = @(
    $window.FindName("QueueTitle1"),
    $window.FindName("QueueTitle2"),
    $window.FindName("QueueTitle3")
)
$script:queueArtists    = @(
    $window.FindName("QueueArtist1"),
    $window.FindName("QueueArtist2"),
    $window.FindName("QueueArtist3")
)
$script:appButtons      = @(
    $window.FindName("AppButton1"),
    $window.FindName("AppButton2"),
    $window.FindName("AppButton3"),
    $window.FindName("AppButton4")
)
$script:appIcons        = @(
    $window.FindName("AppIcon1"),
    $window.FindName("AppIcon2"),
    $window.FindName("AppIcon3"),
    $window.FindName("AppIcon4")
)
$script:appLabels       = @(
    $window.FindName("AppLabel1"),
    $window.FindName("AppLabel2"),
    $window.FindName("AppLabel3"),
    $window.FindName("AppLabel4")
)
$script:miniVizScales   = @(
    $window.FindName("MiniVizScale1"),
    $window.FindName("MiniVizScale2"),
    $window.FindName("MiniVizScale3"),
    $window.FindName("MiniVizScale4"),
    $window.FindName("MiniVizScale5"),
    $window.FindName("MiniVizScale6"),
    $window.FindName("MiniVizScale7")
)

function Start-TrackTransition([int]$direction) {
    if ($direction -ne -1) { $direction = 1 }
    $duration = [TimeSpan]::FromMilliseconds(320)
    $ease = [System.Windows.Media.Animation.CubicEase]::new()
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut

    foreach ($item in @(
        @{ element = $script:coverBorder; offset = $script:coverTrackOffset; scale = $script:coverTrackScale; delay = 0 },
        @{ element = $script:trackMetadata; offset = $script:metadataTrackOffset; scale = $null; delay = 45 }
    )) {
        $item.element.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
        $item.offset.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $null)
        $item.element.Opacity = 1.0
        $item.offset.X = 0.0

        $move = [System.Windows.Media.Animation.DoubleAnimation]::new(
            [double]($direction * 28), 0.0,
            [System.Windows.Media.Animation.Duration]::new($duration)
        )
        $move.EasingFunction = $ease
        $move.BeginTime = [TimeSpan]::FromMilliseconds([double]$item.delay)
        $fade = [System.Windows.Media.Animation.DoubleAnimation]::new(
            0.05, 1.0,
            [System.Windows.Media.Animation.Duration]::new($duration)
        )
        $fade.EasingFunction = $ease
        $fade.BeginTime = [TimeSpan]::FromMilliseconds([double]$item.delay)
        $item.offset.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $move)
        $item.element.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)

        if ($null -ne $item.scale) {
            $item.scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $null)
            $item.scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $null)
            $item.scale.ScaleX = 1.0
            $item.scale.ScaleY = 1.0
            $zoom = [System.Windows.Media.Animation.DoubleAnimation]::new(
                0.90, 1.0,
                [System.Windows.Media.Animation.Duration]::new($duration)
            )
            $zoom.EasingFunction = $ease
            $item.scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleXProperty, $zoom)
            $item.scale.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $zoom)
        }
    }
}

$script:closeDropWindow = $closeDropWindow
$script:closeTargetShell = $closeDropWindow.FindName("CloseTargetShell")
$script:closeTargetScale = $closeDropWindow.FindName("CloseTargetScale")
$script:closeTargetFill = $closeDropWindow.FindName("CloseTargetFill")
$script:closeTargetBorder = $closeDropWindow.FindName("CloseTargetBorder")
$script:closeTargetGlyph = $closeDropWindow.FindName("CloseTargetGlyph")

$script:connectedBrush = [System.Windows.Media.SolidColorBrush]::new(
    [System.Windows.Media.ColorConverter]::ConvertFromString("#FF68E38A")
)
$script:waitingBrush = [System.Windows.Media.SolidColorBrush]::new(
    [System.Windows.Media.ColorConverter]::ConvertFromString("#50FFFFFF")
)
$script:ratingIdleBrush = [System.Windows.Media.SolidColorBrush]::new(
    [System.Windows.Media.ColorConverter]::ConvertFromString("#B8FFFFFF")
)
$script:ratingLikeBrush = [System.Windows.Media.SolidColorBrush]::new(
    [System.Windows.Media.ColorConverter]::ConvertFromString("#FF68E38A")
)
$script:ratingDislikeBrush = [System.Windows.Media.SolidColorBrush]::new(
    [System.Windows.Media.ColorConverter]::ConvertFromString("#FFF27A7A")
)
$script:connectedBrush.Freeze()
$script:waitingBrush.Freeze()
$script:ratingIdleBrush.Freeze()
$script:ratingLikeBrush.Freeze()
$script:ratingDislikeBrush.Freeze()

$collapsedWidth  = 352.0
$collapsedHeight = 74.0
$expandedWidth   = 420.0
$expandedHeight  = 382.0
$collapsedRadius = 37.0
$expandedRadius  = 46.0

$script:expanded  = $false
$script:animating = $false
$script:likeAnimation = $null
$script:dragging = $false
$script:lastCoverKey = ""
$script:lastCoverTrack = ""
$script:lastTrackIdentity = ""
$script:trackTransitionReady = $false
$script:pendingTrackDirection = 0
$script:pendingTrackDirectionUntil = 0.0
$script:lastNativeCoverKey = ""
$script:lastNativeCoverAttemptAt = 0.0
$script:nativeCoverImage = $null
$script:playbackClockTrack = ""
$script:playbackClockPosition = 0.0
$script:playbackClockAt = 0.0
$script:playbackClockPlaying = $false
$script:lastNativeReportedPosition = -1.0
$script:lastDisplayedSecond = -1
$script:lastState = @{}
$script:activeMediaSource = "youtube"
$script:statusOverrideUntil = 0.0
$script:statusOverrideText = ""
$script:registeredHotkeyIds = @()
$script:mediaManager = $null
$script:hwndSource = $null
$script:hitTestHook = $null
$script:closeDropVisible = $false
$script:closeDropArmed = $false
$script:closeDropClosing = $false
$script:dragStartIslandCenterY = 0.0

function New-EasedDoubleAnimation([double]$to, [int]$milliseconds) {
    $animation = [System.Windows.Media.Animation.DoubleAnimation]::new()
    $animation.To = $to
    $animation.Duration = [System.Windows.Duration]::new(
        [TimeSpan]::FromMilliseconds($milliseconds)
    )
    $ease = [System.Windows.Media.Animation.CubicEase]::new()
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    $animation.EasingFunction = $ease
    return $animation
}

function Start-CloseTargetColorAnimation($brush, [string]$color, [int]$milliseconds = 100) {
    $animation = [System.Windows.Media.Animation.ColorAnimation]::new()
    $animation.To = [System.Windows.Media.ColorConverter]::ConvertFromString($color)
    $animation.Duration = [System.Windows.Duration]::new(
        [TimeSpan]::FromMilliseconds($milliseconds)
    )
    $ease = [System.Windows.Media.Animation.CubicEase]::new()
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    $animation.EasingFunction = $ease
    $brush.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $animation)
}

function Position-CloseDropTarget {
    $workArea = $script:animationDriver.GetWorkArea()
    $script:closeDropWindow.Left = $workArea.Left +
        (($workArea.Width - $script:closeDropWindow.Width) / 2.0)
    $script:closeDropWindow.Top = $workArea.Bottom -
        $script:closeDropWindow.Height - 24.0
}

function Set-CloseDropTargetVisible([bool]$visible) {
    if ($script:closeDropVisible -eq $visible) { return }
    $script:closeDropVisible = $visible

    if ($visible) {
        Position-CloseDropTarget
        if ($null -eq $script:closeDropWindow.Owner) {
            try { $script:closeDropWindow.Owner = $window } catch {}
        }
        $script:closeDropWindow.Opacity = 0.0
        $script:closeTargetScale.ScaleX = 0.88
        $script:closeTargetScale.ScaleY = 0.88
        if (-not $script:closeDropWindow.IsVisible) {
            $script:closeDropWindow.Show()
        }
        $script:closeDropWindow.BeginAnimation(
            [System.Windows.Window]::OpacityProperty,
            (New-EasedDoubleAnimation 1.0 130)
        )
        $script:closeTargetScale.BeginAnimation(
            [System.Windows.Media.ScaleTransform]::ScaleXProperty,
            (New-EasedDoubleAnimation 1.0 140)
        )
        $script:closeTargetScale.BeginAnimation(
            [System.Windows.Media.ScaleTransform]::ScaleYProperty,
            (New-EasedDoubleAnimation 1.0 140)
        )
        return
    }

    Set-CloseDropTargetArmed $false
    if (-not $script:closeDropWindow.IsVisible) { return }
    $fade = New-EasedDoubleAnimation 0.0 100
    $fade.Add_Completed({
        if (-not $script:closeDropVisible -and $script:closeDropWindow.IsVisible) {
            $script:closeDropWindow.Hide()
        }
    })
    $script:closeDropWindow.BeginAnimation(
        [System.Windows.Window]::OpacityProperty,
        $fade
    )
    $script:closeTargetScale.BeginAnimation(
        [System.Windows.Media.ScaleTransform]::ScaleXProperty,
        (New-EasedDoubleAnimation 0.90 100)
    )
    $script:closeTargetScale.BeginAnimation(
        [System.Windows.Media.ScaleTransform]::ScaleYProperty,
        (New-EasedDoubleAnimation 0.90 100)
    )
}

function Set-CloseDropTargetArmed([bool]$armed) {
    if ($script:closeDropArmed -eq $armed) { return }
    $script:closeDropArmed = $armed

    if ($armed) {
        Start-CloseTargetColorAnimation $script:closeTargetFill "#F0261719"
        Start-CloseTargetColorAnimation $script:closeTargetBorder "#78FF747A"
        Start-CloseTargetColorAnimation $script:closeTargetGlyph "#FFFFE6E7"
        $scale = 1.07
    } else {
        Start-CloseTargetColorAnimation $script:closeTargetFill "#EC151518"
        Start-CloseTargetColorAnimation $script:closeTargetBorder "#34FFFFFF"
        Start-CloseTargetColorAnimation $script:closeTargetGlyph "#C8FFFFFF"
        $scale = 1.0
    }

    $script:closeTargetScale.BeginAnimation(
        [System.Windows.Media.ScaleTransform]::ScaleXProperty,
        (New-EasedDoubleAnimation $scale 100)
    )
    $script:closeTargetScale.BeginAnimation(
        [System.Windows.Media.ScaleTransform]::ScaleYProperty,
        (New-EasedDoubleAnimation $scale 100)
    )
}

function Get-IslandScreenCenter {
    $islandTop = if (
        $script:island.VerticalAlignment -eq [System.Windows.VerticalAlignment]::Bottom
    ) {
        $window.ActualHeight - $script:island.ActualHeight - 8.0
    } else {
        8.0
    }
    return [System.Windows.Point]::new(
        $window.Left + ($window.ActualWidth / 2.0),
        $window.Top + $islandTop + ($script:island.ActualHeight / 2.0)
    )
}

function Update-CloseDropTarget {
    if (-not $script:dragging -or $script:closeDropClosing) { return }

    $workArea = $script:animationDriver.GetWorkArea()
    $center = Get-IslandScreenCenter
    $movedDown = $center.Y - $script:dragStartIslandCenterY
    $revealLine = $workArea.Top + ($workArea.Height * 0.42)
    $shouldShow = ($movedDown -ge 76.0 -or $center.Y -ge $revealLine)

    Set-CloseDropTargetVisible $shouldShow
    if (-not $shouldShow) { return }

    Position-CloseDropTarget
    $targetX = $script:closeDropWindow.Left + ($script:closeDropWindow.Width / 2.0)
    $targetY = $script:closeDropWindow.Top + ($script:closeDropWindow.Height / 2.0)
    $deltaX = $center.X - $targetX
    $deltaY = $center.Y - $targetY
    $inside = (($deltaX * $deltaX) + ($deltaY * $deltaY)) -le (82.0 * 82.0)
    Set-CloseDropTargetArmed $inside
}

function Invoke-CloseDropAnimation {
    if ($script:closeDropClosing) { return }
    $script:closeDropClosing = $true
    $window.IsHitTestVisible = $false
    Set-CloseDropTargetVisible $true
    Set-CloseDropTargetArmed $true

    $windowFade = New-EasedDoubleAnimation 0.0 125
    $windowFade.Add_Completed({
        if ($window.IsVisible) { $window.Close() }
    })
    $window.BeginAnimation(
        [System.Windows.Window]::OpacityProperty,
        $windowFade
    )
    $script:islandScale.BeginAnimation(
        [System.Windows.Media.ScaleTransform]::ScaleXProperty,
        (New-EasedDoubleAnimation 0.84 125)
    )
    $script:islandScale.BeginAnimation(
        [System.Windows.Media.ScaleTransform]::ScaleYProperty,
        (New-EasedDoubleAnimation 0.84 125)
    )
    $script:closeDropWindow.BeginAnimation(
        [System.Windows.Window]::OpacityProperty,
        (New-EasedDoubleAnimation 0.0 140)
    )
}

$script:winRtAsTask = [System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object {
        $_.Name -eq "AsTask" -and
        $_.IsGenericMethod -and
        $_.GetParameters().Count -eq 1
    } |
    Select-Object -First 1

function Wait-WinRtResult($operation, [Type]$resultType, [int]$timeoutMs = 2500) {
    if ($null -eq $operation -or $null -eq $script:winRtAsTask) {
        throw "Windows media operation is unavailable"
    }

    $task = $script:winRtAsTask.MakeGenericMethod($resultType).Invoke($null, @($operation))
    if (-not $task.Wait($timeoutMs)) {
        throw "Windows media operation timed out"
    }
    if ($task.IsFaulted) {
        throw $task.Exception
    }
    return $task.Result
}

function Initialize-NativeMedia {
    if ($null -ne $script:mediaManager) { return $true }
    try {
        $script:mediaManager = Wait-WinRtResult `
            ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) `
            ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
        return $null -ne $script:mediaManager
    } catch {
        $script:mediaManager = $null
        return $false
    }
}

function Get-MediaSourceInfo($session) {
    if ($null -eq $session) { return $null }
    $sourceId = [string]$session.SourceAppUserModelId
    if ($sourceId -match "(?i)(opera.?gx|operagx)") {
        return [pscustomobject]@{ session = $session; key = "youtube"; name = "Opera GX"; id = $sourceId }
    }
    if ($sourceId -match "(?i)opera") {
        return [pscustomobject]@{ session = $session; key = "youtube"; name = "Opera"; id = $sourceId }
    }
    if ($sourceId -match "(?i)(google.?chrome|chrome)") {
        return [pscustomobject]@{ session = $session; key = "youtube"; name = "Google Chrome"; id = $sourceId }
    }
    if ($sourceId -match "(?i)spotify") {
        return [pscustomobject]@{ session = $session; key = "spotify"; name = "Spotify"; id = $sourceId }
    }
    if ($sourceId -match "(?i)(videolan|vlc)") {
        return [pscustomobject]@{ session = $session; key = "vlc"; name = "VLC"; id = $sourceId }
    }
    return $null
}

function Test-MediaSourceEnabled([string]$key) {
    if ($null -eq $script:appSettings -or $null -eq $script:appSettings.sources) { return $true }
    $property = $script:appSettings.sources.PSObject.Properties[$key]
    if ($null -eq $property) { return $true }
    return [Convert]::ToBoolean($property.Value)
}

function Get-PreferredMediaSession {
    if (-not (Initialize-NativeMedia)) { return $null }

    try {
        $sessions = @($script:mediaManager.GetSessions())
        $candidates = @(
            foreach ($session in $sessions) {
                $info = Get-MediaSourceInfo $session
                if ($null -ne $info -and (Test-MediaSourceEnabled $info.key)) { $info }
            }
        )
        if ($candidates.Count -eq 0) { return $null }

        $currentSession = $script:mediaManager.GetCurrentSession()
        $currentInfo = Get-MediaSourceInfo $currentSession
        if ($null -ne $currentInfo -and -not (Test-MediaSourceEnabled $currentInfo.key)) {
            $currentInfo = $null
        }

        if ($null -ne $currentInfo) {
            try {
                if ([string]$currentInfo.session.GetPlaybackInfo().PlaybackStatus -eq "Playing") {
                    return $currentInfo
                }
            } catch {}
        }

        foreach ($candidate in $candidates) {
            try {
                if ([string]$candidate.session.GetPlaybackInfo().PlaybackStatus -eq "Playing") {
                    return $candidate
                }
            } catch {}
        }

        if ($null -ne $currentInfo) { return $currentInfo }
        return $candidates | Select-Object -First 1
    } catch {
        $script:mediaManager = $null
    }
    return $null
}

function Get-NativeThumbnailBitmap($properties, [string]$trackKey) {
    if ($trackKey -eq $script:lastNativeCoverKey) {
        if ($null -ne $script:nativeCoverImage) {
            return $script:nativeCoverImage
        }

        $retryAge = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $script:lastNativeCoverAttemptAt
        if ($retryAge -lt 1500) { return $null }
    } else {
        $script:lastNativeCoverKey = $trackKey
        $script:nativeCoverImage = $null
    }

    $script:lastNativeCoverAttemptAt = [double][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

    if ($null -eq $properties.Thumbnail -or $null -eq ("NativeMediaThumbnail" -as [type])) {
        return $null
    }

    try {
        [byte[]]$bytes = [NativeMediaThumbnail]::Read($properties.Thumbnail)
        if ($null -eq $bytes -or $bytes.Length -eq 0) { return $null }

        $memory = [IO.MemoryStream]::new($bytes)
        try {
            $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
            $bitmap.BeginInit()
            $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bitmap.StreamSource = $memory
            $bitmap.EndInit()
            $bitmap.Freeze()
            $script:nativeCoverImage = $bitmap
            return $bitmap
        } finally {
            $memory.Dispose()
        }
    } catch {
        return $null
    }
}

function Get-NativeMediaState {
    $sourceInfo = Get-PreferredMediaSession
    if ($null -eq $sourceInfo) { return $null }
    $session = $sourceInfo.session

    try {
        $properties = Wait-WinRtResult `
            ($session.TryGetMediaPropertiesAsync()) `
            ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
        $title = ([string]$properties.Title).Trim()
        if ([string]::IsNullOrWhiteSpace($title)) { return $null }

        $playback = $session.GetPlaybackInfo()
        $timeline = $session.GetTimelineProperties()
        $artist = ([string]$properties.Artist).Trim()
        if ([string]::IsNullOrWhiteSpace($artist)) { $artist = $sourceInfo.name }
        $trackKey = "$($sourceInfo.key)|$(Normalize-TrackTitle $title)|$(Normalize-TrackTitle $artist)"
        $nativeCover = Get-NativeThumbnailBitmap $properties $trackKey
        $playing = ([string]$playback.PlaybackStatus -eq "Playing")
        $duration = [Math]::Max(0.0, [double]$timeline.EndTime.TotalSeconds)
        $reportedPosition = [Math]::Max(0.0, [double]$timeline.Position.TotalSeconds)
        $now = [double][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $sameClockTrack = ($script:playbackClockTrack -eq $trackKey)
        $reportedChanged = (
            -not $sameClockTrack -or
            $script:lastNativeReportedPosition -lt 0 -or
            [Math]::Abs($reportedPosition - $script:lastNativeReportedPosition) -gt 0.25
        )

        if (-not $sameClockTrack -or $script:playbackClockAt -le 0) {
            $current = $reportedPosition
        } elseif (-not $playing) {
            $current = $reportedPosition
        } else {
            $expected = $script:playbackClockPosition + (($now - $script:playbackClockAt) / 1000.0)
            $reportedLooksLikeSeek = (
                $reportedChanged -and
                [Math]::Abs($reportedPosition - $expected) -gt 2.0 -and
                ($reportedPosition -gt 0.0 -or $expected -lt 4.0)
            )
            $current = if ($reportedLooksLikeSeek) { $reportedPosition } else { $expected }
        }

        if ($duration -gt 0) {
            $current = [Math]::Min($duration, $current)
        }
        $current = [Math]::Max(0.0, $current)

        $script:playbackClockTrack = $trackKey
        $script:playbackClockPosition = $current
        $script:playbackClockAt = $now
        $script:playbackClockPlaying = $playing
        $script:lastNativeReportedPosition = $reportedPosition

        return @{
            title    = $title
            artist   = $artist
            cover    = ""
            coverImage = $nativeCover
            playing  = $playing
            current  = $current
            duration = $duration
            at       = $now
            source   = "windows"
            sourceName = $sourceInfo.name
            sourceKey = $sourceInfo.key
            audioSource = $sourceInfo.id
            queue    = @()
            liked   = 0
        }
    } catch {
        return $null
    }
}

function Invoke-NativeMediaAction([string]$action) {
    $sourceInfo = Get-PreferredMediaSession
    if ($null -eq $sourceInfo) { return $false }
    $session = $sourceInfo.session

    try {
        $operation = switch ($action) {
            "play" { $session.TryTogglePlayPauseAsync() }
            "prev" { $session.TrySkipPreviousAsync() }
            "next" { $session.TrySkipNextAsync() }
            default { return $false }
        }
        return [bool](Wait-WinRtResult $operation ([bool]) 2500)
    } catch {
        return $false
    }
}

function Send-MediaAction([string]$action) {
    if ($action -eq "prev" -or $action -eq "next") {
        $script:pendingTrackDirection = if ($action -eq "prev") { -1 } else { 1 }
        $script:pendingTrackDirectionUntil = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + 8000
    }
    if (-not (Invoke-NativeMediaAction $action)) {
        [IslandBridge]::Enqueue($action)
    }
}

$script:settingsPath = Join-Path $PSScriptRoot "island-settings.json"
$script:settingsOpen = $false

function Get-DetectedExecutable([string]$processName, [string]$fallbackPath = "") {
    try {
        $candidate = Get-CimInstance Win32_Process -Filter "Name='$processName'" -ErrorAction Stop |
            Where-Object { $_.ExecutablePath } |
            Select-Object -ExpandProperty ExecutablePath -First 1
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    } catch {}

    $expandedFallback = [Environment]::ExpandEnvironmentVariables($fallbackPath)
    if ($expandedFallback -and (Test-Path -LiteralPath $expandedFallback)) {
        return $expandedFallback
    }
    return ""
}

function New-DefaultIslandSettings {
    $operaPath = Get-DetectedExecutable "opera.exe" "%LOCALAPPDATA%\Programs\Opera GX\opera.exe"
    $discordPath = Get-DetectedExecutable "Discord.exe"
    $explorerPath = Join-Path $env:WINDIR "explorer.exe"
    $notepadPath = Join-Path $env:WINDIR "System32\notepad.exe"

    return [pscustomobject]@{
        version = 2
        position = "TopCenter"
        size = "Standard"
        hotkeysEnabled = $true
        hotkeys = [pscustomobject]@{
            play = [pscustomobject]@{ modifiers = 3; key = 32 }
            previous = [pscustomobject]@{ modifiers = 3; key = 37 }
            next = [pscustomobject]@{ modifiers = 3; key = 39 }
            toggleIsland = [pscustomobject]@{ modifiers = 3; key = 73 }
        }
        autostart = $false
        discordApplicationId = ""
        customLeft = 0.0
        customTop = 0.0
        sources = [pscustomobject]@{
            youtube = $true
            spotify = $true
            vlc = $true
        }
        apps = @(
            [pscustomobject]@{ name = "Opera GX"; path = $operaPath },
            [pscustomobject]@{ name = "Discord"; path = $discordPath },
            [pscustomobject]@{ name = "Explorer"; path = $explorerPath },
            [pscustomobject]@{ name = "Notepad"; path = $notepadPath }
        )
    }
}

function Load-IslandSettings {
    $settings = New-DefaultIslandSettings
    if (Test-Path -LiteralPath $script:settingsPath) {
        try {
            $loaded = Get-Content -Raw -LiteralPath $script:settingsPath | ConvertFrom-Json
            $apps = @($loaded.apps)
            if ($apps.Count -eq 4) { $settings.apps = $apps }

            foreach ($name in @("position", "size", "hotkeysEnabled", "autostart", "customLeft", "customTop", "discordApplicationId")) {
                $property = $loaded.PSObject.Properties[$name]
                if ($null -ne $property) { $settings.$name = $property.Value }
            }

            if ($null -ne $loaded.hotkeys) {
                foreach ($action in @("play", "previous", "next", "toggleIsland")) {
                    $property = $loaded.hotkeys.PSObject.Properties[$action]
                    if ($null -ne $property -and $null -ne $property.Value) {
                        $settings.hotkeys.$action = $property.Value
                    }
                }
            }

            if ($null -ne $loaded.sources) {
                foreach ($sourceKey in @("youtube", "spotify", "vlc")) {
                    $property = $loaded.sources.PSObject.Properties[$sourceKey]
                    if ($null -ne $property) { $settings.sources.$sourceKey = $property.Value }
                }
            }
        } catch {}
    }
    return $settings
}

function Save-IslandSettings {
    $json = $script:appSettings | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText(
        $script:settingsPath,
        $json,
        [Text.UTF8Encoding]::new($false)
    )
}

function Set-IslandAutostart([bool]$enabled) {
    $runPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    $valueName = "YouTubeMusicDynamicIsland"
    if ($enabled) {
        $command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
            (Join-Path $PSScriptRoot "dynamic_island.ps1") + '"'
        New-ItemProperty -Path $runPath -Name $valueName -Value $command -PropertyType String -Force |
            Out-Null
    } else {
        Remove-ItemProperty -Path $runPath -Name $valueName -ErrorAction SilentlyContinue
    }
}

function Get-AppIconSource([string]$path) {
    $expandedPath = [Environment]::ExpandEnvironmentVariables($path)
    if (-not $expandedPath -or -not (Test-Path -LiteralPath $expandedPath)) { return $null }
    if ([IO.Path]::GetExtension($expandedPath) -ieq ".lnk") {
        try {
            $shell = New-Object -ComObject WScript.Shell
            $targetPath = [string]$shell.CreateShortcut($expandedPath).TargetPath
            if ($targetPath -and (Test-Path -LiteralPath $targetPath)) { $expandedPath = $targetPath }
        } catch {}
    }

    $icon = $null
    try {
        $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($expandedPath)
        if ($null -eq $icon) { return $null }
        $source = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
            $icon.Handle,
            [System.Windows.Int32Rect]::Empty,
            [System.Windows.Media.Imaging.BitmapSizeOptions]::FromWidthAndHeight(20, 20)
        )
        $source.Freeze()
        return $source
    } catch {
        return $null
    } finally {
        if ($null -ne $icon) { $icon.Dispose() }
    }
}

function Refresh-AppDock {
    $apps = @($script:appSettings.apps)
    for ($index = 0; $index -lt 4; $index++) {
        $entry = $apps[$index]
        $name = ([string]$entry.name).Trim()
        $path = [Environment]::ExpandEnvironmentVariables(([string]$entry.path).Trim())
        $exists = $path -and (Test-Path -LiteralPath $path)

        $script:appLabels[$index].Text = if ($name) { $name } else { "Setzen" }
        $script:appIcons[$index].Source = if ($exists) { Get-AppIconSource $path } else { $null }
        $script:appButtons[$index].Opacity = if ($exists) { 1.0 } else { 0.52 }
    }
}

function Open-OrFocusApp([int]$index) {
    $apps = @($script:appSettings.apps)
    if ($index -lt 0 -or $index -ge $apps.Count) { return }

    $entry = $apps[$index]
    $path = [Environment]::ExpandEnvironmentVariables(([string]$entry.path).Trim())
    if (-not $path -or -not (Test-Path -LiteralPath $path)) {
        Show-IslandSettings
        return
    }

    try {
        $launchPath = $path
        $launchArguments = ""
        $workingDirectory = [IO.Path]::GetDirectoryName($path)
        if ([IO.Path]::GetExtension($path) -ieq ".lnk") {
            try {
                $shell = New-Object -ComObject WScript.Shell
                $shortcut = $shell.CreateShortcut($path)
                if ($shortcut.TargetPath -and (Test-Path -LiteralPath $shortcut.TargetPath)) {
                    $launchPath = [string]$shortcut.TargetPath
                    $launchArguments = [string]$shortcut.Arguments
                    if ($shortcut.WorkingDirectory) { $workingDirectory = [string]$shortcut.WorkingDirectory }
                }
            } catch {}
        }
        $processName = [IO.Path]::GetFileNameWithoutExtension($launchPath)
        $processIds = @(
            Get-Process -Name $processName -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty Id
        )
        if ($processIds.Count -gt 0 -and [AppWindowBridge]::FocusFirst([int[]]$processIds)) {
            Start-IslandAnimation $false
            return
        }

        if ($launchArguments) {
            Start-Process -FilePath $launchPath -ArgumentList $launchArguments -WorkingDirectory $workingDirectory
        } else {
            Start-Process -FilePath $launchPath -WorkingDirectory $workingDirectory
        }
        Start-IslandAnimation $false
    } catch {}
}

function Select-AppExecutable($nameBox, $pathBox, $iconImage) {
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Title = "App fuer den Schnellzugriff auswaehlen"
    $dialog.Filter = "Apps und Verknuepfungen (*.exe;*.lnk)|*.exe;*.lnk|Programme (*.exe)|*.exe|Verknuepfungen (*.lnk)|*.lnk"
    $dialog.CheckFileExists = $true
    $dialog.Multiselect = $false
    $dialog.RestoreDirectory = $true
    if ($dialog.ShowDialog() -eq $true) {
        $pathBox.Text = $dialog.FileName
        $nameBox.Text = [IO.Path]::GetFileNameWithoutExtension($dialog.FileName)
        if ($null -ne $iconImage) { $iconImage.Source = Get-AppIconSource $dialog.FileName }
    }
}

function Format-IslandHotkey($hotkey) {
    $modifiers = [int]$hotkey.modifiers
    $parts = @()
    if ($modifiers -band 0x0002) { $parts += "Ctrl" }
    if ($modifiers -band 0x0001) { $parts += "Alt" }
    if ($modifiers -band 0x0004) { $parts += "Shift" }
    if ($modifiers -band 0x0008) { $parts += "Win" }
    $key = [System.Windows.Input.KeyInterop]::KeyFromVirtualKey([int]$hotkey.key)
    if ($key -eq [System.Windows.Input.Key]::Space) { $keyName = "Leertaste" }
    elseif ($key -eq [System.Windows.Input.Key]::Left) { $keyName = "Links" }
    elseif ($key -eq [System.Windows.Input.Key]::Right) { $keyName = "Rechts" }
    else { $keyName = $key.ToString() }
    $parts += $keyName
    return ($parts -join " + ")
}

function Show-IslandSettings {
    if ($script:settingsOpen) { return }
    $script:settingsOpen = $true

    [xml]$settingsXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Dynamic Island Einstellungen"
        Width="700" Height="620"
        WindowStyle="None" ResizeMode="NoResize"
        AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" Topmost="True"
        WindowStartupLocation="CenterScreen"
        FontFamily="Bahnschrift"
        TextOptions.TextRenderingMode="ClearType">
  <Window.Resources>
    <Style x:Key="SettingsButtonStyle" TargetType="{x:Type Button}">
      <Setter Property="Background" Value="#12FFFFFF"/>
      <Setter Property="BorderBrush" Value="#24FFFFFF"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Foreground" Value="#EFFFFFFF"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type Button}">
            <Border x:Name="Shell" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="10">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Shell" Property="Background" Value="#20FFFFFF"/>
                <Setter TargetName="Shell" Property="BorderBrush" Value="#40FFFFFF"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Shell" Property="Background" Value="#34FFFFFF"/>
                <Setter Property="Opacity" Value="0.84"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SettingsTextBoxStyle" TargetType="{x:Type TextBox}">
      <Setter Property="Background" Value="#0CFFFFFF"/>
      <Setter Property="Foreground" Value="#EFFFFFFF"/>
      <Setter Property="CaretBrush" Value="White"/>
      <Setter Property="BorderBrush" Value="#1EFFFFFF"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type TextBox}">
            <Border x:Name="Shell" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="9">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Shell" Property="BorderBrush" Value="#52FFFFFF"/>
                <Setter TargetName="Shell" Property="Background" Value="#14FFFFFF"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ChoiceStyle" TargetType="{x:Type RadioButton}">
      <Setter Property="Background" Value="#0CFFFFFF"/>
      <Setter Property="BorderBrush" Value="#1EFFFFFF"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Foreground" Value="#B8FFFFFF"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type RadioButton}">
            <Border x:Name="Shell" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="9"
                    Padding="10,8">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Shell" Property="Background" Value="#18FFFFFF"/>
                <Setter TargetName="Shell" Property="BorderBrush" Value="#32FFFFFF"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Shell" Property="Background" Value="#F0FFFFFF"/>
                <Setter TargetName="Shell" Property="BorderBrush" Value="#FFFFFFFF"/>
                <Setter Property="Foreground" Value="#FF09090B"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="TabStyle" TargetType="{x:Type RadioButton}">
      <Setter Property="Foreground" Value="#78FFFFFF"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type RadioButton}">
            <Grid Background="Transparent">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="16,0"/>
              <Border x:Name="Indicator" Height="2" Background="#F0FFFFFF"
                      VerticalAlignment="Bottom" Visibility="Collapsed"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Foreground" Value="#B8FFFFFF"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter Property="Foreground" Value="#F4FFFFFF"/>
                <Setter TargetName="Indicator" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ToggleStyle" TargetType="{x:Type CheckBox}">
      <Setter Property="Foreground" Value="#D8FFFFFF"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="{x:Type CheckBox}">
            <StackPanel Orientation="Horizontal">
              <Border x:Name="Box" Width="18" Height="18" CornerRadius="6"
                      Background="#0CFFFFFF" BorderBrush="#28FFFFFF" BorderThickness="1">
                <Path x:Name="Tick" Data="M 3,8 L 7,12 L 15,4" Stroke="#FF09090B"
                      StrokeThickness="2" StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                      Visibility="Collapsed"/>
              </Border>
              <ContentPresenter Margin="8,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Box" Property="BorderBrush" Value="#52FFFFFF"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Box" Property="Background" Value="#F0FFFFFF"/>
                <Setter TargetName="Box" Property="BorderBrush" Value="#FFFFFFFF"/>
                <Setter TargetName="Tick" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid Margin="14">
    <Border CornerRadius="22" BorderThickness="1" BorderBrush="#30FFFFFF" Background="#F20A0A0C">
      <Border.Effect>
        <DropShadowEffect Color="#000000" BlurRadius="28" ShadowDepth="8" Opacity="0.42"/>
      </Border.Effect>
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="68"/>
          <RowDefinition Height="48"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="66"/>
        </Grid.RowDefinitions>

        <Grid x:Name="SettingsHeader" Grid.Row="0" Margin="24,14,16,8">
          <StackPanel VerticalAlignment="Center">
            <TextBlock Text="Dynamic Island" Foreground="#F4FFFFFF" FontSize="17" FontWeight="SemiBold"/>
            <TextBlock Text="Einstellungen" Foreground="#78FFFFFF" FontSize="10" Margin="0,4,0,0"/>
          </StackPanel>
          <Button x:Name="CloseSettings" Width="36" Height="36" HorizontalAlignment="Right"
                  Style="{StaticResource SettingsButtonStyle}">
            <Path Data="M 3,3 L 13,13 M 13,3 L 3,13" Stroke="#D8FFFFFF" StrokeThickness="1.6"
                  StrokeStartLineCap="Round" StrokeEndLineCap="Round" Width="16" Height="16"/>
          </Button>
        </Grid>

        <Grid Grid.Row="1" Margin="24,0">
          <Border Height="1" Background="#18FFFFFF" VerticalAlignment="Bottom"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Left">
            <RadioButton x:Name="TabAppearance" GroupName="SettingsTabs" Content="Darstellung"
                         IsChecked="True" Style="{StaticResource TabStyle}"/>
            <RadioButton x:Name="TabPlayback" GroupName="SettingsTabs" Content="Wiedergabe"
                         Style="{StaticResource TabStyle}"/>
            <RadioButton x:Name="TabApps" GroupName="SettingsTabs" Content="Apps"
                         Style="{StaticResource TabStyle}"/>
          </StackPanel>
        </Grid>

        <Grid Grid.Row="2">
          <Grid x:Name="AppearancePanel" Margin="24,20,24,16">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <TextBlock Grid.Row="0" Text="Darstellung" Foreground="#F0FFFFFF"
                       FontSize="16" FontWeight="SemiBold"/>

            <TextBlock Grid.Row="1" Text="Bildschirmkante" Foreground="#A8FFFFFF"
                       FontSize="11" Margin="0,20,0,8"/>
            <UniformGrid Grid.Row="2" Rows="1" Columns="2">
              <RadioButton x:Name="EdgeTop" GroupName="Edge" Tag="Top" Content="Oben"
                           Margin="0,0,8,0" Style="{StaticResource ChoiceStyle}"/>
              <RadioButton x:Name="EdgeBottom" GroupName="Edge" Tag="Bottom" Content="Unten"
                           Style="{StaticResource ChoiceStyle}"/>
            </UniformGrid>

            <TextBlock Grid.Row="3" Text="Ausrichtung" Foreground="#A8FFFFFF"
                       FontSize="11" Margin="0,20,0,8"/>
            <UniformGrid Grid.Row="4" Rows="1" Columns="3">
              <RadioButton x:Name="AlignLeft" GroupName="Alignment" Tag="Left" Content="Links"
                           Margin="0,0,8,0" Style="{StaticResource ChoiceStyle}"/>
              <RadioButton x:Name="AlignCenter" GroupName="Alignment" Tag="Center" Content="Mittig"
                           Margin="0,0,8,0" Style="{StaticResource ChoiceStyle}"/>
              <RadioButton x:Name="AlignRight" GroupName="Alignment" Tag="Right" Content="Rechts"
                           Style="{StaticResource ChoiceStyle}"/>
            </UniformGrid>

            <StackPanel Grid.Row="5" Margin="0,20,0,0">
              <TextBlock Text="Breite" Foreground="#A8FFFFFF" FontSize="11" Margin="0,0,0,8"/>
              <UniformGrid Rows="1" Columns="3">
                <RadioButton x:Name="SizeCompact" GroupName="Size" Tag="Compact" Content="Schmal"
                             Margin="0,0,8,0" Style="{StaticResource ChoiceStyle}"/>
                <RadioButton x:Name="SizeStandard" GroupName="Size" Tag="Standard" Content="Standard"
                             Margin="0,0,8,0" Style="{StaticResource ChoiceStyle}"/>
                <RadioButton x:Name="SizeLarge" GroupName="Size" Tag="Large" Content="Breit"
                             Style="{StaticResource ChoiceStyle}"/>
              </UniformGrid>
            </StackPanel>

            <TextBlock x:Name="CustomPositionHint" Grid.Row="6"
                       Text="Die Island wurde frei verschoben. Eine Auswahl oben setzt sie wieder fest."
                       Foreground="#78FFFFFF" FontSize="10" Margin="0,16,0,0" Visibility="Collapsed"/>
          </Grid>

          <Grid x:Name="PlaybackPanel" Margin="24,20,24,16" Visibility="Collapsed">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="1"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <StackPanel Grid.Column="0" Margin="0,0,24,0">
              <TextBlock Text="Medienquellen" Foreground="#F0FFFFFF" FontSize="16" FontWeight="SemiBold"/>
              <CheckBox x:Name="SourceYouTube" Margin="0,20,0,0" Style="{StaticResource ToggleStyle}">
                <StackPanel>
                  <TextBlock Text="YouTube Music" Foreground="#E8FFFFFF" FontSize="11.5"/>
                  <TextBlock Text="Chrome, Opera und Opera GX" Foreground="#68FFFFFF" FontSize="9.5" Margin="0,3,0,0"/>
                </StackPanel>
              </CheckBox>
              <CheckBox x:Name="SourceSpotify" Margin="0,18,0,0" Style="{StaticResource ToggleStyle}">
                <StackPanel>
                  <TextBlock Text="Spotify" Foreground="#E8FFFFFF" FontSize="11.5"/>
                  <TextBlock Text="Windows-Mediensteuerung" Foreground="#68FFFFFF" FontSize="9.5" Margin="0,3,0,0"/>
                </StackPanel>
              </CheckBox>
              <CheckBox x:Name="SourceVlc" Margin="0,18,0,0" Style="{StaticResource ToggleStyle}">
                <StackPanel>
                  <TextBlock Text="VLC" Foreground="#E8FFFFFF" FontSize="11.5"/>
                  <TextBlock Text="Windows-Mediensteuerung" Foreground="#68FFFFFF" FontSize="9.5" Margin="0,3,0,0"/>
                </StackPanel>
              </CheckBox>
              <TextBlock Text="Discord Application ID" Foreground="#A8FFFFFF" FontSize="10.5" Margin="0,22,0,7"/>
              <TextBox x:Name="DiscordApplicationId" Height="34" Padding="10,6"
                       Style="{StaticResource SettingsTextBoxStyle}"/>
              <TextBlock Text="Developer Portal → General Information" Foreground="#68FFFFFF"
                         FontSize="9" Margin="0,5,0,0"/>
            </StackPanel>

            <Border Grid.Column="1" Background="#18FFFFFF"/>

            <StackPanel Grid.Column="2" Margin="24,0,0,0">
              <TextBlock Text="System" Foreground="#F0FFFFFF" FontSize="16" FontWeight="SemiBold"/>
              <CheckBox x:Name="HotkeysEnabled" Content="Globale Hotkeys"
                        Margin="0,20,0,0" Style="{StaticResource ToggleStyle}"/>
              <CheckBox x:Name="AutostartEnabled" Content="Beim Windows-Login starten"
                        Margin="0,16,0,0" Style="{StaticResource ToggleStyle}"/>
              <Border Height="1" Background="#18FFFFFF" Margin="0,20,0,16"/>
              <Grid>
                <Grid.RowDefinitions>
                  <RowDefinition Height="34"/>
                  <RowDefinition Height="34"/>
                  <RowDefinition Height="34"/>
                  <RowDefinition Height="34"/>
                </Grid.RowDefinitions>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="104"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Row="0" Text="Play / Pause" Foreground="#A8FFFFFF" FontSize="9.5" VerticalAlignment="Center"/>
                <Button x:Name="HotkeyPlay" Grid.Row="0" Grid.Column="1" Content="Ctrl + Alt + Leertaste" Style="{StaticResource SettingsButtonStyle}"/>
                <TextBlock Grid.Row="1" Text="Vorheriger Titel" Foreground="#A8FFFFFF" FontSize="9.5" VerticalAlignment="Center"/>
                <Button x:Name="HotkeyPrevious" Grid.Row="1" Grid.Column="1" Content="Ctrl + Alt + Links" Style="{StaticResource SettingsButtonStyle}"/>
                <TextBlock Grid.Row="2" Text="N&#228;chster Titel" Foreground="#A8FFFFFF" FontSize="9.5" VerticalAlignment="Center"/>
                <Button x:Name="HotkeyNext" Grid.Row="2" Grid.Column="1" Content="Ctrl + Alt + Rechts" Style="{StaticResource SettingsButtonStyle}"/>
                <TextBlock Grid.Row="3" Text="Island ein / aus" Foreground="#A8FFFFFF" FontSize="9.5" VerticalAlignment="Center"/>
                <Button x:Name="HotkeyToggle" Grid.Row="3" Grid.Column="1" Content="Ctrl + Alt + I" Style="{StaticResource SettingsButtonStyle}"/>
              </Grid>
            </StackPanel>
          </Grid>

          <Grid x:Name="AppsPanel" Margin="24,20,24,16" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="42"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <StackPanel Grid.Row="0" VerticalAlignment="Center">
              <TextBlock Text="App-Schnellzugriff" Foreground="#F0FFFFFF" FontSize="16" FontWeight="SemiBold"/>
              <TextBlock Text="App auswählen, Anzeigename bei Bedarf anpassen." Foreground="#78FFFFFF" FontSize="9.5" Margin="0,4,0,0"/>
            </StackPanel>
            <UniformGrid Grid.Row="1" Rows="2" Columns="2" Margin="-4,6,-4,-4">
              <Border Margin="4" Padding="10" CornerRadius="13" Background="#0CFFFFFF" BorderBrush="#18FFFFFF" BorderThickness="1">
                <Grid>
                  <Grid.RowDefinitions><RowDefinition Height="24"/><RowDefinition Height="15"/><RowDefinition Height="32"/><RowDefinition Height="15"/><RowDefinition Height="32"/></Grid.RowDefinitions>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="28"/><ColumnDefinition Width="*"/><ColumnDefinition Width="80"/><ColumnDefinition Width="28"/></Grid.ColumnDefinitions>
                  <Image x:Name="SettingsIcon1" Width="20" Height="20" Stretch="Uniform" VerticalAlignment="Center"/>
                  <TextBlock Grid.Column="1" Text="App 1" Foreground="#C8FFFFFF" FontSize="10" VerticalAlignment="Center"/>
                  <Button x:Name="Browse1" Grid.Column="2" Content="Auswählen" Style="{StaticResource SettingsButtonStyle}"/>
                  <Button x:Name="Clear1" Grid.Column="3" Content="×" ToolTip="Slot leeren" Margin="4,0,0,0" Style="{StaticResource SettingsButtonStyle}"/>
                  <TextBlock Grid.Row="1" Grid.ColumnSpan="4" Text="NAME IM DOCK" Foreground="#70FFFFFF" FontSize="8" VerticalAlignment="Center"/>
                  <TextBox x:Name="Name1" Grid.Row="2" Grid.ColumnSpan="4" ToolTip="Name, der unter dem App-Icon angezeigt wird" Style="{StaticResource SettingsTextBoxStyle}"/>
                  <TextBlock Grid.Row="3" Grid.ColumnSpan="4" Text="PROGRAMMDATEI" Foreground="#70FFFFFF" FontSize="8" VerticalAlignment="Center"/>
                  <TextBox x:Name="Path1" Grid.Row="4" Grid.ColumnSpan="4" IsReadOnly="True" ToolTip="Ausgewählte Programmdatei" Style="{StaticResource SettingsTextBoxStyle}"/>
                </Grid>
              </Border>
              <Border Margin="4" Padding="10" CornerRadius="13" Background="#0CFFFFFF" BorderBrush="#18FFFFFF" BorderThickness="1">
                <Grid>
                  <Grid.RowDefinitions><RowDefinition Height="24"/><RowDefinition Height="15"/><RowDefinition Height="32"/><RowDefinition Height="15"/><RowDefinition Height="32"/></Grid.RowDefinitions>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="28"/><ColumnDefinition Width="*"/><ColumnDefinition Width="80"/><ColumnDefinition Width="28"/></Grid.ColumnDefinitions>
                  <Image x:Name="SettingsIcon2" Width="20" Height="20" Stretch="Uniform" VerticalAlignment="Center"/>
                  <TextBlock Grid.Column="1" Text="App 2" Foreground="#C8FFFFFF" FontSize="10" VerticalAlignment="Center"/>
                  <Button x:Name="Browse2" Grid.Column="2" Content="Auswählen" Style="{StaticResource SettingsButtonStyle}"/>
                  <Button x:Name="Clear2" Grid.Column="3" Content="×" ToolTip="Slot leeren" Margin="4,0,0,0" Style="{StaticResource SettingsButtonStyle}"/>
                  <TextBlock Grid.Row="1" Grid.ColumnSpan="4" Text="NAME IM DOCK" Foreground="#70FFFFFF" FontSize="8" VerticalAlignment="Center"/>
                  <TextBox x:Name="Name2" Grid.Row="2" Grid.ColumnSpan="4" ToolTip="Name, der unter dem App-Icon angezeigt wird" Style="{StaticResource SettingsTextBoxStyle}"/>
                  <TextBlock Grid.Row="3" Grid.ColumnSpan="4" Text="PROGRAMMDATEI" Foreground="#70FFFFFF" FontSize="8" VerticalAlignment="Center"/>
                  <TextBox x:Name="Path2" Grid.Row="4" Grid.ColumnSpan="4" IsReadOnly="True" ToolTip="Ausgewählte Programmdatei" Style="{StaticResource SettingsTextBoxStyle}"/>
                </Grid>
              </Border>
              <Border Margin="4" Padding="10" CornerRadius="13" Background="#0CFFFFFF" BorderBrush="#18FFFFFF" BorderThickness="1">
                <Grid>
                  <Grid.RowDefinitions><RowDefinition Height="24"/><RowDefinition Height="15"/><RowDefinition Height="32"/><RowDefinition Height="15"/><RowDefinition Height="32"/></Grid.RowDefinitions>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="28"/><ColumnDefinition Width="*"/><ColumnDefinition Width="80"/><ColumnDefinition Width="28"/></Grid.ColumnDefinitions>
                  <Image x:Name="SettingsIcon3" Width="20" Height="20" Stretch="Uniform" VerticalAlignment="Center"/>
                  <TextBlock Grid.Column="1" Text="App 3" Foreground="#C8FFFFFF" FontSize="10" VerticalAlignment="Center"/>
                  <Button x:Name="Browse3" Grid.Column="2" Content="Auswählen" Style="{StaticResource SettingsButtonStyle}"/>
                  <Button x:Name="Clear3" Grid.Column="3" Content="×" ToolTip="Slot leeren" Margin="4,0,0,0" Style="{StaticResource SettingsButtonStyle}"/>
                  <TextBlock Grid.Row="1" Grid.ColumnSpan="4" Text="NAME IM DOCK" Foreground="#70FFFFFF" FontSize="8" VerticalAlignment="Center"/>
                  <TextBox x:Name="Name3" Grid.Row="2" Grid.ColumnSpan="4" ToolTip="Name, der unter dem App-Icon angezeigt wird" Style="{StaticResource SettingsTextBoxStyle}"/>
                  <TextBlock Grid.Row="3" Grid.ColumnSpan="4" Text="PROGRAMMDATEI" Foreground="#70FFFFFF" FontSize="8" VerticalAlignment="Center"/>
                  <TextBox x:Name="Path3" Grid.Row="4" Grid.ColumnSpan="4" IsReadOnly="True" ToolTip="Ausgewählte Programmdatei" Style="{StaticResource SettingsTextBoxStyle}"/>
                </Grid>
              </Border>
              <Border Margin="4" Padding="10" CornerRadius="13" Background="#0CFFFFFF" BorderBrush="#18FFFFFF" BorderThickness="1">
                <Grid>
                  <Grid.RowDefinitions><RowDefinition Height="24"/><RowDefinition Height="15"/><RowDefinition Height="32"/><RowDefinition Height="15"/><RowDefinition Height="32"/></Grid.RowDefinitions>
                  <Grid.ColumnDefinitions><ColumnDefinition Width="28"/><ColumnDefinition Width="*"/><ColumnDefinition Width="80"/><ColumnDefinition Width="28"/></Grid.ColumnDefinitions>
                  <Image x:Name="SettingsIcon4" Width="20" Height="20" Stretch="Uniform" VerticalAlignment="Center"/>
                  <TextBlock Grid.Column="1" Text="App 4" Foreground="#C8FFFFFF" FontSize="10" VerticalAlignment="Center"/>
                  <Button x:Name="Browse4" Grid.Column="2" Content="Auswählen" Style="{StaticResource SettingsButtonStyle}"/>
                  <Button x:Name="Clear4" Grid.Column="3" Content="×" ToolTip="Slot leeren" Margin="4,0,0,0" Style="{StaticResource SettingsButtonStyle}"/>
                  <TextBlock Grid.Row="1" Grid.ColumnSpan="4" Text="NAME IM DOCK" Foreground="#70FFFFFF" FontSize="8" VerticalAlignment="Center"/>
                  <TextBox x:Name="Name4" Grid.Row="2" Grid.ColumnSpan="4" ToolTip="Name, der unter dem App-Icon angezeigt wird" Style="{StaticResource SettingsTextBoxStyle}"/>
                  <TextBlock Grid.Row="3" Grid.ColumnSpan="4" Text="PROGRAMMDATEI" Foreground="#70FFFFFF" FontSize="8" VerticalAlignment="Center"/>
                  <TextBox x:Name="Path4" Grid.Row="4" Grid.ColumnSpan="4" IsReadOnly="True" ToolTip="Ausgewählte Programmdatei" Style="{StaticResource SettingsTextBoxStyle}"/>
                </Grid>
              </Border>
            </UniformGrid>
          </Grid>
        </Grid>

        <Grid Grid.Row="3" Margin="24,10,24,18">
          <TextBlock x:Name="SettingsStatus" Foreground="#D8F27A7A" FontSize="10"
                     VerticalAlignment="Center"/>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="CancelSettings" Width="88" Height="38" Content="Abbrechen"
                    Margin="0,0,10,0" Style="{StaticResource SettingsButtonStyle}"/>
            <Button x:Name="SaveSettings" Width="96" Height="38" Content="Speichern"
                    Background="#F0FFFFFF" Foreground="#FF09090B"
                    Style="{StaticResource SettingsButtonStyle}"/>
          </StackPanel>
        </Grid>
      </Grid>
    </Border>
  </Grid>
</Window>
"@

    try {
        $settingsReader = New-Object System.Xml.XmlNodeReader $settingsXaml
        $settingsWindow = [System.Windows.Markup.XamlReader]::Load($settingsReader)
        $settingsWindow.Owner = $window

        $nameBoxes = @(
            $settingsWindow.FindName("Name1"),
            $settingsWindow.FindName("Name2"),
            $settingsWindow.FindName("Name3"),
            $settingsWindow.FindName("Name4")
        )
        $pathBoxes = @(
            $settingsWindow.FindName("Path1"),
            $settingsWindow.FindName("Path2"),
            $settingsWindow.FindName("Path3"),
            $settingsWindow.FindName("Path4")
        )
        $settingsAppIcons = @(
            $settingsWindow.FindName("SettingsIcon1"),
            $settingsWindow.FindName("SettingsIcon2"),
            $settingsWindow.FindName("SettingsIcon3"),
            $settingsWindow.FindName("SettingsIcon4")
        )
        $browseButtons = @(
            $settingsWindow.FindName("Browse1"),
            $settingsWindow.FindName("Browse2"),
            $settingsWindow.FindName("Browse3"),
            $settingsWindow.FindName("Browse4")
        )
        $clearButtons = @(
            $settingsWindow.FindName("Clear1"),
            $settingsWindow.FindName("Clear2"),
            $settingsWindow.FindName("Clear3"),
            $settingsWindow.FindName("Clear4")
        )
        $statusText = $settingsWindow.FindName("SettingsStatus")
        $appearancePanel = $settingsWindow.FindName("AppearancePanel")
        $playbackPanel = $settingsWindow.FindName("PlaybackPanel")
        $appsPanel = $settingsWindow.FindName("AppsPanel")
        $tabAppearance = $settingsWindow.FindName("TabAppearance")
        $tabPlayback = $settingsWindow.FindName("TabPlayback")
        $tabApps = $settingsWindow.FindName("TabApps")
        $edgeChoices = @(
            $settingsWindow.FindName("EdgeTop"),
            $settingsWindow.FindName("EdgeBottom")
        )
        $alignmentChoices = @(
            $settingsWindow.FindName("AlignLeft"),
            $settingsWindow.FindName("AlignCenter"),
            $settingsWindow.FindName("AlignRight")
        )
        $sizeChoices = @(
            $settingsWindow.FindName("SizeCompact"),
            $settingsWindow.FindName("SizeStandard"),
            $settingsWindow.FindName("SizeLarge")
        )
        $sourceYouTube = $settingsWindow.FindName("SourceYouTube")
        $sourceSpotify = $settingsWindow.FindName("SourceSpotify")
        $sourceVlc = $settingsWindow.FindName("SourceVlc")
        $discordClientIdBox = $settingsWindow.FindName("DiscordApplicationId")
        $hotkeysEnabled = $settingsWindow.FindName("HotkeysEnabled")
        $autostartEnabled = $settingsWindow.FindName("AutostartEnabled")
        $hotkeyButtons = @{
            play = $settingsWindow.FindName("HotkeyPlay")
            previous = $settingsWindow.FindName("HotkeyPrevious")
            next = $settingsWindow.FindName("HotkeyNext")
            toggleIsland = $settingsWindow.FindName("HotkeyToggle")
        }
        $hotkeyDraft = @{}
        foreach ($action in @("play", "previous", "next", "toggleIsland")) {
            $hotkeyDraft[$action] = [pscustomobject]@{
                modifiers = [int]$script:appSettings.hotkeys.$action.modifiers
                key = [int]$script:appSettings.hotkeys.$action.key
            }
            $hotkeyButtons[$action].Content = Format-IslandHotkey $hotkeyDraft[$action]
        }
        $captureState = @{ action = "" }

        $apps = @($script:appSettings.apps)
        for ($index = 0; $index -lt 4; $index++) {
            $nameBoxes[$index].Text = [string]$apps[$index].name
            $pathBoxes[$index].Text = [string]$apps[$index].path
            $settingsAppIcons[$index].Source = Get-AppIconSource ([string]$apps[$index].path)
        }
        $currentPosition = [string]$script:appSettings.position
        if ($currentPosition -eq "Custom") {
            $settingsWindow.FindName("CustomPositionHint").Visibility = [System.Windows.Visibility]::Visible
        } else {
            foreach ($choice in $edgeChoices) {
                $choice.IsChecked = $currentPosition.StartsWith([string]$choice.Tag)
            }
            foreach ($choice in $alignmentChoices) {
                $choice.IsChecked = $currentPosition.EndsWith([string]$choice.Tag)
            }
        }
        foreach ($choice in $sizeChoices) {
            $choice.IsChecked = ([string]$choice.Tag -eq [string]$script:appSettings.size)
        }
        $sourceYouTube.IsChecked = [Convert]::ToBoolean($script:appSettings.sources.youtube)
        $sourceSpotify.IsChecked = [Convert]::ToBoolean($script:appSettings.sources.spotify)
        $sourceVlc.IsChecked = [Convert]::ToBoolean($script:appSettings.sources.vlc)
        $discordClientIdBox.Text = [string]$script:appSettings.discordApplicationId
        $hotkeysEnabled.IsChecked = [Convert]::ToBoolean($script:appSettings.hotkeysEnabled)
        $autostartEnabled.IsChecked = [Convert]::ToBoolean($script:appSettings.autostart)

        foreach ($action in @("play", "previous", "next", "toggleIsland")) {
            $selectedAction = $action
            $hotkeyButtons[$action].Add_Click({
                $captureState.action = $selectedAction
                $hotkeyButtons[$selectedAction].Content = "Tastenkombination druecken..."
                $settingsWindow.Activate()
                $settingsWindow.Focus() | Out-Null
            }.GetNewClosure())
        }
        $settingsWindow.Add_PreviewKeyDown({
            param($sender, $eventArgs)
            if (-not $captureState.action) { return }
            $eventArgs.Handled = $true
            $key = $eventArgs.Key
            if ($key -eq [System.Windows.Input.Key]::System) { $key = $eventArgs.SystemKey }
            if ($key -eq [System.Windows.Input.Key]::Escape) {
                $captureState.action = ""
                foreach ($action in @("play", "previous", "next", "toggleIsland")) {
                    $hotkeyButtons[$action].Content = Format-IslandHotkey $hotkeyDraft[$action]
                }
                return
            }
            if ($key -in @([System.Windows.Input.Key]::LeftCtrl, [System.Windows.Input.Key]::RightCtrl,
                           [System.Windows.Input.Key]::LeftAlt, [System.Windows.Input.Key]::RightAlt,
                           [System.Windows.Input.Key]::LeftShift, [System.Windows.Input.Key]::RightShift,
                           [System.Windows.Input.Key]::LWin, [System.Windows.Input.Key]::RWin)) { return }
            $modifiers = [int][System.Windows.Input.Keyboard]::Modifiers
            if (($modifiers -band 0x000B) -eq 0) {
                $hotkeyButtons[$captureState.action].Content = "Ctrl/Alt/Win + Taste"
                return
            }
            $virtualKey = [System.Windows.Input.KeyInterop]::VirtualKeyFromKey($key)
            if ($virtualKey -le 0) { return }
            $action = $captureState.action
            $hotkeyDraft[$action] = [pscustomobject]@{ modifiers = $modifiers; key = [int]$virtualKey }
            $hotkeyButtons[$action].Content = Format-IslandHotkey $hotkeyDraft[$action]
            $captureState.action = ""
        }.GetNewClosure())

        $browseButtons[0].Add_Click({ Select-AppExecutable $nameBoxes[0] $pathBoxes[0] $settingsAppIcons[0] })
        $browseButtons[1].Add_Click({ Select-AppExecutable $nameBoxes[1] $pathBoxes[1] $settingsAppIcons[1] })
        $browseButtons[2].Add_Click({ Select-AppExecutable $nameBoxes[2] $pathBoxes[2] $settingsAppIcons[2] })
        $browseButtons[3].Add_Click({ Select-AppExecutable $nameBoxes[3] $pathBoxes[3] $settingsAppIcons[3] })
        for ($index = 0; $index -lt 4; $index++) {
            $slotIndex = $index
            $clearButtons[$slotIndex].Add_Click({
                $nameBoxes[$slotIndex].Clear()
                $pathBoxes[$slotIndex].Clear()
                $settingsAppIcons[$slotIndex].Source = $null
            }.GetNewClosure())
        }

        $tabAppearance.Add_Checked({
            $appearancePanel.Visibility = [System.Windows.Visibility]::Visible
            $playbackPanel.Visibility = [System.Windows.Visibility]::Collapsed
            $appsPanel.Visibility = [System.Windows.Visibility]::Collapsed
        })
        $tabPlayback.Add_Checked({
            $appearancePanel.Visibility = [System.Windows.Visibility]::Collapsed
            $playbackPanel.Visibility = [System.Windows.Visibility]::Visible
            $appsPanel.Visibility = [System.Windows.Visibility]::Collapsed
        })
        $tabApps.Add_Checked({
            $appearancePanel.Visibility = [System.Windows.Visibility]::Collapsed
            $playbackPanel.Visibility = [System.Windows.Visibility]::Collapsed
            $appsPanel.Visibility = [System.Windows.Visibility]::Visible
        })

        $settingsWindow.FindName("SettingsHeader").Add_MouseLeftButtonDown({
            param($sender, $eventArgs)
            if ($eventArgs.ChangedButton -eq [System.Windows.Input.MouseButton]::Left) {
                try { $settingsWindow.DragMove() } catch {}
            }
        })
        $settingsWindow.FindName("CloseSettings").Add_Click({ $settingsWindow.Close() })
        $settingsWindow.FindName("CancelSettings").Add_Click({ $settingsWindow.Close() })
        $settingsWindow.FindName("SaveSettings").Add_Click({
            $newApps = @()
            for ($index = 0; $index -lt 4; $index++) {
                $name = $nameBoxes[$index].Text.Trim()
                $path = [Environment]::ExpandEnvironmentVariables($pathBoxes[$index].Text.Trim())
                if ($path -and -not (Test-Path -LiteralPath $path)) {
                    $statusText.Text = "Pfad in Slot $($index + 1) wurde nicht gefunden."
                    return
                }
                $newApps += [pscustomobject]@{ name = $name; path = $path }
            }

            if (-not $sourceYouTube.IsChecked -and -not $sourceSpotify.IsChecked -and -not $sourceVlc.IsChecked) {
                $statusText.Text = "Mindestens eine Medienquelle muss aktiv bleiben."
                return
            }

            $hotkeySignatures = @{}
            foreach ($action in @("play", "previous", "next", "toggleIsland")) {
                $hotkey = $hotkeyDraft[$action]
                if (($hotkey.modifiers -band 0x000B) -eq 0 -or $hotkey.key -le 0) {
                    $statusText.Text = "Jeder Hotkey braucht Strg, Alt oder Win und eine Taste."
                    return
                }
                $signature = "$($hotkey.modifiers):$($hotkey.key)"
                if ($hotkeySignatures.ContainsKey($signature)) {
                    $statusText.Text = "Jede Aktion braucht eine eigene Tastenkombination."
                    return
                }
                $hotkeySignatures[$signature] = $action
            }

            $discordClientId = $discordClientIdBox.Text.Trim()
            if ($discordClientId -and $discordClientId -notmatch '^\d{17,20}$') {
                $statusText.Text = "Die Discord Application ID muss aus 17 bis 20 Ziffern bestehen."
                return
            }

            $selectedPosition = [string]$script:appSettings.position
            $selectedEdge = $null
            foreach ($choice in $edgeChoices) {
                if ($choice.IsChecked) { $selectedEdge = [string]$choice.Tag; break }
            }
            $selectedAlignment = $null
            foreach ($choice in $alignmentChoices) {
                if ($choice.IsChecked) { $selectedAlignment = [string]$choice.Tag; break }
            }
            if ($selectedEdge -or $selectedAlignment) {
                if (-not $selectedEdge) { $selectedEdge = "Top" }
                if (-not $selectedAlignment) { $selectedAlignment = "Center" }
                $selectedPosition = "$selectedEdge$selectedAlignment"
            }
            $selectedSize = "Standard"
            foreach ($choice in $sizeChoices) {
                if ($choice.IsChecked) { $selectedSize = [string]$choice.Tag; break }
            }

            $script:appSettings = [pscustomobject]@{
                version = 2
                position = $selectedPosition
                size = $selectedSize
                hotkeysEnabled = [bool]$hotkeysEnabled.IsChecked
                hotkeys = [pscustomobject]@{
                    play = $hotkeyDraft.play
                    previous = $hotkeyDraft.previous
                    next = $hotkeyDraft.next
                    toggleIsland = $hotkeyDraft.toggleIsland
                }
                autostart = [bool]$autostartEnabled.IsChecked
                discordApplicationId = $discordClientId
                customLeft = [double]$script:appSettings.customLeft
                customTop = [double]$script:appSettings.customTop
                sources = [pscustomobject]@{
                    youtube = [bool]$sourceYouTube.IsChecked
                    spotify = [bool]$sourceSpotify.IsChecked
                    vlc = [bool]$sourceVlc.IsChecked
                }
                apps = $newApps
            }

            try {
                Set-IslandAutostart ([bool]$script:appSettings.autostart)
                Save-IslandSettings
                $script:discordPresence.SetApplicationId([string]$script:appSettings.discordApplicationId)
                Refresh-AppDock
                Apply-IslandProfile
                Register-IslandHotkeys
                $settingsWindow.Close()
            } catch {
                $statusText.Text = "Einstellungen konnten nicht gespeichert werden."
            }
        })

        $settingsWindow.ShowDialog() | Out-Null
    } finally {
        $script:settingsOpen = $false
    }
}

$script:appSettings = Load-IslandSettings
$script:discordPresence = [DiscordPresenceClient]::new([string]$script:appSettings.discordApplicationId)
Refresh-AppDock

$script:anim  = $null
$script:watch = New-Object System.Diagnostics.Stopwatch
$script:watch.Start()
$script:animationDriver = [IslandAnimationDriver]::new(
    $window, $script:island, $window.FindName("IslandJelly"),
    $script:details, $script:progressFill, $script:currentText,
    [System.Windows.Media.ScaleTransform[]]$script:miniVizScales
)

function Position-IslandWindow {
    $workArea = [System.Windows.SystemParameters]::WorkArea
    $position = [string]$script:appSettings.position
    if ([string]::IsNullOrWhiteSpace($position)) { $position = "TopCenter" }

    if ($position -eq "Custom") {
        $script:island.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
        $script:island.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
        $window.Left = [Math]::Max(
            $workArea.Left,
            [Math]::Min([double]$script:appSettings.customLeft, $workArea.Right - $window.Width)
        )
        $window.Top = [Math]::Max(
            $workArea.Top,
            [Math]::Min([double]$script:appSettings.customTop, $workArea.Bottom - $window.Height)
        )
        return
    }

    $isBottom = $position.StartsWith("Bottom", [StringComparison]::OrdinalIgnoreCase)
    $script:island.VerticalAlignment = if ($isBottom) {
        [System.Windows.VerticalAlignment]::Bottom
    } else {
        [System.Windows.VerticalAlignment]::Top
    }
    $script:island.Margin = if ($isBottom) {
        [System.Windows.Thickness]::new(0, 0, 0, 8)
    } else {
        [System.Windows.Thickness]::new(0, 8, 0, 0)
    }

    $innerX = ($window.Width - $collapsedWidth) / 2.0
    if ($position.EndsWith("Left", [StringComparison]::OrdinalIgnoreCase)) {
        $window.Left = $workArea.Left + 12 - $innerX
    } elseif ($position.EndsWith("Right", [StringComparison]::OrdinalIgnoreCase)) {
        $window.Left = $workArea.Right - 12 - $collapsedWidth - $innerX
    } else {
        $window.Left = $workArea.Left + (($workArea.Width - $window.Width) / 2.0)
    }
    $window.Top = if ($isBottom) {
        $workArea.Bottom - $window.Height - 4
    } else {
        $workArea.Top + 4
    }
}

function Apply-IslandProfile {
    $size = [string]$script:appSettings.size
    switch ($size) {
        "Compact" {
            Set-Variable -Name collapsedWidth -Scope Script -Value 328.0
            Set-Variable -Name expandedWidth -Scope Script -Value 396.0
            $window.Width = 456.0
        }
        "Large" {
            Set-Variable -Name collapsedWidth -Scope Script -Value 384.0
            Set-Variable -Name expandedWidth -Scope Script -Value 456.0
            $window.Width = 520.0
        }
        default {
            Set-Variable -Name collapsedWidth -Scope Script -Value 352.0
            Set-Variable -Name expandedWidth -Scope Script -Value 420.0
            $window.Width = 480.0
        }
    }
    $window.Height = 430.0
    if (-not $script:animating) {
        $script:island.Width = if ($script:expanded) { $expandedWidth } else { $collapsedWidth }
        $script:island.Height = if ($script:expanded) { $expandedHeight } else { $collapsedHeight }
    }
    Position-IslandWindow
}

function Unregister-IslandHotkeys {
    if ($null -eq $script:hwndSource) { return }
    foreach ($hotkeyId in @($script:registeredHotkeyIds)) {
        [void][IslandSystemBridge]::UnregisterHotKey($script:hwndSource.Handle, [int]$hotkeyId)
    }
    $script:registeredHotkeyIds = @()
}

function Register-IslandHotkeys {
    Unregister-IslandHotkeys
    if ($null -eq $script:hwndSource -or -not [Convert]::ToBoolean($script:appSettings.hotkeysEnabled)) {
        return
    }

    $definitions = @(
        @{ id = 101; action = "play" },
        @{ id = 102; action = "previous" },
        @{ id = 103; action = "next" },
        @{ id = 104; action = "toggleIsland" }
    )
    foreach ($definition in $definitions) {
        $hotkey = $script:appSettings.hotkeys.($definition.action)
        if ([IslandSystemBridge]::RegisterHotKey(
                $script:hwndSource.Handle,
                [int]$definition.id,
                [uint32]$hotkey.modifiers,
                [uint32]$hotkey.key
            )) {
            $script:registeredHotkeyIds += [int]$definition.id
        }
    }
}

# Apple-style easing: easeOutQuint (fast attack, long smooth settle) ≈ cubic-bezier(.32,.72,0,1)
function Ease-Apple([double]$t) {
    $x = [Math]::Max(0.0, [Math]::Min(1.0, $t))
    return 1.0 - [Math]::Pow(1.0 - $x, 4.6)
}
function Ease-Cubic([double]$t) {
    $x = [Math]::Max(0.0, [Math]::Min(1.0, $t))
    return 1.0 - [Math]::Pow(1.0 - $x, 3.0)
}

function Start-LikeAnimation {
    $script:likeAnimation = [pscustomobject]@{
        start = $script:watch.Elapsed.TotalMilliseconds
        duration = 680.0
    }
    $script:likeIcon.Stroke = $script:ratingLikeBrush
    $script:animationDriver.ScriptFrames = $true
}

function Start-IslandAnimation([bool]$open) {
    if ($script:animating -and $script:anim -and $script:anim.open -eq $open) { return }
    if (-not $script:animating -and $script:expanded -eq $open) { return }

    $wasExpanded = [bool]$script:expanded
    $wasAnimating = [bool]$script:animating
    $script:expanded  = $open
    $script:animating = $true
    if ($open) {
        $script:details.Visibility = [System.Windows.Visibility]::Visible
        if (-not $wasExpanded -and -not $wasAnimating) {
            $script:islandScale.ScaleX = 0.95
            $script:islandScale.ScaleY = 0.90
            $script:island.Opacity = 0.94
            $script:detailsScale.ScaleY = 0.90
        }
    } else {
        $script:details.IsHitTestVisible = $false
    }

    $targetW = if ($open) { $expandedWidth }  else { $collapsedWidth }
    $targetH = if ($open) { $expandedHeight } else { $collapsedHeight }
    $targetR = if ($open) { $expandedRadius }  else { $collapsedRadius }
    $sizeTravel = [Math]::Max(
        [Math]::Abs($targetW - [double]$script:island.Width) / [Math]::Max(1.0, [Math]::Abs($expandedWidth - $collapsedWidth)),
        [Math]::Abs($targetH - [double]$script:island.Height) / [Math]::Max(1.0, [Math]::Abs($expandedHeight - $collapsedHeight))
    )
    $baseDuration = if ($open) { 560.0 } else { 460.0 }

    $script:anim = [pscustomobject]@{
        open      = $open
        start     = $script:watch.Elapsed.TotalMilliseconds
        duration  = [Math]::Max(220.0, $baseDuration * [Math]::Min(1.0, $sizeTravel))
        w0        = [double]$script:island.Width
        h0        = [double]$script:island.Height
        r0        = [double]$script:island.CornerRadius.TopLeft
        sx0       = [double]$script:islandScale.ScaleX
        sy0       = [double]$script:islandScale.ScaleY
        opacity0  = [double]$script:island.Opacity
        c0        = [double]$script:chevronRotate.Angle
        w1        = $targetW
        h1        = $targetH
        r1        = $targetR
        c1        = if ($open) { 180.0 } else { 0.0 }
        o0        = [double]$script:details.Opacity
        o1        = if ($open) { 1.0 } else { 0.0 }
        ds0       = [double]$script:detailsScale.ScaleY
        ds1       = if ($open) { 1.0 } else { 0.94 }
    }
    $script:animationDriver.ScriptFrames = $true
}

function Format-Time($seconds) {
    $value = [Math]::Max(0, [int][double]$seconds)
    return "{0}:{1:00}" -f [Math]::Floor($value / 60), ($value % 60)
}

function Normalize-TrackTitle([string]$value) {
    if ([string]::IsNullOrWhiteSpace($value)) { return "" }
    return [Text.RegularExpressions.Regex]::Replace(
        $value.ToLowerInvariant(),
        "[^\p{L}\p{Nd}]",
        ""
    )
}

function Get-CoverIdentity([string]$url) {
    if ([string]::IsNullOrWhiteSpace($url)) { return "" }
    try {
        $uri = [Uri]$url
        return "$($uri.Scheme)://$($uri.Host)$($uri.AbsolutePath)"
    } catch {
        return ($url -split "\?", 2)[0]
    }
}

# PowerShell participates only during the short expand/collapse/like animations.
# Continuous visualizers, drag and spring settling stay in the compiled driver.
$renderHandler = [System.EventHandler]{
    param($sender, $e)

    # 1. morph animation
    $a = $script:anim
    if ($a -ne $null) {
        $t = ($script:watch.Elapsed.TotalMilliseconds - $a.start) / $a.duration
        $finished = $false
        if ($t -ge 1.0) { $t = 1.0; $finished = $true }
        $eMorph = Ease-Apple $t

        $script:island.Width  = $a.w0 + ($a.w1 - $a.w0) * $eMorph
        $script:island.Height = $a.h0 + ($a.h1 - $a.h0) * $eMorph

        $radius = $a.r0 + ($a.r1 - $a.r0) * $eMorph
        $script:island.CornerRadius = [System.Windows.CornerRadius]::new($radius)
        $settlePulse = [Math]::Sin([Math]::PI * $t) * (1.0 - $t)
        if ($a.open) {
            $script:islandScale.ScaleX = $a.sx0 + ((1.0 - $a.sx0) * $eMorph) + (0.12 * $settlePulse)
            $script:islandScale.ScaleY = $a.sy0 + ((1.0 - $a.sy0) * $eMorph) + (0.15 * $settlePulse)
        } else {
            $script:islandScale.ScaleX = $a.sx0 + ((1.0 - $a.sx0) * $eMorph) + (0.07 * $settlePulse)
            $script:islandScale.ScaleY = $a.sy0 + ((1.0 - $a.sy0) * $eMorph) + (0.10 * $settlePulse)
        }
        $script:island.Opacity = $a.opacity0 + ((1.0 - $a.opacity0) * $eMorph)
        $script:chevronRotate.Angle = $a.c0 + ($a.c1 - $a.c0) * $eMorph

        # opacity with stagger: details fade out FIRST on collapse, fade in LAST on expand
        if ($a.open) {
            $ot = [Math]::Max(0.0, ($t - 0.26) / 0.66)
        } else {
            $ot = [Math]::Min(1.0, [Math]::Max(0.0, ($t - 0.16) / 0.56))
        }
        $oe = Ease-Cubic $ot
        $newOpacity = $a.o0 + ($a.o1 - $a.o0) * $oe
        $script:details.Opacity = $newOpacity
        $script:detailsScale.ScaleY = $a.ds0 + (($a.ds1 - $a.ds0) * $oe)
        $script:details.IsHitTestVisible = ($newOpacity -gt 0.6)

        if ($finished) {
            $script:island.Width = $a.w1
            $script:island.Height = $a.h1
            $script:island.CornerRadius = [System.Windows.CornerRadius]::new($a.r1)
            $script:chevronRotate.Angle = $a.c1
            $script:islandScale.ScaleX = 1.0
            $script:islandScale.ScaleY = 1.0
            $script:island.Opacity = 1.0
            $script:details.Opacity = $a.o1
            $script:detailsScale.ScaleY = $a.ds1
            $script:details.IsHitTestVisible = $a.open
            if (-not $a.open) {
                $script:details.Visibility = [System.Windows.Visibility]::Collapsed
            }
            $script:anim = $null
            $script:animating = $false
        }
    }

    # Like feedback: a springy thumb pop, two expanding rings, and a brief sparkle.
    $likeAnim = $script:likeAnimation
    if ($null -ne $likeAnim) {
        $likeT = [Math]::Max(0.0, [Math]::Min(1.0,
            ($script:watch.Elapsed.TotalMilliseconds - $likeAnim.start) / $likeAnim.duration
        ))
        if ($likeT -ge 1.0) {
            $script:likeIconScale.ScaleX = 1.0
            $script:likeIconScale.ScaleY = 1.0
            $script:likePulseOuterScale.ScaleX = 1.0
            $script:likePulseOuterScale.ScaleY = 1.0
            $script:likePulseInnerScale.ScaleX = 1.0
            $script:likePulseInnerScale.ScaleY = 1.0
            $script:likeSparkScale.ScaleX = 1.0
            $script:likeSparkScale.ScaleY = 1.0
            $script:likePulseOuter.Opacity = 0.0
            $script:likePulseInner.Opacity = 0.0
            $script:likeSpark.Opacity = 0.0
            $script:likeAnimation = $null
        } else {
            $thumbScale = 1.0 + (0.40 * [Math]::Exp(-6.5 * $likeT) * [Math]::Sin(18.0 * $likeT))
            $script:likeIconScale.ScaleX = $thumbScale
            $script:likeIconScale.ScaleY = $thumbScale

            $outerT = [Math]::Min(1.0, $likeT / 0.62)
            $script:likePulseOuterScale.ScaleX = 0.38 + (1.02 * $outerT)
            $script:likePulseOuterScale.ScaleY = 0.38 + (1.02 * $outerT)
            $script:likePulseOuter.Opacity = 0.72 * (1.0 - $outerT)

            $innerT = [Math]::Max(0.0, [Math]::Min(1.0, ($likeT - 0.08) / 0.52))
            $script:likePulseInnerScale.ScaleX = 0.38 + (1.08 * $innerT)
            $script:likePulseInnerScale.ScaleY = 0.38 + (1.08 * $innerT)
            $script:likePulseInner.Opacity = 0.82 * (1.0 - $innerT)

            $sparkT = [Math]::Min(1.0, $likeT / 0.52)
            $sparkScale = 0.45 + (0.90 * $sparkT)
            $script:likeSparkScale.ScaleX = $sparkScale
            $script:likeSparkScale.ScaleY = $sparkScale
            $script:likeSpark.Opacity = 0.82 * [Math]::Sin([Math]::PI * $sparkT)
        }
    }

    $script:animationDriver.ScriptFrames = ($null -ne $script:anim -or $null -ne $script:likeAnimation)
}
$script:animationDriver.add_ScriptFrame($renderHandler)
$script:animationDriver.add_DragMoved([System.EventHandler]{ Update-CloseDropTarget })

$window.Add_SourceInitialized({
    $helper = New-Object System.Windows.Interop.WindowInteropHelper($window)
    $script:hwndSource = [System.Windows.Interop.HwndSource]::FromHwnd($helper.Handle)
    $script:hitTestHook = [System.Windows.Interop.HwndSourceHook]{
        param($hwnd, $message, $wParam, $lParam, [ref]$handled)

        if ($message -eq 0x0312) {
            switch ([int]$wParam) {
                101 { Send-MediaAction "play" }
                102 { Send-MediaAction "prev" }
                103 { Send-MediaAction "next" }
                104 { Start-IslandAnimation (-not $script:expanded) }
            }
            $handled.Value = $true
            return [IntPtr]::Zero
        }

        if ($message -eq 0x0084 -and -not $script:dragging) {
            $point = [System.Windows.Input.Mouse]::GetPosition($window)
            $islandLeft = ($window.ActualWidth - $script:island.ActualWidth) / 2.0
            $islandTop = if ($script:island.VerticalAlignment -eq [System.Windows.VerticalAlignment]::Bottom) {
                $window.ActualHeight - $script:island.ActualHeight - 8.0
            } else {
                8.0
            }
            $inside = (
                $point.X -ge $islandLeft -and
                $point.X -le ($islandLeft + $script:island.ActualWidth) -and
                $point.Y -ge $islandTop -and
                $point.Y -le ($islandTop + $script:island.ActualHeight)
            )
            if (-not $inside) {
                $handled.Value = $true
                return [IntPtr](-1)
            }
        }

        return [IntPtr]::Zero
    }
    $script:hwndSource.AddHook($script:hitTestHook)
    Register-IslandHotkeys
})

[IslandBridge]::Start()
Apply-IslandProfile

$leaveTimer = New-Object System.Windows.Threading.DispatcherTimer
$leaveTimer.Interval = [TimeSpan]::FromMilliseconds(110)
$leaveTimer.Add_Tick({
    $leaveTimer.Stop()
    if ($script:dragging -or $StartExpanded) { return }
    $point = [System.Windows.Input.Mouse]::GetPosition($script:island)
    if ($point.X -lt 0 -or $point.Y -lt 0 -or
        $point.X -gt $script:island.ActualWidth -or
        $point.Y -gt $script:island.ActualHeight) {
        Start-IslandAnimation $false
    }
})

$island.Add_MouseEnter({
    $leaveTimer.Stop()
    if (-not $script:dragging) {
        Start-IslandAnimation $true
    }
})
$island.Add_MouseLeave({
    if ($StartExpanded -or $script:dragging) { return }
    $leaveTimer.Stop()
    $leaveTimer.Start()
})

function Test-IsButtonSource($source) {
    $current = $source
    while ($null -ne $current) {
        if ($current -is [System.Windows.Controls.Button]) { return $true }
        if ($current -eq $script:island) { break }
        try {
            $current = [System.Windows.Media.VisualTreeHelper]::GetParent($current)
        } catch {
            $current = $null
        }
    }
    return $false
}

$script:animationDriver.add_DragEnded([System.EventHandler]{
    $closeRequested = $script:closeDropArmed -and -not $script:animationDriver.DragCancelled
    $script:dragging = $false
    if ($closeRequested) {
        Invoke-CloseDropAnimation
    } else {
        Set-CloseDropTargetVisible $false
        if (-not $script:animationDriver.DragCancelled -and $script:animationDriver.DragHasMoved) {
            $workArea = $script:animationDriver.GetWorkArea()
            $window.Left = [Math]::Max(
                $workArea.Left,
                [Math]::Min($window.Left, $workArea.Right - $window.Width)
            )
            $window.Top = [Math]::Max(
                $workArea.Top,
                [Math]::Min($window.Top, $workArea.Bottom - $window.Height)
            )
            # Preserve the visible location when a bottom-anchored island becomes custom.
            if ($script:island.VerticalAlignment -eq [System.Windows.VerticalAlignment]::Bottom) {
                $window.Top += $window.ActualHeight - $script:island.ActualHeight - 16.0
            }
            $script:island.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
            $script:island.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
            $script:appSettings.position = "Custom"
            $script:appSettings.customLeft = [double]$window.Left
            $script:appSettings.customTop = [double]$window.Top
            Save-IslandSettings
        }
        if (-not $StartExpanded) { $leaveTimer.Start() }
    }
})

$island.Add_PreviewMouseLeftButtonDown({
    param($sender, $eventArgs)
    if (Test-IsButtonSource $eventArgs.OriginalSource) { return }
    if ($eventArgs.ChangedButton -ne [System.Windows.Input.MouseButton]::Left) { return }
    if ($script:closeDropClosing) { return }

    $leaveTimer.Stop()
    Set-CloseDropTargetArmed $false
    Set-CloseDropTargetVisible $false
    $script:dragStartIslandCenterY = (Get-IslandScreenCenter).Y
    $script:dragging = $script:animationDriver.BeginDrag()
    $eventArgs.Handled = $script:dragging
})

$island.Add_PreviewMouseWheel({
    param($sender, $eventArgs)
    $delta = if ($eventArgs.Delta -gt 0) { 0.04 } else { -0.04 }
    try {
        $volume = [IslandAudioBridge]::AdjustMasterVolume([single]$delta)
        if ($volume -ge 0) {
            $script:statusOverrideText = "Lautst$([char]0x00E4)rke $volume%"
            $script:statusOverrideUntil = [double][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + 1400.0
        }
    } catch {}
    $eventArgs.Handled = $true
})

foreach ($queueButton in $script:queueButtons) {
    $queueButton.Add_Click({
        param($sender, $eventArgs)
        if ($sender.IsEnabled -and $sender.Tag) {
            [void][IslandBridge]::EnqueueQueue([string]$sender.Tag)
            $eventArgs.Handled = $true
        }
    })
}
$mainPlay.Add_Click({ Send-MediaAction "play" })
$previousButton.Add_Click({ Send-MediaAction "prev" })
$nextButton.Add_Click({ Send-MediaAction "next" })
$script:likeButton.Add_Click({ Start-LikeAnimation; Send-MediaAction "like" })
$script:dislikeButton.Add_Click({ Send-MediaAction "dislike" })
$script:appButtons[0].Add_Click({ Open-OrFocusApp 0 })
$script:appButtons[1].Add_Click({ Open-OrFocusApp 1 })
$script:appButtons[2].Add_Click({ Open-OrFocusApp 2 })
$script:appButtons[3].Add_Click({ Open-OrFocusApp 3 })
$settingsButton.Add_Click({ Show-IslandSettings })

# Native Windows media state is preferred. The browser bridge remains a fallback
# and supplies cover art while Opera is active.
$refresh = New-Object System.Windows.Threading.DispatcherTimer
$refresh.Interval = [TimeSpan]::FromMilliseconds(700)
$refresh.Add_Tick({
    if ($script:animating -or $script:dragging -or $script:animationDriver.IsJellyActive) { return }

    $bridgeState = [IslandBridge]::Snapshot()
    $nativeState = Get-NativeMediaState
    $state = $bridgeState
    $bridgeAge = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [double]$bridgeState["at"]
    $browserFeaturesLive = ($bridgeAge -lt 15000)

    if ($null -ne $nativeState) {
        $bridgeTitle = ([string]$bridgeState["title"]).Trim()
        $nativeTitle = ([string]$nativeState["title"]).Trim()
        $bridgeCover = [string]$bridgeState["cover"]
        $normalizedBridgeTitle = Normalize-TrackTitle $bridgeTitle
        $normalizedNativeTitle = Normalize-TrackTitle $nativeTitle
        $sameTrack = (
            $normalizedBridgeTitle -and
            $normalizedNativeTitle -and
            (
                $normalizedBridgeTitle -eq $normalizedNativeTitle -or
                ($normalizedBridgeTitle.Length -gt 7 -and $normalizedNativeTitle.Contains($normalizedBridgeTitle)) -or
                ($normalizedNativeTitle.Length -gt 7 -and $normalizedBridgeTitle.Contains($normalizedNativeTitle))
            )
        )

        $isYouTubeSource = ([string]$nativeState["sourceKey"] -eq "youtube")
        $browserFeaturesLive = ($isYouTubeSource -and $sameTrack -and $bridgeAge -lt 15000)
        if ($browserFeaturesLive) {
            $nativeState["sourceName"] = "YouTube Music"
            if ($null -eq $nativeState["coverImage"] -and $bridgeCover -and $bridgeAge -lt 5000) {
                $nativeState["cover"] = $bridgeCover
            }
            $nativeState["queue"] = $bridgeState["queue"]
            $nativeState["queueSelection"] = $bridgeState["queueSelection"]
            $nativeState["liked"] = $bridgeState["liked"]
        }
        $state = $nativeState
    }

    $script:lastState = $state
    $audioSource = if ($state["audioSource"]) { [string]$state["audioSource"] } else { [string]$state["sourceKey"] }
    $script:animationDriver.SetAudioSource($audioSource)
    $script:animationDriver.UpdateMedia(
        [Convert]::ToBoolean($state["playing"]), [double]$state["current"],
        [double]$state["duration"], [double]$state["at"]
    )

    $sourceName = [string]$state["sourceName"]
    $sourceKey = [string]$state["sourceKey"]
    if ([string]::IsNullOrWhiteSpace($sourceName)) {
        $sourceName = switch ($sourceKey) {
            "spotify" { "Spotify"; break }
            "vlc" { "VLC"; break }
            default { "YouTube Music" }
        }
    }
    if ([string]::IsNullOrWhiteSpace($sourceKey)) { $sourceKey = "youtube" }

    if (-not [string]::IsNullOrWhiteSpace([string]$state["title"])) {
        $script:discordPresence.Update(
            [string]$state["title"],
            [string]$state["artist"],
            $sourceName,
            [Convert]::ToBoolean($state["playing"]),
            [double]$state["duration"],
            [double]$state["current"]
        )
    } else {
        $script:discordPresence.Clear()
    }

    $titleText.Text  = [string]$state["title"]
    $artistText.Text = [string]$state["artist"]

    $playing = [Convert]::ToBoolean($state["playing"])
    $playbackGeometry = [System.Windows.Media.Geometry]::Parse(
        $(if ($playing) { "M 0,0 H 4 V 14 H 0 Z M 8,0 H 12 V 14 H 8 Z" }
          else { "M 1,0 L 11,7 L 1,14 Z" })
    )
    $mainPlayIcon.Data = $playbackGeometry

    $current = [double]$state["current"]
    $duration = [double]$state["duration"]
    $currentText.Text  = Format-Time $current
    $script:lastDisplayedSecond = [int][Math]::Floor($current)
    $durationText.Text = Format-Time $duration

    $nativeLive = ([string]$state["source"]) -eq "windows"
    $bridgeLive = ($bridgeAge -lt 15000)
    $script:activeMediaSource = $sourceKey

    $nowMilliseconds = [double][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $connectionText.Text = if ($script:statusOverrideUntil -gt $nowMilliseconds) {
        $script:statusOverrideText
    } elseif ($nativeLive) {
        "$sourceName $([char]0x00FC)ber Windows"
    } elseif ($bridgeLive) {
        "Verbunden mit YouTube Music"
    } else {
        "Warte auf YouTube Music"
    }
    $connectionDot.Fill = if ($nativeLive -or $bridgeLive) {
        $script:connectedBrush
    } else {
        $script:waitingBrush
    }

    $queueItems = @($state["queue"])
    for ($queueIndex = 0; $queueIndex -lt 3; $queueIndex++) {
        $songButton = $script:queueButtons[$queueIndex]
        if ($queueIndex -lt $queueItems.Count -and $null -ne $queueItems[$queueIndex]) {
            $queueItem = $queueItems[$queueIndex]
            $script:queueTitles[$queueIndex].Text = [string]$queueItem["title"]
            $script:queueArtists[$queueIndex].Text = [string]$queueItem["artist"]
            $queueToken = [string]$queueItem["queueToken"]
            $canSelectSong = ($browserFeaturesLive -and [Convert]::ToBoolean($state["queueSelection"]) -and
                $queueToken -cmatch '^[a-f0-9]{16}:[1-9][0-9]{0,8}$')
            # Hover belongs to the visible song; only playback needs a current bridge token.
            $songButton.IsEnabled = -not [string]::IsNullOrWhiteSpace([string]$queueItem["title"])
            $songButton.Tag = if ($canSelectSong) { $queueToken } else { $null }
            $songButton.Cursor = if ($canSelectSong) { [System.Windows.Input.Cursors]::Hand } else { [System.Windows.Input.Cursors]::Arrow }
            $songButton.ToolTip = if ($canSelectSong) { "Song abspielen" } else { "YouTube Music und die Bridge-Erweiterung neu laden" }
        } else {
            $songButton.Tag = $null
            $songButton.IsEnabled = $false
            $script:queueTitles[$queueIndex].Text = ""
            $script:queueArtists[$queueIndex].Text = ""
        }
    }
    $script:queueEmpty.Text = if ($queueItems.Count -gt 0) {
        ""
    } elseif ($sourceKey -ne "youtube") {
        "Nur bei YouTube Music"
    } elseif (-not $browserFeaturesLive) {
        "Opera-Erweiterung offline"
    } else {
        "Keine weiteren Titel"
    }

    $rating = 0
    try { $rating = [int]$state["liked"] } catch {}
    $script:likeButton.IsEnabled = $browserFeaturesLive
    $script:dislikeButton.IsEnabled = $browserFeaturesLive
    $script:likeIcon.Stroke = if ($rating -eq 1) { $script:ratingLikeBrush } else { $script:ratingIdleBrush }
    $script:dislikeIcon.Stroke = if ($rating -eq -1) { $script:ratingDislikeBrush } else { $script:ratingIdleBrush }

    $trackIdentity = "$sourceKey|$(Normalize-TrackTitle ([string]$state["title"]))|$(Normalize-TrackTitle ([string]$state["artist"]))"
    $coverUrl = [string]$state["cover"]
    $nativeCover = $state["coverImage"]

    # Once a valid cover source has been selected for a track, keep it. Opera and
    # YouTube rotate signed URL query strings frequently; reloading those caused
    # the visible two-second flash.
    if ($trackIdentity -ne $script:lastCoverTrack -and $null -ne $nativeCover) {
        $cover.ImageSource = $nativeCover
        $note.Visibility = [System.Windows.Visibility]::Collapsed
        $script:lastCoverKey = "native:$trackIdentity"
        $script:lastCoverTrack = $trackIdentity
    } elseif ($trackIdentity -ne $script:lastCoverTrack -and $coverUrl) {
        try {
            $coverKey = "url:$(Get-CoverIdentity $coverUrl)"
            $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
            $bitmap.BeginInit()
            $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bitmap.UriSource = [Uri]$coverUrl
            $bitmap.EndInit()
            $bitmap.Freeze()
            $cover.ImageSource = $bitmap
            $note.Visibility = [System.Windows.Visibility]::Collapsed
            $script:lastCoverKey = $coverKey
            $script:lastCoverTrack = $trackIdentity
        } catch {}
    } elseif ($trackIdentity -ne $script:lastCoverTrack -and
              $trackIdentity -ne $script:lastTrackIdentity -and
              [string]::IsNullOrWhiteSpace($script:lastCoverTrack)) {
        if ($null -eq $nativeCover -and -not $coverUrl) {
            $cover.ImageSource = $null
            $note.Visibility = [System.Windows.Visibility]::Visible
            $script:lastCoverKey = ""
        }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$state["title"]) -and
        $trackIdentity -ne $script:lastTrackIdentity -and $script:trackTransitionReady) {
        $direction = 1
        if ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() -lt $script:pendingTrackDirectionUntil) {
            $direction = [int]$script:pendingTrackDirection
        }
        Start-TrackTransition $direction
        $script:pendingTrackDirection = 0
        $script:pendingTrackDirectionUntil = 0.0
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$state["title"])) {
        $script:trackTransitionReady = $true
    }
    $script:lastTrackIdentity = $trackIdentity
})
$refresh.Start()

$window.Add_Closed({
    $refresh.Stop()
    Unregister-IslandHotkeys
    $leaveTimer.Stop()
    $script:animationDriver.Dispose()
    if ($null -ne $script:hwndSource -and $null -ne $script:hitTestHook) {
        $script:hwndSource.RemoveHook($script:hitTestHook)
    }
    [IslandBridge]::Stop()
    $script:discordPresence.Dispose()
    try { $script:closeDropWindow.Close() } catch {}
})

$window.Add_ContentRendered({
    if ($StartExpanded) { Start-IslandAnimation $true }
    if ($StartSettings) {
        $window.Dispatcher.BeginInvoke(
            [Action]{ Show-IslandSettings },
            [System.Windows.Threading.DispatcherPriority]::Background
        ) | Out-Null
    }
})

$window.ShowDialog() | Out-Null

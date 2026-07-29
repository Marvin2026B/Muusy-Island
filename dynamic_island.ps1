param(
    [switch]$StartExpanded,
    [switch]$StartSettings
)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Web.Extensions
Add-Type -AssemblyName System.Runtime.WindowsRuntime
Add-Type -AssemblyName System.Drawing

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
    private static int nextId;
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
                var after = 0;
                var marker = target.IndexOf("after=");
                if (marker >= 0)
                {
                    var raw = target.Substring(marker + 6).Split('&')[0];
                    Int32.TryParse(raw, out after);
                }
                body = Json.Serialize(Commands.Where(command => Convert.ToInt32(command["id"]) > after).ToArray());
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
            CornerRadius="36" BorderThickness="1"
            BorderBrush="#1FFFFFFF"
            SnapsToDevicePixels="False"
            RenderTransformOrigin="0.5,0.5">
      <Border.Background>
        <SolidColorBrush x:Name="IslandFill" Color="#E8070709"/>
      </Border.Background>
      <Border.RenderTransform>
        <ScaleTransform x:Name="IslandScale" ScaleX="1" ScaleY="1"/>
      </Border.RenderTransform>
      <Border.Effect>
        <DropShadowEffect Color="#000000" BlurRadius="34" ShadowDepth="10"
                          Opacity="0.46" RenderingBias="Performance"/>
      </Border.Effect>
      <Grid ClipToBounds="True">
        <!-- glass inner top-lit highlight -->
        <Border CornerRadius="35" BorderThickness="1" Margin="1"
                IsHitTestVisible="False">
          <Border.BorderBrush>
            <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
              <GradientStop Color="#45FFFFFF" Offset="0"/>
              <GradientStop Color="#0DFFFFFF" Offset="0.5"/>
              <GradientStop Color="#0AFFFFFF" Offset="1"/>
            </LinearGradientBrush>
          </Border.BorderBrush>
        </Border>
        <!-- subtle top specular sheen -->
        <Border CornerRadius="36" IsHitTestVisible="False" Opacity="0.55">
          <Border.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
              <GradientStop Color="#14FFFFFF" Offset="0"/>
              <GradientStop Color="#00FFFFFF" Offset="0.28"/>
            </LinearGradientBrush>
          </Border.Background>
        </Border>

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
                    BorderBrush="#1EFFFFFF" BorderThickness="1">
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

            <StackPanel Grid.Column="2" VerticalAlignment="Center">
              <TextBlock x:Name="TitleText" Text="YouTube Music" Foreground="#F8FFFFFF"
                         FontSize="13.5" FontWeight="SemiBold"
                         TextTrimming="CharacterEllipsis"/>
              <TextBlock x:Name="ArtistText" Text="Opera GX verbinden" Foreground="#90FFFFFF"
                         FontSize="10.5" Margin="0,3,0,0"
                         TextTrimming="CharacterEllipsis"/>
            </StackPanel>

            <Grid Grid.Column="3" Width="40" Height="40" IsHitTestVisible="False">
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
                <Rectangle Width="2" Height="17" RadiusX="1" RadiusY="1"
                           Fill="#70FFFFFF" Margin="0.9,0" RenderTransformOrigin="0.5,0.5">
                  <Rectangle.RenderTransform><ScaleTransform x:Name="MiniVizScale1" ScaleY="0.28"/></Rectangle.RenderTransform>
                </Rectangle>
                <Rectangle Width="2" Height="17" RadiusX="1" RadiusY="1"
                           Fill="#88FFFFFF" Margin="0.9,0" RenderTransformOrigin="0.5,0.5">
                  <Rectangle.RenderTransform><ScaleTransform x:Name="MiniVizScale2" ScaleY="0.38"/></Rectangle.RenderTransform>
                </Rectangle>
                <Rectangle Width="2" Height="17" RadiusX="1" RadiusY="1"
                           Fill="#A4FFFFFF" Margin="0.9,0" RenderTransformOrigin="0.5,0.5">
                  <Rectangle.RenderTransform><ScaleTransform x:Name="MiniVizScale3" ScaleY="0.52"/></Rectangle.RenderTransform>
                </Rectangle>
                <Rectangle Width="2" Height="17" RadiusX="1" RadiusY="1"
                           Fill="#D0FFFFFF" Margin="0.9,0" RenderTransformOrigin="0.5,0.5">
                  <Rectangle.RenderTransform><ScaleTransform x:Name="MiniVizScale4" ScaleY="0.68"/></Rectangle.RenderTransform>
                </Rectangle>
                <Rectangle Width="2" Height="17" RadiusX="1" RadiusY="1"
                           Fill="#F2FFFFFF" Margin="0.9,0" RenderTransformOrigin="0.5,0.5">
                  <Rectangle.RenderTransform><ScaleTransform x:Name="MiniVizScale5" ScaleY="0.44"/></Rectangle.RenderTransform>
                </Rectangle>
                <Rectangle Width="2" Height="17" RadiusX="1" RadiusY="1"
                           Fill="#D0FFFFFF" Margin="0.9,0" RenderTransformOrigin="0.5,0.5">
                  <Rectangle.RenderTransform><ScaleTransform x:Name="MiniVizScale6" ScaleY="0.62"/></Rectangle.RenderTransform>
                </Rectangle>
                <Rectangle Width="2" Height="17" RadiusX="1" RadiusY="1"
                           Fill="#A4FFFFFF" Margin="0.9,0" RenderTransformOrigin="0.5,0.5">
                  <Rectangle.RenderTransform><ScaleTransform x:Name="MiniVizScale7" ScaleY="0.48"/></Rectangle.RenderTransform>
                </Rectangle>
                <Rectangle Width="2" Height="17" RadiusX="1" RadiusY="1"
                           Fill="#88FFFFFF" Margin="0.9,0" RenderTransformOrigin="0.5,0.5">
                  <Rectangle.RenderTransform><ScaleTransform x:Name="MiniVizScale8" ScaleY="0.34"/></Rectangle.RenderTransform>
                </Rectangle>
                <Rectangle Width="2" Height="17" RadiusX="1" RadiusY="1"
                           Fill="#70FFFFFF" Margin="0.9,0" RenderTransformOrigin="0.5,0.5">
                  <Rectangle.RenderTransform><ScaleTransform x:Name="MiniVizScale9" ScaleY="0.24"/></Rectangle.RenderTransform>
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
                Opacity="0" Visibility="Collapsed" IsHitTestVisible="False">
            <Grid.RowDefinitions>
              <RowDefinition Height="4"/>
              <RowDefinition Height="18"/>
              <RowDefinition Height="60"/>
              <RowDefinition Height="38"/>
              <RowDefinition Height="84"/>
              <RowDefinition Height="58"/>
              <RowDefinition Height="18"/>
            </Grid.RowDefinitions>

            <Border Grid.Row="0" Height="4" Background="#1EFFFFFF" CornerRadius="2">
              <Border x:Name="ProgressFill" Width="0" HorizontalAlignment="Left"
                      Background="#F2FFFFFF" CornerRadius="2"/>
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
              <Button x:Name="LikeButton" Width="36" Height="34" HorizontalAlignment="Left"
                      Style="{StaticResource TransportButtonStyle}" ToolTip="Gef&#228;llt mir">
                <Path x:Name="LikeIcon"
                      Data="M 7,17 H 3 V 8 H 7 M 7,8 L 11,2 C 12,2 13,3 13,4 V 7 H 18 C 19,7 19.5,8 19.2,9 L 17.5,16 C 17.3,16.7 16.7,17 16,17 H 7 Z"
                      Stroke="#B8FFFFFF" StrokeThickness="1.5" StrokeLineJoin="Round"
                      Width="20" Height="19" Stretch="Uniform"/>
              </Button>

              <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
                <Rectangle Width="3" Height="18" RadiusX="1.5" RadiusY="1.5"
                           Fill="#A8FFFFFF" Margin="2,0" RenderTransformOrigin="0.5,1">
                  <Rectangle.RenderTransform><ScaleTransform x:Name="VizScale1" ScaleY="0.2"/></Rectangle.RenderTransform>
                </Rectangle>
                <Rectangle Width="3" Height="18" RadiusX="1.5" RadiusY="1.5"
                           Fill="#C8FFFFFF" Margin="2,0" RenderTransformOrigin="0.5,1">
                  <Rectangle.RenderTransform><ScaleTransform x:Name="VizScale2" ScaleY="0.2"/></Rectangle.RenderTransform>
                </Rectangle>
                <Rectangle Width="3" Height="18" RadiusX="1.5" RadiusY="1.5"
                           Fill="#E8FFFFFF" Margin="2,0" RenderTransformOrigin="0.5,1">
                  <Rectangle.RenderTransform><ScaleTransform x:Name="VizScale3" ScaleY="0.2"/></Rectangle.RenderTransform>
                </Rectangle>
                <Rectangle Width="3" Height="18" RadiusX="1.5" RadiusY="1.5"
                           Fill="#FFFFFFFF" Margin="2,0" RenderTransformOrigin="0.5,1">
                  <Rectangle.RenderTransform><ScaleTransform x:Name="VizScale4" ScaleY="0.2"/></Rectangle.RenderTransform>
                </Rectangle>
                <Rectangle Width="3" Height="18" RadiusX="1.5" RadiusY="1.5"
                           Fill="#E8FFFFFF" Margin="2,0" RenderTransformOrigin="0.5,1">
                  <Rectangle.RenderTransform><ScaleTransform x:Name="VizScale5" ScaleY="0.2"/></Rectangle.RenderTransform>
                </Rectangle>
                <Rectangle Width="3" Height="18" RadiusX="1.5" RadiusY="1.5"
                           Fill="#C8FFFFFF" Margin="2,0" RenderTransformOrigin="0.5,1">
                  <Rectangle.RenderTransform><ScaleTransform x:Name="VizScale6" ScaleY="0.2"/></Rectangle.RenderTransform>
                </Rectangle>
                <Rectangle Width="3" Height="18" RadiusX="1.5" RadiusY="1.5"
                           Fill="#A8FFFFFF" Margin="2,0" RenderTransformOrigin="0.5,1">
                  <Rectangle.RenderTransform><ScaleTransform x:Name="VizScale7" ScaleY="0.2"/></Rectangle.RenderTransform>
                </Rectangle>
              </StackPanel>

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

              <TextBlock Grid.Row="1" Grid.Column="0" Text="1" Foreground="#48FFFFFF" FontSize="9.5" VerticalAlignment="Center"/>
              <TextBlock x:Name="QueueTitle1" Grid.Row="1" Grid.Column="1" Foreground="#D8FFFFFF" FontSize="10.5"
                         VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
              <TextBlock x:Name="QueueArtist1" Grid.Row="1" Grid.Column="2" Foreground="#62FFFFFF" FontSize="9.5"
                         TextAlignment="Right" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>

              <TextBlock Grid.Row="2" Grid.Column="0" Text="2" Foreground="#48FFFFFF" FontSize="9.5" VerticalAlignment="Center"/>
              <TextBlock x:Name="QueueTitle2" Grid.Row="2" Grid.Column="1" Foreground="#B8FFFFFF" FontSize="10.5"
                         VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
              <TextBlock x:Name="QueueArtist2" Grid.Row="2" Grid.Column="2" Foreground="#52FFFFFF" FontSize="9.5"
                         TextAlignment="Right" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>

              <TextBlock Grid.Row="3" Grid.Column="0" Text="3" Foreground="#48FFFFFF" FontSize="9.5" VerticalAlignment="Center"/>
              <TextBlock x:Name="QueueTitle3" Grid.Row="3" Grid.Column="1" Foreground="#98FFFFFF" FontSize="10.5"
                         VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
              <TextBlock x:Name="QueueArtist3" Grid.Row="3" Grid.Column="2" Foreground="#42FFFFFF" FontSize="9.5"
                         TextAlignment="Right" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
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
                  <Path Data="M 2,4 H 18 M 2,10 H 18 M 2,16 H 18"
                        Stroke="#D8FFFFFF" StrokeThickness="1.6"
                        StrokeStartLineCap="Round" StrokeEndLineCap="Round"/>
                  <Ellipse Width="4" Height="4" Fill="#F2FFFFFF" HorizontalAlignment="Left" Margin="4,0,0,12"/>
                  <Ellipse Width="4" Height="4" Fill="#F2FFFFFF" HorizontalAlignment="Right" Margin="0,6,5,6"/>
                  <Ellipse Width="4" Height="4" Fill="#F2FFFFFF" HorizontalAlignment="Left" Margin="8,12,0,0"/>
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
$script:dislikeIcon     = $window.FindName("DislikeIcon")
$script:queueEmpty      = $window.FindName("QueueEmpty")
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
$script:vizScales       = @(
    $window.FindName("VizScale1"),
    $window.FindName("VizScale2"),
    $window.FindName("VizScale3"),
    $window.FindName("VizScale4"),
    $window.FindName("VizScale5"),
    $window.FindName("VizScale6"),
    $window.FindName("VizScale7")
)
$script:miniVizScales   = @(
    $window.FindName("MiniVizScale1"),
    $window.FindName("MiniVizScale2"),
    $window.FindName("MiniVizScale3"),
    $window.FindName("MiniVizScale4"),
    $window.FindName("MiniVizScale5"),
    $window.FindName("MiniVizScale6"),
    $window.FindName("MiniVizScale7"),
    $window.FindName("MiniVizScale8"),
    $window.FindName("MiniVizScale9")
)
$script:miniIdleScales  = [double[]]@(0.28, 0.38, 0.52, 0.68, 0.44, 0.62, 0.48, 0.34, 0.24)
$script:miniCurrentScales = [double[]]@(0.28, 0.38, 0.52, 0.68, 0.44, 0.62, 0.48, 0.34, 0.24)
$script:lastMiniVizTime = 0.0
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
$collapsedRadius = 36.0
$expandedRadius  = 30.0

$script:expanded  = $false
$script:animating = $false
$script:dragging = $false
$script:lastCoverKey = ""
$script:lastCoverTrack = ""
$script:lastTrackIdentity = ""
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
    $workArea = [System.Windows.SystemParameters]::WorkArea
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

    $workArea = [System.Windows.SystemParameters]::WorkArea
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
        autostart = $false
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

            foreach ($name in @("position", "size", "hotkeysEnabled", "autostart", "customLeft", "customTop")) {
                $property = $loaded.PSObject.Properties[$name]
                if ($null -ne $property) { $settings.$name = $property.Value }
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
        $processName = [IO.Path]::GetFileNameWithoutExtension($path)
        $processIds = @(
            Get-Process -Name $processName -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty Id
        )
        if ($processIds.Count -gt 0 -and [AppWindowBridge]::FocusFirst([int[]]$processIds)) {
            Start-IslandAnimation $false
            return
        }

        Start-Process -FilePath $path -WorkingDirectory ([IO.Path]::GetDirectoryName($path))
        Start-IslandAnimation $false
    } catch {}
}

function Select-AppExecutable($nameBox, $pathBox) {
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Title = "App fuer die Dynamic Island auswaehlen"
    $dialog.Filter = "Programme (*.exe)|*.exe"
    $dialog.CheckFileExists = $true
    $dialog.Multiselect = $false
    if ($dialog.ShowDialog() -eq $true) {
        $pathBox.Text = $dialog.FileName
        if ([string]::IsNullOrWhiteSpace($nameBox.Text)) {
            $nameBox.Text = [IO.Path]::GetFileNameWithoutExtension($dialog.FileName)
        }
    }
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
                  <RowDefinition Height="28"/>
                  <RowDefinition Height="28"/>
                  <RowDefinition Height="28"/>
                </Grid.RowDefinitions>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="132"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Row="0" Text="Ctrl + Alt + Leertaste" Foreground="#A8FFFFFF" FontSize="9.5"/>
                <TextBlock Grid.Row="0" Grid.Column="1" Text="Play / Pause" Foreground="#68FFFFFF" FontSize="9.5"/>
                <TextBlock Grid.Row="1" Text="Ctrl + Alt + &#8592; / &#8594;" Foreground="#A8FFFFFF" FontSize="9.5"/>
                <TextBlock Grid.Row="1" Grid.Column="1" Text="Titel wechseln" Foreground="#68FFFFFF" FontSize="9.5"/>
                <TextBlock Grid.Row="2" Text="Ctrl + Alt + I" Foreground="#A8FFFFFF" FontSize="9.5"/>
                <TextBlock Grid.Row="2" Grid.Column="1" Text="Island &#246;ffnen" Foreground="#68FFFFFF" FontSize="9.5"/>
              </Grid>
            </StackPanel>
          </Grid>

          <Grid x:Name="AppsPanel" Margin="24,20,24,16" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <TextBlock Grid.Row="0" Text="App-Schnellzugriff" Foreground="#F0FFFFFF"
                       FontSize="16" FontWeight="SemiBold"/>
            <Grid Grid.Row="1" Margin="0,16,0,0">
              <Grid.RowDefinitions>
                <RowDefinition Height="24"/>
                <RowDefinition Height="58"/>
                <RowDefinition Height="58"/>
                <RowDefinition Height="58"/>
                <RowDefinition Height="58"/>
              </Grid.RowDefinitions>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="28"/>
                <ColumnDefinition Width="122"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="74"/>
              </Grid.ColumnDefinitions>

              <TextBlock Grid.Row="0" Grid.Column="1" Text="Name" Foreground="#58FFFFFF" FontSize="9.5"/>
              <TextBlock Grid.Row="0" Grid.Column="2" Text="Programmdatei" Foreground="#58FFFFFF" FontSize="9.5"/>

              <TextBlock Grid.Row="1" Grid.Column="0" Text="1" Foreground="#68FFFFFF" VerticalAlignment="Center"/>
              <TextBox x:Name="Name1" Grid.Row="1" Grid.Column="1" Margin="0,8,8,8" Style="{StaticResource SettingsTextBoxStyle}"/>
              <TextBox x:Name="Path1" Grid.Row="1" Grid.Column="2" Margin="0,8" Style="{StaticResource SettingsTextBoxStyle}"/>
              <Button x:Name="Browse1" Grid.Row="1" Grid.Column="3" Margin="8,8,0,8" Content="Datei..." Style="{StaticResource SettingsButtonStyle}"/>

              <TextBlock Grid.Row="2" Grid.Column="0" Text="2" Foreground="#68FFFFFF" VerticalAlignment="Center"/>
              <TextBox x:Name="Name2" Grid.Row="2" Grid.Column="1" Margin="0,8,8,8" Style="{StaticResource SettingsTextBoxStyle}"/>
              <TextBox x:Name="Path2" Grid.Row="2" Grid.Column="2" Margin="0,8" Style="{StaticResource SettingsTextBoxStyle}"/>
              <Button x:Name="Browse2" Grid.Row="2" Grid.Column="3" Margin="8,8,0,8" Content="Datei..." Style="{StaticResource SettingsButtonStyle}"/>

              <TextBlock Grid.Row="3" Grid.Column="0" Text="3" Foreground="#68FFFFFF" VerticalAlignment="Center"/>
              <TextBox x:Name="Name3" Grid.Row="3" Grid.Column="1" Margin="0,8,8,8" Style="{StaticResource SettingsTextBoxStyle}"/>
              <TextBox x:Name="Path3" Grid.Row="3" Grid.Column="2" Margin="0,8" Style="{StaticResource SettingsTextBoxStyle}"/>
              <Button x:Name="Browse3" Grid.Row="3" Grid.Column="3" Margin="8,8,0,8" Content="Datei..." Style="{StaticResource SettingsButtonStyle}"/>

              <TextBlock Grid.Row="4" Grid.Column="0" Text="4" Foreground="#68FFFFFF" VerticalAlignment="Center"/>
              <TextBox x:Name="Name4" Grid.Row="4" Grid.Column="1" Margin="0,8,8,8" Style="{StaticResource SettingsTextBoxStyle}"/>
              <TextBox x:Name="Path4" Grid.Row="4" Grid.Column="2" Margin="0,8" Style="{StaticResource SettingsTextBoxStyle}"/>
              <Button x:Name="Browse4" Grid.Row="4" Grid.Column="3" Margin="8,8,0,8" Content="Datei..." Style="{StaticResource SettingsButtonStyle}"/>
            </Grid>
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
        $browseButtons = @(
            $settingsWindow.FindName("Browse1"),
            $settingsWindow.FindName("Browse2"),
            $settingsWindow.FindName("Browse3"),
            $settingsWindow.FindName("Browse4")
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
        $hotkeysEnabled = $settingsWindow.FindName("HotkeysEnabled")
        $autostartEnabled = $settingsWindow.FindName("AutostartEnabled")

        $apps = @($script:appSettings.apps)
        for ($index = 0; $index -lt 4; $index++) {
            $nameBoxes[$index].Text = [string]$apps[$index].name
            $pathBoxes[$index].Text = [string]$apps[$index].path
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
        $hotkeysEnabled.IsChecked = [Convert]::ToBoolean($script:appSettings.hotkeysEnabled)
        $autostartEnabled.IsChecked = [Convert]::ToBoolean($script:appSettings.autostart)

        $browseButtons[0].Add_Click({ Select-AppExecutable $nameBoxes[0] $pathBoxes[0] })
        $browseButtons[1].Add_Click({ Select-AppExecutable $nameBoxes[1] $pathBoxes[1] })
        $browseButtons[2].Add_Click({ Select-AppExecutable $nameBoxes[2] $pathBoxes[2] })
        $browseButtons[3].Add_Click({ Select-AppExecutable $nameBoxes[3] $pathBoxes[3] })

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
                autostart = [bool]$autostartEnabled.IsChecked
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
Refresh-AppDock

$script:anim  = $null
$script:watch = New-Object System.Diagnostics.Stopwatch
$script:watch.Start()

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
        @{ id = 101; key = 0x20 }, # Ctrl+Alt+Space
        @{ id = 102; key = 0x25 }, # Ctrl+Alt+Left
        @{ id = 103; key = 0x27 }, # Ctrl+Alt+Right
        @{ id = 104; key = 0x49 }  # Ctrl+Alt+I
    )
    foreach ($definition in $definitions) {
        if ([IslandSystemBridge]::RegisterHotKey(
                $script:hwndSource.Handle,
                [int]$definition.id,
                0x0003,
                [uint32]$definition.key
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

function Start-IslandAnimation([bool]$open) {
    if ($script:animating -and $script:anim -and $script:anim.open -eq $open) { return }
    if (-not $script:animating -and $script:expanded -eq $open) { return }

    $script:expanded  = $open
    $script:animating = $true
    if ($open) {
        $script:details.Visibility = [System.Windows.Visibility]::Visible
    } else {
        $script:details.IsHitTestVisible = $false
    }

    $targetW = if ($open) { $expandedWidth }  else { $collapsedWidth }
    $targetH = if ($open) { $expandedHeight } else { $collapsedHeight }
    $targetR = if ($open) { $expandedRadius }  else { $collapsedRadius }

    $script:anim = [pscustomobject]@{
        open      = $open
        start     = $script:watch.Elapsed.TotalMilliseconds
        duration  = if ($open) { 280.0 } else { 230.0 }
        w0        = [double]$script:island.Width
        h0        = [double]$script:island.Height
        r0        = [double]$script:island.CornerRadius.TopLeft
        c0        = [double]$script:chevronRotate.Angle
        w1        = $targetW
        h1        = $targetH
        r1        = $targetR
        c1        = if ($open) { 180.0 } else { 0.0 }
        o0        = [double]$script:details.Opacity
        o1        = if ($open) { 1.0 } else { 0.0 }
    }
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

# ---- per-frame composition render loop (runs at display refresh, incl. 180Hz) ----
$renderHandler = [System.EventHandler]{
    param($sender, $e)

    if ($script:dragging) {
        Update-CloseDropTarget
    }

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
        $script:chevronRotate.Angle = $a.c0 + ($a.c1 - $a.c0) * $eMorph

        # opacity with stagger: details fade out FIRST on collapse, fade in LAST on expand
        if ($a.open) {
            $ot = [Math]::Max(0.0, ($t - 0.42) / 0.58)
        } else {
            $ot = [Math]::Min(1.0, $t / 0.42)
        }
        $oe = Ease-Cubic $ot
        $newOpacity = $a.o0 + ($a.o1 - $a.o0) * $oe
        $script:details.Opacity = $newOpacity
        $script:details.IsHitTestVisible = ($newOpacity -gt 0.6)

        if ($finished) {
            $script:island.Width = $a.w1
            $script:island.Height = $a.h1
            $script:island.CornerRadius = [System.Windows.CornerRadius]::new($a.r1)
            $script:chevronRotate.Angle = $a.c1
            $script:details.Opacity = $a.o1
            $script:details.IsHitTestVisible = $a.open
            if (-not $a.open) {
                $script:details.Visibility = [System.Windows.Visibility]::Collapsed
            }
            $script:anim = $null
            $script:animating = $false
            $script:islandScale.ScaleX = 1.0
            $script:islandScale.ScaleY = 1.0
        }
    }

    # 2. compact visualizer always runs at the display composition rate.
    $st = $script:lastState
    $miniVisualizerPlaying = (
        $st -and $st.Count -gt 0 -and [Convert]::ToBoolean($st["playing"])
    )
    $miniVisualizerTime = $script:watch.Elapsed.TotalSeconds
    $miniDeltaTime = if ($script:lastMiniVizTime -gt 0) {
        [Math]::Min(0.05, $miniVisualizerTime - $script:lastMiniVizTime)
    } else {
        0.016
    }
    $script:lastMiniVizTime = $miniVisualizerTime
    $miniSmoothing = 1.0 - [Math]::Exp(
        -$miniDeltaTime * $(if ($miniVisualizerPlaying) { 12.0 } else { 7.0 })
    )
    for ($bar = 0; $bar -lt $script:miniVizScales.Count; $bar++) {
        $targetScale = $script:miniIdleScales[$bar]
        if ($miniVisualizerPlaying) {
            $waveA = [Math]::Abs([Math]::Sin(($miniVisualizerTime * 3.25) + ($bar * 0.83)))
            $waveB = [Math]::Abs([Math]::Sin(($miniVisualizerTime * 1.75) - ($bar * 1.19)))
            $energy = (0.62 * $waveA) + (0.38 * $waveB)
            $targetScale = 0.14 + (0.86 * [Math]::Pow($energy, 1.28))
        }
        $script:miniCurrentScales[$bar] += (
            $targetScale - $script:miniCurrentScales[$bar]
        ) * $miniSmoothing
        $script:miniVizScales[$bar].ScaleY = $script:miniCurrentScales[$bar]
    }

    # 3. expanded progress interpolation and visualizer.
    if ($script:details.Visibility -eq [System.Windows.Visibility]::Visible -and
        $script:details.Opacity -gt 0.01 -and
        $st -and $st.Count -gt 0) {
        $dur2    = [double]$st["duration"]
        if ($dur2 -gt 0) {
            $cur = [double]$st["current"]
            $at  = [double]$st["at"]
            $playing2 = [Convert]::ToBoolean($st["playing"])
            if ($playing2 -and $at -gt 0) {
                $elapsed = ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $at) / 1000.0
                $cur = [Math]::Min($dur2, $cur + $elapsed)
            }
            $displaySecond = [int][Math]::Floor($cur)
            if ($displaySecond -ne $script:lastDisplayedSecond) {
                $currentText.Text = Format-Time $displaySecond
                $script:lastDisplayedSecond = $displaySecond
            }
            $available = [Math]::Max(0.0, [double]$script:details.ActualWidth)
            $script:progressFill.Width = [Math]::Min($available, $available * ($cur / $dur2))
        }

        $visualizerPlaying = [Convert]::ToBoolean($st["playing"])
        $visualizerTime = $script:watch.Elapsed.TotalSeconds
        for ($bar = 0; $bar -lt $script:vizScales.Count; $bar++) {
            $scale = 0.18
            if ($visualizerPlaying) {
                $wave = [Math]::Abs([Math]::Sin(
                    ($visualizerTime * (4.8 + ($bar * 0.34))) + ($bar * 1.37)
                ))
                $scale = 0.22 + (0.78 * [Math]::Pow($wave, 1.35))
            }
            $script:vizScales[$bar].ScaleY = $scale
        }
    }
}
[System.Windows.Media.CompositionTarget]::add_Rendering($renderHandler)

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

$window.Add_LocationChanged({
    if ($script:dragging) {
        Update-CloseDropTarget
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
    $script:dragging = $true
    try {
        $window.DragMove()
        $eventArgs.Handled = $true
    } catch {
        [Console]::Error.WriteLine("Island drag failed: " + $_.Exception.Message)
    } finally {
        $closeRequested = $script:closeDropArmed
        $script:dragging = $false
        if ($closeRequested) {
            Invoke-CloseDropAnimation
        } else {
            Set-CloseDropTargetVisible $false
            $workArea = [System.Windows.SystemParameters]::WorkArea
            $window.Left = [Math]::Max(
                $workArea.Left,
                [Math]::Min($window.Left, $workArea.Right - $window.Width)
            )
            $window.Top = [Math]::Max(
                $workArea.Top,
                [Math]::Min($window.Top, $workArea.Bottom - $window.Height)
            )
            $script:appSettings.position = "Custom"
            $script:appSettings.customLeft = [double]$window.Left
            $script:appSettings.customTop = [double]$window.Top
            $script:island.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
            $script:island.Margin = [System.Windows.Thickness]::new(0, 8, 0, 0)
            Save-IslandSettings
        }
    }
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

$mainPlay.Add_Click({ Send-MediaAction "play" })
$previousButton.Add_Click({ Send-MediaAction "prev" })
$nextButton.Add_Click({ Send-MediaAction "next" })
$script:likeButton.Add_Click({ Send-MediaAction "like" })
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
    if ($script:animating -or $script:dragging) { return }

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
            $nativeState["liked"] = $bridgeState["liked"]
        }
        $state = $nativeState
    }

    $script:lastState = $state

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
    $sourceName = [string]$state["sourceName"]
    if ([string]::IsNullOrWhiteSpace($sourceName)) { $sourceName = "YouTube Music" }
    $sourceKey = [string]$state["sourceKey"]
    if ([string]::IsNullOrWhiteSpace($sourceKey)) { $sourceKey = "youtube" }
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
        if ($queueIndex -lt $queueItems.Count -and $null -ne $queueItems[$queueIndex]) {
            $queueItem = $queueItems[$queueIndex]
            $script:queueTitles[$queueIndex].Text = [string]$queueItem["title"]
            $script:queueArtists[$queueIndex].Text = [string]$queueItem["artist"]
        } else {
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
    $script:lastTrackIdentity = $trackIdentity
})
$refresh.Start()

$window.Add_Closed({
    $refresh.Stop()
    Unregister-IslandHotkeys
    [System.Windows.Media.CompositionTarget]::remove_Rendering($renderHandler)
    if ($null -ne $script:hwndSource -and $null -ne $script:hitTestHook) {
        $script:hwndSource.RemoveHook($script:hitTestHook)
    }
    [IslandBridge]::Stop()
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

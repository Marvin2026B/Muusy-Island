using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

public sealed class DiscordPresenceClient : IDisposable
{
    private readonly object gate = new object();
    private readonly AutoResetEvent changed = new AutoResetEvent(false);
    private readonly ManualResetEvent stopping = new ManualResetEvent(false);
    private readonly Thread worker;
    private readonly JavaScriptSerializer json = new JavaScriptSerializer();
    private string clientId;
    private string title;
    private string artist;
    private string source;
    private double duration;
    private double position;
    private bool playing;
    private bool hasTrack;
    private bool disposed;
    private string lastSent;
    private string status = "Discord-Verbindung wird vorbereitet";
    private static readonly string LogPath = Path.Combine(Path.GetTempPath(), "muusy-island-discord-rpc.log");

    public DiscordPresenceClient(string applicationId)
    {
        clientId = NormalizeApplicationId(applicationId);
        worker = new Thread(WorkerLoop);
        worker.IsBackground = true;
        worker.Name = "Muusy Island Discord RPC";
        worker.Start();
    }

    public string Status
    {
        get { lock (gate) return status; }
    }

    private void SetStatus(string value)
    {
        lock (gate)
        {
            if (status == value) return;
            status = value;
        }
        try
        {
            if (File.Exists(LogPath) && new FileInfo(LogPath).Length > 256 * 1024)
                File.WriteAllText(LogPath, String.Empty);
            File.AppendAllText(LogPath,
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + value + Environment.NewLine,
                new UTF8Encoding(false));
        }
        catch { }
    }

    public void SetApplicationId(string applicationId)
    {
        string normalized = NormalizeApplicationId(applicationId);
        lock (gate)
        {
            if (clientId == normalized) return;
            clientId = normalized;
            lastSent = null;
        }
        changed.Set();
    }

    public void Update(string trackTitle, string trackArtist, string sourceName,
        bool isPlaying, double trackDuration, double trackPosition)
    {
        lock (gate)
        {
            title = Limit((trackTitle ?? String.Empty).Trim(), 128);
            artist = Limit((trackArtist ?? String.Empty).Trim(), 128);
            source = Limit((sourceName ?? String.Empty).Trim(), 64);
            duration = Math.Max(0, trackDuration);
            position = Math.Max(0, trackPosition);
            playing = isPlaying;
            hasTrack = title.Length > 0;
        }
        changed.Set();
    }

    public void Clear()
    {
        lock (gate)
        {
            hasTrack = false;
            title = String.Empty;
            artist = String.Empty;
            source = String.Empty;
        }
        changed.Set();
    }

    private static string NormalizeApplicationId(string value)
    {
        value = (value ?? String.Empty).Trim();
        ulong id;
        return UInt64.TryParse(value, out id) && id > 0 ? value : String.Empty;
    }

    private static string Limit(string value, int max)
    {
        if (value.Length <= max) return value;
        return value.Substring(0, max);
    }

    private void WorkerLoop()
    {
        NamedPipeClientStream pipe = null;
        string connectedId = null;
        while (!stopping.WaitOne(0))
        {
            try
            {
                string appId;
                Dictionary<string, object> activity;
                string fingerprint;
                lock (gate)
                {
                    appId = clientId;
                    activity = BuildActivity();
                    fingerprint = activity == null ? "" : json.Serialize(activity);
                }

                if (String.IsNullOrEmpty(appId))
                {
                    SetStatus("Discord Application ID fehlt");
                    if (pipe != null) { TryClear(pipe); pipe.Dispose(); pipe = null; }
                    connectedId = null;
                    lastSent = null;
                    WaitForChange(1000);
                    continue;
                }

                if (pipe == null || connectedId != appId || !pipe.IsConnected)
                {
                    if (pipe != null) { TryClear(pipe); pipe.Dispose(); }
                    SetStatus("Verbinde mit Discord");
                    pipe = Connect(appId);
                    connectedId = pipe == null ? null : appId;
                    lastSent = null;
                    if (pipe == null)
                    {
                        WaitForChange(2500);
                        continue;
                    }
                    SetStatus("Discord RPC verbunden");
                }

                if (fingerprint != lastSent)
                {
                    SendActivity(pipe, activity);
                    lastSent = fingerprint;
                    SetStatus(activity == null ? "Discord-Aktivität zurückgesetzt" : "Rich Presence gesendet");
                }

                WaitForChange(1000);
            }
            catch
            {
                SetStatus("Discord RPC getrennt");
                if (pipe != null) { try { pipe.Dispose(); } catch { } }
                pipe = null;
                connectedId = null;
                lastSent = null;
                WaitForChange(2500);
            }
        }

        if (pipe != null)
        {
            TryClear(pipe);
            try { pipe.Dispose(); } catch { }
        }
    }

    private Dictionary<string, object> BuildActivity()
    {
        if (!hasTrack || String.IsNullOrWhiteSpace(title)) return null;
        var activity = new Dictionary<string, object>();
        activity["type"] = 2;
        activity["name"] = source;
        activity["details"] = title;
        string state = artist;
        if (!playing) state = String.IsNullOrWhiteSpace(state) ? "Pausiert" : state + " · Pausiert";
        activity["state"] = Limit(state, 128);

        if (playing && duration > 0)
        {
            long now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            long end = now + Math.Max(1, (long)Math.Ceiling(duration - position));
            long start = end - Math.Max(1, (long)Math.Ceiling(duration));
            activity["timestamps"] = new Dictionary<string, object> { { "start", start }, { "end", end } };
        }
        if (!String.IsNullOrWhiteSpace(source))
        {
            var assets = new Dictionary<string, object> { { "large_text", source } };
            if (String.Equals(source, "Spotify", StringComparison.OrdinalIgnoreCase))
                assets["large_image"] = "spotify-logo-spotify-symbol-3";
            else if (String.Equals(source, "YouTube Music", StringComparison.OrdinalIgnoreCase))
                assets["large_image"] = "youtube-music-icon-free-png";
            if (assets.ContainsKey("large_image")) activity["assets"] = assets;
        }
        return activity;
    }

    private NamedPipeClientStream Connect(string appId)
    {
        string lastFailure = "No Discord IPC pipe was found.";
        for (int index = 0; index < 10 && !stopping.WaitOne(0); index++)
        {
            NamedPipeClientStream candidate = null;
            bool connected = false;
            try
            {
                candidate = new NamedPipeClientStream(".", "discord-ipc-" + index,
                    PipeDirection.InOut, PipeOptions.None);
                candidate.Connect(300);
                connected = true;
                WriteFrame(candidate, 0, new Dictionary<string, object>
                {
                    { "v", 1 }, { "client_id", appId }
                });
                SetStatus("Discord RPC handshake gesendet (Pipe " + index + ")");
                int opcode;
                ReadFrame(candidate, out opcode);
                if (opcode != 1) throw new IOException("Discord RPC handshake was rejected.");
                return candidate;
            }
            catch (Exception exception)
            {
                lastFailure = (connected ? "Handshake auf Pipe " + index + ": " : "Pipe " + index + ": ") + exception.Message;
                if (candidate != null) { try { candidate.Dispose(); } catch { } }
                if (connected) break;
            }
        }
        SetStatus("Discord RPC-Verbindung fehlgeschlagen: " + Limit(lastFailure, 140));
        return null;
    }

    private void SendActivity(NamedPipeClientStream pipe, Dictionary<string, object> activity)
    {
        var args = new Dictionary<string, object> { { "pid", System.Diagnostics.Process.GetCurrentProcess().Id } };
        args["activity"] = activity;
        WriteFrame(pipe, 1, new Dictionary<string, object>
        {
            { "cmd", "SET_ACTIVITY" }, { "args", args }, { "nonce", Guid.NewGuid().ToString("N") }
        });
        int opcode;
        string response = ReadFrame(pipe, out opcode);
        var envelope = json.DeserializeObject(response) as Dictionary<string, object>;
        object eventValue;
        if (envelope != null && envelope.TryGetValue("evt", out eventValue) &&
            String.Equals(Convert.ToString(eventValue), "ERROR", StringComparison.OrdinalIgnoreCase))
        {
            object dataValue;
            var data = envelope.TryGetValue("data", out dataValue) ? dataValue as Dictionary<string, object> : null;
            object messageValue;
            string message = data != null && data.TryGetValue("message", out messageValue)
                ? Convert.ToString(messageValue) : "Discord rejected the Rich Presence update.";
            SetStatus("Discord RPC Fehler: " + Limit(message, 140));
            throw new IOException(message);
        }
    }

    private void TryClear(NamedPipeClientStream pipe)
    {
        try
        {
            WriteFrame(pipe, 1, new Dictionary<string, object>
            {
                { "cmd", "SET_ACTIVITY" },
                { "args", new Dictionary<string, object>
                    { { "pid", System.Diagnostics.Process.GetCurrentProcess().Id }, { "activity", null } } },
                { "nonce", Guid.NewGuid().ToString("N") }
            });
            int opcode;
            ReadFrame(pipe, out opcode);
        }
        catch { }
    }

    private void WriteFrame(Stream stream, int opcode, object payload)
    {
        byte[] body = Encoding.UTF8.GetBytes(json.Serialize(payload));
        byte[] header = new byte[8];
        Buffer.BlockCopy(BitConverter.GetBytes(opcode), 0, header, 0, 4);
        Buffer.BlockCopy(BitConverter.GetBytes(body.Length), 0, header, 4, 4);
        byte[] packet = new byte[header.Length + body.Length];
        Buffer.BlockCopy(header, 0, packet, 0, header.Length);
        Buffer.BlockCopy(body, 0, packet, header.Length, body.Length);
        stream.Write(packet, 0, packet.Length);
        stream.Flush();
    }

    private string ReadFrame(Stream stream, out int opcode)
    {
        byte[] header = ReadExact(stream, 8);
        opcode = BitConverter.ToInt32(header, 0);
        int length = BitConverter.ToInt32(header, 4);
        if (length < 0 || length > 1024 * 1024) throw new IOException("Invalid Discord RPC frame length.");
        return Encoding.UTF8.GetString(ReadExact(stream, length));
    }

    private byte[] ReadExact(Stream stream, int length)
    {
        byte[] buffer = new byte[length];
        int offset = 0;
        while (offset < length)
        {
            int count = stream.Read(buffer, offset, length - offset);
            if (count <= 0) throw new EndOfStreamException("Discord RPC disconnected.");
            offset += count;
        }
        return buffer;
    }

    private void WaitForChange(int milliseconds)
    {
        WaitHandle.WaitAny(new WaitHandle[] { changed, stopping }, milliseconds);
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        stopping.Set();
        changed.Set();
        if (worker != Thread.CurrentThread) worker.Join(3500);
        changed.Dispose();
        stopping.Dispose();
    }
}

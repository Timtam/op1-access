using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;

namespace OP1AccessInstaller;

/// <summary>One file that goes into the report's ZIP.</summary>
internal sealed class ReportFile
{
    public ReportFile(string path, string zipName, bool text)
    {
        Path = path;
        ZipName = zipName;
        Text = text;
    }

    public string Path { get; }

    public string ZipName { get; }

    /// <summary>Text is cleaned of names and IDs and shortened if long; other files go as they are.</summary>
    public bool Text { get; }
}

/// <summary>One line of the attachment list: a log, or a crash with its dump.</summary>
internal sealed class ReportItem
{
    public string Title { get; set; }

    /// <summary>A short name for the report's list of attachments.</summary>
    public string Name { get; set; }

    public List<ReportFile> Files { get; } = new();

    public long Size { get; set; }

    public DateTime Time { get; set; }

    public bool Selected { get; set; }

    /// <summary>A crash dump: memory of the game, which can't be cleaned, so only on request.</summary>
    public bool IsDump { get; set; }

    public override string ToString() => Title;
}

/// <summary>The report's ZIP and what went into it.</summary>
internal sealed class ReportArchive
{
    public byte[] Zip { get; set; }

    public string FileName { get; set; }

    public List<ReportItem> Included { get; } = new();

    /// <summary>Chosen, but left out to stay under the size limit.</summary>
    public List<ReportItem> LeftOut { get; } = new();

    /// <summary>Long logs were shortened in the middle.</summary>
    public bool Shortened { get; set; }
}

/// <summary>
/// A log as its start and its end: <see cref="Head"/> (up to 128 KB, whole lines), then
/// <see cref="Skipped"/> bytes that were not read, then <see cref="Tail"/>. A short log is all
/// head and tail with nothing skipped.
/// </summary>
internal sealed class LogText
{
    public LogText(string head, string tail, long skipped)
    {
        Head = head ?? string.Empty;
        Tail = tail ?? string.Empty;
        Skipped = Math.Max(0, skipped);
    }

    public string Head { get; }

    public string Tail { get; }

    public long Skipped { get; }

    public string ZipName { get; set; }

    /// <summary>A whole text split after its first <paramref name="headChars"/> characters, at a line end.</summary>
    public static LogText Split(string text, int headChars)
    {
        if (text.Length <= headChars)
            return new LogText(text, string.Empty, 0);
        int cut = text.LastIndexOf('\n', headChars - 1);
        cut = cut > 0 ? cut + 1 : headChars;
        return new LogText(text.Substring(0, cut), text.Substring(cut), 0);
    }

    public bool CanShorten(int tailChars) => Tail.Length > tailChars + ProblemReport.Slack;

    public bool IsShortened(int tailChars) => Skipped > 0 || CanShorten(tailChars);

    /// <summary>The text with at most <paramref name="tailChars"/> characters of its end, and a note where lines are missing.</summary>
    public string Render(int tailChars)
    {
        string tail = Tail;
        long skipped = Skipped;
        if (CanShorten(tailChars))
        {
            tail = Tail.Substring(Tail.Length - tailChars);
            int start = tail.IndexOf('\n');
            if (start >= 0 && start < tail.Length - 1)
                tail = tail.Substring(start + 1);
            skipped += ProblemReport.Utf8.GetByteCount(Tail) - ProblemReport.Utf8.GetByteCount(tail);
        }

        return skipped > 0 ? Head + ProblemReport.Gap(skipped) + tail : Head + tail;
    }
}

/// <summary>
/// Replaces what identifies the user in text before it is sent: the Windows user name in profile
/// paths (C:\Users\name) and on its own, the computer name, Steam IDs (17 digits starting with
/// 7656119, e.g. in Documents\My Games\Octopath_Traveler\&lt;id&gt;), and the machine and login IDs
/// of the game's crash reports.
/// </summary>
internal sealed class Scrubber
{
    private static readonly Regex ProfilePath = new(@"(?i)\b([a-z]:(?:\\\\|\\|/)users(?:\\\\|\\|/))[^\\/:*?""<>|\r\n]+");
    private static readonly Regex SteamId = new(@"(?<!\d)7656119\d{10}(?!\d)");
    private static readonly Regex CrashIds = new(@"<(MachineId|LoginId|EpicAccountId|UserName)>[^<]*</\1>");
    private static readonly HashSet<string> GenericNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "user", "users", "admin", "administrator", "player", "owner", "default", "guest", "public", "test", "windows", "steam", "game", "home",
    };

    private readonly Regex _userName;
    private readonly Regex _machineName;

    public Scrubber(string userName, string machineName)
    {
        _userName = WordPattern(userName, 3);
        _machineName = WordPattern(machineName, 4);
    }

    public static Scrubber ForThisComputer() => new(Environment.UserName, Environment.MachineName);

    public string Apply(string text)
    {
        if (string.IsNullOrEmpty(text))
            return text;
        text = ProfilePath.Replace(text, match => match.Groups[1].Value + "<user>");
        text = SteamId.Replace(text, "<steamid>");
        text = CrashIds.Replace(text, match => $"<{match.Groups[1].Value}>(removed)</{match.Groups[1].Value}>");
        if (_userName != null)
            text = _userName.Replace(text, "<user>");
        if (_machineName != null)
            text = _machineName.Replace(text, "<computer>");
        return text;
    }

    private static Regex WordPattern(string name, int minLength)
    {
        name = name?.Trim();
        if (string.IsNullOrEmpty(name) || name.Length < minLength || GenericNames.Contains(name))
            return null;
        return new Regex(@"(?<![\p{L}\p{N}_])" + Regex.Escape(name) + @"(?![\p{L}\p{N}_])", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    }
}

/// <summary>
/// Gathers what a problem report can attach (the game's UE4SS log, the mod's session logs, the
/// installer's log, the game's crash reports) and packs the chosen ones into one ZIP under the
/// size limit of Static Forms.
/// </summary>
internal static class ProblemReport
{
    /// <summary>Static Forms takes 4.5 MB per submission, the form fields included.</summary>
    public const long ZipBudget = 4_000_000;

    public const string LastReportFile = "last-report.txt";

    internal const int HeadChars = 128 * 1024;
    internal const int MaxTailChars = 6 * 1024 * 1024;
    internal const int MinTailChars = 160 * 1024;

    /// <summary>A log at most this much longer than what is kept is not cut at all.</summary>
    internal const int Slack = 4096;

    internal static readonly UTF8Encoding Utf8 = new(false);

    /// <summary>Local header, data descriptor and central directory entry of one ZIP entry, roughly.</summary>
    private const int EntryOverhead = 256;
    private const int SessionLogs = 3;
    private const int MaxCrashes = 3;
    private static readonly TimeSpan CrashAgeWithoutReport = TimeSpan.FromDays(14);

    /// <summary>The mod's logs folder: logs\session-1.log (this or the last game session) to -3.</summary>
    public static string LogsDir(string gameDir) => Path.Combine(GameInstall.ModDir(gameDir), "logs");

    /// <summary>Where the game's own crash reporter writes (UE4CC-Windows-*\UE4Minidump.dmp).</summary>
    public static string CrashesDir() =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "My Games", "Octopath_Traveler", "Crashes");

    /// <summary>When the last report was sent from this game folder (UTC); null if never.</summary>
    public static DateTime? LastReport(string gameDir)
    {
        try
        {
            string file = Path.Combine(LogsDir(gameDir), LastReportFile);
            if (File.Exists(file) && DateTime.TryParse(File.ReadAllText(file).Trim(), CultureInfo.InvariantCulture,
                    DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out DateTime time))
                return time;
        }
        catch (Exception e) when (e is IOException || e is UnauthorizedAccessException || e is ArgumentException)
        {
            Log.Detail($"No last report time: {e.Message}");
        }

        return null;
    }

    public static void SetLastReport(string gameDir, DateTime utc)
    {
        try
        {
            string dir = LogsDir(gameDir);
            Directory.CreateDirectory(dir);
            File.WriteAllText(Path.Combine(dir, LastReportFile), utc.ToString("o", CultureInfo.InvariantCulture));
        }
        catch (Exception e) when (e is IOException || e is UnauthorizedAccessException || e is ArgumentException)
        {
            Log.Detail($"Could not write the last report time: {e.Message}");
        }
    }

    /// <summary>
    /// The attachments on offer. Logs are chosen at first; crash dumps (newer than the last report,
    /// or of the last 14 days, the newest three) only on request.
    /// </summary>
    public static List<ReportItem> Collect(string gameDir, string crashesDir, string installerLog, DateTime? lastReportUtc, DateTime nowUtc)
    {
        var items = new List<ReportItem>();
        if (!string.IsNullOrEmpty(gameDir))
        {
            string ue4ssLog = Path.Combine(GameInstall.UE4SSDir(gameDir), "UE4SS.log");
            if (TryInfo(ue4ssLog, out FileInfo info))
            {
                items.Add(new ReportItem
                {
                    Title = Strings.Get("report_item_ue4ss", Size(info.Length), Stamp(info.LastWriteTime)),
                    Name = "UE4SS.log",
                    Size = info.Length,
                    Time = info.LastWriteTimeUtc,
                    Selected = true,
                    Files = { new ReportFile(ue4ssLog, "UE4SS.log", true) },
                });
            }

            for (int i = 1; i <= SessionLogs; i++)
            {
                string log = Path.Combine(LogsDir(gameDir), $"session-{i}.log");
                if (!TryInfo(log, out info))
                    continue;
                string started = SessionStart(log);
                items.Add(new ReportItem
                {
                    Title = started == null
                        ? Strings.Get("report_item_session", Size(info.Length), Stamp(info.LastWriteTime))
                        : Strings.Get("report_item_session_from", Size(info.Length), started, Stamp(info.LastWriteTime)),
                    Name = $"session-{i}.log",
                    Size = info.Length,
                    Time = info.LastWriteTimeUtc,
                    Selected = true,
                    Files = { new ReportFile(log, $"session-{i}.log", true) },
                });
            }
        }

        if (!string.IsNullOrEmpty(installerLog) && TryInfo(installerLog, out FileInfo installer))
        {
            items.Add(new ReportItem
            {
                Title = Strings.Get("report_item_installer", Size(installer.Length)),
                Name = "installer.log",
                Size = installer.Length,
                Time = installer.LastWriteTimeUtc,
                Selected = true,
                Files = { new ReportFile(installerLog, "installer.log", true) },
            });
        }

        DateTime since = lastReportUtc ?? nowUtc - CrashAgeWithoutReport;
        items.AddRange(Crashes(crashesDir).Where(crash => crash.Time > since).Take(MaxCrashes));
        return items;
    }

    /// <summary>The game's crash reports, newest first.</summary>
    public static IEnumerable<ReportItem> Crashes(string crashesDir)
    {
        if (string.IsNullOrEmpty(crashesDir) || !Directory.Exists(crashesDir))
            return Enumerable.Empty<ReportItem>();
        var crashes = new List<ReportItem>();
        foreach (string dir in Directory.GetDirectories(crashesDir))
        {
            string dump = Path.Combine(dir, "UE4Minidump.dmp");
            if (!TryInfo(dump, out FileInfo info))
                continue;
            string folder = "crash-" + info.LastWriteTime.ToString("yyyy-MM-dd_HHmmss", CultureInfo.InvariantCulture);
            var crash = new ReportItem
            {
                Title = Strings.Get("report_item_crash", Stamp(info.LastWriteTime), Size(info.Length)),
                Name = folder,
                Size = info.Length,
                Time = info.LastWriteTimeUtc,
                IsDump = true,
                Files = { new ReportFile(dump, folder + "/UE4Minidump.dmp", false) },
            };
            string context = Path.Combine(dir, "CrashContext.runtime-xml");
            if (TryInfo(context, out FileInfo contextInfo))
            {
                crash.Files.Add(new ReportFile(context, folder + "/CrashContext.runtime-xml", true));
                crash.Size += contextInfo.Length;
            }

            crashes.Add(crash);
        }

        return crashes.OrderByDescending(crash => crash.Time);
    }

    /// <summary>
    /// Packs report.txt and the chosen items into one ZIP of at most <paramref name="budget"/> bytes:
    /// long logs are shortened in the middle (their start and end stay), and if that is not enough,
    /// the oldest items are left out. <paramref name="reportText"/> writes report.txt for what is in.
    /// </summary>
    public static ReportArchive Build(IEnumerable<ReportItem> chosen, Func<ReportArchive, string> reportText, Scrubber scrubber, long budget, DateTime now)
    {
        var archive = new ReportArchive { FileName = $"OP1Access-report-{now:yyyyMMdd-HHmmss}.zip" };
        List<Prepared> prepared = chosen.Select(item => Prepare(item, scrubber)).Where(p => p != null).ToList();
        while (true)
        {
            archive.Included.Clear();
            archive.Included.AddRange(prepared.Select(p => p.Item));
            byte[] text = Utf8.GetBytes(reportText(archive));
            long textSize = CompressedSize(text) + EntryOverhead;
            for (int tail = MaxTailChars; ;)
            {
                // Each size is worked out once per length and kept, so trying shorter logs is quick.
                if (textSize + prepared.Sum(p => p.EstimatedSize(tail)) <= budget)
                {
                    byte[] zip = Pack(prepared, tail, text);
                    if (zip.LongLength <= budget)
                    {
                        archive.Shortened = prepared.Any(p => p.Texts.Any(t => t.IsShortened(tail)));
                        archive.Zip = zip;
                        return archive;
                    }
                }

                // Halve the logs' ends while any log can still be shortened at all.
                if (tail == MinTailChars || !prepared.Any(p => p.Texts.Any(t => t.CanShorten(MinTailChars))))
                    break;
                tail = Math.Max(MinTailChars, tail / 2);
            }

            if (prepared.Count == 0)
                throw new InvalidOperationException("The report text alone is over the size limit.");

            // The oldest goes first; among items of the same age the bigger one.
            Prepared drop = prepared.OrderBy(p => p.Item.Time).ThenByDescending(p => p.Item.Size).First();
            prepared.Remove(drop);
            archive.LeftOut.Add(drop.Item);
        }
    }

    /// <summary>The first line of a session log: "OP1 Access session log, started 2026-11-23 13:09:35".</summary>
    public static string SessionStart(string path)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var reader = new StreamReader(stream, Utf8);
            string first = reader.ReadLine() ?? string.Empty;
            Match match = Regex.Match(first, @"started (\d{4}-\d\d-\d\d \d\d:\d\d)");
            if (match.Success && DateTime.TryParseExact(match.Groups[1].Value, "yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture, DateTimeStyles.None, out DateTime started))
                return Stamp(started);
        }
        catch (Exception e) when (e is IOException || e is UnauthorizedAccessException)
        {
        }

        return null;
    }

    /// <summary>Reads a text file that may be in use; a long one as its start and its end.</summary>
    public static LogText ReadText(string path, int headChars = HeadChars, int tailChars = MaxTailChars)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        long length = stream.Length;
        if (length <= (long)headChars + tailChars + Slack)
            return LogText.Split(Decode(ReadBytes(stream, 0, (int)length)), headChars);

        string head = Decode(ReadBytes(stream, 0, headChars));
        int headEnd = head.LastIndexOf('\n');
        if (headEnd > 0)
            head = head.Substring(0, headEnd + 1);
        string tail = Decode(ReadBytes(stream, length - tailChars, tailChars));
        int tailStart = tail.IndexOf('\n');
        if (tailStart >= 0 && tailStart < tail.Length - 1)
            tail = tail.Substring(tailStart + 1);
        return new LogText(head, tail, length - Utf8.GetByteCount(head) - Utf8.GetByteCount(tail));
    }

    public static string Size(long bytes) => bytes switch
    {
        < 1024 => $"{bytes} B",
        < 1024 * 1024 => string.Format(CultureInfo.CurrentCulture, "{0:0} KB", bytes / 1024.0),
        _ => string.Format(CultureInfo.CurrentCulture, "{0:0.0} MB", bytes / (1024.0 * 1024.0)),
    };

    internal static string Gap(long bytes) =>
        $"{Environment.NewLine}[... {Size(bytes)} left out here to stay under the size limit of the report ...]{Environment.NewLine}";

    /// <summary>How big the data is in the ZIP (the same deflate the ZIP uses).</summary>
    internal static long CompressedSize(byte[] data)
    {
        var counter = new CountingStream();
        using (var deflate = new DeflateStream(counter, CompressionLevel.Optimal, true))
            deflate.Write(data, 0, data.Length);
        return counter.Length;
    }

    private static string Stamp(DateTime local) => local.ToString("g", CultureInfo.CurrentCulture);

    private static bool TryInfo(string path, out FileInfo info)
    {
        info = null;
        try
        {
            info = new FileInfo(path);
            return info.Exists;
        }
        catch (Exception e) when (e is IOException || e is UnauthorizedAccessException || e is ArgumentException || e is NotSupportedException)
        {
            return false;
        }
    }

    private static Prepared Prepare(ReportItem item, Scrubber scrubber)
    {
        var prepared = new Prepared { Item = item };
        try
        {
            foreach (ReportFile file in item.Files)
            {
                if (file.Text)
                {
                    LogText text = ReadText(file.Path);
                    prepared.Texts.Add(new LogText(scrubber.Apply(text.Head), scrubber.Apply(text.Tail), text.Skipped) { ZipName = file.ZipName });
                }
                else
                {
                    using var stream = new FileStream(file.Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
                    prepared.Binaries.Add(new KeyValuePair<string, byte[]>(file.ZipName, ReadBytes(stream, 0, (int)Math.Min(stream.Length, int.MaxValue))));
                }
            }
        }
        catch (Exception e) when (e is IOException || e is UnauthorizedAccessException)
        {
            Log.Detail($"Leaving out {item.Name}: {e.Message}");
            return null;
        }

        return prepared;
    }

    private static byte[] Pack(IEnumerable<Prepared> prepared, int tailChars, byte[] reportText)
    {
        using var memory = new MemoryStream();
        using (var zip = new ZipArchive(memory, ZipArchiveMode.Create, true, Utf8))
        {
            Add(zip, "report.txt", reportText);
            foreach (Prepared item in prepared)
            {
                foreach (LogText text in item.Texts)
                    Add(zip, text.ZipName, Utf8.GetBytes(text.Render(tailChars)));
                foreach (KeyValuePair<string, byte[]> binary in item.Binaries)
                    Add(zip, binary.Key, binary.Value);
            }
        }

        return memory.ToArray();
    }

    private static void Add(ZipArchive zip, string name, byte[] data)
    {
        ZipArchiveEntry entry = zip.CreateEntry(name, CompressionLevel.Optimal);
        using Stream stream = entry.Open();
        stream.Write(data, 0, data.Length);
    }

    private static byte[] ReadBytes(Stream stream, long offset, int count)
    {
        stream.Seek(offset, SeekOrigin.Begin);
        var buffer = new byte[count];
        int done = 0;
        while (done < count)
        {
            int read = stream.Read(buffer, done, count - done);
            if (read <= 0)
                break;
            done += read;
        }

        if (done == count)
            return buffer;
        var shorter = new byte[done];
        Buffer.BlockCopy(buffer, 0, shorter, 0, done);
        return shorter;
    }

    /// <summary>UTF-8 (UE4SS, the mod and the installer write it), or UTF-16 with a byte order mark.</summary>
    private static string Decode(byte[] bytes)
    {
        if (bytes.Length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE)
            return Encoding.Unicode.GetString(bytes, 2, bytes.Length - 2);
        if (bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF)
            return Utf8.GetString(bytes, 3, bytes.Length - 3);
        return Utf8.GetString(bytes);
    }

    private sealed class Prepared
    {
        private readonly Dictionary<int, long> _sizes = new();
        private long _binarySize = -1;

        public ReportItem Item { get; set; }

        public List<LogText> Texts { get; } = new();

        public List<KeyValuePair<string, byte[]>> Binaries { get; } = new();

        public long EstimatedSize(int tailChars)
        {
            if (_binarySize < 0)
                _binarySize = Binaries.Sum(binary => CompressedSize(binary.Value) + EntryOverhead);
            // A tail longer than every text's own gives the same size, so it shares one entry.
            int key = Texts.Count == 0 ? 0 : Math.Min(tailChars, Texts.Max(text => text.Tail.Length));
            if (!_sizes.TryGetValue(key, out long size))
            {
                size = Texts.Sum(text => CompressedSize(Utf8.GetBytes(text.Render(tailChars))) + EntryOverhead);
                _sizes[key] = size;
            }

            return _binarySize + size;
        }
    }

    /// <summary>A stream that only counts what is written.</summary>
    private sealed class CountingStream : Stream
    {
        private long _length;

        public override bool CanRead => false;

        public override bool CanSeek => false;

        public override bool CanWrite => true;

        public override long Length => _length;

        public override long Position
        {
            get => _length;
            set => throw new NotSupportedException();
        }

        public override void Write(byte[] buffer, int offset, int count) => _length += count;

        public override void Flush()
        {
        }

        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();

        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();

        public override void SetLength(long value) => throw new NotSupportedException();
    }
}

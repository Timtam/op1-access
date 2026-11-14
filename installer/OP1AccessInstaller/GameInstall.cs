using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace OP1AccessInstaller;

/// <summary>An expected problem, with a message for the user.</summary>
internal sealed class InstallerException : Exception
{
    public InstallerException(string message, int exitCode = 1)
        : base(message)
    {
        ExitCode = exitCode;
    }

    public int ExitCode { get; }
}

/// <summary>What to install where.</summary>
internal sealed class InstallRequest
{
    public string GameDir { get; set; }
    public string PackageZip { get; set; }
    public bool WriteRegistry { get; set; } = true;

    /// <summary>Asked when another UE4SS build is installed: (packaged version) → replace it?</summary>
    public Func<string, bool> ReplaceOtherUE4SS { get; set; }
}

/// <summary>
/// Installs and removes UE4SS and OP1 Access in an Octopath Traveler folder. The game folder is the
/// one with Octopath_Traveler.exe (Steam's "OCTOPATH TRAVELER"); everything goes to
/// Octopath_Traveler\Binaries\Win64, next to the real game EXE: UE4SS (dwmapi.dll, UE4SS.dll,
/// settings, Mods\), phonon.dll (Steam Audio) and the mod in Mods\OP1Access.
/// </summary>
internal static class GameInstall
{
    public const string ModFolderName = "OP1Access";
    public const string LauncherExe = "Octopath_Traveler.exe";
    public const string ShippingExe = "Octopath_Traveler-Win64-Shipping.exe";
    public const string ModsTxtEntry = "OP1Access : 1";

    /// <summary>The launcher starts the shipping EXE; either one running means the game runs.</summary>
    private static readonly string[] GameProcessNames = { "Octopath_Traveler-Win64-Shipping", "Octopath_Traveler" };

    private static readonly string[] UE4SSCoreFiles = { "dwmapi.dll", "UE4SS.dll" };
    private const string UE4SSSettings = "UE4SS-settings.ini";

    /// <summary>The mods UE4SS 3.0.1 ships; removing UE4SS removes these (and leaves other mods alone).</summary>
    private static readonly string[] UE4SSStockMods =
    {
        "ActorDumperMod", "BPML_GenericFunctions", "BPModLoaderMod", "CheatManagerEnablerMod", "ConsoleCommandsMod",
        "ConsoleEnablerMod", "jsbLuaProfilerMod", "Keybinds", "LineTraceMod", "SplitScreenMod", "shared",
    };

    private static readonly (string Section, string Key, string Value)[] RequiredSettings =
    {
        // UE4SS's GUI console window crashed the game at start on some systems, and it would take
        // the focus away from the game anyway.
        ("Debug", "GuiConsoleEnabled", "0"),
    };

    /// <summary>Asset files the package put there, with their hashes: a file the user replaced stays on updates.</summary>
    private const string ShippedAssetsFile = "shipped-assets.txt";

    public static string BinDir(string gameDir) => Path.Combine(gameDir, "Octopath_Traveler", "Binaries", "Win64");

    public static string ModsDir(string gameDir) => Path.Combine(BinDir(gameDir), "Mods");

    public static string ModDir(string gameDir) => Path.Combine(ModsDir(gameDir), ModFolderName);

    public static bool IsGameFolder(string dir) =>
        !string.IsNullOrEmpty(dir) && Path.IsPathRooted(dir) && File.Exists(Path.Combine(dir, LauncherExe))
        && Directory.Exists(BinDir(dir));

    /// <summary>True for an ...\Octopath_Traveler\Binaries\Win64\Mods\OP1Access folder.</summary>
    public static bool IsModFolder(string dir)
    {
        DirectoryInfo mod = new(dir);
        DirectoryInfo mods = mod.Parent;
        DirectoryInfo bin = mods?.Parent;
        DirectoryInfo binaries = bin?.Parent;
        DirectoryInfo project = binaries?.Parent;
        return string.Equals(mod.Name, ModFolderName, StringComparison.OrdinalIgnoreCase)
            && string.Equals(mods?.Name, "Mods", StringComparison.OrdinalIgnoreCase)
            && string.Equals(bin?.Name, "Win64", StringComparison.OrdinalIgnoreCase)
            && string.Equals(binaries?.Name, "Binaries", StringComparison.OrdinalIgnoreCase)
            && string.Equals(project?.Name, "Octopath_Traveler", StringComparison.OrdinalIgnoreCase)
            && project.Parent != null;
    }

    public static string GameDirOfModFolder(string modDir) => new DirectoryInfo(modDir).Parent.Parent.Parent.Parent.Parent.FullName;

    /// <summary>A full path without a trailing backslash (except for a drive root).</summary>
    public static string NormalizeDir(string dir)
    {
        string trimmed = Path.GetFullPath(dir.Trim().Trim('"')).TrimEnd('\\', '/');
        return trimmed.EndsWith(":") ? trimmed + "\\" : trimmed;
    }

    /// <summary>The game folder from the command line, the last installation or the Steam libraries; null if unknown.</summary>
    public static string Locate(string requested)
    {
        if (!string.IsNullOrWhiteSpace(requested))
            return NormalizeDir(requested);
        string registered = UninstallEntry.RegisteredGameDir();
        if (IsGameFolder(registered))
            return registered;
        string found = SteamLocator.FindGame();
        return found == null ? null : NormalizeDir(found);
    }

    /// <summary>True if Octopath Traveler runs from this folder (or from a folder Windows does not tell).</summary>
    public static bool IsGameRunning(string gameDir)
    {
        List<Process> processes = GameProcesses(gameDir);
        processes.ForEach(process => process.Dispose());
        return processes.Count > 0;
    }

    /// <summary>Asks the game to close, like its close button.</summary>
    public static void CloseGame(string gameDir)
    {
        foreach (Process process in GameProcesses(gameDir))
        {
            using (process)
            {
                Log.Detail($"Asking {process.ProcessName} (process {process.Id}) to close");
                process.CloseMainWindow();
            }
        }
    }

    /// <summary>The version of the installed mod; "dev" for a build without version (copied by hand); null if not installed.</summary>
    public static string InstalledModVersion(string gameDir)
    {
        string scripts = Path.Combine(ModDir(gameDir), "Scripts");
        string version = ReadBuildInfo(Path.Combine(scripts, "buildinfo.lua"), "version");
        if (version != null)
            return version;
        return File.Exists(Path.Combine(scripts, "main.lua")) ? "dev" : null;
    }

    /// <summary>True if UE4SS's proxy DLL and core are in the game's Win64 folder.</summary>
    public static bool IsUE4SSInstalled(string gameDir) => UE4SSCoreFiles.All(file => File.Exists(Path.Combine(BinDir(gameDir), file)));

    /// <summary>A value from a buildinfo.lua the package script writes (version = "1.2.3"); null if missing.</summary>
    public static string ReadBuildInfo(string file, string key)
    {
        if (!File.Exists(file))
            return null;
        Match match = Regex.Match(File.ReadAllText(file), key + @"\s*=\s*""(?<value>[^""]*)""");
        return match.Success && match.Groups["value"].Value.Length > 0 ? match.Groups["value"].Value : null;
    }

    /// <summary>Installs the package and returns the installed mod version.</summary>
    public static string Install(InstallRequest request)
    {
        string game = request.GameDir;
        if (!IsGameFolder(game))
            throw new InstallerException(Strings.Get("not_game_folder", game), 2);
        if (IsGameRunning(game))
            throw new InstallerException(Strings.Get("game_running"), 3);

        string work = NewTempDir("OP1AccessPackage");
        try
        {
            Log.Info(Strings.Get("extracting"));
            ZipFile.ExtractToDirectory(request.PackageZip, work);
            string package = PackageRoot(work);
            string packageBin = BinDir(package);
            string packagedMod = ModDir(package);
            string version = ReadBuildInfo(Path.Combine(packagedMod, "Scripts", "buildinfo.lua"), "version");
            if (version == null || !File.Exists(Path.Combine(packagedMod, "Scripts", "main.lua")))
                throw new InstallerException(Strings.Get("not_a_package", Path.GetFileName(request.PackageZip)));
            string ue4ssVersion = ReadBuildInfo(Path.Combine(packagedMod, "Scripts", "buildinfo.lua"), "ue4ss") ?? "?";

            string bin = BinDir(game);
            InstallUE4SS(packageBin, bin, ue4ssVersion, request.ReplaceOtherUE4SS);

            Log.Info(Strings.Get("installing_mod", version));
            InstallModFolder(packagedMod, ModDir(game));
            string phonon = Path.Combine(packageBin, "phonon.dll");
            if (File.Exists(phonon))
                CopyFile(phonon, Path.Combine(bin, "phonon.dll"));

            Configure(packageBin, bin);
            CopySelf(ModDir(game));
            if (request.WriteRegistry)
                UninstallEntry.Write(game, version);
            return version;
        }
        finally
        {
            TryDeleteDirectory(work);
        }
    }

    /// <summary>Removes the mod and, if asked, UE4SS with its own mods.</summary>
    public static void Uninstall(string game, bool removeUE4SS, bool writeRegistry)
    {
        if (string.IsNullOrEmpty(game) || !Path.IsPathRooted(game))
            throw new InstallerException(Strings.Get("not_game_folder", game), 2);

        string modDir = ModDir(game);
        if (!IsGameFolder(game) && !Directory.Exists(modDir))
        {
            // The game was moved or removed; only the entry under Installed apps is left.
            Log.Info(Strings.Get("nothing_installed", game));
            if (writeRegistry)
                UninstallEntry.Remove();
            return;
        }

        if (IsGameRunning(game))
            throw new InstallerException(Strings.Get("game_running"), 3);

        string bin = BinDir(game);
        Log.Info(Strings.Get("removing", "OP1 Access"));
        DeleteDirectory(modDir);
        DeleteFile(Path.Combine(bin, "phonon.dll"));
        string modsTxt = Path.Combine(ModsDir(game), "mods.txt");
        if (File.Exists(modsTxt))
            WriteKeepingBom(modsTxt, SetModsTxtEntry(ReadKeepingBom(modsTxt, out bool bom), null), bom);

        if (removeUE4SS)
        {
            Log.Info(Strings.Get("removing", "UE4SS"));
            foreach (string file in UE4SSCoreFiles.Concat(new[] { UE4SSSettings, "UE4SS.log" }))
                DeleteFile(Path.Combine(bin, file));
            string mods = ModsDir(game);
            foreach (string stock in UE4SSStockMods)
                DeleteDirectory(Path.Combine(mods, stock));
            DeleteFile(modsTxt);
            if (Directory.Exists(mods) && !Directory.EnumerateFileSystemEntries(mods).Any())
                DeleteDirectory(mods);
        }

        if (writeRegistry)
            UninstallEntry.Remove();
    }

    /// <summary>Sets the given keys in an INI file and keeps everything else as it is.</summary>
    public static string PatchConfig(string text, IEnumerable<(string Section, string Key, string Value)> settings)
    {
        string newline = text.Contains("\r\n") ? "\r\n" : text.Contains("\n") ? "\n" : Environment.NewLine;
        List<string> lines = text.Length == 0 ? new List<string>() : text.Replace("\r\n", "\n").Split('\n').ToList();

        foreach ((string section, string key, string value) in settings)
        {
            string entry = $"{key} = {value}";
            int start = -1;
            int end = lines.Count;
            for (int i = 0; i < lines.Count; i++)
            {
                string trimmed = lines[i].Trim();
                if (!trimmed.StartsWith("[") || !trimmed.EndsWith("]"))
                    continue;
                if (start >= 0)
                {
                    end = i;
                    break;
                }
                if (string.Equals(trimmed.Substring(1, trimmed.Length - 2).Trim(), section, StringComparison.OrdinalIgnoreCase))
                    start = i;
            }

            if (start < 0)
            {
                while (lines.Count > 0 && lines[lines.Count - 1].Trim().Length == 0)
                    lines.RemoveAt(lines.Count - 1);
                if (lines.Count > 0)
                    lines.Add(string.Empty);
                lines.AddRange(new[] { $"[{section}]", entry, string.Empty });
                continue;
            }

            int found = -1;
            for (int i = start + 1; i < end && found < 0; i++)
            {
                string trimmed = lines[i].Trim();
                int equals = trimmed.IndexOf('=');
                if (!trimmed.StartsWith(";") && !trimmed.StartsWith("#") && equals > 0
                    && string.Equals(trimmed.Substring(0, equals).Trim(), key, StringComparison.OrdinalIgnoreCase))
                    found = i;
            }

            if (found >= 0)
            {
                lines[found] = entry;
                continue;
            }

            int insertAt = end;
            while (insertAt - 1 > start && lines[insertAt - 1].Trim().Length == 0)
                insertAt--;
            lines.Insert(insertAt, entry);
        }

        string result = string.Join(newline, lines);
        return result.EndsWith(newline) ? result : result + newline;
    }

    /// <summary>
    /// mods.txt with the OP1Access line set to <paramref name="entry"/> ("OP1Access : 1"), or removed
    /// when it is null. A missing line goes to the end, after the built-in Keybinds mod.
    /// </summary>
    public static string SetModsTxtEntry(string text, string entry)
    {
        string newline = text.Contains("\r\n") ? "\r\n" : text.Contains("\n") ? "\n" : "\r\n";
        List<string> lines = text.Length == 0 ? new List<string>() : text.Replace("\r\n", "\n").Split('\n').ToList();
        var ours = new Regex(@"^\s*" + Regex.Escape(ModFolderName) + @"\s*:", RegexOptions.IgnoreCase);
        int index = lines.FindIndex(line => ours.IsMatch(line));
        if (entry == null)
        {
            if (index >= 0)
                lines.RemoveAt(index);
        }
        else if (index >= 0)
        {
            lines[index] = entry;
        }
        else
        {
            while (lines.Count > 0 && lines[lines.Count - 1].Trim().Length == 0)
                lines.RemoveAt(lines.Count - 1);
            lines.Add(entry);
        }

        string result = string.Join(newline, lines);
        return result.Length == 0 || result.EndsWith(newline) ? result : result + newline;
    }

    public static string NewTempDir(string prefix)
    {
        string dir = Path.Combine(Path.GetTempPath(), $"{prefix}-{Guid.NewGuid():N}");
        Directory.CreateDirectory(dir);
        return dir;
    }

    public static void TryDeleteDirectory(string dir)
    {
        try
        {
            DeleteDirectory(dir);
        }
        catch (Exception e) when (e is IOException || e is UnauthorizedAccessException)
        {
            Log.Detail($"Could not delete {dir}: {e.Message}");
        }
    }

    private static void InstallUE4SS(string packageBin, string bin, string packagedVersion, Func<string, bool> replaceOther)
    {
        if (!File.Exists(Path.Combine(packageBin, "UE4SS.dll")))
        {
            Log.Detail("The package has no UE4SS");
            return;
        }

        bool installed = UE4SSCoreFiles.All(file => File.Exists(Path.Combine(bin, file)));
        bool same = installed && UE4SSCoreFiles.All(file => SameContent(Path.Combine(packageBin, file), Path.Combine(bin, file)));
        if (installed && !same)
        {
            // Another build (an experimental one deadlocked the game on NPC dialogue).
            if (replaceOther == null || !replaceOther(packagedVersion))
            {
                Log.Info(Strings.Get("keeping_ue4ss"));
                return;
            }

            Log.Info(Strings.Get("installing_ue4ss", packagedVersion));
            foreach (string file in UE4SSCoreFiles)
                CopyFile(Path.Combine(packageBin, file), Path.Combine(bin, file));
            return;
        }

        if (same)
            Log.Info(Strings.Get("ue4ss_present", packagedVersion));
        else
            Log.Info(Strings.Get("installing_ue4ss", packagedVersion));

        foreach (string file in UE4SSCoreFiles)
        {
            if (!same)
                CopyFile(Path.Combine(packageBin, file), Path.Combine(bin, file));
        }

        // Settings, mods.txt and UE4SS's own mods only where missing: the user's stay as they are.
        string settings = Path.Combine(bin, UE4SSSettings);
        if (!File.Exists(settings) && File.Exists(Path.Combine(packageBin, UE4SSSettings)))
            CopyFile(Path.Combine(packageBin, UE4SSSettings), settings);
        string packagedMods = Path.Combine(packageBin, "Mods");
        string mods = Path.Combine(bin, "Mods");
        Directory.CreateDirectory(mods);
        foreach (string dir in Directory.GetDirectories(packagedMods))
        {
            string name = Path.GetFileName(dir);
            if (!string.Equals(name, ModFolderName, StringComparison.OrdinalIgnoreCase) && !Directory.Exists(Path.Combine(mods, name)))
                CopyDirectory(dir, Path.Combine(mods, name));
        }
        if (!File.Exists(Path.Combine(mods, "mods.txt")) && File.Exists(Path.Combine(packagedMods, "mods.txt")))
            CopyFile(Path.Combine(packagedMods, "mods.txt"), Path.Combine(mods, "mods.txt"));
    }

    /// <summary>
    /// Replaces the mod folder, except for sounds in Assets the user put there or changed: a packaged
    /// asset overwrites a file only if that is the same as before or one an earlier package put there
    /// unchanged (listed in shipped-assets.txt with its hash).
    /// </summary>
    private static void InstallModFolder(string packagedMod, string modDir)
    {
        Dictionary<string, string> shipped = ReadShippedAssets(Path.Combine(modDir, ShippedAssetsFile));
        string assets = Path.Combine(modDir, "Assets");
        string keptAssets = null;
        if (Directory.Exists(assets))
        {
            keptAssets = NewTempDir("OP1AccessAssets");
            CopyDirectory(assets, keptAssets);
        }

        try
        {
            DeleteDirectory(modDir);
            CopyDirectory(packagedMod, modDir);

            var written = new List<string>();
            string packagedAssets = Path.Combine(packagedMod, "Assets");
            if (keptAssets != null)
            {
                foreach (string kept in Directory.GetFiles(keptAssets, "*", SearchOption.AllDirectories))
                {
                    string relative = kept.Substring(keptAssets.Length).TrimStart('\\');
                    string target = Path.Combine(assets, relative);
                    string packaged = Path.Combine(packagedAssets, relative);
                    if (!File.Exists(packaged))
                    {
                        // The user's own file.
                        Directory.CreateDirectory(Path.GetDirectoryName(target));
                        CopyFile(kept, target);
                        continue;
                    }

                    string keptHash = Sha256(kept);
                    bool unchanged = keptHash == Sha256(packaged)
                        || (shipped.TryGetValue(relative, out string old) && old == keptHash);
                    if (!unchanged)
                    {
                        Log.Info(Strings.Get("keeping_asset", relative));
                        CopyFile(kept, target);
                    }
                }
            }

            if (Directory.Exists(packagedAssets))
            {
                foreach (string packaged in Directory.GetFiles(packagedAssets, "*", SearchOption.AllDirectories))
                {
                    string relative = packaged.Substring(packagedAssets.Length).TrimStart('\\');
                    string target = Path.Combine(assets, relative);
                    if (File.Exists(target) && Sha256(target) == Sha256(packaged))
                        written.Add($"{relative}\t{Sha256(packaged)}");
                }
            }

            File.WriteAllLines(Path.Combine(modDir, ShippedAssetsFile), written);
        }
        finally
        {
            if (keptAssets != null)
                TryDeleteDirectory(keptAssets);
        }
    }

    private static Dictionary<string, string> ReadShippedAssets(string file)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (!File.Exists(file))
            return result;
        foreach (string line in File.ReadAllLines(file))
        {
            int tab = line.IndexOf('\t');
            if (tab > 0)
                result[line.Substring(0, tab)] = line.Substring(tab + 1).Trim();
        }

        return result;
    }

    private static void Configure(string packageBin, string bin)
    {
        Log.Info(Strings.Get("config"));
        string settings = Path.Combine(bin, UE4SSSettings);
        if (File.Exists(settings))
        {
            string text = ReadKeepingBom(settings, out bool bom);
            string patched = PatchConfig(text, RequiredSettings);
            if (patched != text)
            {
                WriteKeepingBom(settings, patched, bom);
                Log.Detail($"Wrote {settings}");
            }
        }

        string modsTxt = Path.Combine(bin, "Mods", "mods.txt");
        bool modsBom = false;
        string modsText = File.Exists(modsTxt) ? ReadKeepingBom(modsTxt, out modsBom) : string.Empty;
        string modsPatched = SetModsTxtEntry(modsText, ModsTxtEntry);
        if (modsPatched != modsText || !File.Exists(modsTxt))
        {
            WriteKeepingBom(modsTxt, modsPatched, modsBom);
            Log.Detail($"Wrote {modsTxt}");
        }
    }

    /// <summary>Puts this installer into the mod folder, so the mod can start it for updates.</summary>
    private static void CopySelf(string modDir)
    {
        string target = Path.Combine(modDir, Program.ExeName);
        if (string.Equals(Path.GetFullPath(Program.ExePath), Path.GetFullPath(target), StringComparison.OrdinalIgnoreCase))
            return;
        Version packaged = Releases.ParseVersion(File.Exists(target) ? FileVersionInfo.GetVersionInfo(target).ProductVersion : null);
        if (packaged != null && packaged > Program.InstallerVersion)
        {
            Log.Detail($"Keeping the newer installer {packaged} from the package");
            return;
        }

        CopyFile(Program.ExePath, target);
    }

    /// <summary>The folder with Octopath_Traveler in it, also when the ZIP has one folder around everything.</summary>
    private static string PackageRoot(string extracted)
    {
        if (Directory.Exists(Path.Combine(extracted, "Octopath_Traveler")))
            return extracted;
        string[] dirs = Directory.GetDirectories(extracted);
        return dirs.Length == 1 && Directory.Exists(Path.Combine(dirs[0], "Octopath_Traveler")) ? dirs[0] : extracted;
    }

    private static List<Process> GameProcesses(string gameDir)
    {
        string root = string.IsNullOrEmpty(gameDir) ? null : Path.GetFullPath(gameDir).TrimEnd('\\') + "\\";
        var result = new List<Process>();
        foreach (string name in GameProcessNames)
        {
            foreach (Process process in Process.GetProcessesByName(name))
            {
                string path = NativeMethods.ProcessImagePath(process.Id);
                if (root == null || path == null || Path.GetFullPath(path).StartsWith(root, StringComparison.OrdinalIgnoreCase))
                    result.Add(process);
                else
                    process.Dispose();
            }
        }

        return result;
    }

    private static string ReadKeepingBom(string file, out bool bom)
    {
        byte[] bytes = File.ReadAllBytes(file);
        bom = bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF;
        return new UTF8Encoding(false).GetString(bytes, bom ? 3 : 0, bytes.Length - (bom ? 3 : 0));
    }

    private static void WriteKeepingBom(string file, string text, bool bom)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(file));
        Retry(() => File.WriteAllText(file, text, new UTF8Encoding(bom)));
    }

    private static bool SameContent(string a, string b) =>
        File.Exists(a) && File.Exists(b) && new FileInfo(a).Length == new FileInfo(b).Length && Sha256(a) == Sha256(b);

    private static string Sha256(string file)
    {
        using var sha = SHA256.Create();
        using FileStream stream = File.OpenRead(file);
        return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", string.Empty).ToLowerInvariant();
    }

    private static void CopyDirectory(string source, string target)
    {
        if (!Directory.Exists(source))
            return;
        Directory.CreateDirectory(target);
        foreach (string file in Directory.GetFiles(source))
            CopyFile(file, Path.Combine(target, Path.GetFileName(file)));
        foreach (string dir in Directory.GetDirectories(source))
            CopyDirectory(dir, Path.Combine(target, Path.GetFileName(dir)));
    }

    private static void CopyFile(string source, string target)
    {
        Retry(() =>
        {
            if (File.Exists(target))
                File.SetAttributes(target, FileAttributes.Normal);
            File.Copy(source, target, true);
        });
        Log.Detail($"Copied {target}");
    }

    private static void DeleteDirectory(string dir)
    {
        if (!Directory.Exists(dir))
            return;
        Retry(() =>
        {
            foreach (string file in Directory.GetFiles(dir, "*", SearchOption.AllDirectories))
                File.SetAttributes(file, FileAttributes.Normal);
            Directory.Delete(dir, true);
        });
        Log.Detail($"Deleted {dir}");
    }

    private static void DeleteFile(string file)
    {
        if (!File.Exists(file))
            return;
        Retry(() =>
        {
            File.SetAttributes(file, FileAttributes.Normal);
            File.Delete(file);
        });
        Log.Detail($"Deleted {file}");
    }

    /// <summary>Virus scanners and a game that is just closing hold files for a moment.</summary>
    private static void Retry(Action action)
    {
        for (int attempt = 1; ; attempt++)
        {
            try
            {
                action();
                return;
            }
            catch (IOException) when (attempt < 6)
            {
                Thread.Sleep(500);
            }
            catch (UnauthorizedAccessException) when (attempt < 3)
            {
                Thread.Sleep(500);
            }
        }
    }
}

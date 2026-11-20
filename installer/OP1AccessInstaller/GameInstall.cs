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
/// Octopath_Traveler\Binaries\Win64, next to the real game EXE: UE4SS 4's proxy dwmapi.dll and
/// phonon.dll (Steam Audio) there, the rest of UE4SS in Win64\ue4ss (UE4SS.dll, its settings, its
/// log, Mods\) and the mod in ue4ss\Mods\OP1Access.
/// </summary>
internal static class GameInstall
{
    public const string ModFolderName = "OP1Access";
    public const string LauncherExe = "Octopath_Traveler.exe";
    public const string ShippingExe = "Octopath_Traveler-Win64-Shipping.exe";
    public const string ModsTxtEntry = "OP1Access : 1";

    /// <summary>The launcher starts the shipping EXE; either one running means the game runs.</summary>
    private static readonly string[] GameProcessNames = { "Octopath_Traveler-Win64-Shipping", "Octopath_Traveler" };

    private const string UE4SSProxy = "dwmapi.dll";
    private const string UE4SSCore = "UE4SS.dll";
    private const string UE4SSSettings = "UE4SS-settings.ini";
    private const string UE4SSFolderName = "ue4ss";

    /// <summary>The mods UE4SS 4.0 ships; removing UE4SS removes these (and leaves other mods alone).</summary>
    private static readonly string[] UE4SSStockMods =
    {
        "BPML_GenericFunctions", "BPModLoaderMod", "CheatManagerEnablerMod", "ConsoleCommandsMod",
        "ConsoleEnablerMod", "Keybinds", "LineTraceMod", "SplitScreenMod", "shared",
    };

    /// <summary>What else UE4SS 4 keeps in Win64\ue4ss.</summary>
    private static readonly string[] UE4SSExtraFiles = { "LICENSE", "UE4SS.log", "UE4SS.pdb" };
    private static readonly string[] UE4SSExtraDirs = { "UE4SS_SDK_Backends" };

    private static readonly (string Section, string Key, string Value)[] RequiredSettings =
    {
        // UE4SS's GUI console window crashed the game at start on some systems, and it would take
        // the focus away from the game anyway.
        ("Debug", "GuiConsoleEnabled", "0"),
    };

    /// <summary>Asset files the package put there, with their hashes: a file the user replaced stays on updates.</summary>
    private const string ShippedAssetsFile = "shipped-assets.txt";

    public static string BinDir(string gameDir) => Path.Combine(gameDir, "Octopath_Traveler", "Binaries", "Win64");

    /// <summary>UE4SS 4's folder: Win64\ue4ss.</summary>
    public static string UE4SSDir(string gameDir) => Path.Combine(BinDir(gameDir), UE4SSFolderName);

    public static string ModsDir(string gameDir) => Path.Combine(UE4SSDir(gameDir), "Mods");

    public static string ModDir(string gameDir) => Path.Combine(ModsDir(gameDir), ModFolderName);

    public static bool IsGameFolder(string dir) =>
        !string.IsNullOrEmpty(dir) && Path.IsPathRooted(dir) && File.Exists(Path.Combine(dir, LauncherExe))
        && Directory.Exists(BinDir(dir));

    /// <summary>True for an ...\Octopath_Traveler\Binaries\Win64\ue4ss\Mods\OP1Access folder.</summary>
    public static bool IsModFolder(string dir) => GameDirOfModFolder(dir) != null;

    /// <summary>The game folder of a mod folder, or null for another folder.</summary>
    public static string GameDirOfModFolder(string modDir)
    {
        static bool Named(DirectoryInfo d, string name) => d != null && string.Equals(d.Name, name, StringComparison.OrdinalIgnoreCase);
        DirectoryInfo mod = new(modDir);
        DirectoryInfo mods = mod.Parent;
        DirectoryInfo ue4ss = mods?.Parent;
        DirectoryInfo bin = ue4ss?.Parent;
        DirectoryInfo binaries = bin?.Parent;
        DirectoryInfo project = binaries?.Parent;
        bool ok = Named(mod, ModFolderName) && Named(mods, "Mods") && Named(ue4ss, UE4SSFolderName) && Named(bin, "Win64")
            && Named(binaries, "Binaries") && Named(project, "Octopath_Traveler") && project.Parent != null;
        return ok ? project.Parent.FullName : null;
    }

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

    /// <summary>True if UE4SS's proxy DLL is in the game's Win64 folder and its core in Win64\ue4ss.</summary>
    public static bool IsUE4SSInstalled(string gameDir) =>
        File.Exists(Path.Combine(BinDir(gameDir), UE4SSProxy)) && File.Exists(Path.Combine(UE4SSDir(gameDir), UE4SSCore));

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
            InstallUE4SS(package, game, ue4ssVersion, request.ReplaceOtherUE4SS);
            string modsDir = ModsDir(game);
            string modDir = ModDir(game);

            Log.Info(Strings.Get("installing_mod", version));
            InstallModFolder(packagedMod, modDir);
            string phonon = Path.Combine(packageBin, "phonon.dll");
            if (File.Exists(phonon))
                CopyFile(phonon, Path.Combine(bin, "phonon.dll"));

            Configure(modsDir);
            CopySelf(modDir);
            if (request.WriteRegistry)
                UninstallEntry.Write(game, version, modDir);
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

        if (!IsGameFolder(game) && !Directory.Exists(ModDir(game)))
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
        DeleteDirectory(ModDir(game));
        string modsTxt = Path.Combine(ModsDir(game), "mods.txt");
        if (File.Exists(modsTxt))
            WriteKeepingBom(modsTxt, SetModsTxtEntry(ReadKeepingBom(modsTxt, out bool bom), null), bom);
        DeleteFile(Path.Combine(bin, "phonon.dll"));

        if (removeUE4SS)
        {
            Log.Info(Strings.Get("removing", "UE4SS"));
            DeleteFile(Path.Combine(bin, UE4SSProxy));
            string ue4ss = UE4SSDir(game);
            foreach (string file in new[] { UE4SSCore, UE4SSSettings }.Concat(UE4SSExtraFiles))
                DeleteFile(Path.Combine(ue4ss, file));
            foreach (string dir in UE4SSExtraDirs)
                DeleteDirectory(Path.Combine(ue4ss, dir));
            RemoveStockMods(ModsDir(game));
            if (Directory.Exists(ue4ss) && !Directory.EnumerateFileSystemEntries(ue4ss).Any())
                DeleteDirectory(ue4ss);
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

    /// <summary>
    /// Puts the package's UE4SS 4 in place: dwmapi.dll in Win64, the rest in Win64\ue4ss, its own mods
    /// in ue4ss\Mods. Another UE4SS build stays if the user says so.
    /// </summary>
    private static void InstallUE4SS(string package, string game, string packagedVersion, Func<string, bool> replaceOther)
    {
        string bin = BinDir(game);
        string ue4ss = UE4SSDir(game);
        string packageBin = BinDir(package);
        string packageUE4SS = UE4SSDir(package);
        if (!File.Exists(Path.Combine(packageUE4SS, UE4SSCore)) || !File.Exists(Path.Combine(packageBin, UE4SSProxy)))
        {
            Log.Detail("The package has no UE4SS");
            return;
        }

        bool current = IsUE4SSInstalled(game);
        bool same = current && SameContent(Path.Combine(packageBin, UE4SSProxy), Path.Combine(bin, UE4SSProxy))
            && SameContent(Path.Combine(packageUE4SS, UE4SSCore), Path.Combine(ue4ss, UE4SSCore));
        if (current && !same)
        {
            // Another build (an experimental one deadlocked the game on NPC dialogue).
            if (replaceOther == null || !replaceOther(packagedVersion))
            {
                Log.Info(Strings.Get("keeping_ue4ss"));
                return;
            }
        }

        if (same)
        {
            Log.Info(Strings.Get("ue4ss_present", packagedVersion));
        }
        else
        {
            Log.Info(Strings.Get("installing_ue4ss", packagedVersion));
            Directory.CreateDirectory(ue4ss);
            CopyFile(Path.Combine(packageUE4SS, UE4SSCore), Path.Combine(ue4ss, UE4SSCore));
            CopyFile(Path.Combine(packageBin, UE4SSProxy), Path.Combine(bin, UE4SSProxy));
        }

        // The rest of UE4SS only where missing: the user's settings, mods.txt and mods stay as they are.
        foreach (string file in Directory.GetFiles(packageUE4SS))
        {
            string target = Path.Combine(ue4ss, Path.GetFileName(file));
            if (!File.Exists(target))
                CopyFile(file, target);
        }
        foreach (string dir in Directory.GetDirectories(packageUE4SS))
        {
            string name = Path.GetFileName(dir);
            if (!string.Equals(name, "Mods", StringComparison.OrdinalIgnoreCase) && !Directory.Exists(Path.Combine(ue4ss, name)))
                CopyDirectory(dir, Path.Combine(ue4ss, name));
        }
        string packagedMods = Path.Combine(packageUE4SS, "Mods");
        string mods = ModsDir(game);
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

    /// <summary>UE4SS's own mods and mods.txt in a Mods folder, and the folder once it is empty.</summary>
    private static void RemoveStockMods(string mods)
    {
        if (!Directory.Exists(mods))
            return;
        foreach (string stock in UE4SSStockMods)
            DeleteDirectory(Path.Combine(mods, stock));
        string modsTxt = Path.Combine(mods, "mods.txt");
        bool othersLeft = Directory.GetDirectories(mods).Any(dir =>
            !string.Equals(Path.GetFileName(dir), ModFolderName, StringComparison.OrdinalIgnoreCase));
        if (!othersLeft)
            DeleteFile(modsTxt);
        if (!Directory.EnumerateFileSystemEntries(mods).Any())
            DeleteDirectory(mods);
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

    /// <summary>UE4SS's settings (Win64\ue4ss, next to its Mods folder) and our line in mods.txt.</summary>
    private static void Configure(string modsDir)
    {
        Log.Info(Strings.Get("config"));
        string settings = Path.Combine(Directory.GetParent(modsDir).FullName, UE4SSSettings);
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

        string modsTxt = Path.Combine(modsDir, "mods.txt");
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

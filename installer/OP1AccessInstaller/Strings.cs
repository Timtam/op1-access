using System;
using System.Collections.Generic;
using System.Globalization;

namespace OP1AccessInstaller;

/// <summary>The installer's texts in English and German, chosen by the Windows display language.</summary>
internal static class Strings
{
    private static bool _german = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName == "de";

    private static readonly Dictionary<string, (string En, string De)> Table = new()
    {
        ["title"] = ("OP1 Access Installer", "OP1 Access Installer"),
        ["intro"] = ("This installs OP1 Access, the screen reader mod for Octopath Traveler, together with the UE4SS mod loader.",
                     "Dies installiert OP1 Access, den Screenreader-Mod für Octopath Traveler, zusammen mit dem Mod-Loader UE4SS."),
        ["game_folder"] = ("&Game folder", "&Spielordner"),
        ["change"] = ("C&hoose folder...", "&Ordner wählen …"),
        ["choose_folder"] = ("Select Octopath_Traveler.exe in the game folder", "Octopath_Traveler.exe im Spielordner auswählen"),
        ["log"] = ("&Progress", "&Verlauf"),

        ["installed"] = ("Installed version: {0}", "Installierte Version: {0}"),
        ["not_installed"] = ("OP1 Access is not installed.", "OP1 Access ist nicht installiert."),
        ["latest"] = ("Latest version: {0}", "Neueste Version: {0}"),
        ["latest_checking"] = ("Latest version: checking ...", "Neueste Version: wird geprüft …"),
        ["latest_unknown"] = ("Latest version: unknown ({0})", "Neueste Version: unbekannt ({0})"),
        ["latest_none"] = ("Latest version: none published yet", "Neueste Version: noch keine veröffentlicht"),
        ["no_repo"] = ("this build has no update source", "dieser Build hat keine Update-Quelle"),
        ["check_failed"] = ("no connection: {0}", "keine Verbindung: {0}"),
        ["ue4ss"] = ("UE4SS: installed", "UE4SS: installiert"),
        ["ue4ss_missing"] = ("UE4SS: not installed", "UE4SS: nicht installiert"),

        ["install"] = ("&Install", "&Installieren"),
        ["update"] = ("&Update to {0}", "&Aktualisieren auf {0}"),
        ["reinstall"] = ("&Reinstall", "&Neu installieren"),
        ["uninstall"] = ("U&ninstall", "&Deinstallieren"),
        ["remove_ue4ss"] = ("Also remove &UE4SS when uninstalling (other UE4SS mods stop working)",
                            "Beim Deinstallieren auch &UE4SS entfernen (andere UE4SS-Mods funktionieren dann nicht mehr)"),
        ["close"] = ("&Close", "Sch&ließen"),
        ["cancel"] = ("&Cancel", "Abbre&chen"),
        ["close_game"] = ("Close &Octopath Traveler", "&Octopath Traveler beenden"),

        ["game_missing"] = ("Octopath Traveler was not found. Choose the game folder (the one with Octopath_Traveler.exe).",
                            "Octopath Traveler wurde nicht gefunden. Wähle den Spielordner (den mit Octopath_Traveler.exe)."),
        ["not_game_folder"] = ("{0} is not an Octopath Traveler folder (Octopath_Traveler.exe and Octopath_Traveler\\Binaries\\Win64 are needed).",
                               "{0} ist kein Octopath-Traveler-Ordner (Octopath_Traveler.exe und Octopath_Traveler\\Binaries\\Win64 werden gebraucht)."),
        ["game_running"] = ("Octopath Traveler is running. Please close the game first.", "Octopath Traveler läuft. Bitte beende zuerst das Spiel."),

        ["checking"] = ("Checking for the latest version ...", "Suche nach der neuesten Version …"),
        ["downloading"] = ("Downloading {0} ...", "Lade {0} herunter …"),
        ["using_package"] = ("Using the package {0}.", "Verwende das Paket {0}."),
        ["extracting"] = ("Extracting the package ...", "Entpacke das Paket …"),
        ["installing_ue4ss"] = ("Installing UE4SS {0} ...", "Installiere UE4SS {0} …"),
        ["ue4ss_present"] = ("UE4SS {0} is already installed.", "UE4SS {0} ist bereits installiert."),
        ["keeping_ue4ss"] = ("Keeping the installed UE4SS.", "Das installierte UE4SS bleibt."),
        ["removing_old_ue4ss"] = ("Removing the old UE4SS 3 files ...", "Entferne die alten Dateien von UE4SS 3 …"),
        ["installing_mod"] = ("Installing OP1 Access {0} ...", "Installiere OP1 Access {0} …"),
        ["keeping_asset"] = ("Keeping your own sound {0}.", "Dein eigener Sound {0} bleibt."),
        ["config"] = ("Adjusting the UE4SS settings ...", "Passe die UE4SS-Einstellungen an …"),
        ["removing"] = ("Removing {0} ...", "Entferne {0} …"),

        ["done_install"] = ("OP1 Access {0} is installed.\n\nStart Octopath Traveler with your screen reader running. You hear \"OP1 Access loaded\" when the mod is ready.",
                            "OP1 Access {0} ist installiert.\n\nStarte Octopath Traveler, während dein Screenreader läuft. Wenn der Mod bereit ist, hörst du „OP1 Access loaded“."),
        ["installed_short"] = ("OP1 Access {0} is installed.", "OP1 Access {0} ist installiert."),
        ["done_uninstall"] = ("OP1 Access was removed.", "OP1 Access wurde entfernt."),
        ["done_uninstall_ue4ss"] = ("OP1 Access and UE4SS were removed.", "OP1 Access und UE4SS wurden entfernt."),
        ["nothing_installed"] = ("OP1 Access is not installed in {0}.", "OP1 Access ist nicht in {0} installiert."),
        ["confirm_uninstall"] = ("Remove OP1 Access from {0}?", "OP1 Access aus {0} entfernen?"),
        ["confirm_remove_ue4ss"] = ("Also remove UE4SS? Choose No if you use other UE4SS mods for Octopath Traveler.",
                                    "Auch UE4SS entfernen? Wähle Nein, wenn du andere UE4SS-Mods für Octopath Traveler nutzt."),

        ["error"] = ("Something went wrong: {0}\n\nThe log file is {1}", "Etwas ist schiefgegangen: {0}\n\nDie Protokolldatei ist {1}"),
        ["no_package"] = ("There is no package to install: {0}", "Es gibt kein Paket zum Installieren: {0}"),
        ["no_package_local"] = ("put the OP1Access ZIP next to the installer or start it with --zip <file>",
                                "lege die OP1Access-ZIP neben den Installer oder starte ihn mit --zip <Datei>"),
        ["not_a_package"] = ("{0} is not an OP1 Access package.", "{0} ist kein OP1-Access-Paket."),
        ["write_failed"] = ("Could not write to {0}. Start the installer as administrator?",
                            "Konnte nicht nach {0} schreiben. Den Installer als Administrator starten?"),
        ["other_ue4ss"] = ("Another UE4SS build is installed. OP1 Access is made for UE4SS {0}; other builds can freeze the game. Replace it? Choose No to keep it if other mods need it.",
                           "Ein anderer UE4SS-Build ist installiert. OP1 Access ist für UE4SS {0} gemacht; andere Builds können das Spiel einfrieren. Ersetzen? Wähle Nein, wenn andere Mods den installierten brauchen."),

        ["update_waiting"] = ("The update is downloaded. Please close Octopath Traveler; it is installed as soon as the game has closed.",
                              "Das Update ist heruntergeladen. Bitte beende Octopath Traveler; es wird installiert, sobald das Spiel geschlossen ist."),
        ["up_to_date"] = ("OP1 Access is up to date (version {0}).", "OP1 Access ist aktuell (Version {0})."),
        ["start_game_question"] = ("The update is installed. Start Octopath Traveler now?", "Das Update ist installiert. Octopath Traveler jetzt starten?"),
        ["start_game_now"] = ("Start Octopath Traveler now?", "Octopath Traveler jetzt starten?"),
        ["starting_game"] = ("Starting Octopath Traveler ...", "Starte Octopath Traveler …"),
        ["canceled"] = ("Canceled.", "Abgebrochen."),
        ["new_installer"] = ("A newer installer (version {0}) is available. Download and start it now?",
                             "Ein neuerer Installer (Version {0}) ist verfügbar. Jetzt herunterladen und starten?"),
        ["self_updating"] = ("Starting the new installer ...", "Starte den neuen Installer …"),
    };

    /// <summary>Overrides the display language ("de" or "en").</summary>
    public static void SetLanguage(string code)
    {
        if (!string.IsNullOrEmpty(code))
            _german = code.StartsWith("de", StringComparison.OrdinalIgnoreCase);
    }

    public static string Get(string key, params object[] args)
    {
        if (!Table.TryGetValue(key, out var text))
            return key;
        string format = _german ? text.De : text.En;
        return args.Length == 0 ? format : string.Format(format, args);
    }
}

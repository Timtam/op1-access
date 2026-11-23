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

        ["report_button"] = ("Report a pro&blem ...", "&Problem melden …"),
        ["report_unavailable"] = ("Problem reports are not available in this build: it was built without a form key.",
                                  "Problemberichte sind in diesem Build nicht verfügbar: Er wurde ohne Formularschlüssel gebaut."),
        ["report_title"] = ("Report a problem - OP1 Access", "Problem melden – OP1 Access"),
        ["report_shortcut"] = ("OP1 Access - Report a problem", "OP1 Access – Problem melden"),
        ["report_intro"] = ("Describe what happened and what you did just before. The report goes by e-mail to the developer of OP1 Access, through the form service Static Forms (staticforms.dev).",
                            "Beschreibe, was passiert ist und was du kurz vorher gemacht hast. Der Bericht geht per E-Mail an den Entwickler von OP1 Access, über den Formulardienst Static Forms (staticforms.dev)."),
        ["report_description"] = ("&What happened?", "&Was ist passiert?"),
        ["report_email"] = ("Your &e-mail address for questions (optional)", "Deine &E-Mail-Adresse für Rückfragen (freiwillig)"),
        ["report_files"] = ("&Attachments (Space checks or unchecks one)", "&Anhänge (die Leertaste wählt einen aus oder ab)"),
        ["report_privacy"] = ("Before sending, your Windows user name, your computer name and your Steam ID are replaced in the logs. Crash dumps can't be cleaned: they hold part of the game's memory at the moment of the crash and can contain paths and names. So they only go along when you check them.",
                              "Vor dem Senden werden in den Logs dein Windows-Benutzername, dein Computername und deine Steam-ID ersetzt. Absturz-Speicherabbilder lassen sich nicht bereinigen: Sie enthalten einen Teil des Spielspeichers im Moment des Absturzes und können Pfade und Namen enthalten. Darum gehen sie nur mit, wenn du sie ankreuzt."),
        ["report_system"] = ("&System information that goes along", "&Systemangaben, die mitgeschickt werden"),
        ["report_send"] = ("&Send", "&Senden"),
        ["report_collecting"] = ("Looking for logs and crash reports ...", "Suche Logs und Absturzberichte …"),
        ["report_found"] = ("Attachments found: {0}.", "Gefundene Anhänge: {0}."),
        ["report_dumps_found"] = ("Crash dumps among them, not checked yet: {0}.", "Davon Absturz-Speicherabbilder, noch nicht ausgewählt: {0}."),
        ["report_nothing_found"] = ("No logs or crash reports found; the report goes without attachments.",
                                    "Keine Logs oder Absturzberichte gefunden; der Bericht geht ohne Anhänge."),
        ["report_no_game"] = ("The game folder was not found, so the game's logs can't be attached.",
                              "Der Spielordner wurde nicht gefunden, darum können die Logs des Spiels nicht angehängt werden."),
        ["report_collect_failed"] = ("The logs could not be gathered: {0}", "Die Logs konnten nicht gesammelt werden: {0}"),
        ["report_need_description"] = ("Please describe the problem first.", "Bitte beschreibe zuerst das Problem."),
        ["report_bad_email"] = ("That doesn't look like an e-mail address. Correct it or leave the field empty.",
                                "Das sieht nicht nach einer E-Mail-Adresse aus. Korrigiere sie oder lass das Feld leer."),
        ["report_discard"] = ("Close without sending the report?", "Schließen, ohne den Bericht zu senden?"),
        ["report_packing"] = ("Packing the report ...", "Packe den Bericht …"),
        ["report_left_out"] = ("Too big for one report, left out: {0}", "Zu groß für einen Bericht, weggelassen: {0}"),
        ["report_protecting"] = ("Solving the spam protection ...", "Löse den Spamschutz …"),
        ["report_sending"] = ("Sending the report ({0}) ...", "Sende den Bericht ({0}) …"),
        ["report_sent"] = ("The report was sent. Thank you!", "Der Bericht wurde gesendet. Danke!"),
        ["report_altcha_failed"] = ("The spam protection could not be solved: {0}", "Der Spamschutz ließ sich nicht lösen: {0}"),
        ["report_failed_network"] = ("No connection to Static Forms ({0}). Check the internet connection and send again.",
                                     "Keine Verbindung zu Static Forms ({0}). Prüfe die Internetverbindung und sende noch einmal."),
        ["report_failed_rejected"] = ("Static Forms refused the report: {0}", "Static Forms hat den Bericht abgelehnt: {0}"),
        ["report_failed_key"] = ("Static Forms does not accept the form key of this build ({0}). Please report the problem another way.",
                                 "Static Forms nimmt den Formularschlüssel dieses Builds nicht an ({0}). Bitte melde das Problem auf anderem Weg."),
        ["report_failed_forbidden"] = ("Static Forms turned the report away: {0}. This can be the spam protection; send again.",
                                       "Static Forms hat den Bericht abgewiesen: {0}. Das kann am Spamschutz liegen; sende noch einmal."),
        ["report_failed_too_large"] = ("The report is too big. Check fewer attachments and send again.",
                                       "Der Bericht ist zu groß. Wähle weniger Anhänge aus und sende noch einmal."),
        ["report_failed_rate"] = ("Too many reports were sent just now. Please try again in a few minutes.",
                                  "Gerade wurden zu viele Berichte gesendet. Bitte versuche es in ein paar Minuten noch einmal."),
        ["report_failed_server"] = ("Static Forms reported an error ({0}: {1}). Please try again later.",
                                    "Static Forms hat einen Fehler gemeldet ({0}: {1}). Bitte versuche es später noch einmal."),
        ["report_item_ue4ss"] = ("UE4SS log of the current or last game session ({0}, last written {1})",
                                 "UE4SS-Log der laufenden oder letzten Spielsitzung ({0}, zuletzt geschrieben {1})"),
        ["report_item_session"] = ("Mod log of a game session ({0}, until {1})", "Mod-Log einer Spielsitzung ({0}, bis {1})"),
        ["report_item_session_from"] = ("Mod log of the game session from {1} to {2} ({0})", "Mod-Log der Spielsitzung von {1} bis {2} ({0})"),
        ["report_item_installer"] = ("Log of the installer's last runs ({0})", "Log der letzten Installer-Läufe ({0})"),
        ["report_item_crash"] = ("Crash on {0}: crash dump ({1})", "Absturz am {0}: Speicherabbild ({1})"),
    };

    public static bool German => _german;

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

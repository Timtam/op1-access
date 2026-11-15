# Translating OP1 Access

The mod speaks the game's own texts as the game shows them. Its own words ("Arrived",
"chest 1 of 5", "weak to ...") are English in the code and translated with gettext
files: `scripts/Mods/OP1Access/Scripts/lang/<language>.po`. The mod picks the file of
the game's text language (Options in the game), so German speech comes with the game set
to German. English needs no file. Shipped: German (`de.po`).

## Translating

1. Start a file for the language, or open the existing one:

   ```
   python scripts/i18n.py new fr
   ```

   Language codes as the game uses them: `de`, `fr`, `es`, `it`, `ja`, `ko`, `zh_cn`,
   `zh_tw`.
2. Open `lang/fr.po` in [Poedit](https://poedit.net) (or any text editor that saves
   UTF-8) and translate. Keep the `%s` and `%d` codes: each one is a name or a number the
   mod fills in, in the same order. Entries marked as plural have two forms ("1 target",
   "2 targets").
3. Copy the `.po` file into the game's `Mods\OP1Access\Scripts\lang` folder and start the
   game. An entry left empty or marked fuzzy stays English. The log (`UE4SS.log`) lists
   every English text spoken without a translation as `I18N missing: ...`, once each.

`python scripts/i18n.py check fr` counts what is translated and lists the rest; it also
reports translations whose `%`-codes don't match the English.

## For developers

- Wrap every text the mod says in `tr("...")`, a text with codes in `trf("... %s", x)`,
  a count in `trn("%d target", "%d targets", n)` (formatted with n, or with the extra
  arguments: `trn("%s, %d target. ", "%s, %d targets. ", n, name, n)`). The English text
  is the key, so it must be one literal: no `..` inside the call.
- A text that is said through a variable (a table of labels, a category name) is marked
  with `N_("...")` where it is written and translated with `tr(value)` where it is said.
  Keep comparing the English value in code (`kind == "save point"`); translate only what
  goes to speech.
- After changing texts: `python scripts/i18n.py update` rewrites `lang/op1access.pot` and
  merges it into every `.po` (new texts empty, old ones kept as obsolete `#~` entries).
- The release package copies `lang/*.po` and the template (`scripts/package.ps1`).

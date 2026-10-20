# Translating the app

You can translate the app's own text into your language: the home screen, Settings, the touch controls, the Cheats menu and every message the app shows. You don't need Xcode, GitHub or any files.

The game's own text (missions, subtitles, the phone, the menus inside the game) comes from Rockstar's files, which exist only in Rockstar's 13 languages. Translations of that are PC mods; see [MODS.md](MODS.md).

## How to translate

1. Open **[fivestarport.site/translate](https://fivestarport.site/translate/)** on your phone or computer.
2. Pick your language. If it isn't listed, add it by name.
3. Translate line by line. Each line says where it appears in the app. Your work is saved in your browser, so you can stop and come back later.
4. Tap **Send** when you're done. It goes straight to the developer. Add your name if you'd like to be thanked in the release notes.

A new language shows up in **Settings › Language** from the next release. Lines nobody has translated yet show in English. When the app is in a language Rockstar didn't make, the game's own text stays English.

You can also fix a language the app already has: pick it, and the page shows its current translations for you to change. After an update, the page shows the new lines first.

## Tips

- Keep parts like `{arg0}` exactly as written. The app puts a number or a name there. You can move them to wherever they fit in your sentence.
- Keep the line breaks. If the English has an empty line, yours needs one in the same place.
- Short labels (touch control buttons, Settings rows) have to stay short, or they get cut off on small iPhones.
- Use the words players know from GTA V in your language.
- Avoid the long dash (—). The page points it out.

## For developers

`app/Scripts/translations.py` does the work on the Mac:

```sh
python3 app/Scripts/translations.py export --out-dir <folder>   # lines.json + one file per language, for the translate page
python3 app/Scripts/translations.py check tr.json               # same checks as the page
python3 app/Scripts/translations.py merge tr.json               # writes it into app/App/Localizable.xcstrings
```

A language the translator added by name (not in the page's list) arrives with an `x-` code: pick its real code (the `.lproj` name Apple uses) with `--code`, for example `merge --code ckb file.json`.

`export` also lists lines the code shows that the catalog doesn't have yet, and catalog lines no code uses any more. Every line must go through `AppLanguage.choose("English text")`. A merged language that isn't one of the game's 13 appears in the language picker by itself.

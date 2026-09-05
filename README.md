# XLSConvertToString

XLSConvertToString is a small macOS utility for converting localization tables in `.xls` or `.csv` format into Apple `.strings` files.

## What it does

- Converts one `.xls` or `.csv` file into localized `.strings` output
- Saves multiple named conversion configurations for different spreadsheets and projects
- Supports exporting to a standalone folder of `*.strings` files
- Supports replacing `Localizable.strings` directly inside an existing project’s `<language>.lproj` folders
- Provides a helper tool to find unused localization keys in a source tree
- Imports translation-platform `.strings` attachments into a project

### Main window

![UI](./imgs/UI.png)

### Conversion result

![functions](./imgs/functions.png)

## Conversion configurations

The main window supports multiple named configurations so that one installation can work with several apps or projects. Each configuration remembers its own:

- Spreadsheet file
- Standalone `.strings` output directory
- Project localization directory
- Ordered language keys

Use **New** to create a blank configuration, **Duplicate** to use the current configuration as a starting point, and **Delete** to remove one. Edit **Configuration Name** directly to rename it. Conversion always uses the configuration currently selected in the picker.

When upgrading from a version that only supported one set of paths, the existing values are migrated automatically into a configuration named `Default`. At least one configuration is always retained.

## Spreadsheet format

The app uses the following column layout:

| Column | Meaning |
| --- | --- |
| 1 | Localization key |
| 2 | Note / comment column |
| 3+ | Translation columns, one column per language |

Notes:

- Empty key cells are skipped
- Empty translation cells are skipped
- Double quotes in values are escaped automatically
- Leading and trailing whitespace is trimmed before writing output
- CSV files must be UTF-8 encoded and follow standard CSV quoting rules. Quoted fields can contain commas, line breaks, and escaped quotes (`""`).
- XLS remains available during the CSV migration. New localization tables should use CSV.

## Conversion output modes

### 1. Export `.strings` files to a folder

The app writes one file per language key, for example:

- `en.strings`
- `es.strings`
- `de.strings`

Each file contains entries in the standard Apple format:

```text
"hello_key" = "Hello";
```

### 2. Replace project localization files directly

If you select a project localization directory, the app writes to:

- `<language>.lproj/Localizable.strings`

This is useful when you want to update an existing macOS or iOS project in place.

Both output modes can be enabled at the same time.

## More tools

The bottom of the main window contains two tool cards. Each tool opens in a separate window so its paths, status, and actions stay independent of the main conversion workflow.

### Import translation-platform attachments

Open **Translation Attachments** when the translation platform exports `.strings` files as attachments. Select the attachment directory and the project's localization directory, then click **Import Attachments**. Both paths are remembered globally and are not tied to the currently selected conversion configuration.

The attachment directory may contain one or more language folders such as:

```text
en.lproj/Localizable.strings
fr.lproj/Localizable.strings
```

The app finds every `*.lproj/Localizable.strings` file and directly replaces the matching file in the selected project directory. It creates a missing language folder when needed. The import does not merge keys, create backups, move, or archive the source attachments; use Git history to review or restore changes.

### Find unused localization keys

Open **Unused Localization Keys** to find localization keys from an XLS or CSV file that are not referenced in source code. Select the project source directory and spreadsheet, then click **Start Search**.

It scans:

- `.m`
- `.h`
- `.swift`

Optional behavior:

- Ignore comments while scanning source files

The result panel lists the remaining unused keys and shows progress while the scan runs. Its project and spreadsheet paths are remembered independently from conversion configurations.

## Usage

1. Open the app in Xcode and run it as a macOS app.
2. Select an existing conversion configuration, or create a new one for the app you want to update.
3. Select an `.xls` or `.csv` file. Each configuration remembers its own spreadsheet, output paths, and language keys.
4. Choose either:
   - an output folder for `.strings` files, or
   - a project localization folder to update `<language>.lproj/Localizable.strings`
5. Enter the language keys in the same order as the translation columns in the spreadsheet.
6. Click **Convert**.

After a successful conversion, the source spreadsheet is renamed in place with its completion time, for example `translate_20260714-153045.csv`. This preserves a versioned archive and leaves the original filename available for the next CSV export. If a file with the same timestamp already exists, the app adds a numeric suffix instead of overwriting it.

For example, if your spreadsheet uses these translation columns:

- `en`
- `es`
- `de`

Then the language keys field should be:

```text
en,es,de
```

## Build notes

- The project now vendors `libxls` source directly in `XLSConvertToString/Vendor/libxls` and builds it as part of the app target.
- This removes the previous Apple Silicon Rosetta dependency caused by the old `x86_64`-only `DHxlsReader` static library.
- The app now builds as a universal macOS binary (`arm64` + `x86_64`) on current Xcode versions.
- The code signing team identifier is intentionally not committed for open-source use. Set your own signing team locally if you want to archive or distribute the app.
- The bundle identifier is safe to change for your own release process if needed.

## License

This project is licensed under the MIT License. See [LICENSE](./LICENSE).

Bundled third-party code may use its own license terms:

- `XLSConvertToString/Vendor/libxls` is distributed under its included license at `XLSConvertToString/Vendor/libxls/LICENSE`.

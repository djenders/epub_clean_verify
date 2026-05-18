# EPUB Clean & Verify

A bash script for macOS that strips OceanofPDF watermarks from `.epub` files, normalizes em-dash and en-dash spacing, and verifies the result with [epubcheck](https://www.w3.org/publishing/epubcheck/). Designed to run as a Finder Quick Action so any EPUB (or batch of EPUBs) can be cleaned with a right-click.

## What it does

For each input `.epub`, the script:

1. **Validates** that the file is a real ZIP archive containing a `mimetype` entry (the EPUB spec requirement).
2. **Backs up** the original next to it as `<name>_original_backup.epub`.
3. **Unzips** the archive to a temp directory and snapshots it for the structural safety net described below.
4. **Removes** Ocean's loose promo file (`oceanofpdf.com`) if present.
5. **Strips watermarks** — `<div>...OceanofPDF...</div>` blocks in every text-bearing file (`.xhtml`, `.html`, `.opf`, `.ncx`).
6. **Normalizes dash spacing** in three passes:
   - `--` (double hyphen) → `—` (em-dash) in text content, never in attribute values.
   - `word—word` → `word — word` (add spaces on both sides).
   - `word —word` or `word— word` → `word — word` (normalize half-spaced cases).
7. **Verifies structure** — for each modified file, compares the count of `<section>`, `<body>`, `<html>`, `<ul>`, `<ol>`, and `<table>` tags against the snapshot. If anything doesn't balance (meaning the regex damaged structural markup), the file is restored from the snapshot and the watermark is left in place. Better one stray watermark than a corrupted file.
8. **Repacks** the EPUB with the correct mimetype-first, uncompressed order required by the spec.
9. **Runs epubcheck** if installed. A pass deletes any log; a fail writes `<name>_cleaned_epubcheck.log` next to the output.
10. **Reports** via a single macOS notification and a batch log at `~/Library/Logs/epub_clean_verify_<timestamp>.log`.

The script accepts one or more files. If you select 12 EPUBs and one fails, the other 11 still process and you get a summary at the end (`10 of 12 cleaned · 2 failed`).

## Why these specific choices

The watermark regex uses a tempered greedy pattern with a negative lookbehind (`(?<!/)>`) so it only matches opening `<div>` tags — not self-closing `<div id="x"/>` markers that some publishers (HarperCollins, for one) use as anchor points. Without the lookbehind, the regex would consume self-closing divs as openers and eat everything between them and the next real `</div>`, destroying any markup in between.

The structural safety net exists because regex-based HTML editing is inherently fragile. Even with a correct regex today, some future watermark variant could overlap with structural tags in a way that damages the file. The snapshot-and-compare pass turns a silent corruption bug into a logged warning with the watermark preserved — the worst-case outcome becomes "this book still has one watermark" instead of "this book no longer renders."

The script intentionally does not use `set -e` at the top level. A failure on file 3 of 12 should not kill the batch.

## Requirements

- **macOS** (uses BSD `find`, `osascript` for notifications)
- **bash 3.2+** (the version shipped with macOS)
- **unzip, zip, perl, grep, find** — all preinstalled on macOS
- **epubcheck** (optional, recommended): `brew install epubcheck`

## Installation

```bash
mkdir -p ~/.local/bin
mv epub_clean_verify.sh ~/.local/bin/
chmod +x ~/.local/bin/epub_clean_verify.sh
```

Verify it's executable:

```bash
ls -l ~/.local/bin/epub_clean_verify.sh
```

The first column should start with `-rwxr-xr-x`. If it doesn't, run `chmod +x` again.

Optional — add `~/.local/bin` to your shell PATH so you can run the script from any terminal session:

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

## Usage from the terminal

```bash
# Single file
epub_clean_verify.sh ~/Books/some_book.epub

# Multiple files
epub_clean_verify.sh ~/Books/*.epub

# From any directory if PATH is set; otherwise use the full path
~/.local/bin/epub_clean_verify.sh book.epub
```

## Creating the Quick Action

A Quick Action makes the script available from Finder's right-click menu.

1. **Open Automator** (Applications → Automator, or `⌘-Space` → "Automator").
2. Choose **New Document**, then **Quick Action**.
3. At the top of the workflow pane, set:
   - **Workflow receives current:** `files or folders`
   - **in:** `Finder`
   - **Image:** any icon you like (optional)
   - **Color:** any color (optional)
4. In the actions library on the left, search for **Run Shell Script** and drag it into the workflow area.
5. In the Run Shell Script action, set:
   - **Shell:** `/bin/bash`
   - **Pass input:** `as arguments`
6. Replace the default script with this single line:

   ```bash
   "$HOME/.local/bin/epub_clean_verify.sh" "$@"
   ```

7. Save the workflow with `⌘-S`. Name it something like **Clean & Verify EPUB**. The file goes to `~/Library/Services/` automatically.

## Using the Quick Action

1. In Finder, select one or more `.epub` files. (You can `⌘-click` to select multiple.)
2. Right-click and choose **Quick Actions → Clean & Verify EPUB** (or whatever you named it). On newer macOS, the action may also appear directly in the right-click menu without going through the Quick Actions submenu.
3. Wait for the notification in the top-right corner. For a single book this takes a few seconds; a large batch might take a minute.

The cleaned files appear in the same directory as the originals, with `_cleaned.epub` appended to the name. Backups of the originals are saved alongside as `_original_backup.epub`.

## Output files

For each input `book.epub` in a directory, the script produces:

| File | Purpose |
|------|---------|
| `book_cleaned.epub` | The cleaned, repacked EPUB. This is what you read. |
| `book_original_backup.epub` | A byte-identical copy of the input. Keep until you've verified the cleaned version. |
| `book_cleaned_epubcheck.log` | Only written if epubcheck found errors. Lists what's wrong with the cleaned file. |

Plus one batch log per script invocation at `~/Library/Logs/epub_clean_verify_<timestamp>.log` summarizing the whole run.

## Troubleshooting

**The Quick Action runs but nothing happens.**
Open Console.app and filter for "epub_clean_verify" to see the live output, or check the latest log in `~/Library/Logs/`. The most common cause is that the script path in the Run Shell Script action is wrong — verify it matches where you installed the script.

**"command not found: epub_clean_verify.sh"** from the terminal.
The script isn't on your PATH. Either use the full path (`~/.local/bin/epub_clean_verify.sh`) or add `~/.local/bin` to your PATH as shown in the install section.

**"epubcheck not installed" in the notification.**
The script still produced a cleaned file — it just skipped the verification step. Install epubcheck with `brew install epubcheck` if you want structural validation.

**Notification says "Cleaned with epubcheck errors."**
The output file exists and is usable, but epubcheck flagged issues. Check the `_epubcheck.log` file next to the cleaned EPUB. Some errors (like `RSC-012` fragment identifier warnings) are pre-existing problems in the publisher's source file and not something the script can fix.

**A book finished but the notification says one file was restored.**
The structural safety net caught damage in one of the cleaned files and reverted it from the snapshot. The book is still structurally valid, but that specific file still contains its watermark. The batch log will name the file and the tag that mismatched. You can clean that one page manually in Sigil or Calibre if you want.

**"Not a valid zip archive" on a file you know is an EPUB.**
The file is probably DRM-encrypted (typical of files from Apple Books, Amazon, or Kobo). The script can't process DRM-encrypted EPUBs; you'd need to remove DRM first using whatever tool is appropriate for your jurisdiction.

## What the script doesn't do

- Doesn't handle DRM-protected EPUBs.
- Doesn't fix pre-existing structural problems in the publisher's source file (broken anchor IDs, missing alt text, etc.).
- Doesn't process `.azw3`, `.mobi`, or other non-EPUB formats.
- Doesn't run in parallel — files are processed one at a time. Simpler, safer, easier to debug.
- Doesn't strip every possible watermark variant. The regex targets the OceanofPDF pattern specifically; other sources may need a different approach.

## Uninstall

```bash
rm ~/.local/bin/epub_clean_verify.sh
rm ~/Library/Services/Clean\ &\ Verify\ EPUB.workflow  # or whatever you named it
```

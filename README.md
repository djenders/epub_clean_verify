# EPUB Clean & Verify

A bash script for macOS that strips OceanofPDF watermarks from `.epub` files, normalizes em-dash and en-dash spacing, and verifies the result with [epubcheck](https://www.w3.org/publishing/epubcheck/). Designed to run as a Finder Quick Action so any EPUB (or batch of EPUBs) can be cleaned with a right-click.

## What it does

For each input `.epub`, the script:

1. **Validates** that the file is a real ZIP archive containing a `mimetype` entry (the EPUB spec requirement).
2. **Optionally backs up** the original next to it as `<name>_original_backup.epub` when `--backup` / `-b` is passed. Off by default; the original input file is never modified by the script.
3. **Unzips** the archive to a temp directory and snapshots it for the structural safety net described below.
4. **Removes** Ocean's loose promo file (`oceanofpdf.com`) if present.
5. **Strips watermarks** — `<div>...OceanofPDF...</div>` blocks in every text-bearing file (`.xhtml`, `.html`, `.opf`, `.ncx`).
6. **Normalizes dash spacing** in three passes:
   - `--` (double hyphen) → `—` (em-dash) in text content, never in attribute values.
   - `word—word` → `word — word` (add spaces on both sides).
   - `word —word` or `word— word` → `word — word` (normalize half-spaced cases).
7. **Verifies structure** — for each modified file, compares the count of `<section>`, `<body>`, `<html>`, `<ul>`, `<ol>`, and `<table>` tags against the snapshot. If anything doesn't balance (meaning the regex damaged structural markup), the file is restored from the snapshot and the watermark is left in place. Better one stray watermark than a corrupted file.
8. **Repacks** the EPUB with the correct mimetype-first, uncompressed order required by the spec.
9. **Runs epubcheck** if installed. If the cleaned file has errors, also runs epubcheck on the original to compare — this distinguishes pre-existing publisher errors from anything the script may have introduced. Both epubcheck outputs are appended to the consolidated run log under clear section headers.
10. **Reports** via a single macOS notification and a consolidated timestamped log file (`epub_clean_verify_<timestamp>.log`) placed in the same directory as the input files.

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

# With backup for an important book
epub_clean_verify.sh --backup ~/Books/irreplaceable.epub

# Show usage
epub_clean_verify.sh --help

# From any directory if PATH is set; otherwise use the full path
~/.local/bin/epub_clean_verify.sh book.epub
```

### Options

- `--backup`, `-b` — Save a copy of each input as `<name>_original_backup.epub`. Default: off. The script never modifies the original input file, so this is only useful as protection against you accidentally deleting the original.
- `--help`, `-h` — Show usage information.

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

### Optional: a second Quick Action with backups

If you want a right-click option that *also* keeps backups (for important or irreplaceable books), create a second Quick Action following the same steps. Use a distinctive name like **Clean & Verify EPUB (with backup)**, and change the shell script line to:

```bash
"$HOME/.local/bin/epub_clean_verify.sh" --backup "$@"
```

Now both options appear in the right-click menu and you can pick the right one for each book.

## Using the Quick Action

1. In Finder, select one or more `.epub` files. (You can `⌘-click` to select multiple.)
2. Right-click and choose **Quick Actions → Clean & Verify EPUB** (or whatever you named it). On newer macOS, the action may also appear directly in the right-click menu without going through the Quick Actions submenu.
3. Wait for the notification in the top-right corner. For a single book this takes a few seconds; a large batch might take a minute.

The cleaned files appear in the same directory as the originals, with `_cleaned.epub` appended to the name. The original files are never modified.

## Output files

For each input `book.epub` in a directory, the script produces:

| File | Purpose |
|------|---------|
| `book_cleaned.epub` | The cleaned, repacked EPUB. This is what you read. |
| `book_original_backup.epub` | Only created when `--backup` / `-b` is passed. A byte-identical copy of the input. The original input file is never modified by the script, so the backup is purely belt-and-suspenders insurance for accidentally-deleted originals. |

Plus one consolidated log per script invocation, written to the same directory as the inputs:

`epub_clean_verify_<YYYYMMDD_HHMMSS>.log`

The log opens with a summary section showing the run timing, totals (files cleaned, failed, introduced errors), how many watermarks were removed across the whole batch, and a per-book result line for each file. Full detail — including any epubcheck output — appears below the summary for when you need to dig in. Each invocation creates a new timestamped log; old logs are never overwritten.

A per-book result line looks like this:

```
✓ Book.epub → Book_cleaned.epub (epubcheck passed · 41 watermark(s) removed)
✓ Book.epub → Book_cleaned.epub (20 pre-existing source error(s) · 35 watermark(s) removed)
⚠ Book.epub → Book_cleaned.epub (2 error(s) introduced, 37 pre-existing · 41 watermark(s) removed)
✗ Not a valid zip archive: Book.epub
```

Every successful row reports the same two pieces of information in the same order: the epubcheck verdict (passed, count of pre-existing errors, or count of introduced errors), followed by the watermarks removed count. This makes the summary scannable like a table — a `0 watermark(s) removed` on a known OceanofPDF book is itself a useful signal (the file may have been pre-cleaned, or the watermark used a pattern outside the script's regex).

## Troubleshooting

**The Quick Action runs but nothing happens.**
Look in the same directory as the EPUBs you selected — there should be a fresh `epub_clean_verify_<timestamp>.log` file. Open it to see what happened. If there's no log file at all, the script never started, which usually means the script path in the Run Shell Script action is wrong; verify it matches where you installed the script.

**"command not found: epub_clean_verify.sh"** from the terminal.
The script isn't on your PATH. Either use the full path (`~/.local/bin/epub_clean_verify.sh`) or add `~/.local/bin` to your PATH as shown in the install section.

**"epubcheck not installed" in the notification.**
The script still produced a cleaned file — it just skipped the verification step. Install epubcheck with `brew install epubcheck` if you want structural validation.

**Notification says "Cleaned with epubcheck errors" or "introduced new errors".**
See the next section, "Reading epubcheck errors." The short version: most errors in Ocean books are pre-existing publisher problems, not script issues, and the script now tells you which is which.

**A book finished but the notification says one file was restored.**
The structural safety net caught damage in one of the cleaned files and reverted it from the snapshot. The book is still structurally valid, but that specific file still contains its watermark. The run log will name the file and the tag that mismatched. You can clean that one page manually in Sigil or Calibre if you want.

**"Not a valid zip archive" on a file you know is an EPUB.**
The file is probably DRM-encrypted (typical of files from Apple Books, Amazon, or Kobo). The script can't process DRM-encrypted EPUBs; you'd need to remove DRM first using whatever tool is appropriate for your jurisdiction.

## Reading epubcheck errors

When epubcheck reports errors on a cleaned file, the script runs epubcheck on the *original* too and compares error counts. The full output of both runs is appended to the consolidated log so you can see exactly what each one found. The notification and per-file summary line then tell you which of two situations you're in:

- **"Pre-existing source errors"** — the cleaned file has the same errors the original had. The script didn't cause them, and removing them isn't its job. The book will read fine in any reader; epubcheck is just being strict about XHTML spec compliance the publisher didn't meet. You can ignore these or fix them in Sigil/Calibre if you want a spec-perfect file.
- **"Introduced errors"** — the cleaned file has *more* errors than the original. This is the script's fault. The log file will show both epubcheck runs so you can see exactly which errors are new. This is worth reporting as a bug.

OceanofPDF books pulled from major publishers (HarperCollins, Random House, Simon & Schuster) routinely carry dozens or even thousands of pre-existing errors. This is normal; epubcheck is much stricter than most readers. A pre-existing-only error log means cleaning succeeded.

### Common error categories you can safely ignore

| Code | What it means | Why it's usually harmless |
|------|----|----|
| `RSC-005` "element X not allowed here" | Publisher used an EPUB 3 element in a file declared as EPUB 2 | Renders correctly everywhere; metadata declaration is the only thing off |
| `RSC-005` "img missing required attribute alt" | Publisher accessibility failure | Cosmetic; image still displays |
| `RSC-012` "Fragment identifier is not defined" | An internal link points at an anchor that doesn't exist | Bad link, but doesn't break the book |
| `OPF-031`, `OPF-032` "File listed in guide not declared in manifest" | Publisher manifest mismatch | Reader software ignores the guide and uses the spine |
| `RSC-004` "File is encrypted" | Adobe-obfuscated fonts | Info-level, not an error. Standard publishing practice |
| `RSC-007` "Referenced resource could not be found" | Manifest references missing file | Often paired with `OPF-031`; same publisher issue |
| `HTM-025` "value attribute on li" | Deprecated XHTML attribute | Renders correctly; just out of spec |

### The one "introduced error" you might see — and why it's not really damage

On some books — particularly ones where the publisher used EPUB 3 elements like `<section>` inside a file the OPF declares as EPUB 2 — you may see the script report a number of *introduced* errors all of the same shape:

```
ERROR(RSC-005): ... element "body" incomplete; expected element "address",
"blockquote", "del", "div", "dl", "h1", ... "ul" ...
```

Here's what's actually happening. In these books, Ocean's watermark `<div>` is placed inside `<body>` next to the publisher's `<section>`. The schema epubcheck is enforcing doesn't recognize `<section>` as a valid block child of `<body>` (that's an EPUB 3 element being checked against EPUB 2 rules — a pre-existing publisher issue). But the watermark `<div>` *is* a valid block child, so before cleaning, `<body>` had at least one element the parser accepted, and the "body incomplete" error didn't fire.

When the script removes the watermark, the only thing left in `<body>` is the `<section>` epubcheck doesn't recognize — and now it complains that `<body>` is empty (of valid elements). One new error per affected file.

The cleaned file renders perfectly in every actual reader (Apple Books, Kindle Previewer, Calibre, Thorium). The error is a strict-schema technicality, and it exists because the publisher's own markup was already out of spec for the version they declared. The watermark was, ironically, the only thing satisfying the validator. The script could mask this by inserting an empty `<p/>` placeholder in place of every stripped watermark, but that would mean modifying files beyond actual cleaning for a problem that's cosmetic — so it doesn't.

If you see this pattern (introduced errors with the exact same "body incomplete" message, one per chapter file), you can safely treat it the same as pre-existing publisher errors.

### When to actually worry

If the log shows errors with line numbers that match files Ocean's watermark touched (any `.xhtml`, `.html`, `.opf`, or `.ncx`), and those errors mention `</section>`, `</body>`, `</div>`, or tag-balance issues *other than* the "body incomplete" case above, that *could* be the script — open a backup vs. cleaned diff to compare. The structural safety net should catch most cases automatically, but a novel watermark pattern could slip through.

## What the script doesn't do

- Doesn't handle DRM-protected EPUBs.
- Doesn't fix pre-existing structural problems in the publisher's source file (broken anchor IDs, missing alt text, deprecated attributes, etc.). Use Sigil or Calibre's "Polish books" feature for those.
- Doesn't process `.azw3`, `.mobi`, or other non-EPUB formats.
- Doesn't run in parallel — files are processed one at a time. Simpler, safer, easier to debug.
- Doesn't strip every possible watermark variant. The regex targets the OceanofPDF pattern specifically; other sources may need a different approach.

## Uninstall

```bash
rm ~/.local/bin/epub_clean_verify.sh
rm ~/Library/Services/Clean\ &\ Verify\ EPUB.workflow  # or whatever you named it
```
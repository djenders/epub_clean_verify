#!/usr/bin/env bash
# epub_clean_verify.sh
# Quick Action: strip OceanofPDF watermarks, normalize dash spacing,
# repack as a valid EPUB, and verify with epubcheck.
#
# Accepts one or more .epub files. Processes them sequentially; if one
# fails, the rest still run. Writes a batch log to ~/Library/Logs and
# fires a single summary notification at the end.

set -uo pipefail
# Note: no `-e` at the top level. Per-file failures must not kill the
# whole batch. Each file is processed inside a function whose return
# code we check explicitly.

# Quick Actions launch with a minimal PATH; ensure Homebrew tools resolve.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# ---- Globals -------------------------------------------------------------

# Final log path is set after the first input's directory is known.
# During the run, all log output goes to a temp BODY_LOG; on completion
# we prepend the summary and write the final consolidated log.
BATCH_LOG=""
BODY_LOG="$(mktemp)"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

TOTAL=0
SUCCEEDED=0
FAILED=0
INTRODUCED_ERRORS=0   # script produced more epubcheck errors than the source had
TOTAL_WATERMARKS_REMOVED=0

# Track per-book results for the top-of-log summary.
RESULT_LINES=()

# ---- Helpers -------------------------------------------------------------

notify() {
  local title="$1"
  local message="$2"
  osascript -e "display notification \"${message//\"/\\\"}\" with title \"${title//\"/\\\"}\"" 2>/dev/null || true
}

log() {
  # Echo to stdout for live feedback, append to body log for archival.
  echo "$@"
  echo "$@" >>"$BODY_LOG"
}

log_only() {
  # Body log only — verbose per-file detail that would clutter stdout.
  echo "$@" >>"$BODY_LOG"
}

log_block() {
  # Append a block of text (e.g. raw epubcheck output) to the body log.
  # Reads from stdin so callers can pipe arbitrary content in.
  cat >>"$BODY_LOG"
}

# Collect a one-line summary entry for a processed file.
record_result() {
  RESULT_LINES+=("$1")
}

# Log a fatal-for-this-file message AND record it for the summary.
fail() {
  local msg="$1"
  log "$msg"
  record_result "$msg"
}

# ---- Per-file processor --------------------------------------------------
# Returns: 0 = success (epubcheck passed or missing)
#          1 = success but epubcheck reported errors
#          2 = hard failure (could not produce output)

process_one() {
  local input="$1"
  local input_dir input_file basename out_name output backup workdir
  local epubcheck_status="not_run"
  local remaining

  # --- Argument validation ---
  if [[ ! -f "$input" ]]; then
    fail "  ✗ Not a file: $input"
    return 2
  fi
  if [[ "${input##*.}" != "epub" ]]; then
    fail "  ✗ Not an .epub: $input"
    return 2
  fi

  input_dir="$(cd "$(dirname "$input")" && pwd)"
  input_file="$(basename "$input")"
  basename="${input_file%.epub}"

  # Strip the OceanofPDF prefix from the output name if present.
  if [[ "$input_file" == _OceanofPDF.com_* ]]; then
    out_name="${input_file:16}"
  else
    out_name="${basename}_cleaned.epub"
  fi

  output="$input_dir/$out_name"
  backup="$input_dir/${basename}_original_backup.epub"

  workdir="$(mktemp -d)"
  # Local trap: clean up this file's workdir on function exit.
  trap "rm -rf '$workdir'" RETURN

  log_only "  Input:  $input"
  log_only "  Output: $output"
  [[ "$KEEP_BACKUP" -eq 1 ]] && log_only "  Backup: $backup"

  # --- Pre-flight ---
  if ! unzip -l "$input" >/dev/null 2>&1; then
    fail "  ✗ Not a valid zip archive: $input_file"
    return 2
  fi

  local zip_listing
  zip_listing="$(unzip -l "$input")"
  if ! echo "$zip_listing" | grep -q " mimetype$"; then
    fail "  ✗ Missing mimetype entry: $input_file"
    return 2
  fi

  # --- Backup (optional) ---
  # The script never modifies the input file, so the backup is purely
  # belt-and-suspenders. Off by default; enable with --backup or -b.
  if [[ "$KEEP_BACKUP" -eq 1 ]]; then
    if ! cp "$input" "$backup"; then
      fail "  ✗ Could not create backup: $input_file"
      return 2
    fi
  fi

  # --- Unzip ---
  if ! unzip -q "$input" -d "$workdir"; then
    fail "  ✗ Unzip failed: $input_file"
    return 2
  fi

  if [[ ! -f "$workdir/mimetype" ]]; then
    fail "  ✗ Unzipped tree missing mimetype: $input_file"
    return 2
  fi
  if [[ ! -f "$workdir/META-INF/container.xml" ]]; then
    fail "  ✗ Unzipped tree missing META-INF/container.xml: $input_file"
    return 2
  fi

  # Normalize permissions on the unzipped tree. Some EPUBs (notably
  # certain OceanofPDF redistributions) have the file mode bits set to
  # 0000 inside the ZIP itself — meaning the extracted files are
  # unreadable to the user that just unzipped them. Terminal sessions
  # often work around this via permissive umask or root, but Quick
  # Actions run in a sandboxed bash that honors the 0000 strictly,
  # causing zip to fail with "Permission denied" on repack. Forcing
  # readable+writable on the whole tree is harmless for normal EPUBs
  # and rescues the broken ones.
  chmod -R u+rwX "$workdir" 2>/dev/null || true

  # --- Content cleaning ---

  # Remove loose OceanofPDF promo files. Silent on books without them.
  rm -f "$workdir/oceanofpdf.com" \
        "$workdir/OceanofPDF.com" \
        "$workdir"/OEBPS/oceanofpdf.com 2>/dev/null || true

  # Snapshot the unzipped tree before any text edits. If a file ends up
  # structurally damaged by an aggressive regex match, we can restore it
  # from this snapshot per-file.
  local snapshot
  snapshot="$(mktemp -d)"
  cp -R "$workdir/." "$snapshot/"

  # Watermark: <div ...>...OceanofPDF...</div> with arbitrary nested
  # content. Tempered-greedy regex matches across nested tags without
  # overshooting.
  #
  # The (?<!/) negative lookbehind is critical: it ensures the regex
  # only matches OPENING <div> tags, not self-closing <div .../>. Some
  # publishers (e.g. HarperCollins) use <div id="x"/> as a structural
  # marker; without the lookbehind, the regex sees those as openers
  # and runs forward until it finds OceanofPDF in a sibling div,
  # consuming all the markup in between — including </section> tags.
  local watermark_re='s{<div\b[^>]*(?<!/)>(?:(?!</div>).)*?OceanofPDF(?:(?!</div>).)*?</div>}{}gis'

  # Dash normalization, three passes:
  #
  # 1. Double hyphen → em-dash. Some sources use `--` as a poor man's
  #    em-dash. Only convert in text content (between '>' and '<'), so
  #    we don't touch attribute values like href="x--y".
  local doublehyphen_re='s{(>[^<]*?)--(?=[^<]*?<)}{$1\x{2014}}g'
  #
  # 2. No-space case: word—word → word — word. Both sides non-space.
  local dash_nospace_re='s{(\S)(\x{2014}|\x{2013}|&\#8212;|&\#8211;|&\#x2014;|&\#x2013;)(\S)}{$1 $2 $3}g'
  #
  # 3. Half-space case: `word —word` or `word— word` → `word — word`.
  #    Normalize to exactly one space on each side. Skip when one side
  #    is an HTML tag boundary (< or >), since the typography is
  #    handled by the tag itself in those cases.
  local dash_halfspace_re='s{([^\s<>])(\x{2014}|\x{2013}) (\S)}{$1 $2 $3}g; s{(\S) (\x{2014}|\x{2013})([^\s<>])}{$1 $2 $3}g'

  # Count watermark references in the snapshot before cleaning. This is
  # the source-of-truth count — every "OceanofPDF" string that existed
  # in the unzipped tree (excluding the promo file we removed earlier).
  local watermarks_before
  watermarks_before=$( { grep -roh "OceanofPDF" "$snapshot" 2>/dev/null || true; } | wc -l | tr -d ' ')

  # Run all passes in one perl invocation across all text-bearing files.
  if ! find "$workdir" \
       \( -name "*.xhtml" -o -name "*.html" -o -name "*.htm" \
          -o -name "*.opf"   -o -name "*.ncx" \) \
       -type f -print0 \
     | xargs -0 perl -CSD -i -0777 -pe \
       "$watermark_re; $doublehyphen_re; $dash_nospace_re; $dash_halfspace_re"
  then
    fail "  ✗ Content cleaning failed: $input_file"
    rm -rf "$snapshot"
    return 2
  fi

  # Count watermark references remaining after cleaning.
  local watermarks_after watermarks_removed
  watermarks_after=$( { grep -roh "OceanofPDF" "$workdir" 2>/dev/null || true; } | wc -l | tr -d ' ')
  watermarks_removed=$((watermarks_before - watermarks_after))

  # --- Structural safety net ---
  # For each cleaned XHTML/HTML file, verify that opening/closing tag
  # counts for key block elements still balance against the snapshot
  # (allowing for legitimate removal of watermark divs). If a file is
  # structurally damaged, restore it from the snapshot — we'd rather
  # ship a file with one extra watermark than a broken one.
  local restored=0
  local rel_path snap_file work_file
  while IFS= read -r -d '' work_file; do
    rel_path="${work_file#$workdir/}"
    snap_file="$snapshot/$rel_path"
    [[ -f "$snap_file" ]] || continue

    # Count critical structural tags that should never net-change.
    # Watermarks only touch <div>, so <section>, <body>, <html>, <ul>,
    # <ol>, <table> counts must be identical before and after.
    local tag check_failed=0
    for tag in section body html ul ol table; do
      local before after
      before=$(grep -ocE "<${tag}\b" "$snap_file" 2>/dev/null || echo 0)
      after=$(grep -ocE "<${tag}\b" "$work_file" 2>/dev/null || echo 0)
      if [[ "$before" != "$after" ]]; then
        check_failed=1
        log_only "  ! Tag count mismatch in $rel_path: <$tag> before=$before after=$after"
        break
      fi
      before=$(grep -ocE "</${tag}>" "$snap_file" 2>/dev/null || echo 0)
      after=$(grep -ocE "</${tag}>" "$work_file" 2>/dev/null || echo 0)
      if [[ "$before" != "$after" ]]; then
        check_failed=1
        log_only "  ! Tag count mismatch in $rel_path: </$tag> before=$before after=$after"
        break
      fi
    done

    if [[ "$check_failed" == "1" ]]; then
      cp "$snap_file" "$work_file"
      restored=$((restored + 1))
    fi
  done < <(find "$workdir" \( -name "*.xhtml" -o -name "*.html" -o -name "*.htm" \) -type f -print0)

  if [[ "$restored" -gt 0 ]]; then
    log "  ! Restored $restored file(s) from snapshot (structural damage detected — watermarks preserved in those files)"
  fi

  rm -rf "$snapshot"

  # Sanity check on watermark removal. `|| true` because grep returns 1
  # when it finds nothing, which is what we want.
  remaining=$( { grep -rli "oceanofpdf" "$workdir" 2>/dev/null || true; } \
               | wc -l | tr -d ' ')
  if [[ "$remaining" != "0" ]]; then
    log_only "  ! $remaining file(s) still contain 'oceanofpdf' references"
  fi

  # --- Repack (EPUB-valid order) ---
  #
  # Capture zip's stderr to a temp file so any failure (permission
  # denied, disk full, illegal filename, etc.) actually shows up in
  # the run log instead of being swallowed by `-q`.

  rm -f "$output"
  local zip_err
  zip_err="$(mktemp)"
  if ! (
    cd "$workdir" || exit 1
    zip -X0 -q "$output" mimetype 2>"$zip_err" && \
    zip -Xr9D -q "$output" . -x mimetype 2>>"$zip_err"
  ); then
    fail "  ✗ Repack failed: $input_file"
    if [[ -s "$zip_err" ]]; then
      {
        echo "    ↳ zip stderr:"
        sed 's/^/      /' "$zip_err"
      } | log_block
    fi
    rm -f "$zip_err"
    # Clean up any partial output the first zip command may have left
    # behind. Better to leave the directory empty than to have an
    # invalid stub file sitting there that the user might mistake for
    # a real cleaned book.
    rm -f "$output"
    return 2
  fi
  rm -f "$zip_err"

  # --- epubcheck (with baseline comparison) ---
  #
  # We run epubcheck on the cleaned file. If it reports errors, we also
  # run it on the original to determine which errors are pre-existing
  # in the publisher's source vs. introduced by cleaning. Full output
  # of both passes is appended to the consolidated log.

  local cleaned_errors=0 original_errors=0
  local introduced=0
  local cleaned_check_out baseline_check_out

  if command -v epubcheck >/dev/null 2>&1; then
    cleaned_check_out="$(mktemp)"
    if epubcheck "$output" >"$cleaned_check_out" 2>&1; then
      epubcheck_status="passed"
      rm -f "$cleaned_check_out"
    else
      cleaned_errors=$(grep -cE "^(ERROR|FATAL)" "$cleaned_check_out" 2>/dev/null || echo 0)

      baseline_check_out="$(mktemp)"
      epubcheck "$input" >"$baseline_check_out" 2>&1 || true
      original_errors=$(grep -cE "^(ERROR|FATAL)" "$baseline_check_out" 2>/dev/null || echo 0)

      introduced=$((cleaned_errors - original_errors))
      [[ "$introduced" -lt 0 ]] && introduced=0

      if [[ "$introduced" -eq 0 ]]; then
        epubcheck_status="preexisting"
      else
        epubcheck_status="introduced"
      fi

      # Append both epubcheck outputs to the consolidated log under
      # clear section headers. We truncate the "expected attribute"
      # enumerations in RSC-005 errors — those are 4KB walls of every
      # legal attribute name, the same on every line, completely
      # unhelpful for diagnosis. The actual error message ("attribute
      # 'X' not allowed here") is what matters.
      local trim_re='s/; expected attribute .*$/; [expected-attribute list truncated]/'
      {
        echo ""
        echo "  --- epubcheck on original ($original_errors errors) ---"
        sed -E "$trim_re" "$baseline_check_out" | sed 's/^/    /'
        echo ""
        echo "  --- epubcheck on cleaned ($cleaned_errors errors) ---"
        sed -E "$trim_re" "$cleaned_check_out" | sed 's/^/    /'
        echo ""
      } | log_block

      rm -f "$cleaned_check_out" "$baseline_check_out"
    fi
  else
    epubcheck_status="missing"
  fi

  # --- Per-file result ---

  # Every result line carries the same three pieces of information so
  # the summary reads as a consistent table:
  #   1. epubcheck verdict   (passed / N pre-existing / N introduced / not run)
  #   2. watermarks removed  (always shown, even when 0)
  TOTAL_WATERMARKS_REMOVED=$((TOTAL_WATERMARKS_REMOVED + watermarks_removed))

  local wm_part="$watermarks_removed watermark(s) removed"
  local check_part
  case "$epubcheck_status" in
    passed)      check_part="epubcheck passed" ;;
    preexisting) check_part="$cleaned_errors pre-existing source error(s)" ;;
    introduced)  check_part="$introduced error(s) introduced, $original_errors pre-existing" ;;
    missing)     check_part="epubcheck not installed" ;;
  esac

  local mark="✓"
  [[ "$epubcheck_status" == "introduced" ]] && mark="⚠"

  local line="  $mark $input_file → $out_name ($check_part · $wm_part)"
  log "$line"
  record_result "$line"

  case "$epubcheck_status" in
    introduced) return 1 ;;
    *)          return 0 ;;
  esac
}

# ---- Main ----------------------------------------------------------------

if [[ $# -eq 0 ]]; then
  notify "EPUB Cleaner" "No files provided"
  echo "Usage: $0 [--backup|-b] book1.epub [book2.epub ...]" >&2
  exit 1
fi

# --- Argument parsing ---
# Backups are off by default. The original input file is never modified
# by the script, so the redundant copy is only useful as belt-and-
# suspenders insurance against the user accidentally deleting the
# original. Pass --backup or -b to enable.
KEEP_BACKUP=0
INPUTS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup|-b)
      KEEP_BACKUP=1
      shift
      ;;
    --help|-h)
      echo "Usage: $0 [--backup|-b] book1.epub [book2.epub ...]"
      echo ""
      echo "Options:"
      echo "  --backup, -b   Save a copy of each input as <name>_original_backup.epub"
      echo "                 (default: off; the original input file is not modified)"
      echo "  --help, -h     Show this message"
      exit 0
      ;;
    --)
      shift
      INPUTS+=("$@")
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      echo "Usage: $0 [--backup|-b] book1.epub [book2.epub ...]" >&2
      exit 1
      ;;
    *)
      INPUTS+=("$1")
      shift
      ;;
  esac
done

if [[ ${#INPUTS[@]} -eq 0 ]]; then
  notify "EPUB Cleaner" "No files provided"
  echo "Usage: $0 [--backup|-b] book1.epub [book2.epub ...]" >&2
  exit 1
fi

# Re-set positional parameters to just the file inputs for the loop below.
set -- "${INPUTS[@]}"

# Place the consolidated log in the directory of the first input. If
# that directory can't be resolved (e.g. file doesn't exist), fall back
# to the current working directory.
FIRST_INPUT_DIR="$(cd "$(dirname "$1")" 2>/dev/null && pwd)"
[[ -z "$FIRST_INPUT_DIR" ]] && FIRST_INPUT_DIR="$(pwd)"
BATCH_LOG="$FIRST_INPUT_DIR/epub_clean_verify_${TIMESTAMP}.log"

# Body log header (full detail will be assembled below the summary).
{
  echo "EPUB clean + verify"
  echo "Started: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "Files queued: $#"
  echo "Backups:      $([[ $KEEP_BACKUP -eq 1 ]] && echo 'enabled' || echo 'disabled')"
  echo "Log file: $BATCH_LOG"
  echo ""
} >>"$BODY_LOG"

# Stdout shows the same header for live feedback.
echo "EPUB clean + verify"
echo "Started: $(date '+%Y-%m-%d %H:%M:%S')"
echo "Files queued: $#"
echo "Log file: $BATCH_LOG"
echo ""

for input in "$@"; do
  TOTAL=$((TOTAL + 1))
  log "[$TOTAL/$#] $(basename "$input")"

  set +e
  process_one "$input"
  rc=$?
  set -e

  case "$rc" in
    0) SUCCEEDED=$((SUCCEEDED + 1)) ;;
    1) SUCCEEDED=$((SUCCEEDED + 1))
       INTRODUCED_ERRORS=$((INTRODUCED_ERRORS + 1)) ;;
    *) FAILED=$((FAILED + 1)) ;;
  esac
done

# ---- Summary + final log assembly ---------------------------------------

# Final footer in the body log.
{
  echo ""
  echo "Finished: $(date '+%Y-%m-%d %H:%M:%S')"
} >>"$BODY_LOG"

# Write the final consolidated log with summary at the top, then body.
{
  echo "════════════════════════════════════════════════════════════════"
  echo " EPUB CLEAN + VERIFY  ·  SUMMARY"
  echo "════════════════════════════════════════════════════════════════"
  echo ""
  echo "  Run started:  $(date -r "$BODY_LOG" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')"
  echo "  Run finished: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "  Files:        $SUCCEEDED of $TOTAL cleaned · $FAILED failed · $INTRODUCED_ERRORS with script-introduced errors"
  echo "  Watermarks:   $TOTAL_WATERMARKS_REMOVED removed across all files"
  echo ""
  echo "  Per-book results:"
  if [[ ${#RESULT_LINES[@]} -gt 0 ]]; then
    for line in "${RESULT_LINES[@]}"; do
      echo "  $line"
    done
  else
    echo "    (no files processed)"
  fi
  echo ""
  echo "  Legend:"
  echo "    ✓  cleaned successfully (errors, if any, are pre-existing in the source)"
  echo "    ⚠  cleaned but script introduced new epubcheck errors"
  echo "    ✗  failed before producing output"
  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo " FULL RUN DETAIL"
  echo "════════════════════════════════════════════════════════════════"
  echo ""
  cat "$BODY_LOG"
} >"$BATCH_LOG"

rm -f "$BODY_LOG"

# Build a tight notification message.
if [[ $TOTAL -eq 1 ]]; then
  if   [[ $FAILED -gt 0 ]]; then msg="Failed · see log"
  elif [[ $INTRODUCED_ERRORS -gt 0 ]]; then msg="Cleaned but introduced new errors · see log"
  else msg="Cleaned successfully"
  fi
else
  msg="$SUCCEEDED of $TOTAL cleaned"
  [[ $FAILED -gt 0 ]] && msg="$msg · $FAILED failed"
  [[ $INTRODUCED_ERRORS -gt 0 ]] && msg="$msg · $INTRODUCED_ERRORS introduced errors"
fi

notify "EPUB Cleaner" "$msg"

# Exit non-zero if anything failed, for scripting/automation use.
[[ $FAILED -eq 0 ]]
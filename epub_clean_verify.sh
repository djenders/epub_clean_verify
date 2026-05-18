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

BATCH_LOG="$HOME/Library/Logs/epub_clean_verify_$(date +%Y%m%d_%H%M%S).log"
mkdir -p "$(dirname "$BATCH_LOG")"

TOTAL=0
SUCCEEDED=0
FAILED=0
EPUBCHECK_FAILED=0   # cleaned successfully but epubcheck found errors

# ---- Helpers -------------------------------------------------------------

notify() {
  local title="$1"
  local message="$2"
  osascript -e "display notification \"${message//\"/\\\"}\" with title \"${title//\"/\\\"}\"" 2>/dev/null || true
}

log() {
  # Write to both the batch log and stdout so Quick Action console shows it.
  echo "$@" | tee -a "$BATCH_LOG"
}

log_only() {
  # Log file only — for verbose per-file detail that would clutter stdout.
  echo "$@" >>"$BATCH_LOG"
}

# ---- Per-file processor --------------------------------------------------
# Returns: 0 = success (epubcheck passed or missing)
#          1 = success but epubcheck reported errors
#          2 = hard failure (could not produce output)

process_one() {
  local input="$1"
  local input_dir input_file basename out_name output backup logfile workdir
  local epubcheck_status="not_run"
  local remaining

  # --- Argument validation ---
  if [[ ! -f "$input" ]]; then
    log "  ✗ Not a file: $input"
    return 2
  fi
  if [[ "${input##*.}" != "epub" ]]; then
    log "  ✗ Not an .epub: $input"
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
  logfile="$input_dir/${out_name%.epub}_epubcheck.log"

  workdir="$(mktemp -d)"
  # Local trap: clean up this file's workdir on function exit.
  trap "rm -rf '$workdir'" RETURN

  log_only "  Input:  $input"
  log_only "  Output: $output"
  log_only "  Backup: $backup"

  # --- Pre-flight ---
  if ! unzip -l "$input" >/dev/null 2>&1; then
    log "  ✗ Not a valid zip archive: $input_file"
    return 2
  fi

  local zip_listing
  zip_listing="$(unzip -l "$input")"
  if ! echo "$zip_listing" | grep -q " mimetype$"; then
    log "  ✗ Missing mimetype entry: $input_file"
    return 2
  fi

  # --- Backup ---
  if ! cp "$input" "$backup"; then
    log "  ✗ Could not create backup: $input_file"
    return 2
  fi

  # --- Unzip ---
  if ! unzip -q "$input" -d "$workdir"; then
    log "  ✗ Unzip failed: $input_file"
    return 2
  fi

  if [[ ! -f "$workdir/mimetype" ]]; then
    log "  ✗ Unzipped tree missing mimetype: $input_file"
    return 2
  fi
  if [[ ! -f "$workdir/META-INF/container.xml" ]]; then
    log "  ✗ Unzipped tree missing META-INF/container.xml: $input_file"
    return 2
  fi

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

  # Run all passes in one perl invocation across all text-bearing files.
  if ! find "$workdir" \
       \( -name "*.xhtml" -o -name "*.html" -o -name "*.htm" \
          -o -name "*.opf"   -o -name "*.ncx" \) \
       -type f -print0 \
     | xargs -0 perl -CSD -i -0777 -pe \
       "$watermark_re; $doublehyphen_re; $dash_nospace_re; $dash_halfspace_re"
  then
    log "  ✗ Content cleaning failed: $input_file"
    rm -rf "$snapshot"
    return 2
  fi

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

  rm -f "$output"
  (
    cd "$workdir" || exit 1
    zip -X0 -q "$output" mimetype && \
    zip -Xr9D -q "$output" . -x mimetype
  ) || {
    log "  ✗ Repack failed: $input_file"
    return 2
  }

  # --- epubcheck ---

  if command -v epubcheck >/dev/null 2>&1; then
    if epubcheck "$output" >"$logfile" 2>&1; then
      epubcheck_status="passed"
      rm -f "$logfile"
    else
      epubcheck_status="failed"
    fi
  else
    epubcheck_status="missing"
  fi

  # --- Per-file result ---

  case "$epubcheck_status" in
    passed)
      log "  ✓ $input_file → $out_name (epubcheck passed)"
      return 0
      ;;
    failed)
      log "  ⚠ $input_file → $out_name (epubcheck errors, see $(basename "$logfile"))"
      return 1
      ;;
    missing)
      log "  ✓ $input_file → $out_name (epubcheck not installed)"
      return 0
      ;;
  esac
}

# ---- Main ----------------------------------------------------------------

if [[ $# -eq 0 ]]; then
  notify "EPUB Cleaner" "No files provided"
  echo "Usage: $0 book1.epub [book2.epub ...]" >&2
  exit 1
fi

log "EPUB clean + verify"
log "Started: $(date '+%Y-%m-%d %H:%M:%S')"
log "Files queued: $#"
log ""

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
       EPUBCHECK_FAILED=$((EPUBCHECK_FAILED + 1)) ;;
    *) FAILED=$((FAILED + 1)) ;;
  esac
done

# ---- Summary -------------------------------------------------------------

log ""
log "Finished: $(date '+%Y-%m-%d %H:%M:%S')"
log "Summary: $SUCCEEDED of $TOTAL cleaned · $FAILED failed · $EPUBCHECK_FAILED with epubcheck errors"
log "Full log: $BATCH_LOG"

# Build a tight notification message.
if [[ $TOTAL -eq 1 ]]; then
  if   [[ $FAILED -gt 0 ]]; then msg="Failed · see log"
  elif [[ $EPUBCHECK_FAILED -gt 0 ]]; then msg="Cleaned with epubcheck errors"
  else msg="Cleaned successfully"
  fi
else
  msg="$SUCCEEDED of $TOTAL cleaned"
  [[ $FAILED -gt 0 ]] && msg="$msg · $FAILED failed"
  [[ $EPUBCHECK_FAILED -gt 0 ]] && msg="$msg · $EPUBCHECK_FAILED epubcheck errors"
fi

notify "EPUB Cleaner" "$msg"

# Exit non-zero if anything failed, for scripting/automation use.
[[ $FAILED -eq 0 ]]
#!/bin/bash
# Run the Lakebridge Oracle profiler for every database in databases.csv.
# Run on the machine where Lakebridge is installed (Mac or Linux).
#
#   read -rs -p 'Profiler password: ' LB_ORACLE_PROFILER_PWD; echo; export LB_ORACLE_PROFILER_PWD
#   ./step3b_run_profiler.sh <output_dir> databases.csv [more .csv files ...]
#
# databases.csv columns:  db_name,instance_sid,host,port   (comma-separated)
#   instance_sid = the SID of one instance of the database (e.g. EDW1 on RAC)
#   host         = the server / RAC node where that instance runs (not SCAN)
#   port         = listener port (blank = 1521)
# Lakebridge sends its "service_name" setting to Oracle as a SID, which only the
# listener on that node knows. One row per database is enough on RAC: the
# profiler reads the cluster-wide gv$ views and AWR. Each database is profiled
# once (first row per db_name, case-insensitive). Columns are found by the
# header row (any order; extra columns ignored); a file without a header uses
# the order above. Repeated header rows, blank rows, rows without name/SID/host,
# a UTF-8 BOM, Windows or old-Mac line endings, spaces and quotes around values
# are handled; rows with invalid values are reported and skipped.
#
# - One folder per database: <output_dir>/<db_name>/
# - The extract is renamed profiler_extract_oracle_<version>_<date>_<DB>.db
# - Success = Lakebridge exits 0 and the extract's own run record says COMPLETE;
#   it is marked with a .completed file. Completed databases are skipped on a
#   re-run, failed ones are retried. Delete .completed to profile again.
# - Nothing usable is deleted: before a run, earlier complete extracts move to
#   <db>/previous/ and are put back if the run fails or is interrupted (Ctrl-C,
#   kill, closed terminal). An extract that another program has open is left
#   alone and that database is skipped.
#   Failed or interrupted attempts are kept as *.db.failed.<timestamp>, which
#   later steps ignore.
# - Writes profile_report.txt next to each extract and <output_dir>/summary.csv
#   (one line per database; a re-run replaces that database's line).
# - The password is read from LB_ORACLE_PROFILER_PWD and never written to disk;
#   per-database connection files live in a private temp folder, removed at exit.
# - Only one run at a time per output folder (lock folder <output_dir>/.lock).
#
# Optional settings (environment variables):
#   LB_ORACLE_PROFILER_USER  account to connect with (default: lakebridge_profiler)
#   DATABRICKS_PROFILE       Databricks CLI profile (default: DEFAULT)
#   LB_DEBUG=1               pass --debug to Lakebridge (a little more detail in profiler.log)
#   LB_PY                    Python with duckdb (default: the one inside the Lakebridge install)
set -uo pipefail

if [[ $# -lt 2 ]]; then sed -n '2,6p' "$0"; exit 1; fi
OUT="$1"; shift
for f in "$@"; do
  [[ -f "$f" ]] || { echo "File not found: $f"; exit 1; }
  if head -1 "$f" | grep -q ';' && ! head -1 "$f" | grep -q ','; then
    echo "$f looks semicolon-separated; save it as comma-separated CSV"; exit 1
  fi
done
: "${LB_ORACLE_PROFILER_PWD:?set LB_ORACLE_PROFILER_PWD first}"
export LB_ORACLE_PROFILER_PWD
USER_NAME="${LB_ORACLE_PROFILER_USER:-lakebridge_profiler}"
PROFILE="${DATABRICKS_PROFILE:-DEFAULT}"
DEBUG_FLAG=""; [[ "${LB_DEBUG:-0}" == "1" ]] && DEBUG_FLAG="--debug"
HERE=$(cd "$(dirname "$0")" && pwd)
LB_PY="${LB_PY:-$HOME/.databricks/labs/lakebridge/state/venv/bin/python}"
command -v databricks >/dev/null || { echo "The databricks CLI is not on PATH"; exit 1; }
if ! "$LB_PY" -I -c 'import duckdb' >/dev/null 2>&1; then
  echo "Cannot run Lakebridge's Python ($LB_PY) with duckdb; it's needed to check each result."
  echo "Install Lakebridge first (databricks labs install lakebridge), or set LB_PY to a Python that has duckdb."
  exit 1
fi
RE_NAME='^[A-Za-z0-9_$#][A-Za-z0-9_$#.-]*$'
RE_SID='^[A-Za-z][A-Za-z0-9_$#]*$'
RE_HOST='^[A-Za-z0-9][A-Za-z0-9._-]*$'
RE_PORT='^[0-9]{1,5}$'
RE_USER='^[A-Za-z][A-Za-z0-9_$#]*$'
[[ "$USER_NAME" =~ $RE_USER ]] || { echo "Invalid account name: $USER_NAME"; exit 1; }

# all lists -> "name,sid,host,port" lines, first row per name (case-insensitive)
rows() {
  local f
  for f in "$@"; do
    LC_ALL=C tr '\r' '\n' < "$f" | LC_ALL=C awk -F, -v bom="$(printf '\357\273\277')" -v file="$f" '
      BEGIN { cn = 1; cs = 2; ch = 3; cp = 4 }
      NR == 1 && index($0, bom) == 1 { $0 = substr($0, 4) }
      { hdr = 0; for (i = 1; i <= NF; i++) { gsub(/^[ \t"]+|[ \t"]+$/, "", $i); if (tolower($i) == "db_name") hdr = 1 } }
      hdr { cn = cs = ch = cp = 0
            for (i = 1; i <= NF; i++) { k = tolower($i)
              if (k == "db_name") cn = i; else if (k == "instance_sid") cs = i; else if (k == "host") ch = i; else if (k == "port") cp = i }
            if (!cs || !ch) { print file ": header row has no instance_sid or host column" > "/dev/stderr"; exit 2 }
            next }
      { n = $cn; s = $cs; h = $ch; p = (cp ? $cp : "") }
      n == "" || s == "" || h == "" { next }
      { print n "," s "," h "," (p == "" ? "1521" : p) }' || exit 1
  done | LC_ALL=C awk -F, '!seen[toupper($1)]++'
}
LIST=$(rows "$@") || { echo "Could not read the database list(s)"; exit 1; }
if [[ -z "$LIST" ]]; then echo "No database rows found in: $* (expected columns db_name,instance_sid,host,port)"; exit 1; fi

status_of() { "$LB_PY" -I "$HERE/step3b_report_extract.py" "$1" --status 2>/dev/null || echo UNKNOWN; }
stamp() { date +%Y%m%d%H%M%S; }

mkdir -p "$OUT"
if ! mkdir "$OUT/.lock" 2>/dev/null; then
  echo "Another run is using $OUT (remove $OUT/.lock if no run is active)"; exit 1
fi
CREDS=$(mktemp -d); chmod 700 "$CREDS"
CUR=""        # folder of the database being worked on right now
STARTED=0     # 1 once the profiler has been started for CUR
MOVED_FROM=(); MOVED_TO=()   # extracts this run moved into previous/ (to put back on failure)

# put a folder back the way it was: this run's (partial) extract -> .failed,
# the extracts this run moved to previous/ back to their place; if that leaves no
# extract at the top (e.g. an earlier run was killed), the newest one in previous/
restore() {
  local d="$1" x i=0 newest
  [[ -n "$d" && -d "$d" ]] || return 0
  if [[ $STARTED -eq 1 ]]; then
    for x in "$d"/profiler_extract_oracle_*.db; do [[ -f "$x" ]] && mv "$x" "$x.failed.$(stamp)"; done
  fi
  while [[ $i -lt ${#MOVED_TO[@]} ]]; do
    [[ -f "${MOVED_TO[$i]}" && ! -e "${MOVED_FROM[$i]}" ]] && mv "${MOVED_TO[$i]}" "${MOVED_FROM[$i]}"
    i=$((i + 1))
  done
  MOVED_FROM=(); MOVED_TO=(); STARTED=0
  if ! ls "$d"/profiler_extract_oracle_*.db >/dev/null 2>&1; then
    newest=$(ls -t "$d"/previous/profiler_extract_oracle_*.db 2>/dev/null | head -1)
    [[ -n "$newest" && ! -e "$d/$(basename "$newest")" ]] && mv "$newest" "$d/"
  fi
  rmdir "$d/previous" 2>/dev/null || true
}
cleanup() { rm -rf "$CREDS"; rmdir "$OUT/.lock" 2>/dev/null || true; }
on_interrupt() {
  echo; if [[ -n "$CUR" ]]; then echo "interrupted: restoring $CUR"; restore "$CUR"; else echo "interrupted"; fi
  cleanup; exit 130
}
trap cleanup EXIT
trap on_interrupt INT TERM HUP

SUMMARY="$OUT/summary.csv"
# one line per database: a re-run replaces that database's line (written to a temp file, then moved)
summary_line() {
  { LC_ALL=C awk -F, -v d="$name" 'NR == 1 || toupper($1) != toupper(d)' "$SUMMARY"; echo "$1"; } > "$SUMMARY.tmp" &&
    mv "$SUMMARY.tmp" "$SUMMARY"
}
[[ -f "$SUMMARY" ]] || echo "db_name,instance_sid,host,status,seconds,tables_with_data,empty_tables,awr_from,awr_to,awr_days,failed_steps,extract" > "$SUMMARY"

while IFS=, read -r name sid host port; do
  if ! [[ "$name" =~ $RE_NAME ]]; then echo "skip '$name': database name may only contain letters, digits and _ \$ # . - (not starting with .)"; continue; fi
  if ! [[ "$sid" =~ $RE_SID && "$host" =~ $RE_HOST && "$port" =~ $RE_PORT ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
    echo "skip $name: invalid instance_sid '$sid', host '$host' or port '$port'"; continue
  fi
  port=$((10#$port))
  dir="$OUT/$name"; mkdir -p "$dir"
  if [[ -f "$dir/.completed" ]]; then echo "skip $name (already profiled)"; continue; fi

  cat > "$CREDS/$name.yml" <<YML
secret_vault_type: env
oracle:
  host: "$host"
  port: $port
  service_name: "$sid"
  user: "$USER_NAME"
  password: LB_ORACLE_PROFILER_PWD
YML
  # sort what's already in the folder: complete extracts are kept aside in previous/,
  # anything else (e.g. left by an interrupted run) is marked .failed
  CUR="$dir"; locked=""; blocked=""
  mkdir -p "$dir/previous"
  for x in "$dir"/profiler_extract_oracle_*.db; do
    [[ -f "$x" ]] || continue
    st=$(status_of "$x")
    if [[ "$st" == LOCKED ]]; then locked="$x"; break; fi
    if [[ "$st" == COMPLETE ]]; then
      t="$dir/previous/$(basename "$x")"
      if [[ -e "$t" ]]; then   # same name already kept: add a timestamp (and a counter if needed)
        base="$dir/previous/$(basename "$x" .db).$(stamp)"; t="$base.db"; n=1
        while [[ -e "$t" ]]; do t="$base-$n.db"; n=$((n + 1)); done
      fi
      MOVED_FROM+=("$x"); MOVED_TO+=("$t")   # recorded first, so an interrupt during mv is still undone
      mv "$x" "$t" || { blocked="$x"; break; }
    else
      mv "$x" "$x.failed.$(stamp)" || { blocked="$x"; break; }
    fi
  done
  if [[ -n "$locked" || -n "$blocked" ]]; then
    if [[ -n "$locked" ]]; then echo "skip $name: $(basename "$locked") is open in another program; close it and run again"
    else echo "skip $name: could not move $(basename "$blocked") aside (see the error above); fix that and run again"; fi
    restore "$dir"; CUR=""; continue
  fi
  echo "profiling $name (instance $sid on $host:$port) ..."
  STARTED=1
  start=$(date +%s)
  databricks labs lakebridge execute-database-profiler --source-tech oracle \
    --cred-file-path "$CREDS/$name.yml" --output-folder "$dir" -p "$PROFILE" $DEBUG_FLAG > "$dir/profiler.log" 2>&1 < /dev/null
  rc=$?; secs=$(( $(date +%s) - start ))
  # only an extract written by this run can be at the top level now
  extract=$(ls -t "$dir"/profiler_extract_oracle_*.db 2>/dev/null | head -1)
  if [[ -n "$extract" && "$extract" != *"_${name}.db" ]]; then
    mv -f "$extract" "${extract%.db}_${name}.db" && extract="${extract%.db}_${name}.db"
  fi
  status=FAILED
  [[ $rc -eq 0 && -n "$extract" && "$(status_of "$extract")" == COMPLETE ]] && status=OK
  stats=",,,,,"
  if [[ -n "$extract" ]]; then
    "$LB_PY" -I "$HERE/step3b_report_extract.py" "$extract" > "$dir/profile_report.txt" 2>&1
    stats=$("$LB_PY" -I "$HERE/step3b_report_extract.py" "$extract" --csv 2>/dev/null | head -1)
    [[ -n "$stats" ]] || stats=",,,,,"
  fi
  if [[ $status == OK ]]; then
    CUR=""; STARTED=0; MOVED_FROM=(); MOVED_TO=()   # from here on, an interrupt leaves this database as it is
    summary_line "$name,$sid,$host,$status,$secs,$stats,$extract"
    touch "$dir/.completed"
    rmdir "$dir/previous" 2>/dev/null || true
  else
    restore "$dir"; CUR=""
    summary_line "$name,$sid,$host,$status,$secs,$stats,"
  fi
  echo "  -> $status in ${secs}s"
done <<<"$LIST"

echo
if command -v column >/dev/null; then
  # show empty fields as "-" (column would otherwise shift them)
  sed -e 's/,,/,-,/g' -e 's/,,/,-,/g' -e 's/,$/,-/' "$SUMMARY" | column -s, -t
else
  cat "$SUMMARY"
fi
exit 0

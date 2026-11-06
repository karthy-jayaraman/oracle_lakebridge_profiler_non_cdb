"""Summarize one Lakebridge Oracle profiler extract (DuckDB file).

Prints a readable report. Options:
  --csv     one line for summary.csv:
            tables_with_data,empty_tables,awr_from,awr_to,awr_days,failed_steps
  --status  one word: COMPLETE (Lakebridge recorded a complete run in the
            extract, incl. COMPLETE_WITH_ABSENCES), FAILED (recorded, not complete),
            LOCKED (another program has the file open) or UNKNOWN (no run record,
            or the file can't be read)
  failed_steps lists steps that did not complete; optional steps Lakebridge
  skipped (no data / not licensed) are shown as <step>:absent.

Never fails on a missing, empty or unreadable extract: it reports what it can.
The extract is opened read-only with file and network access disabled.

Run with the Python inside the Lakebridge install (it already has duckdb):
  ~/.databricks/labs/lakebridge/state/venv/bin/python step3b_report_extract.py <extract.db> [--csv | --status]
"""
import json
import re
import sys

import duckdb

EXPECTED = ["config_containers", "config_db_features", "config_instance", "config_memory_evolution",
            "config_pdb_objects", "config_pdb_partitions", "config_storage", "perf_cpu_waits",
            "perf_fgd_session_evolution", "perf_heatmap", "perf_sqltext"]
# DuckDB's message when another process holds the file (Mac/Linux, Windows)
LOCK_ERROR = re.compile(r"Could not set lock on file|Conflicting lock is held|being used by another process", re.I)
# (table, time column) pairs that show how much AWR history the profile covers
TIME_COLS = [("config_memory_evolution", "snap_time"), ("perf_cpu_waits", "mtime"),
             ("perf_fgd_session_evolution", "snap_time"), ("perf_sqltext", "dt")]


def first(con, sql, default=None):
    try:
        row = con.execute(sql).fetchone()
        return row[0] if row and row[0] is not None else default
    except duckdb.Error:
        return default


def main(path, mode):
    try:
        con = duckdb.connect(path, read_only=True, config={"enable_external_access": False})
        present = {t for (t,) in con.execute("select table_name from information_schema.tables").fetchall()}
    except Exception as e:  # unreadable / truncated / not a DuckDB file / open in another program
        if mode == "status":
            print("LOCKED" if LOCK_ERROR.search(str(e)) else "UNKNOWN")
        elif mode == "csv":
            print("0,%d,,,0,unreadable extract" % len(EXPECTED))
        else:
            print(f"Cannot read {path}: {e}")
        return

    counts = {t: (first(con, f'select count(*) from "{t}"', 0) if t in present else 0) for t in EXPECTED}

    meta = {}
    if "profiler_run_metadata" in present:
        try:
            cur = con.execute("select * from profiler_run_metadata")
            row = cur.fetchone()
            meta = dict(zip([d[0] for d in cur.description], row)) if row else {}
        except duckdb.Error:
            meta = {}
    if mode == "status":
        st = str(meta.get("status") or "").upper()
        # COMPLETE, or COMPLETE_WITH_ABSENCES (optional steps missing) in newer Lakebridge versions
        print("COMPLETE" if st.startswith("COMPLETE") else ("FAILED" if st else "UNKNOWN"))
        return

    lo = hi = None
    for t, col in TIME_COLS:
        if counts[t]:
            try:
                a, b = con.execute(f'select min(cast("{col}" as timestamp)), max(cast("{col}" as timestamp)) from "{t}"').fetchone()
            except duckdb.Error:
                continue
            lo = a if lo is None or (a and a < lo) else lo
            hi = b if hi is None or (b and b > hi) else hi
    days = round((hi - lo).total_seconds() / 86400, 1) if lo and hi else 0

    steps = {}
    try:
        results = json.loads(meta.get("results") or "[]")
    except (TypeError, ValueError):
        results = []
    for s in results:
        steps.setdefault(s.get("step_name"), s)  # each step is listed twice (DDL + data); keep the first
        if s.get("status") != "COMPLETE":
            steps[s.get("step_name")] = s
    failed = [n + (":absent" if s.get("status") == "ABSENT" else "")
              for n, s in steps.items() if s.get("status") != "COMPLETE"]

    with_data = sum(1 for t in EXPECTED if counts[t])
    if mode == "csv":
        print(f"{with_data},{len(EXPECTED) - with_data},{lo or ''},{hi or ''},{days},{'|'.join(failed)}")
        return

    db = first(con, "select name from config_containers limit 1", "?") if counts["config_containers"] else "?"
    ver = first(con, "select value from config_db_features where name = 'VERSION'", "?") if counts["config_db_features"] else "?"
    print(f"Database        : {db}  (Oracle {ver})")
    print(f"Lakebridge      : {meta.get('lakebridge_version', '?')}  run status {meta.get('status', '?')}  at {meta.get('generated_at', '?')}")
    print(f"AWR data covers : {lo} -> {hi}  ({days} days)")
    print(f"Tables with data: {with_data} of {len(EXPECTED)}")
    print()
    print(f"{'step / table':30} {'status':10} {'rows':>8}")
    for t in EXPECTED:
        st = steps.get(t, {}).get("status", "NOT RUN")
        note = "  <- empty" if st == "COMPLETE" and not counts[t] else ""
        err = steps.get(t, {}).get("error_message")
        print(f"{t:30} {st:10} {counts[t]:>8}{note}{('  ' + err) if err else ''}")


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(1)
    main(args[0], "csv" if "--csv" in args[1:] else ("status" if "--status" in args[1:] else "text"))

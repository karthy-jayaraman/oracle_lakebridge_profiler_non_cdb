# Oracle Lakebridge Profiler for non-CDB databases

Scripts and a step-by-step guide for running the [Databricks Lakebridge Oracle profiler](https://databrickslabs.github.io/lakebridge/docs/assessment/profiler/oracle/) on **standalone (non-CDB) Oracle databases**, from one database to hundreds, including databases on RAC clusters. Covers Windows and Mac.

The Lakebridge documentation describes a multitenant (CDB) setup. On a non-CDB the profiler works with an ordinary local account in each database, and its "service name" setting must be the **instance SID** on the node where that instance runs. The guide explains both.

**Start with the guide:** [Oracle_NonCDB_Profiler_Guide.md](Oracle_NonCDB_Profiler_Guide.md)

## Scripts

| Script | Runs on | What it does |
|---|---|---|
| `step2_optional_create_profiler_user.sh` | each database server / RAC node | Creates the read-only profiler account (`CREATE SESSION`, `SELECT_CATALOG_ROLE`) in the databases running there. Dry run by default (`--apply` to run); never changes an existing account's password unless `--reset-password`; refuses Oracle-maintained and powerful accounts. |
| `step3a_optional_write_databases_csv.sh` | each database server / RAC node | Writes `databases.csv` rows (`db_name,instance_sid,host,port`) for the open primary non-CDB databases running there; skips standbys, ASM/MGMTDB and CDBs. |
| `step3b_run_profiler.sh` / `step3b_run_profiler.ps1` | the profiler machine (Mac/Linux / Windows) | Runs the profiler once per database in `databases.csv`: one folder per database, the database name appended to the result file, a report per database and a `summary.csv`. Safe to re-run: completed databases are skipped, failed ones retried, nothing usable is deleted. |
| `step3b_report_extract.py` | the profiler machine | Summarizes one result file (called by the loop). |

The `step2` and `step3a` helpers are optional; the guide shows the equivalent manual steps.

## Requirements

- Oracle non-CDB databases with AWR (Diagnostic Pack licensed).
- Databricks CLI with Lakebridge installed (`databricks labs install lakebridge`). Tested with Lakebridge 0.15.2.
- Mac/Linux loop: bash (macOS bash 3.2 or newer). Windows loop: PowerShell 5.1 or 7.
- Helpers: Linux database servers, run as the `oracle` OS user with `sqlplus`.

## Testing

Tested against Oracle 19c (two non-CDB databases and one CDB) with Lakebridge 0.15.2; loop scenarios tested on macOS bash 3.2, Linux bash 5.1 and PowerShell 7.6. **Not yet tested on Windows PowerShell 5.1 on a real Windows host or on a live RAC cluster.** Please report issues.

## Security

- The profiler password is read from the `LB_ORACLE_PROFILER_PWD` environment variable and is never written to disk or printed.
- The profiler reads only Oracle dictionary and AWR views; it does not read table data and makes no changes to the database.

This is a community kit, not an official Databricks product. Use at your own risk.

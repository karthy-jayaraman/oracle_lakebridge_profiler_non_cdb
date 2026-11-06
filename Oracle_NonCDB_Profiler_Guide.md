# Profiling Oracle Non-CDB Databases with Databricks Lakebridge (Windows & Mac)

This guide covers profiling **standalone (non-CDB) Oracle databases** with the Databricks Lakebridge Oracle Profiler, from one database to hundreds, including databases on RAC clusters.

The profiler connects to each database with a read-only account. It collects configuration and workload metadata: CPU and core counts, memory, storage, object and partition counts, CPU and wait activity, and SQL activity from AWR. It reads only Oracle dictionary and AWR views; it does **not** read table data and makes **no changes** to the database. The results for each database are written to a local **DuckDB file**, which Databricks uses to size the target environment and build the migration cost model.

**Non-CDB vs. the Lakebridge documentation.** The Lakebridge documentation describes a multitenant (CDB) setup: connect to `CDB$ROOT` with a `C##` common user. **Ignore that for non-CDB databases.** The profiler works on non-CDB databases with an ordinary local account (Step 2). The commands from the documentation fail on a non-CDB with ORA-65117.

## The steps at a glance

| Step | What | Where |
|---|---|---|
| 1 | Install the Databricks CLI and Lakebridge (once) | Profiler machine (Windows or Mac) |
| 2 | Create a read-only profiler account in each database | Each database |
| 3 | List the databases in `databases.csv` and run the profiler | Profiler machine |
| 4 | Check the results and send them to Databricks | Profiler machine |

Optional helper scripts for Steps 2 and 3a are described in Appendices A and B. **Download all scripts from GitHub:** https://github.com/karthy-jayaraman/oracle_lakebridge_profiler_non_cdb. On that page, click **Code → Download ZIP** and extract it into a folder on the profiler machine (this guide uses `C:\oracle_profiler` on Windows and `~/oracle_profiler` on Mac), or run `git clone https://github.com/karthy-jayaraman/oracle_lakebridge_profiler_non_cdb.git`. The scripts are:

| File | Used in | What it does | Runs on |
|---|---|---|---|
| `step2_optional_create_profiler_user.sh` | Step 2 (optional, Appendix A) | Creates the profiler account in many databases | Oracle servers (Linux) |
| `step3a_optional_write_databases_csv.sh` | Step 3a (optional, Appendix B) | Writes the `databases.csv` rows for a server | Oracle servers (Linux) |
| `step3b_run_profiler.ps1` / `step3b_run_profiler.sh` | Step 3b | Runs the profiler for every database in `databases.csv` | Windows / Mac (or Linux) profiler machine |
| `step3b_report_extract.py` | Step 3b (called automatically) | Summarizes each result | Profiler machine |

## Prerequisites

- **Oracle Enterprise Edition with the Diagnostic Pack licensed.** The workload metrics come from AWR. AWR views return data whether or not the pack is licensed, so please confirm the license before running.
- **Plain TCP with username and password.** The profiler doesn't support TCPS/TLS listeners, Oracle Wallet, Kerberos or OS authentication.
- **Network:** the profiler machine must reach the **listener port (default 1521) on each database server or RAC node by its hostname or VIP**, not only the SCAN address (see below).
- **Profiler machine:**
  - Python **3.10.1 – 3.14.x** (on Windows, the **64-bit** version)
  - network access to **GitHub and PyPI**
  - access to a Databricks workspace (used for sign-in only; no data is uploaded). If you don't have access to one, tell Databricks before you start.
  - if your network uses a proxy or inspects HTTPS traffic, the proxy settings and your company's root certificate (see Appendix C)
  - stays switched on and connected for the whole run (see "Long runs" in Step 3b)
- **Disk:** a few MB per database; roughly 10–50 MB with weeks of AWR history.
- **Primary databases only.** Profile the primary of each database, not its standby.

### Checks before the run (one-time, per database)

Run these as a DBA in each database you plan to profile, or at least in a few representative ones:
```sql
-- Diagnostic Pack must be enabled: expect DIAGNOSTIC or DIAGNOSTIC+TUNING
SELECT value FROM v$parameter WHERE name = 'control_management_pack_access';

-- How much AWR history there is: retention and snapshot interval
SELECT retention, snap_interval FROM dba_hist_wr_control;
```
The profile covers whatever AWR history the database keeps. **At least 7 days** is needed; 30 days or more gives a better picture of month-end and peak workloads. If retention is short, you can extend it ahead of the run (for example `EXEC DBMS_WORKLOAD_REPOSITORY.MODIFY_SNAPSHOT_SETTINGS(retention => 43200);` for 30 days), following your own change process.

### Connect with the instance SID and the node hostname

The profiler's connection setting is labeled **"service name"**, but Lakebridge sends that value to Oracle as a **SID**. So, for each database, use:
- the **instance SID** (for example `EDW1`), not a RAC service name or the SCAN name;
- the **server or RAC node where that instance runs** (its hostname or VIP), because a SID is only known to that node's local listener.

**One instance per database is enough on RAC.** The profiler reads the cluster-wide `gv$` views and AWR, so connecting to one instance covers all instances of that database.

---

## 1. One-time setup: install the Databricks CLI and Lakebridge

### Windows

**Step 1. Install the Databricks CLI** (PowerShell or Command Prompt):
```
winget install Databricks.DatabricksCLI
```
(Alternatives: `choco install databricks-cli`, or download the binary from https://github.com/databricks/cli/releases and add it to PATH.) Close and reopen the terminal afterwards so the `databricks` command is on your PATH.

Verify (expect `v0.2xx` or newer, not the legacy `0.18`):
```
databricks --version
```

**Step 2. Sign in to your Databricks workspace** (browser / SSO):
```
databricks auth login --host https://<your-workspace-url>
```
Press **Enter** to accept the default profile name. Verify (prints your user name):
```
databricks current-user me
```

**Step 3. Install Lakebridge:**
```
databricks labs install lakebridge
```
If it's already installed, upgrade instead: `databricks labs upgrade lakebridge`. Verify:
```
databricks labs lakebridge --help
```
The list should include `execute-database-profiler`.

### Mac

**Step 1. Install the Databricks CLI** (Homebrew):
```
brew tap databricks/tap
brew install databricks
databricks --version
```

**Step 2. Sign in:**
```
databricks auth login --host https://<your-workspace-url>
databricks current-user me
```

**Step 3. Install (or upgrade) Lakebridge:**
```
databricks labs install lakebridge
databricks labs lakebridge --help
```

> Use the Lakebridge **command line** as shown in this guide, not the Lakebridge desktop app. The desktop app currently stops the profiler after 5 minutes, which isn't enough for databases with a long AWR history.

---

## 2. Create a read-only profiler account in each database

In Oracle, accounts belong to a database: each database has its own users. The profiler therefore needs an account **in every database you profile**. One account per database is enough: it sees all schemas in that database.

**Option 1: use an existing monitoring account.** If your databases already have a standard read-only monitoring account with `SELECT_CATALOG_ROLE` (or `SELECT ANY DICTIONARY`), you can use it and create nothing. Pass its name to the profiler loop in Step 3. Please don't use `SYS` or `SYSTEM`: they have far more privileges than the profiler needs.

`SELECT_CATALOG_ROLE` gives read access to the whole data dictionary (including SQL text in `V$SQL`), so treat the profiler account as sensitive: share its password only with the person running the profiler, and lock or drop it when profiling is finished (Step 4).

**Option 2: create a dedicated account.** Run as a DBA in each database:
```sql
CREATE USER lakebridge_profiler IDENTIFIED BY "<password>";
GRANT CREATE SESSION, SELECT_CATALOG_ROLE TO lakebridge_profiler;
```
Use the same password in every database, so one password works for the whole run in Step 3. The password must meet your password policy (profile/verify function); avoid the double-quote character `"`. If your default profile expires or locks passwords, consider a profile that won't expire during the profiling window.

> **Prefer a script?** To create the account in many databases at once, use `step2_optional_create_profiler_user.sh` from the GitHub repository (see the top of this guide). It's described in **Appendix A**.

---

## 3. List the databases and run the profiler

### 3a. Create databases.csv

Create a file named `databases.csv` in the folder with the scripts, with **one row per database** you want profiled:
```
db_name,instance_sid,host,port
EDWPRD,EDWPRD1,dbnode1.example.com,1521
FINPRD,FINPRD1,dbnode1.example.com,1521
HRPRD,HRPRD,dbserver7.example.com,1521
```

| Column | What to enter |
|---|---|
| `db_name` | The database name (`DB_UNIQUE_NAME`). It's used for the output folder and file names. Letters, digits and `_ $ # . -` only. |
| `instance_sid` | The SID of **one instance** of the database (on RAC, e.g. `EDWPRD1`). |
| `host` | The server or RAC node **where that instance runs**. Not the SCAN name. Write each server the same way in every row (always the name, or always the IP address). |
| `port` | The listener port on that host (usually `1521`). |

- Keep the header row and use commas between values. The columns can be in any order and extra columns (for example notes) are ignored. If you edit the file in Excel, save it as **CSV (Comma delimited)** (in some regions Excel uses semicolons; the scripts will tell you if so).
- Each database is profiled once: if a name appears more than once, the first row is used. Blank rows and rows without a SID or host are skipped.
- List the **primary** of each database, not a standby.
- To profile more databases later, add rows and run again; databases already profiled are skipped.

> **Prefer a script?** `step3a_optional_write_databases_csv.sh` from the GitHub repository writes these rows for every database running on a server. It's described in **Appendix B**.

### 3b. Run the profiler loop

The loop runs the profiler once for each database in `databases.csv`:
- it writes a temporary connection file with the SID and host filled in, and deletes it at the end;
- it saves the results in a folder per database;
- it appends the database name to the result file;
- it writes a short report per database and a `summary.csv` for the whole run.

The password is read from the `LB_ORACLE_PROFILER_PWD` environment variable and is never written to disk. Type it at a prompt (as shown below) rather than on the command line, so it doesn't end up in your shell history.

**Re-running is safe**:
- A database that completed successfully gets a `.completed` file in its folder and is skipped next time; failed databases are retried. You can stop and resume at any time.
- To profile a database again (for example after extending AWR retention), delete its `.completed` file and run the loop.
- Nothing usable is deleted. Before a run, earlier complete results move to a `previous` subfolder; if the run fails or you stop it with Ctrl-C, they are put back, and the failed attempt is kept as `*.db.failed.<timestamp>`.
- Close any tool that has a result file open (for example DBeaver or DuckDB) before re-running; a database whose result file is open elsewhere is skipped with a message.
- Only one run at a time can use an output folder (a second one stops with a message).

**Start with one database.** Put one row in `databases.csv`, run the loop, and check that `summary.csv` shows `OK` and a reasonable `awr_days`. Then add the remaining databases and run again; the first one is skipped.

**Running against production:**
- The profiler only reads the data dictionary and AWR views. It changes nothing in the database.
- The loop profiles **one database at a time**.
- Most databases take a few minutes. Databases with a large AWR history take longer, mainly for the SQL-activity query. If possible, run outside peak hours.

**Long runs:** with many databases the run can take hours.
- Keep the machine awake and connected. On Windows, keep the PowerShell window open and switch off sleep. On Mac, start the command with `caffeinate -i`, for example `caffeinate -i ./step3b_run_profiler.sh ...`.
- If the run is interrupted, just start the same command again: completed databases are skipped.

#### Windows (PowerShell)
```powershell
cd C:\oracle_profiler
$env:LB_ORACLE_PROFILER_PWD = [Net.NetworkCredential]::new('', (Read-Host 'Profiler password' -AsSecureString)).Password
.\step3b_run_profiler.ps1 -OutputDir C:\oracle_profiles -Databases .\databases.csv
```
Optional parameters:
- `-ProfilerUser <name>`: if you use an existing monitoring account (Step 2, Option 1). Default is `lakebridge_profiler`.
- `-DatabricksProfile <name>`: if you signed in with a named profile.
- `-LbDebug`: more detail in the logs.

If PowerShell blocks the script ("running scripts is disabled on this system", or "... is not digitally signed" for scripts downloaded from GitHub), allow it for the current window only:
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

#### Mac
```bash
cd ~/oracle_profiler
chmod +x step3b_run_profiler.sh
read -rs -p 'Profiler password: ' LB_ORACLE_PROFILER_PWD; echo; export LB_ORACLE_PROFILER_PWD
./step3b_run_profiler.sh ~/oracle_profiles databases.csv
```
Optional settings:
- `LB_ORACLE_PROFILER_USER=<name>`: existing monitoring account. Default is `lakebridge_profiler`.
- `DATABRICKS_PROFILE=<name>`
- `LB_DEBUG=1`

### Profiling one database by hand (optional)

To test a single database first, create a connection file (for example `edw.yml`):
```yaml
secret_vault_type: env
oracle:
  host: dbnode1.example.com      # the node where the instance runs (not the SCAN name)
  port: 1521
  service_name: EDWPRD1          # the instance SID
  user: lakebridge_profiler
  password: LB_ORACLE_PROFILER_PWD # name of the environment variable holding the password
```
Then set the password variable as shown in Step 3b and run:
```
databricks labs lakebridge execute-database-profiler --source-tech oracle --cred-file-path edw.yml --output-folder <folder>
```

---

## 4. Check the results and send them to Databricks

Each database gets its own folder:
```
oracle_profiles\
├── summary.csv
├── EDWPRD\
│   ├── profiler_extract_oracle_<version>_<date>_EDWPRD.db  (the profile)
│   ├── profile_report.txt   (rows per table, AWR window)
│   ├── profiler.log         (Lakebridge log)
│   ├── .completed           (marks a successful run)
│   ├── previous\            (only after a re-profile: earlier results)
│   └── *.db.failed.<time>   (only after a failed attempt)
└── FINPRD\ ...
```

**summary.csv** has one line per database. Before sending, please check:
- **status**: `OK` for each database. For `FAILED`, look at that database's `profiler.log` (see Appendix C).
- **awr_days**: how much AWR history the profile covers. **At least 7 days** is needed, ideally your full AWR retention. A very low number means short AWR retention or a recent restart.
- **empty_tables**: one or two empty tables can be normal for a quiet database. Many empty tables usually means AWR has little data (see Appendix C).

**profile_report.txt** shows the same for each database, step by step.

**Send the whole oracle_profiles folder** as one archive, keeping the folder structure:
- Windows (PowerShell or Command Prompt, Windows 10 or later): `tar -czf C:\oracle_profiles_<YYYYMMDD>.tar.gz -C C:\ oracle_profiles`. (Avoid `Compress-Archive`: in Windows PowerShell 5.1 it fails on archives larger than 2 GB.)
- Mac: `tar -czf ~/oracle_profiles_<YYYYMMDD>.tar.gz -C ~ oracle_profiles`

Databricks will send you a secure upload link. The archive contains no table data. It does contain database metadata: database, instance and host names, schema (owner) names, database user names seen in active sessions, object and partition counts, storage sizes, memory settings, CPU and wait statistics, and SQL activity statistics grouped by type (the SQL text itself is not included in this Lakebridge version). Please review it against your data-handling policy before sending.

**After Databricks confirms receipt**, remove or lock the profiler account in each database (`DROP USER lakebridge_profiler;` or `ALTER USER lakebridge_profiler ACCOUNT LOCK;`). If you used an existing monitoring account and the script granted it `SELECT_CATALOG_ROLE`, revoke that grant if it didn't have it before. When you're done, clear the password variable (Mac/Linux: `unset LB_ORACLE_PROFILER_PWD`; Windows: `Remove-Item Env:LB_ORACLE_PROFILER_PWD`).

---

## Before you start: questions we'll ask

1. How many RAC clusters and standalone servers are there, and what does each host?
2. Are production and dev/test **separate databases** (for example `EDWPRD`, `EDWTST`) or **schemas in one database**? Are they on separate clusters?
3. Which databases are in scope for the migration? We usually profile the production databases first.
4. Is the **Diagnostic Pack** licensed on these databases?
5. What is the **AWR retention and snapshot interval** (`SELECT retention, snap_interval FROM dba_hist_wr_control;`)?
6. Do the listeners accept plain TCP connections with username and password from the profiler machine?

---

## Appendix A (optional): create the profiler account with a script

**Both helper scripts (Appendices A and B) run on Linux database servers** as the `oracle` OS user, with `sqlplus` available. They aren't supported on AIX or Solaris. Copy the scripts (and `databases.csv` for Appendix A) to each server, for example with `scp` or WinSCP, and make them executable with `chmod +x`.

`step2_optional_create_profiler_user.sh` (in the GitHub repository) creates the account from Step 2 in every database in `databases.csv` whose instance runs on the server. Run it as the **oracle OS user** on each database server or RAC node, with a copy of `databases.csv`:

**Review first (dry run: prints the SQL, changes nothing):**
```bash
read -rs -p 'Profiler password: ' LB_ORACLE_PROFILER_PWD; echo; export LB_ORACLE_PROFILER_PWD
./step2_optional_create_profiler_user.sh databases.csv
```
**Then apply:**
```bash
./step2_optional_create_profiler_user.sh databases.csv --apply
```
- It connects locally (`/ as sysdba`), checks whether the account exists, then runs `CREATE USER` (only if it's missing) and the `GRANT` from Step 2. The password is masked in the dry run.
- It refuses to touch Oracle-maintained accounts (`SYS`, `SYSTEM`, `DBSNMP`, ...) and powerful accounts: the DBA role (directly or through other roles), the `ALTER USER`, `GRANT ANY PRIVILEGE`, `GRANT ANY ROLE`, `BECOME USER` or `ALTER DATABASE` privileges, or administrative privileges such as `SYSDBA`. Use a dedicated account name instead. Refused databases count as failed, also in the dry run.
- If the account already exists, the script only applies the grants and **leaves its password unchanged** (it also shows the account status, for example `LOCKED`). To also set the password (only for an account created for profiling, never a shared monitoring account), add `--reset-password`.
- If one database fails (for example, the password doesn't meet its password policy), the script reports it and carries on with the others, then prints how many succeeded and failed.
- Rows for instances that don't run on that server are skipped. On RAC, each database is handled on the node of the instance listed in `databases.csv`.
- To use a different account name, set `LB_ORACLE_PROFILER_USER=<name>` before running.

## Appendix B (optional): write databases.csv with a script

`step3a_optional_write_databases_csv.sh` (in the GitHub repository) lists the databases running on a server, in the `databases.csv` format. Run it as the **oracle OS user** on each database server or RAC node:
```bash
chmod +x step3a_optional_write_databases_csv.sh
./step3a_optional_write_databases_csv.sh > databases_$(hostname -s).csv
```
- It finds every running instance (its `ora_pmon_<SID>` process), connects locally (`/ as sysdba`), and asks each database about itself (`v$database`, `v$instance`).
- It lists **open PRIMARY non-CDB** databases.
- It skips standbys, databases that aren't open read-write, and Oracle's internal instances (ASM, the Grid management database `-MGMTDB`, APX, IOS).
- It skips **multitenant (CDB) databases** with the message "not covered, tell Databricks".
- Every skipped instance and the reason are printed on screen.
- Optional settings: `CONNECT_HOST` (the host name the profiler machine uses for this server; default is the server's FQDN) and `LISTENER_PORT` (default `1521`).

Copy the files to the profiler machine and **delete the lines for databases you don't want profiled**. Then pass all the files to the loop; it uses the first row for each database:
- Windows: `.\step3b_run_profiler.ps1 -OutputDir C:\oracle_profiles -Databases (Get-ChildItem .\databases_*.csv).FullName`
- Mac: `./step3b_run_profiler.sh ~/oracle_profiles databases_*.csv`

On RAC, each node lists the same database once, which is expected.

## Appendix C: troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `DPY-6005` / cannot connect, although SQL Developer works with the service name | Lakebridge sends the "service name" as a SID | Use the **instance SID** and the **node hostname** |
| `ORA-12505` / `ORA-12514` (listener doesn't know the SID / service) | Connected through SCAN, or to a node where that instance isn't running | Use the node where the listed instance runs |
| `ORA-01017: invalid username/password` | Password differs, or the account doesn't exist in that database | Create the account (Step 2), or set the password of the profiling account: `ALTER USER lakebridge_profiler IDENTIFIED BY "<password>";` (Appendix A script: `--reset-password`). Don't reset a shared monitoring account's password; use its current password instead. |
| `ORA-28000: the account is locked` | Too many failed logins (wrong password) | `ALTER USER lakebridge_profiler ACCOUNT UNLOCK;` and fix the password |
| `ORA-28001: the password has expired` | The account's profile expired the password | Reset the password (`ALTER USER ... IDENTIFIED BY`, or the Appendix A script with `--reset-password`) and consider a non-expiring profile for the profiling window |
| `ORA-01031` / `ORA-00942` (insufficient privileges / table or view does not exist) | The account lacks `SELECT_CATALOG_ROLE` | `GRANT SELECT_CATALOG_ROLE TO lakebridge_profiler;` |
| `ORA-12541: no listener` | Wrong host or port, or no listener on that node | Check the host and listener port in `databases.csv` |
| `Cannot run Lakebridge's Python ... with duckdb` | Lakebridge isn't installed for this user, or is installed elsewhere | Install it (Step 1), or set `LB_PY` (Mac) / `$env:LB_PY` (Windows) to Lakebridge's Python |
| `skip <db>: ... is open in another program` | A result file of that database is open in another tool | Close it and run the loop again |
| `Another run is using ...` | A second run was started on the same output folder, or an earlier run was killed | Wait for the other run; if none is running, delete the `.lock` folder in the output folder |
| `databricks: command not found` / not recognized | The CLI isn't on PATH | Reopen the terminal after installing; check `databricks --version` |
| SSL / certificate errors or timeouts during `databricks labs install lakebridge` | Corporate proxy or HTTPS inspection | Set `HTTPS_PROXY` (and `HTTP_PROXY`) to your proxy; if HTTPS is inspected, point `REQUESTS_CA_BUNDLE` and `PIP_CERT` at a file containing your company's root certificate, then retry |
| `ORA-65117: CONTAINER clause may only be specified when connected to a container` | The multitenant commands from the Lakebridge docs were run on a non-CDB | Use the account in Step 2 |
| Timeout / connection refused | Firewall between the profiler machine and the node listener | Open TCP 1521 (or your listener port) to each node |
| Profiler stops after exactly 5 minutes | Lakebridge desktop app limit | Use the command line (this guide) |
| `status` OK but many empty tables or `awr_days` near 0 | Little AWR history (short retention, recent restart), or AWR not collecting | Check `SELECT retention, snap_interval FROM dba_hist_wr_control;` and that `control_management_pack_access` includes `DIAGNOSTIC` |
| `[UPGRADE ADVISED] Newer lakebridge version …` | Informational | Optional: `databricks labs upgrade lakebridge` |
| TCPS / Wallet / Kerberos-only listener | Not supported by the profiler | Use a plain TCP listener endpoint with username and password |

## References

- Lakebridge Oracle profiler: https://databrickslabs.github.io/lakebridge/docs/assessment/profiler/oracle/
- Lakebridge installation: https://databrickslabs.github.io/lakebridge/docs/installation/

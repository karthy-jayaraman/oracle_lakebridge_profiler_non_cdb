#!/bin/bash
# OPTIONAL helper: write databases.csv rows for the Oracle databases running on
# THIS server, instead of typing them by hand.
#
# Run as the oracle OS user on each database server (on RAC: each node):
#   ./step3a_optional_write_databases_csv.sh > databases_$(hostname -s).csv
#
# Output columns (the same format the profiler loop reads):
#   db_name,instance_sid,host,port
# db_name is the database's DB_UNIQUE_NAME (the same as DB_NAME unless Data Guard
# or a site suffix is used).
#
# For every running database instance owned by this OS user (its ora_pmon_<SID>
# process; ASM, APX and the Grid management DB use other process names and are
# not considered) the script connects
# locally (/ as sysdba) and asks the database about itself. It lists open
# PRIMARY non-CDB databases only. It skips, with the reason on screen:
#   - standbys and databases that are not open read-write
#   - Oracle-internal instances: ASM, the Grid management DB, APX, IOS
#   - multitenant (CDB) databases: not covered by this guide; tell Databricks
#
# On RAC every node lists the same database once (EDW1 on node 1, EDW2 on node 2).
# That's fine: the profiler loop keeps the first row per db_name.
# Delete the lines for databases you don't want profiled.
#
# Optional settings (environment variables):
#   CONNECT_HOST   host name the profiler machine uses for this server (default: FQDN)
#   LISTENER_PORT  listener port (default 1521)
set -uo pipefail

ORACLE_INTERNAL='^(\+ASM[0-9]*|-MGMTDB|\+APX[0-9]*|\+IOS[0-9]*)$'
CONNECT_HOST="${CONNECT_HOST:-$(hostname -f)}"
LISTENER_PORT="${LISTENER_PORT:-1521}"

command -v pgrep >/dev/null || { echo "pgrep is required (package procps)" >&2; exit 1; }
echo "db_name,instance_sid,host,port"
found=0

for pid in $(pgrep -u "$(id -u)" -f '^ora_pmon_'); do
  sid=$(ps -o args= -p "$pid" | sed 's/^ora_pmon_//')
  [[ -z "$sid" ]] && continue
  if [[ "$sid" =~ $ORACLE_INTERNAL ]]; then echo "skip $sid: Oracle internal instance" >&2; continue; fi

  # ORACLE_HOME of the running instance = the directory of its oracle binary
  exe=$(readlink "/proc/$pid/exe" 2>/dev/null); exe="${exe% (deleted)}"
  if [[ -z "$exe" ]]; then echo "skip $sid: can't read ORACLE_HOME (run as the instance owner)" >&2; continue; fi
  home="${exe%/bin/oracle}"
  if [[ ! -x "$home/bin/sqlplus" ]]; then echo "skip $sid: no sqlplus in $home/bin" >&2; continue; fi

  row=$(ORACLE_SID="$sid" ORACLE_HOME="$home" "$home/bin/sqlplus" -s / as sysdba <<'SQL' 2>/dev/null
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 400 TRIMSPOOL ON
SELECT d.db_unique_name||','||i.instance_name||','||d.cdb||','||d.database_role||','||d.open_mode
  FROM v$database d CROSS JOIN v$instance i;
SQL
)
  row=$(echo "$row" | tr -d '\r' | grep ',' | head -1 | xargs)
  if [[ -z "$row" ]]; then echo "skip $sid: could not query v\$database (instance not mounted/open, or no SYSDBA access)" >&2; continue; fi

  IFS=, read -r name inst cdb role mode <<<"$row"
  if [[ "$cdb" == "YES" ]]; then echo "skip $sid: $name is a multitenant (CDB) database; not covered, tell Databricks" >&2; continue; fi
  if [[ "$role" != "PRIMARY" ]]; then echo "skip $sid: role $role (standby)" >&2; continue; fi
  if [[ "$mode" != "READ WRITE" ]]; then echo "skip $sid: open mode $mode" >&2; continue; fi
  echo "$name,$inst,$CONNECT_HOST,$LISTENER_PORT"; found=$((found + 1))
done
# instances owned by other OS users (role separation): say so, so nothing is skipped silently
for pid in $(pgrep -f '^ora_pmon_'); do
  owner=$(ps -o user= -p "$pid" | xargs)
  [[ "$owner" == "$(id -un)" ]] && continue
  echo "skip $(ps -o args= -p "$pid" | sed 's/^ora_pmon_//'): owned by OS user $owner; run this script as $owner too" >&2
done
[[ $found -eq 0 ]] && echo "No open primary non-CDB database found for OS user $(id -un) on this server." >&2
exit 0

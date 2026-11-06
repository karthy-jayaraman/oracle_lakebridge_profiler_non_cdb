#!/bin/bash
# OPTIONAL helper: create the profiler account in every database from
# databases.csv whose instance runs on THIS server.
# Dry run by default (prints the SQL, with the password masked); add --apply to run it.
#
# Run as the oracle OS user on each database server (on RAC: each node):
#   read -rs -p 'Profiler password: ' LB_ORACLE_PROFILER_PWD; echo; export LB_ORACLE_PROFILER_PWD
#   ./step2_optional_create_profiler_user.sh databases.csv            # review
#   ./step2_optional_create_profiler_user.sh databases.csv --apply    # create
#
# Account: LAKEBRIDGE_PROFILER (or LB_ORACLE_PROFILER_USER) with
#   CREATE SESSION, SELECT_CATALOG_ROLE   (read access to the dictionary and AWR)
# - A missing account is created with a plain CREATE USER statement (Oracle keeps
#   the password out of V$SQL and audit text for CREATE/ALTER USER).
# - An existing account only gets the grants; its password is left unchanged.
#   Add --reset-password to also set the password (only for an account created
#   for profiling). The script refuses to touch Oracle-maintained accounts
#   (SYS, SYSTEM, DBSNMP, ...) and powerful accounts: the DBA role (also through
#   other roles), ALTER USER, GRANT ANY PRIVILEGE, GRANT ANY ROLE, BECOME USER or
#   ALTER DATABASE, or an entry in the password file (SYSDBA, SYSOPER, ...).
#   Use a dedicated account name instead (LB_ORACLE_PROFILER_USER).
# - Each database is handled on the server where its listed instance_sid runs;
#   rows for instances on other servers are skipped.
# - A failure in one database is reported and the script carries on; it prints
#   how many succeeded and failed, and exits 1 if any failed or was refused
#   (also in the dry run).
set -uo pipefail
LIST="${1:?usage: $0 databases.csv [--apply] [--reset-password]}"; shift
APPLY=0; RESET=0
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    --reset-password) RESET=1 ;;
    *) echo "unknown option $a"; exit 1 ;;
  esac
done
: "${LB_ORACLE_PROFILER_PWD:?set LB_ORACLE_PROFILER_PWD first}"
U="${LB_ORACLE_PROFILER_USER:-lakebridge_profiler}"
if [[ "$LB_ORACLE_PROFILER_PWD" == *'"'* ]]; then echo 'The password must not contain a double quote (").'; exit 1; fi
if [[ "$LB_ORACLE_PROFILER_PWD" =~ [[:cntrl:]] ]]; then echo 'The password must not contain control characters.'; exit 1; fi
RE_ACCOUNT='^[A-Za-z][A-Za-z0-9_$#]{0,127}$'
RE_SID='^[A-Za-z][A-Za-z0-9_$#]*$'
RE_NAME='^[A-Za-z0-9_$#][A-Za-z0-9_$#.-]*$'
if ! [[ "$U" =~ $RE_ACCOUNT ]]; then echo "Invalid account name: $U"; exit 1; fi
UU=$(echo "$U" | tr '[:lower:]' '[:upper:]')
command -v pgrep >/dev/null || { echo "pgrep is required (package procps)"; exit 1; }
[[ -f "$LIST" ]] || { echo "File not found: $LIST"; exit 1; }
if head -1 "$LIST" | grep -q ';' && ! head -1 "$LIST" | grep -q ','; then
  echo "$LIST looks semicolon-separated; save it as comma-separated CSV"; exit 1
fi

# databases.csv -> "name,sid" lines, read the same way as the profiler loop:
# columns by header name (else db_name,instance_sid,host,port order); strips a
# BOM, CR, spaces and quotes; skips header, blank and incomplete rows; keeps the
# first row per database name.
rows() {
  LC_ALL=C tr '\r' '\n' < "$LIST" | LC_ALL=C awk -F, -v bom="$(printf '\357\273\277')" -v file="$LIST" '
    BEGIN { cn = 1; cs = 2; ch = 3 }
    NR == 1 && index($0, bom) == 1 { $0 = substr($0, 4) }
    { hdr = 0; for (i = 1; i <= NF; i++) { gsub(/^[ \t"]+|[ \t"]+$/, "", $i); if (tolower($i) == "db_name") hdr = 1 } }
    hdr { cn = cs = ch = 0
          for (i = 1; i <= NF; i++) { k = tolower($i)
            if (k == "db_name") cn = i; else if (k == "instance_sid") cs = i; else if (k == "host") ch = i }
          if (!cs || !ch) { print file ": header row has no instance_sid or host column" > "/dev/stderr"; exit 2 }
          next }
    { n = $cn; s = $cs; h = $ch }
    n == "" || s == "" || h == "" { next }
    !seen[toupper(n)]++ { print n "," s }'
}
ROWS=$(rows) || { echo "Could not read $LIST"; exit 1; }
label() { awk -v n="$1" '{ print "   " n ": " $0 }'; }   # prefix output lines with the database name
# Oracle error lines only, with the password masked (SQL*Plus echoes a failing statement)
errors() {
  LC_ALL=C awk 'BEGIN { pw = ENVIRON["LB_ORACLE_PROFILER_PWD"] }
    /ORA-|SP2-/ { out = ""; while ((i = index($0, pw)) > 0) { out = out substr($0, 1, i - 1) "********"; $0 = substr($0, i + length(pw)) }
                  print out $0 }'
}

USER_SQL() {   # $1 = CREATE | ALTER, $2 = password text to embed
  echo "SET DEFINE OFF VERIFY OFF FEEDBACK ON
WHENEVER SQLERROR EXIT FAILURE
$1 USER $U IDENTIFIED BY \"$2\";"
}
GRANT_SQL="SET DEFINE OFF FEEDBACK ON
WHENEVER SQLERROR EXIT FAILURE
GRANT CREATE SESSION, SELECT_CATALOG_ROLE TO $U;"

ok=0; failed=0; handled=0; planned=0
while IFS=, read -r name sid; do
  [[ -n "$name" ]] || continue
  if ! [[ "$name" =~ $RE_NAME ]]; then echo "-- skip '$name': invalid database name"; continue; fi
  if ! [[ "$sid" =~ $RE_SID ]]; then echo "-- skip $name: invalid instance SID '$sid'"; continue; fi
  # match the full command line (process names are cut to 15 characters); escape $ for the regex
  pid=$(pgrep -u "$(id -u)" -f "^ora_pmon_${sid//\$/\\$}\$" | head -1) || true
  if [[ -z "$pid" ]]; then echo "-- skip $name: instance $sid does not run on this server (as $(id -un))"; continue; fi
  home=$(readlink "/proc/$pid/exe" 2>/dev/null); home="${home% (deleted)}"; home="${home%/bin/oracle}"
  handled=$((handled + 1))
  echo "-- $name (instance $sid)"
  if [[ -z "$home" || ! -x "$home/bin/sqlplus" ]]; then
    echo "   $name: FAILED (cannot find ORACLE_HOME/bin/sqlplus for instance $sid)"; failed=$((failed + 1)); continue
  fi
  run() { ORACLE_SID="$sid" ORACLE_HOME="$home" "$home/bin/sqlplus" -s / as sysdba 2>&1; }

  # 1. look at the account first (no password involved)
  info=$(run <<SQL
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 200 DEFINE OFF
-- "powerful" = DBA role or powerful system privileges, directly or through other
-- roles, or SYSDBA/SYSOPER-style administrative privileges in the password file
WITH roles AS (SELECT granted_role FROM dba_role_privs
               START WITH grantee = '$UU' CONNECT BY NOCYCLE PRIOR granted_role = grantee),
     holders AS (SELECT '$UU' AS g FROM dual UNION SELECT granted_role FROM roles)
SELECT 'EXISTS|' || u.oracle_maintained || '|' ||
       CASE WHEN EXISTS (SELECT 1 FROM roles WHERE granted_role = 'DBA')
              OR EXISTS (SELECT 1 FROM dba_sys_privs WHERE grantee IN (SELECT g FROM holders)
                           AND privilege IN ('ALTER USER', 'GRANT ANY PRIVILEGE', 'GRANT ANY ROLE', 'BECOME USER', 'ALTER DATABASE'))
              OR EXISTS (SELECT 1 FROM v\$pwfile_users WHERE username = '$UU')
            THEN 'Y' ELSE 'N' END || '|' || u.account_status
  FROM dba_users u WHERE u.username = '$UU'
UNION ALL SELECT 'MISSING' FROM dual WHERE NOT EXISTS (SELECT 1 FROM dba_users WHERE username = '$UU');
SQL
)
  state=$(echo "$info" | grep -E '^(EXISTS|MISSING)' | head -1)
  if [[ -z "$state" ]]; then
    echo "$info" | grep -E 'ORA-|SP2-' | label "$name"
    echo "   $name: FAILED (could not read DBA_USERS)"; failed=$((failed + 1)); continue
  fi
  IFS='|' read -r kind maintained isdba status <<<"$state"
  if [[ "$kind" == EXISTS && ( "$maintained" == Y || "$isdba" == Y ) ]]; then
    echo "   $name: FAILED (refusing to modify $UU: Oracle-maintained, DBA or administrative account)"; failed=$((failed + 1)); continue
  fi

  # 2. the statements to run
  pw_stmt=""
  if [[ "$kind" == MISSING ]]; then pw_stmt=CREATE; elif [[ $RESET -eq 1 ]]; then pw_stmt=ALTER; fi
  if [[ $APPLY -eq 0 ]]; then
    [[ "$kind" == EXISTS ]] && echo "   account exists (status $status): password $([[ $RESET -eq 1 ]] && echo 'would be reset' || echo 'left unchanged')"
    [[ -n "$pw_stmt" ]] && USER_SQL "$pw_stmt" '********' | sed 's/^/   /'
    echo "$GRANT_SQL" | sed 's/^/   /'
    planned=$((planned + 1))
    continue
  fi
  rc=0
  if [[ -n "$pw_stmt" ]]; then
    out=$(USER_SQL "$pw_stmt" "$LB_ORACLE_PROFILER_PWD" | run); rc=$?
    echo "$out" | errors | label "$name"
  fi
  if [[ $rc -eq 0 ]]; then
    out=$(echo "$GRANT_SQL" | run); rc=$?
    echo "$out" | errors | label "$name"
  fi
  if [[ $rc -eq 0 ]]; then
    case "$kind/$pw_stmt" in
      MISSING/CREATE) echo "   $name: account created, grants applied" ;;
      EXISTS/ALTER)   echo "   $name: account exists (status $status): password reset, grants applied" ;;
      *)              echo "   $name: account exists (status $status): password unchanged, grants applied" ;;
    esac
    ok=$((ok + 1))
  else
    echo "   $name: FAILED (see the ORA- message above)"; failed=$((failed + 1))
  fi
done <<<"$ROWS"

if [[ $handled -eq 0 ]]; then echo "No database in $LIST runs on this server (as $(id -un))."; fi
echo
if [[ $APPLY -eq 1 ]]; then
  echo "done: $ok OK, $failed failed"
  [[ $failed -gt 0 ]] && exit 1
else
  echo "dry run: $planned database(s) would be changed, $failed refused or failed; nothing was changed (add --apply)"
  [[ $failed -gt 0 ]] && exit 1
fi
exit 0

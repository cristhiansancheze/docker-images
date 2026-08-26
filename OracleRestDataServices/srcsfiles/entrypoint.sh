#!/bin/bash
# Copyright (c) 2025, Oracle and/or its affiliates. All rights reserved.
#
#    NAME
#        entrypoint.sh
#
#    DESCRIPTION
#        Script to configure and install APEX and ORDS on a container
#    NOTES

# Variables
ORDS_HOME=/opt/oracle/ords
APEX_HOME=/opt/oracle/apex
APEXI=/opt/oracle/apex/images
INSTALL_LOGS=/tmp/install_logs
ORDS_ENTRYPOINT_DIR=/ords-entrypoint.d
ORDS_CONF_DIR="/etc/ords/config"
ORDS_DB_POOL="${ORDS_DB_POOL:-default}"
ORDS_DB_POOL_OPTION=()
if [[ "${ORDS_DB_POOL}" != "default" ]]; then
    ORDS_DB_POOL_OPTION=(--db-pool "${ORDS_DB_POOL}")
fi

function _detect_database_type() {
    local conn_type="$1" target probe
    if [[ "${conn_type}" == simple ]]; then
        target="${DBHOST}:${DBPORT}/${DBSERVICENAME}"
    else
        target="${CONN_STRING}"
    fi
    probe=$'WHENEVER SQLERROR EXIT SQL.SQLCODE\nSELECT 1 FROM dual;\nEXIT SUCCESS;'

    if printf '%s\n' "${probe}" | sql -s "sys/${ORACLE_PWD}@${target} as sysdba" >/dev/null 2>&1; then
        DB_TYPE=free
        ADB_MODE=false
    elif printf '%s\n' "${probe}" | sql -s "ADMIN/${ORACLE_PWD}@${target}" >/dev/null 2>&1; then
        DB_TYPE=adb
        ADB_MODE=true
    else
        return 1
    fi
    export DB_TYPE ADB_MODE
    printf '%s\n' "INFO : Detected database type: ${DB_TYPE}"
}

for secret_name in ORACLE_PWD ORACLE_USER_PWD; do
    if [[ -z "${!secret_name:-}" ]] && [[ -r "/run/secrets/${secret_name}" ]]; then
        secret_value=$(< "/run/secrets/${secret_name}")
        secret_value="${secret_value//$'\n'/}"
        printf -v "${secret_name}" '%s' "${secret_value}"
        export "${secret_name}"
    fi
done

# Function definitions

#Validate DBPORT 
function _validate_dbport {
    if [[ -n "$DBPORT" ]] && ! [[ "$DBPORT" =~ ^[0-9]+$ ]]; then
        printf "%s%s\n" "ERROR: " "DBPORT must be a numeric value."
        exit 1
    fi
}

# Validate Oracle user name
function _validate_oracle_username {
    if ! [[ "$ORACLE_USER_NAME" =~ ^[a-zA-Z0-9_]+$ ]]; then
        printf "%s%s\n" "ERROR: " "ORACLE_USER_NAME must be a valid identifier (alphanumeric and underscore)."
        exit 1
    fi
}

function _validate_adb_password() {
    local label="$1" password="$2" username="${3:-}"
    if (( ${#password} < 12 || ${#password} > 30 )); then
        printf '%s\n' "ERROR: ADB ${label} password must be 12 to 30 characters long." >&2
        return 1
    fi
    if [[ ! "$password" =~ [A-Z] || ! "$password" =~ [a-z] || ! "$password" =~ [0-9] ]]; then
        printf '%s\n' "ERROR: ADB ${label} password must contain uppercase, lowercase, and numeric characters." >&2
        return 1
    fi
    if [[ -n "$username" ]] && [[ "${password,,}" == *"${username,,}"* ]]; then
        printf '%s\n' "ERROR: ADB ${label} password must not contain the username." >&2
        return 1
    fi
}

function _set_ords_config_default() {
    local config_key="$1"
    local config_value="$2"
    local existing_value

    existing_value=$("${ORDS_HOME}/bin/ords" config get "${config_key}" 2>/dev/null | tail -1)
    if [[ -z "${existing_value}" ]] || [[ "${existing_value}" == "null" ]]; then
        "${ORDS_HOME}/bin/ords" config set "${config_key}" "${config_value}" >/dev/null 2>&1
    fi
}

#Generate random default credentials
function _generate_string() {
    local length=$1
    local character_set=$2
    LC_ALL=C tr -dc "$character_set" </dev/urandom | head -c "$length"
    echo
}

function _set_apex_pwd() {
  if [[ -z "$APEX_PWD" ]]; then
       APEX_PWD=$(_generate_string "12" '0-9a-zA-Z')
       printf "%s%s\n" "INFO : " "The APEX_PWD variable was not supplied.
       A new password must be set to complete the configuration.
       To do this, connect as SYS with SYSDBA privileges and run:
       ALTER USER APEX_PUBLIC_USER IDENTIFIED BY \"<new_password>\";"
  fi
}

function execute_sql() {
    local query=$1
    local user_conn=$2
    sql -s "${user_conn}" << _SQL_SCRIPT >> /tmp/ords_user_setup.log 2>&1
        WHENEVER SQLERROR EXIT FAILURE
        ${query}
        EXIT SUCCESS
_SQL_SCRIPT
    local sql_exit_code=$?
    return ${sql_exit_code}
}

function _ords_user_setup() {
    if [[ -n "$2" ]]; then
        if ! [[ "$2" =~ ^[a-zA-Z][a-zA-Z0-9_$#]*$ ]]; then
            printf "%s\n" "ERROR: Invalid database username: $2" >&2
            exit 1
        fi
        local CONN_STRING=$1
        QUERY_OUTPUT=$(sql -s "$CONN_STRING" <<SQL_COMMANDS
        SET TERMOUT OFF;
        SET PAGESIZE 0;
        SET FEEDBACK OFF;
        SELECT username FROM dba_users WHERE username = UPPER('$2') AND ROWNUM = 1;
        EXIT;
SQL_COMMANDS
        )
        if [[ "$QUERY_OUTPUT" == *"$2"* ]]; then
           SET_USER="ALTER SESSION SET CONTAINER = ${DBSERVICENAME};  
            @/opt/oracle/ords/scripts/installer/ords_installer_privileges.sql ${2};
            EXIT;"
        else
            SET_USER="ALTER SESSION SET CONTAINER = ${DBSERVICENAME};
            CREATE USER ${2} IDENTIFIED BY \"${3}\";  
            @/opt/oracle/ords/scripts/installer/ords_installer_privileges.sql ${2};
            EXIT;"
        fi
        execute_sql "$SET_USER" "$CONN_STRING"
        FUNCTION_STATUS=$?
        if [ ${FUNCTION_STATUS} -ne 0 ]; then
            printf "%s%s\n" "ERROR : " "ORACLE_USER_NAME setup failed: SQL error occurred"
            exit 1
        else
            printf "%s%s\n" "INFO : " "${2} setup Complete."
        fi
    fi
}

function _get_ords_user_pwd() {
    if [[ -z "${ORACLE_USER_PWD}" ]]; then
        printf '%s\n' 'ERROR: Required variable ORACLE_USER_PWD is missing or empty. Aborting execution.' >&2
        return 1
    fi
    if [[ "${ADB_MODE:-false}" == "true" && "${ORACLE_USER_NAME:-}" == "ADMIN" \
        && -n "${ORACLE_PWD:-}" && -n "${ORACLE_USER_PWD:-}" ]]; then
        echo "ADMIN/${ORACLE_PWD}/${ORACLE_USER_PWD}"
        return 0
    fi
    #Optional USER/PWD provided
    if [[ -n "$ORACLE_USER_NAME" ]] && [[ -n "$ORACLE_USER_PWD" ]]; then
        echo "${ORACLE_USER_NAME}/${ORACLE_USER_PWD}/${ORACLE_USER_PWD}"
    #No USER provided PWD Generated
    elif [[ -z "$ORACLE_USER_NAME" ]] && [[ -n "$ORDS_USER_PWD" ]]; then
        echo "sys/${ORACLE_PWD}/${ORDS_USER_PWD}"
    #USER provided PWD Generated
    elif [[ -n "$ORACLE_USER_NAME" ]] && [[ -n "$ORDS_USER_PWD" ]]; then
        echo "${ORACLE_USER_NAME}/${ORACLE_USER_PWD}/${ORDS_USER_PWD}"
    #USER provided PWD not Generated     
    elif [[ -n "$ORACLE_USER_NAME" ]] && [[ -z "$ORACLE_USER_PWD" ]]; then
        echo "${ORACLE_USER_NAME}/${ORACLE_USER_PWD}/${ORACLE_USER_PWD}"
    #No USER, Password provided
    elif [[ -z "$ORACLE_USER_NAME" ]] && [[ -n "$ORACLE_USER_PWD" ]]; then
        echo "sys/${ORACLE_PWD}/${ORACLE_USER_PWD}"
    #No USER/No PWD provided
    elif [[ -z "$ORACLE_USER_NAME" ]] && [[ -z "$ORACLE_USER_PWD" ]]; then
        echo "sys/${ORACLE_PWD}/${ORACLE_USER_PWD}"
    fi
}

#Parse DB connection string
function _get_dbservicename() {
  CONN_STRING=$1
  regex='(//)?[a-zA-Z0-9.-]+:[0-9]{1,5}/[a-zA-Z0-9_.]+'
  #Strip jdbc if present explicitly
  if [[ "$CONN_STRING" =~ "jdbc:oracle:thin:@" ]]; then
    declare -g CONN_STRING="${CONN_STRING#jdbc:oracle:thin:@}"
  fi
  # Format Custom (Service Name): (DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=myhost)(PORT=1521))(CONNECT_DATA=(SERVICE_NAME=ora.example.com)))
  if [[ "$CONN_STRING" =~ \(DESCRIPTION=.+ ]]; then
    CONN_STRING_OUT=$(echo "$CONN_STRING" | grep -Eo 'SERVICE_NAME=[a-zA-Z0-9_.]+' | awk -F'=' '{print $2}')
  # --- Check for connection string formats ---
  # Format (Service Name): hostname:port/service_name 
  elif [[ "$CONN_STRING" =~ $regex  ]]; then
    CONN_STRING_OUT="${CONN_STRING##*/}"
  # Set 'na' for any other connection string
  else
    CONN_STRING_OUT="na"
  fi
  echo "${CONN_STRING_OUT};${CONN_STRING}"
}

function _dbconnect_var(){
    if [ -n "${ORACLE_PWD}" ]; then 
        if [ -n "${DBHOST}" ] && [ -n "${DBPORT}" ] && [ -n "${DBSERVICENAME}" ]; then
            echo "conn_type_simple"
        elif [ -n "${CONN_STRING}" ]; then
            DBSERVICENAME_OUT=$(_get_dbservicename "$CONN_STRING")
            echo "conn_type_string_;${DBSERVICENAME_OUT}"
        else
            echo "conn_type_declare"
        fi
    else
        echo "conn_type_declare"
    fi
}

# Test DB connection
function _test_preconfigured_user_database() {
    local DB_USER="${ORACLE_USER_NAME}"
    local DB_TEST_URL
    if [[ "${CONN_TYPE}" == "string" ]]; then
        DB_TEST_URL="${DB_USER}/${ORACLE_USER_PWD}@${CONN_STRING}"
    else
        DB_TEST_URL="${DB_USER}/${ORACLE_USER_PWD}@${DBHOST}:${DBPORT}/${DBSERVICENAME}"
    fi

    printf '%s%s\n' "INFO : " "Testing preconfigured database user ${DB_USER}..."
    if echo "WHENEVER SQLERROR EXIT SQL.SQLCODE
SELECT 1 FROM dual;
EXIT SUCCESS;" | sql -s "${DB_TEST_URL}" >/dev/null 2>&1; then
        printf '%s%s\n' "INFO : " "Preconfigured database user connection successful."
        return 0
    fi

    printf '%s%s\n' "ERROR : " "Preconfigured database user ${DB_USER} failed to connect." >&2
    return 1
}

function _test_sys_database() {
    local MAX_RETRIES=${DB_WAIT_RETRY}
    local RETRY_DELAY=10
    local ATTEMPT=1
    DBCONNECT_OUT=$(_dbconnect_var) > /dev/null
    CONN_TYPE=$(echo "$DBCONNECT_OUT" | cut -d";" -f 1 | cut -d"_" -f 3)
    case "${CONN_TYPE}" in
        "simple") ;;
        "string") CONN_STRING=$(echo "$DBCONNECT_OUT" | cut -d";" -f 3); export CONN_STRING ;;
        "declare") _connection_error ;;
        *) _unknown_error ;;
    esac
    echo "Testing database connection..."
    while [ "$ATTEMPT" -le "$MAX_RETRIES" ]; do
            if ! _detect_database_type "${CONN_TYPE}"; then
                printf "%s%s\n" "INFO : " "Database not ready (attempt $ATTEMPT of $MAX_RETRIES). Retrying in ${RETRY_DELAY}s..."
                sleep "$RETRY_DELAY"
                ((ATTEMPT++))
                continue
            fi
            if [[ "${CONN_TYPE}" == "simple" ]]; then
                if [[ "${ADB_MODE}" == true ]]; then
                    DB_URL="ADMIN/${ORACLE_PWD}@${DBHOST}:${DBPORT}/${DBSERVICENAME}"
                else
                    DB_URL="sys/${ORACLE_PWD}@${DBHOST}:${DBPORT}/${DBSERVICENAME} as sysdba"
                fi
            elif [[ "${ADB_MODE}" == true ]]; then
                DB_URL="ADMIN/${ORACLE_PWD}@${CONN_STRING}"
            else
                DB_URL="sys/${ORACLE_PWD}@${CONN_STRING} as sysdba"
            fi
            if [[ "${CONN_TYPE}" == "string" ]]; then
              printf "%s%s\n" "INFO : " "Attempt $ATTEMPT: Connecting to ${CONN_STRING}..."
            else
              printf "%s%s\n" "INFO : " "Attempt $ATTEMPT: Connecting to ${DBHOST}:${DBPORT}/${DBSERVICENAME}..."
            fi
            if [[ "${ADB_MODE:-false}" != "true" || "${ORACLE_USER_NAME:-ADMIN}" != "ADMIN" ]]; then
              SQL_OUTPUT=$(echo "
                WHENEVER SQLERROR EXIT SQL.SQLCODE
                SET HEADING OFF FEEDBACK OFF VERIFY OFF ECHO OFF
                SELECT 1 FROM dual;
                EXIT SUCCESS;" \
                | sql -s "${DB_URL}" 2>&1)
              SQL_EXIT_CODE=$?
            elif [ -n "${DBSERVICENAME}" ] && [ "${DBSERVICENAME}" != "na" ]; then
              SQL_OUTPUT=$(echo "
                WHENEVER SQLERROR EXIT SQL.SQLCODE
                SET HEADING OFF FEEDBACK OFF VERIFY OFF ECHO OFF
                SELECT open_mode
                  FROM v\$containers
                 WHERE con_id = TO_NUMBER(SYS_CONTEXT('USERENV', 'CON_ID'));
                EXIT SUCCESS;" \
                | sql -s "${DB_URL}" 2>&1)
              SQL_EXIT_CODE=$?
            else
              SQL_OUTPUT=$(echo "
                WHENEVER SQLERROR EXIT SQL.SQLCODE
                SET HEADING OFF FEEDBACK OFF VERIFY OFF ECHO OFF
                SELECT open_mode FROM v\$containers;
                EXIT SUCCESS; " \
                | sql -s "${DB_URL}" 2>&1)
              SQL_EXIT_CODE=$?
            fi
            if [ "${SQL_EXIT_CODE}" -eq 0 ]; then
              if [[ "${ADB_MODE:-false}" != "true" || "${ORACLE_USER_NAME:-ADMIN}" != "ADMIN" ]]; then
                RESULT=1
              else
                RESULT=$(printf '%s\n' "${SQL_OUTPUT}" | grep -c "READ WRITE" || true)
              fi
            else
              RESULT=0
              if [ "${ATTEMPT}" -eq "${MAX_RETRIES}" ]; then
                printf '%s\n' "${SQL_OUTPUT}" >&2
              fi
            fi
            if [ "$RESULT" -ge 1 ]; then
                printf "%s%s\n" "INFO : " "Database connection successful."
                if [[ -n "${ORACLE_USER_NAME:-}" && "${ORACLE_USER_NAME}" != "ADMIN" ]]; then
                    _test_preconfigured_user_database || exit 1
                fi
                return 0
            else
                printf "%s%s\n" "INFO : " "Database not ready (attempt $ATTEMPT of $MAX_RETRIES). Retrying in ${RETRY_DELAY}s..."
                sleep $RETRY_DELAY
                ((ATTEMPT++))
            fi
    done
    printf "%s%s\n" "ERROR :" "Failed to connect to database after $MAX_RETRIES attempts."
    printf "%s%s\n" "       " "To increase the time waiting for the database connection set DB_WAIT_RETRIES greater than 30."
    exit 1
}

function _ensure_custom_url_runtime_wallet_secret() {
    local pool_name="${1:-default}"
    local password="${2:-}"
    local configured_password

    if [[ -z "${password}" ]]; then
        printf "%s\n" "ERROR: Cannot initialize the ORDS runtime wallet: password is empty." >&2
        return 1
    fi

    configured_password=$("${ORDS_HOME}/bin/ords" config --db-pool "${pool_name}" get --secret db.password 2>/dev/null | tail -n 1 || true)
    if [[ "${configured_password}" == "${password}" ]]; then
        return 0
    fi

    printf "%s\n" "INFO : Initializing the ORDS runtime wallet secret for custom URL database connection."
    if ! printf '%s\n%s\n' "${password}" "${password}" | "${ORDS_HOME}/bin/ords" config --db-pool "${pool_name}" secret db.password >/dev/null 2>&1; then
        printf "%s%s\n" "ERROR: " "Could not store the ORDS database password in the pool wallet." >&2
        return 1
    fi

    configured_password=$("${ORDS_HOME}/bin/ords" config --db-pool "${pool_name}" get --secret db.password 2>/dev/null | tail -n 1 || true)
    if [[ "${configured_password}" != "${password}" ]]; then
        printf "%s%s\n" "ERROR: " "The ORDS runtime wallet db.password secret could not be verified." >&2
        return 1
    fi
}

function _test_ords_database(){
    local MAX_RETRIES=${ORDS_DB_WAIT_RETRY:-10}
    local RETRY_DELAY=10
    local ATTEMPT=1
    printf "\a%s%s\n" "INFO : " "Using credentials found in the ORDS_CONFIG directory to test the Database health."
    if [[ -f "${ORDS_CONF_DIR}/databases/${ORDS_DB_POOL}/pool.xml" ]]; then
        POOL_FILE="${ORDS_CONF_DIR}/databases/${ORDS_DB_POOL}/pool.xml"
    else
        POOL_FILE=$(find "${ORDS_CONF_DIR}/databases" -mindepth 2 -maxdepth 2 \
            -type f -name pool.xml -print -quit 2>/dev/null)
    fi
    POOL_NAME=$(basename "$(dirname "${POOL_FILE}")")
    if [[ -z "${POOL_NAME}" ]]; then
        printf "%s%s\n" "ERROR: " "Could not determine the ORDS database pool name."
        return 1
    fi
    CONNECTION_TYPE=$(grep db.connectionType "${POOL_FILE}"|cut -d">" -f2|cut -d"<" -f1)
    WALLET_PATH=$(grep db.wallet.zip.path "${POOL_FILE}"|cut -d">" -f2|cut -d"<" -f1)
    if [ "${CONNECTION_TYPE}" == "basic" ]; then
        DBHOST=$(grep db.hostname "${POOL_FILE}"|cut -d">" -f2|cut -d"<" -f1)
        DBPORT=$(grep db.port "${POOL_FILE}"|cut -d">" -f2|cut -d"<" -f1)
        DBSERVICENAME=$(grep db.servicename "${POOL_FILE}"|cut -d">" -f2|cut -d"<" -f1)
        ORDSUSERNAME=$(grep db.username "${POOL_FILE}"|cut -d">" -f2|cut -d"<" -f1)
        ORDS_PWD=$(ords config --db-pool "${POOL_NAME}" get --secret db.password| tail -1)
        DB_URL="${ORDSUSERNAME}/${ORDS_PWD}@${DBHOST}:${DBPORT}/${DBSERVICENAME}"
    elif [ "${CONNECTION_TYPE}" == "customurl" ]; then
        CONN_STRING=$(grep db.customURL "${POOL_FILE}"|cut -d">" -f2|cut -d"<" -f1)
        ORDSUSERNAME=$(grep db.username "${POOL_FILE}"|cut -d">" -f2|cut -d"<" -f1)
        ORDS_PWD=$(ords config --db-pool "${POOL_NAME}" get --secret db.password| tail -1)
        DB_URL="${ORDSUSERNAME}/${ORDS_PWD}@${CONN_STRING}"
    elif [[ -n "$WALLET_PATH" ]]; then
        printf "%s%s\n" "INFO : " "Wallet settings found skipping test"
        return 0
    else
        printf "%s%s\n" "INFO : " "The database details were not found at /etc/ords/config."
    fi
    while [ $ATTEMPT -le "$MAX_RETRIES" ]; do
        printf "%s%s\n" "INFO : " "Attempt $ATTEMPT: Connecting to ${DBHOST:-configured}:${DBPORT:-configured}/${DBSERVICENAME:-configured}..."
        if sql -s "${DB_URL}" >/dev/null 2>&1 <<'SQL_COMMANDS'
            WHENEVER SQLERROR EXIT SQL.SQLCODE
            SELECT 1 FROM dual;
            EXIT SUCCESS;
SQL_COMMANDS
        then
            printf "%s%s\n" "INFO : " "Database connection successful."
            return 0
        else
            if [ "$ATTEMPT" -lt "$MAX_RETRIES" ]; then
                printf "%s%s\n" "INFO : " "Database not ready (attempt $ATTEMPT of $MAX_RETRIES). Retrying in ${RETRY_DELAY}s..."
                sleep "$RETRY_DELAY"
            else
                printf "%s%s\n" "INFO : " "Database not ready (attempt $ATTEMPT of $MAX_RETRIES)."
            fi
            ((ATTEMPT++))
        fi
    done
    printf "%s%s\n" "WARN : " "Failed to connect to database $POOL_NAME after $MAX_RETRIES attempts."
    printf "%s%s\n" "WARN : " "Starting services, if they exist, for additional preset databases identified in /etc/ords/config."
}


function _apex_ver(){
    # Validate if apex is installed and the version
    # Get APEX version from APEX files
    if [ -f ${APEX_HOME}/core/scripts/set_appun.sql ]; then 
        APEX_VER=$(grep  "APEX_[0-9][0-9]0[1-5][0-9][0-9]" ${APEX_HOME}/core/scripts/set_appun.sql | awk '{print $4}' | cut -d"_" -f2|cut -d"'" -f1| awk -F '' '{print $1$2"."$4"."$6}')
        APEX_YEAR=$(echo "${APEX_VER}" | cut -d"." -f1)
        export APEX_YEAR
        APEX_QTR=$(echo "${APEX_VER}" | cut -d"." -f2)
        APEX_PATCH=$(echo "${APEX_VER}" | cut -d"." -f3)
        printf "%s%s\n" "INFO : " "The container found Oracle APEX version ${APEX_VER} in the mounted volume."
    else
        printf "\a%s%s\n" "ERROR: " "The Oracle APEX installation files are missing."
        exit 1
    fi
    # Get APEX version from DB
    CONN_TYPE=$(_dbconnect_var | cut -d";" -f 1 | cut -d"_" -f 3) > /dev/null
    case "${CONN_TYPE}" in
        "simple")
            sql -s /nolog << _SQL_SCRIPT > /tmp/apex_version 2> /dev/null
            conn sys/${ORACLE_PWD}@${DBHOST}:${DBPORT}/${DBSERVICENAME} as sysdba
            SET LINESIZE 20000 TRIM ON TRIMSPOOL ON
            SET PAGESIZE 0
            SELECT VERSION FROM DBA_REGISTRY WHERE COMP_ID='APEX';
_SQL_SCRIPT
        ;;
        "string") 
            sql -s /nolog << _SQL_SCRIPT > /tmp/apex_version 2> /dev/null
            conn sys/${ORACLE_PWD}@${CONN_STRING} as sysdba
            SET LINESIZE 20000 TRIM ON TRIMSPOOL ON
            SET PAGESIZE 0
            SELECT VERSION FROM DBA_REGISTRY WHERE COMP_ID='APEX';
_SQL_SCRIPT
        ;;
        "declare")
            _connection_error
        ;;
        *)
            _unknown_error
        ;;
    esac
    # Get DB installed version
    APEX_DBVER=$(cat /tmp/apex_version|grep -v DEBUG|grep "[0-9][0-9].[1-5].[0-9]" |sed '/^$/d'|sed 's/ //g')
    export APEX_DBVER
    APEXDB_YEAR=$(echo "${APEX_DBVER}" | cut -d"." -f1)
    APEXDB_QTR=$(echo "${APEX_DBVER}" | cut -d"." -f2)
    APEXDB_PATCH=$(echo "${APEX_DBVER}" | cut -d"." -f3)
    grep "SQL Error" /tmp/apex_version > /dev/null
    SQL_ERROR=$?
    if [[ "$SQL_ERROR" -eq 0 ]] ; then
        printf "\a%s%s\n" "ERROR: " "Please validate the database status."
        grep "SQL Error" /tmp/apex_version 
        exit 1
    fi
    if [ -n "${APEX_DBVER}" ]; then
        # Validate if an upgrade needed
        if [ "${APEX_DBVER}" = "${APEX_VER}" ]; then
            printf "%s%s\n" "INFO : " "The Oracle APEX ${APEX_VER} is already installed in your database."
        elif [ "$APEXDB_YEAR" -gt "$APEX_YEAR" ]; then
            printf "\a%s%s\n" "ERROR: " "A newer Oracle APEX version (${APEX_DBVER}) is already installed in your database. The APEX version mounted on the container is ${APEX_VER}. Stopping the container."
            exit 1
        elif [ "$APEXDB_YEAR" -eq "$APEX_YEAR" ] && [ "$APEXDB_QTR" -gt "$APEX_QTR" ]; then
            printf "\a%s%s\n" "ERROR: " "A newer Oracle APEX version (${APEX_DBVER}) is already installed in your database. The APEX version mounted on the container is ${APEX_VER}. Stopping the container." 
            exit 1
        elif [ "$APEXDB_YEAR" -eq "$APEX_YEAR" ] && [ "$APEXDB_QTR" -eq "$APEX_QTR" ] && [ "$APEXDB_PATCH" -gt "$APEX_PATCH" ]; then
            printf "\a%s%s\n" "INFO : " "The Oracle APEX (${APEX_DBVER}) is already installed in your database. The APEX version mounted on the container is ${APEX_VER}."
            printf "\a%s%s\n" "INFO : " "Starting Oracle REST Data Services with the ${APEX_VER} Oracle Apex images."
        else
            printf "%s%s\n" "INFO : " "The Oracle APEX (${APEX_DBVER}) is installed on your database, and will be upgraded to ${APEX_VER}."
            _install_apex
        fi
    else
        _install_apex
    fi
}

function _install_apex(){
    # Validate if DB is a PDB or CDB
    CONN_TYPE=$(_dbconnect_var | cut -d";" -f 1 | cut -d"_" -f 3 ) > /dev/null
    case "${CONN_TYPE}" in
        "simple")
            sql -s /nolog << _SQL_SCRIPT > /tmp/db_type 2> /dev/null
            conn sys/${ORACLE_PWD}@${DBHOST}:${DBPORT}/${DBSERVICENAME} as sysdba
            SET LINESIZE 20000 TRIM ON TRIMSPOOL ON
            SET PAGESIZE 0
            SELECT CASE sys_context('USERENV', 'CON_ID') WHEN '1' THEN 'CDB' ELSE 'PDB' END as TYPE FROM DUAL;
_SQL_SCRIPT
        ;;
        "string") 
            sql -s /nolog << _SQL_SCRIPT > /tmp/db_type 2> /dev/null
            conn sys/${ORACLE_PWD}@${CONN_STRING} as sysdba
            SET LINESIZE 20000 TRIM ON TRIMSPOOL ON
            SET PAGESIZE 0
            SELECT CASE sys_context('USERENV', 'CON_ID') WHEN '1' THEN 'CDB' ELSE 'PDB' END as TYPE FROM DUAL;
_SQL_SCRIPT
        ;;
        "declare")
            _connection_error
        ;;
        *)
            _unknown_error
        ;;
    esac
    grep "SQL Error" /tmp/db_type > /dev/null
    SQL_ERROR=$?
    if [[ "$SQL_ERROR" -eq 0 ]] ; then
        printf "\a%s%s\n" "ERROR: " "Please validate the database status."
        grep "SQL Error" /tmp/apex_version 
        exit 1
    fi 
    grep "CDB" /tmp/db_type > /dev/null
    CDB_INS=$?
    if [[ "$CDB_INS" -eq 0 ]] ; then
        printf "\a%s%s\n" "ERROR: " "Oracle APEX cannot be installed on the CDB remotely, please install Oracle APEX directly on your database."
        exit 1
    fi 
    if [ -f $APEX_HOME/apxsilentins.sql ]; then
        printf "%s%s\n" "INFO : " "Installing Oracle APEX on your DB, please be patient."
        cd $APEX_HOME || exit 1
        touch ${INSTALL_LOGS}/apex_install.log
        case "${CONN_TYPE}" in
            "simple")
                _set_apex_pwd
                sql -s /nolog << _SQL_SCRIPT > ${INSTALL_LOGS}/apex_install.log 2> /dev/null
                conn sys/${ORACLE_PWD}@${DBHOST}:${DBPORT}/${DBSERVICENAME} as sysdba
                @apxsilentins.sql SYSAUX SYSAUX TEMP /i/ 'OraCle#1' 'OraCle#2' 'OraCle#3' 'OraCle#4'
                ALTER PROFILE default limit password_life_time UNLIMITED;
                ALTER USER APEX_PUBLIC_USER ACCOUNT UNLOCK;
                ALTER USER APEX_PUBLIC_USER IDENTIFIED BY "${APEX_PWD}";
_SQL_SCRIPT
                RESULT=$?
                if [[ "$RESULT" -eq 0 ]] ; then
                    printf "%s%s\n" "INFO : " "The Oracle APEX has been installed. You can create an APEX Workspace in Database Actions APEX Workspaces section."
                else
                    printf "\a%s%s\n" "ERROR: " "The Oracle APEX installation has failed"
                    tail -20 ${INSTALL_LOGS}/apex_install.log
                    exit 1
                fi
            ;;
            "string")
                 
                sql -s /nolog << _SQL_SCRIPT > ${INSTALL_LOGS}/apex_install.log 2> /dev/null
                conn sys/${ORACLE_PWD}@${CONN_STRING} as sysdba
                @apxsilentins.sql SYSAUX SYSAUX TEMP /i/ 'OraCle#1' 'OraCle#2' 'OraCle#3' 'OraCle#4'
                ALTER PROFILE default limit password_life_time UNLIMITED;
                ALTER USER APEX_PUBLIC_USER ACCOUNT UNLOCK;
                ALTER USER APEX_PUBLIC_USER IDENTIFIED BY "${APEX_PWD}";
_SQL_SCRIPT
                RESULT=$?
                if [[ "$RESULT" -eq 0 ]] ; then
                    printf "%s%s\n" "INFO : " "The Oracle APEX has been installed. You can create an APEX Workspace in Database Actions APEX Workspaces section."
                else
                    printf "\a%s%s\n" "ERROR: " "The Oracle APEX installation has failed"
                    exit 1
                fi
            ;;
            "declare")
                _connection_error
            ;;
            *)
                _unknown_error
            ;;
        esac
    else
        printf "\a%s%s\n" "ERROR: " "The Oracle APEX installation script is missing."
        exit 1
    fi
}

function _ords_repair(){
    cd ${ORDS_CONF_DIR} || exit 1 
    # ORDS repair
    printf "%s%s\n" "INFO : " "Set plsql.gateway.mode proxied after Oracle APEX was installed."
    ${ORDS_HOME}/bin/ords config "${ORDS_DB_POOL_OPTION[@]}" \
        set plsql.gateway.mode proxied >/dev/null 2>&1
    CONN_TYPE=$(_dbconnect_var | cut -d";" -f 1 | cut -d"_" -f 3) > /dev/null
    if ! GET_FUNC_OUT=$(_get_ords_user_pwd); then
        exit 1
    fi
    GET_ORDS_OUTPUT=$(echo "$GET_FUNC_OUT" | head -n -1)
    echo "$GET_ORDS_OUTPUT"
    ORDS_AUTH=$(echo "$GET_FUNC_OUT" | tail -n 1)
    IFS='/' read -r ORDS_USER_NAME ORDS_USER_PWD ORDS_PUBLIC_USER_PWD <<< "$ORDS_AUTH"
    case "${CONN_TYPE}" in
        "simple")
            ${ORDS_HOME}/bin/ords install repair "${ORDS_DB_POOL_OPTION[@]}" --admin-user "${ORDS_USER_NAME}" --password-stdin --db-hostname "${DBHOST}" \
            --db-port "${DBPORT}" --db-servicename "${DBSERVICENAME}"  << _SECRET >/dev/null 2>&1
${ORDS_USER_PWD}
_SECRET
        ;;
        "string")
            ${ORDS_HOME}/bin/ords  install repair "${ORDS_DB_POOL_OPTION[@]}" --admin-user "${ORDS_USER_NAME}" --db-custom-url "jdbc:oracle:thin:@${CONN_STRING}" \
            --password-stdin  << _SECRET >/dev/null 2>&1
${ORDS_USER_PWD}
_SECRET
        ;;
        *)
            _unknown_error
        ;;
    esac
}

function _ords_ver(){
    # Get ORDS version
    ORDS_YEAR=$(echo "${ORDS_VER}" | cut -d"." -f1)
    ORDS_QTR=$(echo "${ORDS_VER}" | cut -d"." -f2)
    ORDS_PATCH=$(echo "${ORDS_VER}" | cut -d"." -f3)
    CONN_TYPE=$(_dbconnect_var | cut -d";" -f 1 | cut -d"_" -f 3) > /dev/null

    if [[ "${ADB_MODE:-false}" == "true" ]]; then
        printf "%s%s\n" "INFO : " "Using the ORDS ADB installer for version and privilege management."
        _install_ords
        return
    fi
    # Grant inherit privileges on user sys to ORDS_METADATA;
    case "${CONN_TYPE}" in
        "simple")
            sql -s /nolog << _SQL_SCRIPT > /tmp/ords_db_version 2> /dev/null
            conn sys/${ORACLE_PWD}@${DBHOST}:${DBPORT}/${DBSERVICENAME} as sysdba
            SET LINESIZE 20000 TRIM ON TRIMSPOOL ON
            SET PAGESIZE 0
            select version from ORDS_VERSION;
_SQL_SCRIPT
        ;;
        "string") 
            sql -s /nolog << _SQL_SCRIPT > /tmp/ords_db_version 2> /dev/null
            conn sys/${ORACLE_PWD}@${CONN_STRING} as sysdba
            SET LINESIZE 20000 TRIM ON TRIMSPOOL ON
            SET PAGESIZE 0
            select version from ORDS_VERSION;
_SQL_SCRIPT
        ;;
        "declare")
            _connection_error
        ;;
        *)
            _unknown_error
        ;;
    esac
    grep "ORA-00942" /tmp/ords_db_version > /dev/null
    IS_INSTALL=$?
    if [[ "$IS_INSTALL" -eq 0 ]]; then
        printf "%s%s\n" "INFO : " "The Oracle REST Data Services are not installed on your database."
        _install_ords
    else
        grep "SQL Error" /tmp/ords_db_version > /dev/null
        SQL_ERROR=$?
        if [[ "$SQL_ERROR" -eq 0 ]]; then
            printf "\a%s%s\n" "ERROR: " "Please validate the database status."
            grep "SQL Error" /tmp/ords_db_version 
            exit 1
        fi
        ORDS_DBVER=$(cat /tmp/ords_db_version|grep -v DEBUG| grep "[0-9][0-9].[1-5].[0-9]" | tr -cd '[:digit:].' )
        ORDS_DBVER_SHORT=$(cat /tmp/ords_db_version|grep -v DEBUG| grep "[0-9][0-9].[1-5].[0-9]" | awk -F'.' '{print $1"."$2"."$3}')
        if [[ -z "${ORDS_DBVER_SHORT}" ]]; then
            printf "%s%s\n" "INFO : " "No valid ORDS version was found; installing ORDS ${ORDS_VER}."
            _install_ords
            return
        fi
        IFS='.' read -r ORDSDB_YEAR ORDSDB_QTR ORDSDB_PATCH <<< "$ORDS_DBVER_SHORT"
        if [ "${ORDS_DBVER_SHORT}" = "${ORDS_VER}" ]; then
            if [[ ! -f "${ORDS_CONF_DIR}/databases/${ORDS_DB_POOL}/pool.xml" ]]; then
                printf "%s%s\n" "INFO : " "The Oracle REST Data Services is installed in the database; configuring pool '${ORDS_DB_POOL}'."
                _install_ords
            else
                printf "%s%s\n" "INFO : " "The Oracle REST Data Services is already installed in your database."
            fi
        elif [ "${ORDSDB_YEAR}" -gt "${ORDS_YEAR}" ]; then
            printf "\a%s%s\n" "ERROR: " "A newer Oracle REST Data Services ($ORDS_DBVER) is already installed in your database. Oracle REST Data Services will not work correctly, update your docker image."
            exit 1 
        elif [ "${ORDSDB_YEAR}" -eq "${ORDS_YEAR}" ] && [ "${ORDSDB_QTR}" -gt "${ORDS_QTR}" ]; then
            printf "\a%s%s\n" "ERROR: " "A newer Oracle REST Data Services ($ORDS_DBVER) is already installed in your database. Oracle REST Data Services will not work correctly, update your docker image."
            exit 1
        elif [ "${ORDSDB_YEAR}" -eq "${ORDS_YEAR}" ] && [ "${ORDSDB_QTR}" -eq "${ORDS_QTR}" ] && [ "${ORDSDB_PATCH}" -gt "${ORDS_PATCH}" ]; then
            printf "\a%s%s\n" "ERROR: " "A newer Oracle REST Data Services ($ORDS_DBVER) is already installed in your database. Oracle REST Data Services will not work correctly, update your docker image."
            exit 1
        else
            printf "%s%s\n" "INFO : " "The Oracle REST Data Services version ${ORDS_DBVER} is installed on your database and will be upgraded to ${ORDS_VER} version."
            _install_ords
        fi
    fi
}

function _install_ords(){
    printf "%s%s\n" "INFO : " "Installing The Oracle REST Data Services $ORDS_VER."
    # Randomize the password for all the ORDS connection pool accounts
    cd ${ORDS_CONF_DIR} || exit 1
    CONN_TYPE=$(_dbconnect_var | cut -d";" -f 1 | cut -d"_" -f 3) > /dev/null
    if ! GET_FUNC_OUT=$(_get_ords_user_pwd); then
        exit 1
    fi
    GET_ORDS_OUTPUT=$(echo "$GET_FUNC_OUT" | head -n -1)
    echo "$GET_ORDS_OUTPUT"
    ORDS_AUTH=$(echo "$GET_FUNC_OUT" | tail -n 1)
    IFS='/' read -r ORDS_USER_NAME ORDS_USER_PWD ORDS_PUBLIC_USER_PWD <<< "$ORDS_AUTH"
    local PRECONFIGURED_USER=false
    if [[ -n "$ORACLE_USER_NAME" ]] && [[ -n "$ORACLE_USER_PWD" ]]; then
        _validate_oracle_username
        PRECONFIGURED_USER=true
    elif [[ -n "$ORACLE_USER_NAME" ]] && [[ -n "$ORDS_USER_PWD" ]]; then
        _validate_oracle_username
        local ORDS_SET_USER="$ORACLE_USER_NAME"
        local ORDS_SET_PWD="$ORDS_USER_PWD"    
    fi

    if [[ "${ADB_MODE:-false}" == "true" ]]; then
        local ADB_DB_USER="${ORDS_DB_USER:-ORDS_PUBLIC_USER2}"
        local ADB_GATEWAY_USER="${ORDS_GATEWAY_USER:-ORDS_PLSQL_GATEWAY2}"
        local ADB_WALLET_ZIP="${ORDS_CONF_DIR}/adb-wallet.zip"
        local ADB_SERVICE="${ORDS_WALLET_SERVICE:-${CONN_STRING:-${DBSERVICENAME:-}}}"
        _validate_adb_password "administrator" "${ORACLE_PWD}" "ADMIN" || exit 1
        _validate_adb_password "runtime" "${ORDS_PUBLIC_USER_PWD}" "${ADB_DB_USER}" || exit 1
        _validate_adb_password "gateway" "${ORDS_PUBLIC_USER_PWD}" "${ADB_GATEWAY_USER}" || exit 1
        if [[ -z "${TNS_ADMIN:-}" || ! -d "${TNS_ADMIN}" ]]; then
            printf '%s\n' 'ERROR: TNS_ADMIN must point to the extracted ADB wallet directory.' >&2
            exit 1
        fi
        if [[ ! -r "${TNS_ADMIN}/tnsnames.ora" ]]; then
            printf '%s\n' "ERROR: ADB wallet is missing ${TNS_ADMIN}/tnsnames.ora." >&2
            exit 1
        fi
        if [[ ! "${ADB_SERVICE}" =~ ^[A-Za-z][A-Za-z0-9_.-]*$ ]]; then
            printf '%s\n' "ERROR: ADB wallet service must be a TNS alias, got '${ADB_SERVICE}'." >&2
            exit 1
        fi
        if ! awk -v alias="${ADB_SERVICE}" 'tolower($1) == tolower(alias) { found=1 } END { exit(found ? 0 : 1) }' "${TNS_ADMIN}/tnsnames.ora"; then
            printf '%s\n' "ERROR: TNS alias '${ADB_SERVICE}' was not found in ${TNS_ADMIN}/tnsnames.ora." >&2
            exit 1
        fi
        if [[ ! -f "${ADB_WALLET_ZIP}" ]]; then
            (cd "${TNS_ADMIN}" && \
                jar cf "${ADB_WALLET_ZIP}" .) || {
                printf '%s\n' 'ERROR: Could not package the ADB wallet for ORDS installation.' >&2
                exit 1
            }
        fi
        if ! "${ORDS_HOME}/bin/ords" install adb "${ORDS_DB_POOL_OPTION[@]}" \
            --admin-user ADMIN \
            --db-user "${ADB_DB_USER}" \
            --gateway-user "${ADB_GATEWAY_USER}" \
            --wallet "${ADB_WALLET_ZIP}" \
            --wallet-service-name "${ADB_SERVICE}" \
            --feature-sdw true --log-folder "${INSTALL_LOGS}" --password-stdin \
            << _ADB_SECRET > "${INSTALL_LOGS}/ords_install.log" 2>&1
${ORACLE_PWD}
${ORDS_PUBLIC_USER_PWD}
${ORDS_PUBLIC_USER_PWD}
_ADB_SECRET
        then
            printf '%s\n' 'ERROR: The Oracle REST Data Services ADB installation has failed.' >&2
            tail -20 "${INSTALL_LOGS}/ords_install.log" >&2 || true
            exit 1
        fi
        printf "%s%s\n" "INFO : " "The Oracle REST Data Services $ORDS_VER has been installed correctly on ADB."
        return 0
    fi
    case "${CONN_TYPE}" in 
        "simple")
            if [[ "${ADB_MODE:-false}" == "true" ]]; then
                DB_CONN="${ORACLE_USER_NAME:-ADMIN}/${ORACLE_PWD}@${DBHOST}:${DBPORT}/${DBSERVICENAME}"
            else
                DB_CONN="sys/${ORACLE_PWD}@${DBHOST}:${DBPORT}/${DBSERVICENAME} as sysdba"
            fi
            if [[ "${PRECONFIGURED_USER}" != true ]]; then
                _ords_user_setup "$DB_CONN" "$ORDS_SET_USER" "$ORDS_SET_PWD"
            fi
            ${ORDS_HOME}/bin/ords install "${ORDS_DB_POOL_OPTION[@]}" --admin-user "${ORDS_USER_NAME}" --proxy-user --password-stdin --db-hostname "${DBHOST}" \
            --db-port "${DBPORT}" --db-servicename "${DBSERVICENAME}" --feature-sdw true \
            --log-folder ${INSTALL_LOGS}  << _SECRET > ${INSTALL_LOGS}/ords_install.log 2>&1
${ORDS_USER_PWD}
${ORDS_PUBLIC_USER_PWD}
_SECRET
        ;;
        "string")
            if [[ "${ADB_MODE:-false}" == "true" ]]; then
                DB_CONN="${ORACLE_USER_NAME:-ADMIN}/${ORACLE_PWD}@${CONN_STRING}"
            else
                DB_CONN="sys/${ORACLE_PWD}@${CONN_STRING} as sysdba"
            fi
            if [[ "${PRECONFIGURED_USER}" != true ]]; then
                _ords_user_setup "$DB_CONN" "$ORDS_SET_USER" "$ORDS_SET_PWD"
            fi
            ${ORDS_HOME}/bin/ords  install "${ORDS_DB_POOL_OPTION[@]}" --admin-user "${ORDS_USER_NAME}" --db-custom-url "jdbc:oracle:thin:@${CONN_STRING}" \
            --proxy-user --password-stdin --feature-sdw true \
            --log-folder ${INSTALL_LOGS}  << _SECRET > ${INSTALL_LOGS}/ords_install.log 2>&1
${ORDS_USER_PWD}
${ORDS_PUBLIC_USER_PWD}
_SECRET
        ;;
        *) 
            _unknown_error
        ;;
    esac
    RESULT=$?
    if [[ "$RESULT" -eq 0 ]]; then
        printf "%s%s\n" "INFO : " "The Oracle REST Data Services $ORDS_VER has been installed correctly on your database."
    else
        printf "\a%s%s\n" "ERROR: " "The Oracle REST Data Services installation has failed."
        if grep -qF 'ORA-20203: ERROR: Cannot create ORDS_PUBLIC_USER due to missing value' "${INSTALL_LOGS}/ords_install.log"; then
            printf "%s%s\n" "ERROR: " "ORDS installation stopped because ORDS_PUBLIC_USER could not be created due to a missing value."
            printf "%s\n" "The container will not retry automatically; fix the credentials and restart it."
            exit 0
        fi
        if [[ "${PRECONFIGURED_USER}" == true ]]; then
            printf '[%s] [ERROR] [ORDS] Preconfigured user %s could not complete the ORDS installation.\n' "${ORACLE_USER_NAME}" "${ORACLE_USER_NAME}"
            printf '[%s] [ACTION] [ORDS] Verify that the user exists and has the required ORDS privileges. A SYS-level user must run the ORDS privilege script for this user on the target database.\n' "${ORACLE_USER_NAME}"
        fi
        tail -20 ${INSTALL_LOGS}/ords_install.log
        exit 1
    fi
}

function _ords_entrypoint_dir(){
    if [ -d "${ORDS_ENTRYPOINT_DIR}" ] ; then
        mapfile -t CUSTOM_SCRIPTS < <(find -L "${ORDS_ENTRYPOINT_DIR}" -maxdepth 1 -type f -name '*.sh' -print | sort)
        if [ "${#CUSTOM_SCRIPTS[@]}" -eq 0 ]; then
            printf "%s%s\n" "INFO : " "No custom scripts were detected to run before starting the service."
        else
            printf "%s%s\n" "INFO : " "Files with extensions .sh, were found in ${ORDS_ENTRYPOINT_DIR}. Files will be executed alphabetically."
            for CUSTOM_SCRIPT in "${CUSTOM_SCRIPTS[@]}"; do
                printf "%s%s\n" "INFO : " "Executing script ${CUSTOM_SCRIPT}."
                bash "${CUSTOM_SCRIPT}"
            done
        fi
    fi
}

function _config_ords(){
    if [[ -z "$(find "${ORDS_CONF_DIR}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
        printf "\a%s%s\n" "ERROR: " "The ORDS config directory ${ORDS_CONF_DIR} is empty, please validate you ords config volume."
        exit 1
    fi
    cd ${ORDS_CONF_DIR} || exit 1
    ${ORDS_HOME}/bin/ords config "${ORDS_DB_POOL_OPTION[@]}" set feature.sdw true >/dev/null 2>&1
    ${ORDS_HOME}/bin/ords config "${ORDS_DB_POOL_OPTION[@]}" set restEnabledSql.active true >/dev/null 2>&1
    if [[ "${ORDS_DB_POOL}" != "default" ]]; then
        printf "%s%s\n" "INFO : " "SQL Developer Web for pool '${ORDS_DB_POOL}' is available at /ords/${ORDS_DB_POOL}/."
    fi
    # Set standalone accesslogs
    _set_ords_config_default standalone.access.log /tmp/ords_access_logs/
    mkdir /tmp/ords_access_logs/ >/dev/null 2>&1
    touch "/tmp/ords_access_logs/ords_$(date +%Y_%m_%d).log" >/dev/null 2>&1
    tail -f  "/tmp/ords_access_logs/ords_$(date +%Y_%m_%d).log" &
    # Set MongoDB
    _set_ords_config_default mongo.enabled true
    if [ -d "${APEXI}" ]; then
        printf "%s%s\n" "INFO : " "Setup standalone.static.path ${APEX_HOME}/images."
        ${ORDS_HOME}/bin/ords config set standalone.static.path ${APEX_HOME}/images  >/dev/null 2>&1
    fi
    export CERT_FILE="$ORDS_CONF_DIR/ssl/cert.crt"
    export KEY_FILE="$ORDS_CONF_DIR/ssl/key.key"
    # Set secure if certificates are present
    if [ -e "${CERT_FILE}" ] && [ -e "${KEY_FILE}" ]; then
        printf "%s%s\n" "INFO : " "The SSL certificates were found, and the Oracle REST Data Services instance will run on secure port 8443."
        ${ORDS_HOME}/bin/ords config set standalone.https.cert ${CERT_FILE}  >/dev/null 2>&1
        ${ORDS_HOME}/bin/ords config set standalone.https.cert.key ${KEY_FILE}  >/dev/null 2>&1
        ${ORDS_HOME}/bin/ords config set standalone.https.port 8443  >/dev/null 2>&1
    fi
    # If FORCE SECURE is true and Certificates does not exist, exit
    if { [ "${FORCE_SECURE}" = "TRUE" ] || [ "${FORCE_SECURE}" = "true" ]; } && { [ ! -e "${CERT_FILE}" ] || [ ! -e "${KEY_FILE}"  ]; }; then 
        printf "\a%s%s\n" "ERROR: " "The FORCE_SECURE flag is TRUE but the certificate files are missing at /etc/ords/config/ssl directory:"
        printf "%s%s\n" "       " "  - /etc/ords/config/ssl/cert.crt certificate file"
        printf "%s%s\n" "       " "  - /etc/ords/config/ssl/key.key  key file"
        exit 1
    fi
    if [ "${DEBUG}" = "TRUE" ] || [ "${DEBUG}" = "true" ]; then 
        ${ORDS_HOME}/bin/ords config set debug.printDebugToScreen true >/dev/null 2>&1
    elif [ "${DEBUG}" = "FALSE" ] || [ "${DEBUG}" = "false" ]; then 
        ${ORDS_HOME}/bin/ords config set debug.printDebugToScreen false >/dev/null 2>&1
    fi
}

function _run_ords(){
    printf "%s%s\n" "INFO : " "Starting the Oracle REST Data Services instance."
    _cleanup
    exec "${ORDS_HOME}/bin/ords" serve
}

function _unknown_error(){
    printf "\a%s%s\n" "ERROR: " "Unknown error."
    exit 1
}

function _connection_error(){
    printf "\a%s%s\n" "ERROR: " "Cannot connect to the database with the shared credentials it is necessary to meet one of the below requirements:"
    printf "%s%s\n"   "       " "- CONN_STRING and ORACLE_PWD variables declared."
    printf "%s%s\n"   "       " "- DBHOST, DBPORT, DBSERVICENAME, and ORACLE_PWD variables declared."
    exit 1
}

function _run_cli(){
    printf "%s%s\n" "INFO : " "Running Oracle REST Data Services CLI command."
    ${ORDS_HOME}/bin/ords ${CLI_CMD}
}

function _get_pool(){
    if [[ -f "${ORDS_CONF_DIR}/databases/${ORDS_DB_POOL}/pool.xml" ]]; then
        POOL_FILE="${ORDS_CONF_DIR}/databases/${ORDS_DB_POOL}/pool.xml"
    else
        POOL_FILE=$(find "${ORDS_CONF_DIR}/databases" -mindepth 2 -maxdepth 2 \
            -type f -name pool.xml -print -quit 2>/dev/null)
    fi
    CONNECTION_TYPE=$(grep db.connectionType "${POOL_FILE}"|cut -d">" -f2|cut -d"<" -f1)
    if [ "${CONNECTION_TYPE}" == "basic" ]; then
        DB_HOST=$(grep db.hostname "${POOL_FILE}" |cut -d">" -f2|cut -d"<" -f1)
        DB_PORT=$(grep db.port "${POOL_FILE}" |cut -d">" -f2|cut -d"<" -f1)
        DB_NAME=$(grep db.servicename "${POOL_FILE}" |cut -d">" -f2|cut -d"<" -f1)
        printf "%s%s\n" "INFO : " "Starting the Oracle REST Data Services instance with the preset configuration in /etc/ords/config:"
        printf "%s%s\n" "INFO : " "  ${DB_HOST}:${DB_PORT}/${DB_NAME}."
    elif [ "${CONNECTION_TYPE}" == "customurl" ]; then
        CONN_STRING=$(grep db.customURL "${POOL_FILE}" |cut -d">" -f2|cut -d"<" -f1)
        printf "%s%s\n" "INFO : " "Starting the Oracle REST Data Services instance with the preset configuration in /etc/ords/config:"
        printf "%s%s\n" "INFO : " "  ${CONN_STRING} "
    else
        printf "%s%s\n" "INFO : " "Starting the Oracle REST Data Services instance with the preset configuration in /etc/ords/config."
    fi
}

function _cleanup(){
    unset APEX_PWD ORACLE_PWD ORACLE_USER_PWD ORDS_PWD ORDS_USER_PWD ORDS_PUBLIC_USER_PWD
}

# Main
CLI_CMD=$*
function _run_script(){
    if [ "${CLI_CMD}" = "" ]; then
        if [[ -z "${ORACLE_USER_PWD}" ]] && [[ -z "${ORACLE_PWD}" ]] && [[ ! -d "${ORDS_CONF_DIR}" || -z "$(find "${ORDS_CONF_DIR}" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
            printf '%s\n' 'ERROR: Required variable ORACLE_USER_PWD is missing or empty. Aborting execution.' >&2
            exit 1
        fi
        # If credentials are present try to Install/Upgrade before run the service
        if [ ! -z "${DBHOST}" ] && [ ! -z "${DBPORT}" ] && [ ! -z "${DBSERVICENAME}" ] && [ ! -z "${ORACLE_PWD}" ]; then
            _validate_dbport
            mkdir -p ${INSTALL_LOGS}
            _test_sys_database
            if [ -f ${APEX_HOME}/apxsilentins.sql ]; then
                _ords_ver
                _apex_ver
                _ords_repair
            else
                _ords_ver
            fi
            _config_ords
            _ords_entrypoint_dir
            _run_ords
        elif [ ! -z "${CONN_STRING}" ] && [ ! -z "${ORACLE_PWD}" ]; then
            mkdir -p ${INSTALL_LOGS}
            _test_sys_database
            if [ -f ${APEX_HOME}/apxsilentins.sql ]; then
                _ords_ver
                _apex_ver
                _ords_repair
            else
                _ords_ver
            fi
            if [[ "${ADB_MODE:-false}" == "true" ]]; then
                if ! _ensure_custom_url_runtime_wallet_secret "${ORDS_DB_POOL}" "${ORDS_PUBLIC_USER_PWD}"; then
                    exit 1
                fi
            fi
            _config_ords
            _ords_entrypoint_dir
            _run_ords
        else
            if [[ -d "${ORDS_CONF_DIR}/databases" ]] &&
               [[ -n "$(find "${ORDS_CONF_DIR}/databases" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] &&
               [[ -e "${ORDS_CONF_DIR}/global/settings.xml" ]]; then
                _get_pool
                _test_ords_database
                _config_ords
                _ords_entrypoint_dir
                _run_ords
            else
                printf "\a%s%s\n" "ERROR: " "The container can't find a valid configuration in Oracle REST Data Services config directory /etc/ords/config."
                printf "%s%s\n" "       " "To install the product on your database and create a new configuration set the credentials meeting one of the below requirements:"
                printf "%s%s\n" "       " "    - CONN_STRING and ORACLE_PWD variables declared."
                printf "%s%s\n" "       " "    - DBHOST, DBPORT, DBSERVICENAME, and ORACLE_PWD variables declared."
                exit 1
            fi
        fi
    else
        _run_cli
    fi
}
function _debug_log() {
    if [ "${DEBUG}" = "TRUE" ] || [ "${DEBUG}" = "true" ]; then
        local conn_state='<unset>' oracle_pwd_state='<unset>' oracle_user_pwd_state='<unset>' ords_user_pwd_state='<unset>' ords_public_pwd_state='<unset>'
        [[ -n "${CONN_STRING}" ]] && conn_state='<set>'
        [[ -n "${ORACLE_PWD}" ]] && oracle_pwd_state='<set>'
        [[ -n "${ORACLE_USER_PWD}" ]] && oracle_user_pwd_state='<set>'
        [[ -n "${ORDS_USER_PWD}" ]] && ords_user_pwd_state='<set>'
        [[ -n "${ORDS_PUBLIC_USER_PWD}" ]] && ords_public_pwd_state='<set>'
        printf '%s\n' "DEBUG: startup diagnostics (credentials redacted)"
        printf '%s\n' "DEBUG: DBHOST=${DBHOST:-<unset>} DBPORT=${DBPORT:-<unset>} DBSERVICENAME=${DBSERVICENAME:-<unset>}"
        printf '%s\n' "DEBUG: CONN_STRING=${conn_state} ORACLE_PWD=${oracle_pwd_state}"
        printf '%s\n' "DEBUG: ORACLE_USER_NAME=${ORACLE_USER_NAME:-<unset>} ORACLE_USER_PWD=${oracle_user_pwd_state}"
        printf '%s\n' "DEBUG: ORDS_USER_PWD=${ords_user_pwd_state} ORDS_PUBLIC_USER_PWD=${ords_public_pwd_state}"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    _debug_log
    _run_script
fi

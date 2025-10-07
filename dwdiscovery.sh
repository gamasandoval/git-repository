#!/bin/bash
#########################################################################
# Name:          dwdiscovery.sh
# Description:   Check prechecks and gather of DW variables
# Args:          degreeworksuser
# Author:        G. Sandoval
# Date:          10.07.2025
# Version:       1.11
#########################################################################

####### VARIABLES SECTION #######
APP="DegreeWorks"
THRESHOLD=80   # % usage threshold for warnings

# Colors
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
CLEAR="\e[0m"

# Placeholder variables
DWVERSION=""
DGWBASE=""
SERVER_TYPE=""
HTTPD_PROCS=""
COUNT_NON_BLOB=""
COUNT_BLOB=""
DW_JARS=""

####### FUNCTIONS SECTION #######
f_log() {
    local msg="$1"
    local color="${2:-}"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    case "$color" in
        green)  echo -e "$timestamp: ${GREEN}${msg}${CLEAR}" ;;
        red)    echo -e "$timestamp: ${RED}${msg}${CLEAR}" ;;
        yellow) echo -e "$timestamp: ${YELLOW}${msg}${CLEAR}" ;;
        *)      echo "$timestamp: $msg" ;;
    esac
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        f_log "This script must be run as root. Current user: $(whoami)" red
        exit 1
    else
        f_log "Running as root user: $(whoami)" green
    fi
}

check_args() {
    if [[ $# -lt 1 ]]; then
        f_log "Usage: $0 degreeworksuser" red
        exit 1
    fi

    DEGREEWORKSUSER="$1"

    if id "$DEGREEWORKSUSER" &>/dev/null; then
        f_log "User $DEGREEWORKSUSER exists" green
    else
        f_log "User $DEGREEWORKSUSER does not exist!" red
        exit 1
    fi
}

check_os() {
    f_log "---------------------------------------------"
    f_log "Gathering OS information..."
    f_log "Hostname: $(hostname)"
    f_log "OS: $(grep '^PRETTY_NAME' /etc/os-release | cut -d= -f2- | tr -d '\"')"
    f_log "Kernel: $(uname -r)"
    f_log "Architecture: $(uname -m)"
    f_log "Uptime: $(uptime -p)"
}

check_filesystems() {
    f_log "Gathering filesystem information..."
    df -hT
}

check_fs_usage() {
    f_log "---------------------------------------------"
    f_log "Checking filesystem usage..."
    local threshold=$THRESHOLD
    df -h --output=source,pcent,size,used,avail,target | tail -n +2 | while read -r fs pcent size used avail mount; do
        usage=${pcent%%%}  # strip %
        if (( usage > threshold )); then
            f_log "WARNING: $fs mounted on $mount is ${pcent} used (total: $size, used: $used, avail: $avail)" red
        else
            f_log "$fs mounted on $mount is healthy (${pcent} used, total: $size, used: $used, avail: $avail)" green
        fi
    done
}

check_storage() {
    check_filesystems
    check_fs_usage
}

check_dw_version() {
    f_log "---------------------------------------------"
    f_log "Checking DegreeWorks version..."
    DWVERSION=$(su - "$DEGREEWORKSUSER" -c 'bash -l -c "echo \$DWRELEASE"' 2>/dev/null | tail -n1)
    if [[ -n "$DWVERSION" ]]; then
        f_log "DegreeWorks version: $DWVERSION" green
    else
        f_log "Could not detect DWRELEASE variable for $DEGREEWORKSUSER" red
    fi
}

check_dgwbase() {
    f_log "Checking DGWBASE variable..."
    DGWBASE=$(su - "$DEGREEWORKSUSER" -c 'bash -l -c "echo \$DGWBASE"' 2>/dev/null | tail -n1)
    if [[ -n "$DGWBASE" ]]; then
        f_log "DGWBASE variable: $DGWBASE" green
    else
        f_log "DGWBASE variable is not set for user $DEGREEWORKSUSER" yellow
    fi
}

check_server_type() {
    f_log "---------------------------------------------"
    f_log "Detecting server type (Classic vs Web vs Hybrid)..."
    f_log "DWVERSION='$DWVERSION'"
    f_log "DGWBASE='$DGWBASE'"

    # Detect Java jar processes
    HTTPD_PROCS=$(ps -u "$DEGREEWORKSUSER" -f | grep -i '.jar' | grep -iE "Responsive|Dashboard|Controller|API|Transit" | grep -iv "jenkins")
    JAVA_COUNT=$(echo "$HTTPD_PROCS" | grep -vi "transitexecutor.jar" | grep -v '^$' | wc -l)

    f_log "Relevant Java jar processes count: $JAVA_COUNT"

    if [[ -n "$DWVERSION" && -n "$DGWBASE" && $JAVA_COUNT -eq 0 ]]; then
        SERVER_TYPE="Classic"
        f_log "Decision: DW variables exist → Classic server" green
    elif [[ -z "$DWVERSION" && $JAVA_COUNT -ge 2 ]]; then
        SERVER_TYPE="Web"
        f_log "Decision: Multiple Java jars running → Web server" yellow
    elif [[ -n "$DWVERSION" && $JAVA_COUNT -ge 1 ]]; then
        SERVER_TYPE="Hybrid"
        f_log "Decision: DW variables + Java jars → Hybrid server" yellow
    else
        SERVER_TYPE="Unknown"
        f_log "Decision: Could not determine server type" red
    fi
}

check_rabbitmq_status() {
    f_log "---------------------------------------------"
    f_log "Checking RabbitMQ service status..."
    if systemctl is-active --quiet rabbitmq-server; then
        f_log "RabbitMQ service is running" green
    else
        f_log "RabbitMQ service is NOT running" red
    fi
}

check_rabbitmq_server_version() {
    f_log "Getting RabbitMQ server version..."
    if command -v rabbitmqctl &>/dev/null; then
        RABBIT_VERSION=$(rabbitmqctl version 2>/dev/null)
        f_log "RabbitMQ server version: ${RABBIT_VERSION:-Not detected}" green
    else
        f_log "rabbitmqctl command not found" red
    fi
}

check_rabbitmq_client_versions() {
    f_log "Checking RabbitMQ client installations under /opt..."
    if [[ -d /opt ]]; then
        CLIENT_DIRS=$(ls -d /opt/rabbitmq-c-* 2>/dev/null)
        if [[ -n "$CLIENT_DIRS" ]]; then
            f_log "Found RabbitMQ client versions:" green
            for dir in $CLIENT_DIRS; do
                version=$(basename "$dir" | sed 's/rabbitmq-c-//')
                f_log "  - $version"
            done
        else
            f_log "No RabbitMQ client directories found under /opt" red
        fi
    else
        f_log "/opt directory does not exist" red
    fi
}

check_java_version() {
    f_log "---------------------------------------------"
    f_log "Checking Java version as $DEGREEWORKSUSER..."
    JAVA_VER=$(su - "$DEGREEWORKSUSER" -c "java -version" 2>&1 | head -n 1)
    f_log "Java version detected: ${JAVA_VER:-Not detected}" green
}

check_apache_fop() {
    f_log "---------------------------------------------"
    f_log "Checking Apache FOP..."
    FOP_PATH=$(su - "$DEGREEWORKSUSER" -c 'which fop' 2>/dev/null)
    if [[ -n "$FOP_PATH" ]]; then
        f_log "Apache FOP path: $FOP_PATH" green
    else
        f_log "Apache FOP not found for user $DEGREEWORKSUSER" red
    fi
}

check_gcc() {
    f_log "---------------------------------------------"
    f_log "Checking GCC version..."
    if command -v gcc &>/dev/null; then
        GCC_VER=$(gcc -v 2>&1 | grep "gcc version" | head -n 1)
        f_log "GCC version detected: $GCC_VER" green
    else
        f_log "GCC is not installed or not in PATH" red
    fi
}

check_openssl() {
    f_log "---------------------------------------------"
    f_log "Checking OpenSSL version..."
    if command -v openssl &>/dev/null; then
        OPENSSL_VER=$(openssl version 2>/dev/null)
        f_log "OpenSSL version detected: $OPENSSL_VER" green
    else
        f_log "OpenSSL is not installed or not in PATH" red
    fi
}

check_perl() {
    f_log "---------------------------------------------"
    f_log "Checking Perl version..."
    if command -v perl &>/dev/null; then
        PERL_VER=$(perl -e 'printf "%vd\n", $^V' 2>/dev/null)
        f_log "Perl version detected: $PERL_VER" green
    else
        f_log "Perl is not installed or not in PATH" red
    fi
}

check_dw_db() {
    f_log "---------------------------------------------"
    f_log "Checking DW database connection with jdbcverify..."
    DB_OUTPUT=$(su - "$DEGREEWORKSUSER" -c 'jdbcverify --verbose' 2>&1)
    DB_EXIT=$?
    if [[ $DB_EXIT -eq 0 ]]; then
        f_log "Database connection OK" green
        echo "$DB_OUTPUT"
    else
        f_log "Database connection failed" red
        echo "$DB_OUTPUT"
    fi
}

check_db_version() {
    f_log "---------------------------------------------"
    f_log "Checking DW database version..."

    TMP_DB_FILE="/tmp/OracleDB_$$.txt"

    f_log "Running database command with nohup..."
    nohup su - "$DEGREEWORKSUSER" -c "db > $TMP_DB_FILE 2>&1" >/dev/null 2>&1 &

    # Wait a few seconds for the command to start and write output
    sleep 3

    if [[ -f "$TMP_DB_FILE" ]]; then
        DB_VERSION=$(egrep -i "version" "$TMP_DB_FILE" | head -n1)
        if [[ -n "$DB_VERSION" ]]; then
            f_log "Database version detected: $DB_VERSION" green
        else
            f_log "Could not detect database version in $TMP_DB_FILE" yellow
        fi
    else
        f_log "Database output file $TMP_DB_FILE not found" red
    fi
}


check_blob_conversion() {
    f_log "---------------------------------------------"
    f_log "Checking BLOB conversion requirement..."
    if [[ -z "$DWVERSION" ]]; then
        f_log "DWVERSION is not set. Skipping BLOB conversion check." red
        return
    fi

    SQL_NON_BLOB="select count(*) from DAP_AUDIT_DTL where DAP_CREATE_WHO!='BLOB';"
    SQL_BLOB="select count(*) from DAP_AUDIT_DTL where DAP_CREATE_WHO='BLOB';"

    f_log "Executing SQL (Non-BLOB): $SQL_NON_BLOB"
    NON_BLOB_OUTPUT=$(su - "$DEGREEWORKSUSER" -c "runsql \"$SQL_NON_BLOB\"" 2>&1)
    COUNT_NON_BLOB=$(echo "$NON_BLOB_OUTPUT" | grep -v -E '^$|^runsql:|^-ksh:' | head -n 1)
    f_log "Non-BLOB count: $COUNT_NON_BLOB"

    f_log "Executing SQL (BLOB): $SQL_BLOB"
    BLOB_OUTPUT=$(su - "$DEGREEWORKSUSER" -c "runsql \"$SQL_BLOB\"" 2>&1)
    COUNT_BLOB=$(echo "$BLOB_OUTPUT" | grep -v -E '^$|^runsql:|^-ksh:' | head -n 1)
    f_log "BLOB count: $COUNT_BLOB"
}

check_duplicate_exceptions() {
    f_log "---------------------------------------------"
    SQL_QUERY="select dap_stu_id, dap_exc_num, count(*) cnt from dap_except_dtl group by dap_stu_id, dap_exc_num having count(*) > 1 order by 1, 2;"
    f_log "Executing SQL: $SQL_QUERY"
    SQL_OUTPUT=$(su - "$DEGREEWORKSUSER" -c "runsql \"$SQL_QUERY\"" 2>&1)
    f_log "Duplicate exceptions:"
    echo "$SQL_OUTPUT" | grep -v -E '^$|^runsql:|^-ksh:'
}

check_duplicate_notes() {
    f_log "---------------------------------------------"
    SQL_QUERY="select dap_stu_id, dap_note_num, count(*) cnt from dap_note_dtl group by dap_stu_id, dap_note_num having count(*) > 1 order by 1, 2;"
    f_log "Executing SQL: $SQL_QUERY"
    SQL_OUTPUT=$(su - "$DEGREEWORKSUSER" -c "runsql \"$SQL_QUERY\"" 2>&1)
    f_log "Duplicate notes:"
    echo "$SQL_OUTPUT" | grep -v -E '^$|^runsql:|^-ksh:'
}


list_dw_jar_files() {
    f_log "---------------------------------------------"
    f_log "Listing DW-related Java JAR files for $SERVER_TYPE server..."
    
    if [[ "$SERVER_TYPE" != "Web" && "$SERVER_TYPE" != "Hybrid" ]]; then
        f_log "Skipping DW JAR file listing for Classic server" yellow
        return
    fi

    DW_JARS=$(ps -u "$DEGREEWORKSUSER" -f | grep -i '.jar' | grep -iE "Responsive|Dashboard|Controller|API|Transit" | grep -iv "jenkins")
    
    if [[ -n "$DW_JARS" ]]; then
        f_log "Found DW Java JAR processes:" green
        echo "$DW_JARS"
    else
        f_log "No DW-related Java JAR processes found" yellow
    fi
}

get_dw_jar_versions() {
    f_log "---------------------------------------------"
    f_log "Getting DW JAR versions..."

    if [[ "$SERVER_TYPE" != "Web" && "$SERVER_TYPE" != "Hybrid" ]]; then
        f_log "Skipping DW JAR version check for Classic server" yellow
        return
    fi

    for jar in $(echo "$DW_JARS" | awk '{for(i=8;i<=NF;i++) print $i}'); do
        if [[ -f "$jar" ]]; then
            JAR_VER=$(unzip -p "$jar" META-INF/MANIFEST.MF 2>/dev/null | grep -i "Implementation-Version" | head -n1)
            f_log "JAR: $(basename "$jar") → Version: ${JAR_VER:-Not found}"
        fi
    done
}

list_java_processes() {
    f_log "---------------------------------------------"
    f_log "Listing all Java processes..."
    ps -u "$DEGREEWORKSUSER" -f | grep -i '.jar' | grep -v grep
}

list_cronjobs() {
    f_log "---------------------------------------------"
    f_log "Listing cron jobs for $DEGREEWORKSUSER..."
    crontab -u "$DEGREEWORKSUSER" -l 2>/dev/null
}

check_httpd_processes() {
    f_log "---------------------------------------------"
    f_log "Checking for Apache/httpd processes..."
    HTTPD_PROCS=$(ps -ef | grep -iE "httpd|apache" | grep -v grep)
    if [[ -n "$HTTPD_PROCS" ]]; then
        f_log "Apache/httpd processes found:" green
        echo "$HTTPD_PROCS"
    else
        f_log "No Apache/httpd processes found" yellow
    fi
}

print_summary() {
    echo -e "\n==================== SUMMARY ===================="
    case "$SERVER_TYPE" in
        Classic) ST_COLOR="$GREEN" ;;
        Web)     ST_COLOR="$YELLOW" ;;
        Hybrid)  ST_COLOR="$YELLOW" ;;
        *)       ST_COLOR="$RED" ;;
    esac
    printf "%-25s : %b%s%b\n" "Server Type" "$ST_COLOR" "$SERVER_TYPE" "$CLEAR"
    printf "%-25s : %s\n" "DegreeWorks Version" "${DWVERSION:-Not set}"
    printf "%-25s : %s\n" "DGWBASE" "${DGWBASE:-Not set}"

    if [[ "$SERVER_TYPE" == "Classic" || "$SERVER_TYPE" == "Hybrid" ]]; then
        if systemctl is-active --quiet rabbitmq-server; then RABBIT_COLOR="$GREEN"; else RABBIT_COLOR="$RED"; fi
        printf "%-25s : %b%s%b\n" "RabbitMQ Status" "$RABBIT_COLOR" "$(systemctl is-active rabbitmq-server 2>/dev/null)" "$CLEAR"
        RABBIT_VER=$(rabbitmqctl version 2>/dev/null)
        printf "%-25s : %s\n" "RabbitMQ Version" "$RABBIT_VER"

        JAVA_VER=$(su - "$DEGREEWORKSUSER" -c "java -version" 2>&1 | head -n1)
        printf "%-25s : %s\n" "Java Version" "$JAVA_VER"

        CRON_COUNT=$(crontab -u "$DEGREEWORKSUSER" -l 2>/dev/null | grep -v '^#' | grep -v '^$' | wc -l)
        CRON_COLOR="$GREEN"
        [[ "$CRON_COUNT" -eq 0 ]] && CRON_COLOR="$YELLOW"
        printf "%-25s : %b%d job(s)%b\n" "Cron Jobs Count" "$CRON_COLOR" "$CRON_COUNT" "$CLEAR"

        BLOB_COLOR="$YELLOW"
        [[ "$COUNT_NON_BLOB" -eq 0 ]] && BLOB_COLOR="$GREEN"
        printf "%-25s : %bNon-BLOB: %s, BLOB: %s%b\n" "BLOB Conversion" "$BLOB_COLOR" "$COUNT_NON_BLOB" "$COUNT_BLOB" "$CLEAR"
    fi

    if [[ "$SERVER_TYPE" == "Web" || "$SERVER_TYPE" == "Hybrid" ]]; then
        HTTPD_COUNT=$(echo "$HTTPD_PROCS" | grep -v '^$' | wc -l)
        if [[ "$HTTPD_COUNT" -gt 0 ]]; then
            HTTPD_COLOR="$GREEN"; HTTPD_STATUS="Found $HTTPD_COUNT process(es)"
        else
            HTTPD_COLOR="$YELLOW"; HTTPD_STATUS="No Apache/httpd processes found"
        fi
        printf "%-25s : %b%s%b\n" "Apache/httpd Processes" "$HTTPD_COLOR" "$HTTPD_STATUS" "$CLEAR"
    fi

    echo "================================================"
}

main() {
    f_log "---------------------------------------------"
    f_log "START - checking DegreeWorks Environment ..."

    check_root
    check_args "$@"
    check_os
    check_storage
    check_dw_version
    check_dgwbase
    check_server_type

    if [[ "$SERVER_TYPE" == "Classic" || "$SERVER_TYPE" == "Hybrid" ]]; then
        check_rabbitmq_status
        check_rabbitmq_server_version
        check_rabbitmq_client_versions
        check_java_version
        check_apache_fop
        check_gcc
        check_openssl
        check_perl
        check_dw_db
        check_db_version
        list_cronjobs
        check_blob_conversion
        check_duplicate_exceptions
        check_duplicate_notes
    fi

    if [[ "$SERVER_TYPE" == "Web" || "$SERVER_TYPE" == "Hybrid" ]]; then
        list_dw_jar_files
        get_dw_jar_versions
        check_httpd_processes
        
    fi

    print_summary

    f_log "---------------------------------------------"
    f_log "END - DegreeWorks Environment check complete."
}

main "$@"

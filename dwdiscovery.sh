#!/bin/bash
#########################################################################
# Name:          dwdiscovery.sh
# Description:   Check prechecks and gather of DW variables
# Args:          degreeworksuser [--sql] [--buildall]
# Author:        G. Sandoval
# Date:          10.07.2025
# Version:       1.13
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
SKIP_SQL=false
RUN_BUILDALL=false

####### FUNCTIONS #######
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
        f_log "Usage: $0 degreeworksuser [--sql] [--buildall]" red
        exit 1
    fi

    DEGREEWORKSUSER="$1"

    for arg in "$@"; do
        case "$arg" in
            --sql) SQL_FLAG="yes" ;;
            --buildall) BUILDALL_FLAG="yes" ;;
        esac
    done

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
    DWVERSION=$(su - "$DEGREEWORKSUSER" -c 'bash -l -c "echo $DWRELEASE"' 2>/dev/null | tail -n1)
    if [[ -n "$DWVERSION" ]]; then
        f_log "DegreeWorks version: $DWVERSION" green
    else
        f_log "Could not detect DWRELEASE variable for $DEGREEWORKSUSER" red
    fi
}

check_dgwbase() {
    f_log "Checking DGWBASE variable..."
    DGWBASE=$(su - "$DEGREEWORKSUSER" -c 'bash -l -c "echo $DGWBASE"' 2>/dev/null | tail -n1)
    if [[ -n "$DGWBASE" ]]; then
        f_log "DGWBASE variable: $DGWBASE" green
    else
        f_log "DGWBASE variable is not set for user $DEGREEWORKSUSER" yellow
    fi
}

check_server_type() {
    f_log "---------------------------------------------"
    f_log "Detecting server type (Classic vs Web vs Hybrid)..."

    HTTPD_PROCS=$(ps -u "$DEGREEWORKSUSER" -f | grep -i '.jar' | grep -iE "Responsive|Dashboard|Controller|API|Transit" | grep -iv "jenkins")
    JAVA_COUNT=$(echo "$HTTPD_PROCS" | grep -vi "transitexecutor.jar" | grep -v '^$' | wc -l)

    if [[ -n "$DWVERSION" && -n "$DGWBASE" && $JAVA_COUNT -eq 0 ]]; then
        SERVER_TYPE="Classic"
    elif [[ -z "$DWVERSION" && $JAVA_COUNT -ge 2 ]]; then
        SERVER_TYPE="Web"
    elif [[ -n "$DWVERSION" && $JAVA_COUNT -ge 1 ]]; then
        SERVER_TYPE="Hybrid"
    else
        SERVER_TYPE="Unknown"
    fi
    f_log "Detected server type: $SERVER_TYPE"
}

# --- BASIC CLASSIC/HYBRID FUNCTIONS ---
check_rabbitmq_status() {
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

list_cronjobs() {
    f_log "---------------------------------------------"
    f_log "Listing cron jobs for $DEGREEWORKSUSER..."
    crontab -u "$DEGREEWORKSUSER" -l 2>/dev/null
}

check_dw_base_commands() {
    f_log "---------------------------------------------"
    f_log "Checking DW base commands as $DEGREEWORKSUSER..."

    # Only run on Classic or Hybrid servers
    if [[ "$SERVER_TYPE" != "Classic" && "$SERVER_TYPE" != "Hybrid" ]]; then
        f_log "Skipping DW base command checks for $SERVER_TYPE server" yellow
        return
    fi

    # List of DW commands to run
    DW_COMMANDS=(webshow dapshow tbeshow preqshow resshow)

    # Declare associative array to track command status
    declare -gA DW_COMMAND_STATUS

    for cmd in "${DW_COMMANDS[@]}"; do
        f_log "Running command: $cmd..."
        CMD_OUTPUT=$(su - "$DEGREEWORKSUSER" -c "$cmd" 2>&1)

        if [[ -n "$CMD_OUTPUT" ]]; then
            # Check if command not found
            if echo "$CMD_OUTPUT" | grep -qi "not found"; then
                DW_COMMAND_STATUS["$cmd"]="Not found"
                f_log "$cmd: not found" red
                continue
            fi

            # Special handling for preqshow
            if [[ "$cmd" == "preqshow" ]]; then
                # Sum all numeric values in output
                SUM=$(echo "$CMD_OUTPUT" | grep -oE '[0-9]+' | paste -sd+ - | bc)
                if [[ "$SUM" -eq 0 ]]; then
                    DW_COMMAND_STATUS["$cmd"]="Not used"
                    echo "$CMD_OUTPUT" 
                    f_log "$cmd: all queues are empty → Not used" yellow
                else
                    DW_COMMAND_STATUS["$cmd"]="Running" 
                    f_log "Output from $cmd:" green
                    echo "$CMD_OUTPUT"
                fi
            else
                DW_COMMAND_STATUS["$cmd"]="Running"
                f_log "Output from $cmd:" green
                echo "$CMD_OUTPUT"
            fi
        else
            DW_COMMAND_STATUS["$cmd"]="Not running"
            f_log "No output from $cmd" yellow
        fi
    done
}

rmqtest() {
    f_log "---------------------------------------------"
    f_log "Running rmqtest as $DEGREEWORKSUSER..."

    # Run rmqtest as dwuser
    RMQ_OUTPUT=$(su - "$DEGREEWORKSUSER" -c "rmqtest" 2>&1)
    RMQ_EXIT=$?

    # Print full output to general log
    if [[ -n "$RMQ_OUTPUT" ]]; then
        f_log "Output from rmqtest:" green
        echo "$RMQ_OUTPUT"
    else
        f_log "No output from rmqtest" yellow
    fi

    # Determine summary status
    if echo "$RMQ_OUTPUT" | grep -q "Success - reached the end"; then
        RMQTEST_STATUS="Success"
    elif echo "$RMQ_OUTPUT" | grep -qi "not found"; then
        RMQTEST_STATUS="Not found"
    else
        RMQTEST_STATUS="Failed"
    fi
}

###########################
# SQL Functions
###########################
check_dw_db() {
    f_log "---------------------------------------------"
    f_log "Checking DW database connection..."
    DB_OUTPUT=$(su - "$DEGREEWORKSUSER" -c 'jdbcverify --verbose' 2>&1)
    DB_EXIT=$?
    DB_EXIT_STATUS=$([[ $DB_EXIT -eq 0 ]] && echo "OK" || echo "Failed")
    f_log "Database connection: $DB_EXIT_STATUS" $([[ $DB_EXIT -eq 0 ]] && echo green || echo red)
    echo "$DB_OUTPUT"
}

check_db_version() {
    f_log "---------------------------------------------"
    f_log "Checking DW database version..."

    TMP_DB_FILE="/tmp/OracleDB_$$.txt"
    f_log "Running database command with nohup..."
    nohup su - "$DEGREEWORKSUSER" -c "db > $TMP_DB_FILE 2>&1" >/dev/null 2>&1 &
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
    f_log "Checking BLOB conversion..."
    SQL_NON_BLOB="select count(*) from DAP_AUDIT_DTL where DAP_CREATE_WHO!='BLOB';"
    SQL_BLOB="select count(*) from DAP_AUDIT_DTL where DAP_CREATE_WHO='BLOB';"
    COUNT_NON_BLOB=$(su - "$DEGREEWORKSUSER" -c "runsql \"$SQL_NON_BLOB\"" 2>/dev/null | grep -o '[0-9]\+')
    COUNT_BLOB=$(su - "$DEGREEWORKSUSER" -c "runsql \"$SQL_BLOB\"" 2>/dev/null | grep -o '[0-9]\+')
    f_log "Non-BLOB: $COUNT_NON_BLOB, BLOB: $COUNT_BLOB"
}

check_duplicate_exceptions() {
    SQL="select dap_stu_id, dap_exc_num, count(*) cnt from dap_except_dtl group by dap_stu_id,dap_exc_num having count(*)>1 order by 1,2;"
    OUTPUT=$(su - "$DEGREEWORKSUSER" -c "runsql \"$SQL\"" 2>/dev/null)
    DUP_EXCEPTIONS_STATUS=$(echo "$OUTPUT" | grep -v -E '^$|^runsql:' | wc -l)
    f_log "Duplicate exceptions: $DUP_EXCEPTIONS_STATUS"
}

check_duplicate_notes() {
    SQL="select dap_stu_id, dap_note_num, count(*) cnt from dap_note_dtl group by dap_stu_id,dap_note_num having count(*)>1 order by 1,2;"
    OUTPUT=$(su - "$DEGREEWORKSUSER" -c "runsql \"$SQL\"" 2>/dev/null)
    DUP_NOTES_STATUS=$(echo "$OUTPUT" | grep -v -E '^$|^runsql:' | wc -l)
    f_log "Duplicate notes: $DUP_NOTES_STATUS"
}

#Web/Hybrid functions
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

# --- BUILDALL PLACEHOLDER ---
check_build_all() {
    f_log "---------------------------------------------"
    f_log "Running BuildAll checks..." green

    BUILD_SUCCESS="Timed out"
    BUILD_FAIL="Timed out"

    if [[ "$BUILDALL_FLAG" != "yes" ]]; then
        f_log "BuildAll checks skipped (--buildall not used)" yellow
        return
    fi

    TMP_BUILD_LOG="/tmp/buildall_$$.log"

    # Run build all as DW user in background
    su - "$DEGREEWORKSUSER" -c "build all" > "$TMP_BUILD_LOG" 2>&1 &
    BUILD_PID=$!

    f_log "BuildAll process started (PID: $BUILD_PID), max timeout 5 minutes..."

    # Timeout handling (300 sec)
    SECONDS_WAITED=0
    TIMEOUT=300

    # Live output
    tail -f "$TMP_BUILD_LOG" &
    TAIL_PID=$!

    while kill -0 "$BUILD_PID" 2>/dev/null; do
        sleep 1
        ((SECONDS_WAITED++))
        if (( SECONDS_WAITED >= TIMEOUT )); then
            f_log "BuildAll exceeded 5 minutes, killing process..." red
            kill -9 "$BUILD_PID" 2>/dev/null
            BUILD_SUCCESS="Timed out"
            BUILD_FAIL="Timed out"
            break
        fi
    done

    # Stop tail
    kill "$TAIL_PID" 2>/dev/null

    # If finished normally, parse success/failure
    if [[ "$BUILD_SUCCESS" != "Timed out" ]]; then
        BUILD_SUCCESS=$(grep -E "Success count" "$TMP_BUILD_LOG" | awk -F= '{gsub(/ /,"",$2); print $2}' | tail -n1)
        BUILD_FAIL=$(grep -E "Failure count" "$TMP_BUILD_LOG" | awk -F= '{gsub(/ /,"",$2); print $2}' | tail -n1)
        f_log "BuildAll finished. Success: $BUILD_SUCCESS, Failure: $BUILD_FAIL" green
    else
        f_log "BuildAll did not complete successfully (Timed out)" red
    fi

    # Clean up
    rm -f "$TMP_BUILD_LOG"
}


###########################
# Summary Function
###########################
print_summary() {
    echo -e "\n==================== SUMMARY ===================="

    printf "%-25s : %s\n" "Server Type" "$SERVER_TYPE"
    printf "%-25s : %s\n" "DegreeWorks Version" "${DWVERSION:-Not set}"
    printf "%-25s : %s\n" "DGWBASE" "${DGWBASE:-Not set}"

    if [[ "$SERVER_TYPE" == "Classic" || "$SERVER_TYPE" == "Hybrid" ]]; then
        printf "%-25s : %s\n" "RabbitMQ Status" "$(systemctl is-active rabbitmq-server 2>/dev/null)"
        printf "%-25s : %s\n" "Java Version" "$(su - "$DEGREEWORKSUSER" -c "java -version" 2>&1 | head -n1)"

        printf "%-25s : %s\n" "DW Base Commands" ""
        for cmd in "${!DW_COMMAND_STATUS[@]}"; do
            printf "  %-23s : %s\n" "$cmd" "${DW_COMMAND_STATUS[$cmd]}"
        done

        printf "%-25s : %s\n" "RMQ Test" "$RMQTEST_STATUS"

        # --- SQL Results Only if --sql is used ---
        if [[ "$SQL_FLAG" == "yes" ]]; then
            printf "%-25s : %s\n" "DW DB Connection" "${DB_EXIT_STATUS:-Not checked}"
            printf "%-25s : %s\n" "DW DB Version" "${DB_VERSION:-None}"
            printf "%-25s : %s\n" "BLOB Count NonBlob" "${COUNT_NON_BLOB:-0}" 
            printf "%-25s : %s\n" "BLOB Count Blob" "${COUNT_BLOB:-0}"
            printf "%-25s : %s\n" "Duplicate Exceptions" "${DUP_EXCEPTIONS_STATUS:-None}"
            printf "%-25s : %s\n" "Duplicate Notes" "${DUP_NOTES_STATUS:-None}"
        fi

        # --- BuildAll Only if --buildall is used ---
        if [[ "$BUILDALL_FLAG" == "yes" ]]; then
            if [[ "$BUILD_SUCCESS" == "Timed out" ]]; then
                printf "%-25s : %s\n" "BuildAll" "Timed out"
            else
                printf "%-25s : Success: %s Failure: %s\n" "BuildAll" "$BUILD_SUCCESS" "$BUILD_FAIL"
            fi
        fi
    fi

    # --- Web Server Info ---
    if [[ "$SERVER_TYPE" == "Web" || "$SERVER_TYPE" == "Hybrid" ]]; then
        # Apache presence
        if [[ -n "$HTTPD_PROCS" ]]; then
            printf "%-25s : %s\n" "Apache" "Yes"
        else
            printf "%-25s : %s\n" "Apache" "No"
        fi

        # DW Jars with versions
        if [[ -n "$DW_JARS" ]]; then
            printf "%-25s :\n" "DW Jar"
            for jar in $(echo "$DW_JARS" | awk '{for(i=8;i<=NF;i++) print $i}'); do
                if [[ -f "$jar" ]]; then
                    JAR_VER=$(unzip -p "$jar" META-INF/MANIFEST.MF 2>/dev/null | grep -i "Implementation-Version" | head -n1 | awk -F: '{gsub(/ /,"",$2); print $2}')
                    printf "  %-23s : %s\n" "$(basename "$jar")" "${JAR_VER:-Not found}"
                fi
            done
        else
            printf "%-25s : %s\n" "DW Jar" "None found"
        fi
    fi

    echo "=================================================="
}

# ---------------- MAIN ----------------
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
# Basic checks
check_rabbitmq_status
check_rabbitmq_server_version
check_rabbitmq_client_versions
check_java_version
check_apache_fop
check_gcc
check_openssl
check_perl
list_cronjobs
check_dw_base_commands
rmqtest

# SQL checks if flag enabled
if [[ "$SQL_FLAG" == "yes"  ]]; then
    check_dw_db
    check_db_version
    check_blob_conversion
    check_duplicate_exceptions
    check_duplicate_notes
else
            f_log "SQL checks were skipped (--sql)" yellow
        fi



if [[ "$BUILDALL_FLAG" == "yes" ]]; then
   check_build_all
else
          f_log "BUILD checks were skipped (--buildall)" yellow
fi

fi


if [[ "$SERVER_TYPE" == "Web" || "$SERVER_TYPE" == "Hybrid" ]]; then
        list_dw_jar_files
        get_dw_jar_versions
        check_httpd_processes
fi


# Summary
print_summary

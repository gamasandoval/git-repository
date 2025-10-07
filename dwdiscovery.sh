#!/bin/bash
#########################################################################
# Name:          dwdiscovery.sh
# Description:   Check prechecks and gather DW variables
# Args:          degreeworksuser
# Author:        G. Sandoval
# Date:          10.07.2025
# Version:       1.9
#########################################################################

####### VARIABLES SECTION #######
APP="DegreeWorks"
THRESHOLD=80   # % usage threshold for warnings

# Colors
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
CLEAR="\e[0m"

# Server type
SERVER_TYPE="Unknown"

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

# Check root user
check_root() {
    if [[ $EUID -ne 0 ]]; then
        f_log "This script must be run as root. Current user: $(whoami)" red
        exit 1
    else
        f_log "Running as root user: $(whoami)" green
    fi
}

# Validate arguments
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

# OS Info
check_os() {
    f_log "Gathering OS information..."
    f_log "Hostname: $(hostname)"
    f_log "OS: $(grep '^PRETTY_NAME' /etc/os-release | cut -d= -f2- | tr -d '\"')"
    f_log "Kernel: $(uname -r)"
    f_log "Architecture: $(uname -m)"
    f_log "Uptime: $(uptime -p)"
}

# Filesystem Info
check_filesystems() {
    f_log "Gathering filesystem information..."
    df -hT | while read -r fs type size used avail pcent mount; do
        if [[ "$fs" == "Filesystem" ]]; then continue; fi
    done
}

# Filesystem usage
check_fs_usage() {
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

# Wrapper: storage checks
check_storage() {
    check_filesystems
    check_fs_usage
}

###############################################
# DEGREEWORKS CHECKS
###############################################

check_dw_version() {
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

# Detect server type
check_server_type() {
    f_log "Detecting server type (Classic vs Web vs Hybrid)..."
    f_log "DWVERSION='$DWVERSION'"
    f_log "DGWBASE='$DGWBASE'"

    # Count relevant Java jar processes for DW
    JAVA_PROCS=$(ps -u "$DEGREEWORKSUSER" -o comm,args | grep -iE 'Responsive|Dashboard|Controller|API|Transit' | grep -vi 'jenkins' | grep '\.jar' | grep -vi 'transitexecutor.jar' | wc -l)
    f_log "Relevant Java jar processes count: $JAVA_PROCS"

    if [[ -n "$DWVERSION" && -n "$DGWBASE" && $JAVA_PROCS -ge 1 ]]; then
        SERVER_TYPE="Hybrid"
        f_log "Decision: DW variables + Java jars → Hybrid server" green
    elif [[ -n "$DWVERSION" && -n "$DGWBASE" ]]; then
        SERVER_TYPE="Classic"
        f_log "Decision: DW variables exist → Classic server" green
    elif [[ $JAVA_PROCS -ge 2 ]]; then
        SERVER_TYPE="Web"
        f_log "Decision: Java jar processes found → Web server" yellow
    else
        SERVER_TYPE="Unknown"
        f_log "Server type could not be determined → Unknown" red
    fi
}

# Check RabbitMQ
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
        f_log "RabbitMQ server version: ${RABBIT_VERSION:-Unknown}" green
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
    JAVA_VER=$(su - "$DEGREEWORKSUSER" -c "java -version" 2>&1 | head -n1)
    f_log "Java version detected: ${JAVA_VER:-Not installed}" green
}

check_apache_fop() {
    f_log "Checking Apache FOP..."
    FOP_PATH=$(su - "$DEGREEWORKSUSER" -c 'which fop' 2>/dev/null)
    f_log "Apache FOP path: ${FOP_PATH:-Not found}" green
}

check_gcc() {
    f_log "Checking GCC version..."
    if command -v gcc &>/dev/null; then
        GCC_VER=$(gcc -v 2>&1 | grep "gcc version" | head -n 1)
        f_log "GCC version detected: ${GCC_VER:-Unknown}" green
    else
        f_log "GCC not installed" red
    fi
}

check_openssl() {
    f_log "Checking OpenSSL version..."
    OPENSSL_VER=$(openssl version 2>/dev/null)
    f_log "OpenSSL version detected: ${OPENSSL_VER:-Unknown}" green
}

check_perl() {
    f_log "Checking Perl version..."
    PERL_VER=$(perl -e 'printf "%vd\n", $^V' 2>/dev/null)
    f_log "Perl version detected: ${PERL_VER:-Unknown}" green
}

check_dw_db() {
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

check_blob_conversion() {
    f_log "Checking BLOB conversion requirement..."
    SQL_NON_BLOB="select count(*) from DAP_AUDIT_DTL where DAP_CREATE_WHO!='BLOB';"
    SQL_BLOB="select count(*) from DAP_AUDIT_DTL where DAP_CREATE_WHO='BLOB';"
    NON_BLOB_OUTPUT=$(su - "$DEGREEWORKSUSER" -c "runsql \"$SQL_NON_BLOB\"" 2>&1)
    COUNT_NON_BLOB=$(echo "$NON_BLOB_OUTPUT" | grep -v -E '^$|^runsql:|^-ksh:' | head -n1)
    BLOB_OUTPUT=$(su - "$DEGREEWORKSUSER" -c "runsql \"$SQL_BLOB\"" 2>&1)
    COUNT_BLOB=$(echo "$BLOB_OUTPUT" | grep -v -E '^$|^runsql:|^-ksh:' | head -n1)
    f_log "Non-BLOB count: $COUNT_NON_BLOB, BLOB count: $COUNT_BLOB" green
}

check_duplicate_exceptions() {
    f_log "Checking duplicate exceptions..."
    SQL_QUERY="select dap_stu_id, dap_exc_num, count(*) cnt from dap_except_dtl group by dap_stu_id, dap_exc_num having count(*) > 1 order by 1,2;"
    SQL_OUTPUT=$(su - "$DEGREEWORKSUSER" -c "runsql \"$SQL_QUERY\"" 2>&1)
    ROW_COUNT=$(echo "$SQL_OUTPUT" | grep -v -E '^$|^runsql:|^-ksh:' | wc -l)
    if [[ $ROW_COUNT -gt 0 ]]; then
        f_log "Found $ROW_COUNT duplicate exception(s)" red
    else
        f_log "No duplicate exceptions found" green
    fi
}

check_duplicate_notes() {
    f_log "Checking duplicate notes..."
    SQL_QUERY="select dap_stu_id, dap_note_num, count(*) cnt from dap_note_dtl group by dap_stu_id, dap_note_num having count(*) > 1 order by 1,2;"
    SQL_OUTPUT=$(su - "$DEGREEWORKSUSER" -c "runsql \"$SQL_QUERY\"" 2>&1)
    ROW_COUNT=$(echo "$SQL_OUTPUT" | grep -v -E '^$|^runsql:|^-ksh:' | wc -l)
    if [[ $ROW_COUNT -gt 0 ]]; then
        f_log "Found $ROW_COUNT duplicate note(s)" red
    else
        f_log "No duplicate notes found" green
    fi
}

# List Java processes
list_java_processes() {
    f_log "Listing Java processes for DW..."
    ps -u "$DEGREEWORKSUSER" -f | grep -i '.jar' | grep -v grep
}

# List cron jobs for DW user
check_dw_cronjobs() {
    f_log "Listing cron jobs for $DEGREEWORKSUSER..."
    CRON_OUTPUT=$(crontab -u "$DEGREEWORKSUSER" -l 2>/dev/null)
    if [[ -n "$CRON_OUTPUT" ]]; then
        f_log "Cron jobs for $DEGREEWORKSUSER:" green
        echo "$CRON_OUTPUT"
    else
        f_log "No cron jobs found for $DEGREEWORKSUSER" yellow
    fi
}


# Check HTTPD/Apache for Web/Hybrid
check_httpd_process() {
    if [[ "$SERVER_TYPE" != "Web" && "$SERVER_TYPE" != "Hybrid" ]]; then
        f_log "Skipping Apache/httpd check — not a Web or Hybrid server." yellow
        return
    fi
    f_log "Checking for Apache/httpd processes..."
    ps aux | grep -iE 'httpd|apache' | grep -v grep || f_log "No httpd/apache processes found" green
}

###############################################
# MAIN EXECUTION
###############################################
main() {
    f_log "---------------------------------------------"
    f_log "START - checking DegreeWorks Environment ..."

    check_root
    check_args "$@"
    check_os
    check_storage

    # DW Checks
    check_dw_version
    check_dgwbase
    check_server_type

    case "$SERVER_TYPE" in
        Classic)
            check_rabbitmq_status
            check_rabbitmq_server_version
            check_rabbitmq_client_versions
            check_java_version
            check_apache_fop
            check_gcc
            check_openssl
            check_perl
            check_dw_db
            check_dw_cronjobs
            check_blob_conversion
            check_duplicate_exceptions
            check_duplicate_notes
            ;;
        Web)
            list_java_processes
            check_httpd_process
            ;;
        Hybrid)
            check_rabbitmq_status
            check_rabbitmq_server_version
            check_rabbitmq_client_versions
            check_java_version
            check_apache_fop
            check_gcc
            check_openssl
            check_perl
            check_dw_db
            check_dw_cronjobs
            check_blob_conversion
            check_duplicate_exceptions
            check_duplicate_notes
            list_java_processes
            check_httpd_process
            ;;
        *)
            f_log "Unknown server type. Exiting..." red
            exit 1
            ;;
    esac

    f_log "---------------------------------------------"
    f_log "END - DegreeWorks Environment check complete."
}

# Run main
main "$@"

#!/bin/bash
#########################################################################
# Name:          dwdiscovery.sh
# Description:   Check prechecks and gather of DW variables
# Args:          degreeworksuser
# Author:        G. Sandoval
# Date:          10.01.2025
# Version:       1.7
#########################################################################

####### VARIABLES SECTION #######
APP="DegreeWorks"
THRESHOLD=80   # % usage threshold for warnings

# Colors
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
CLEAR="\e[0m"

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

# Check if running as root
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
    if [[ $# -ne 1 ]]; then
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

# OS Information
check_os() {
    f_log "Gathering OS information..."
    f_log "Hostname: $(hostname)"
    f_log "OS: $(grep '^PRETTY_NAME' /etc/os-release | cut -d= -f2- | tr -d '\"')"
    f_log "Kernel: $(uname -r)"
    f_log "Architecture: $(uname -m)"
    f_log "Uptime: $(uptime -p)"
}

# Filesystem Type Information (local vs shared)
check_filesystems() {
    f_log "Gathering filesystem information..."
    df -hT | while read -r fs type size used avail pcent mount; do
        # Skip header
        if [[ "$fs" == "Filesystem" ]]; then
            continue
        fi

        #case "$type" in
        #    nfs|cifs|glusterfs|lustre)
        #        f_log "Shared filesystem: $fs mounted on $mount (type: $type, total: $size, used: $used, avail: $avail)" red
        #        ;;
        #    *)
        #        f_log "Local filesystem: $fs mounted on $mount (type: $type, total: $size, used: $used, avail: $avail)" green
        #        ;;
        #esac
    done
}

# Filesystem Usage (threshold check)
check_fs_usage() {
    f_log "Checking filesystem usage..."
    local threshold=80

    df -h --output=source,pcent,size,used,avail,target | tail -n +2 | while read -r fs pcent size used avail mount; do
        usage=${pcent%%%}  # strip the % sign
        if (( usage > threshold )); then
            f_log "WARNING: $fs mounted on $mount is ${pcent} used (total: $size, used: $used, avail: $avail)" red
        else
            f_log "$fs mounted on $mount is healthy (${pcent} used, total: $size, used: $used, avail: $avail)" green
        fi
    done
}


# Wrapper: Run all storage-related checks
check_storage() {
    check_filesystems
    check_fs_usage
}

###############################################
# DEGREEWORKS-SPECIFIC CHECKS
###############################################

# Check DegreeWorks version via $DWRELEASE
check_dw_version() {
    f_log "Checking DegreeWorks version..."
    DWVERSION=$(su - "$DEGREEWORKSUSER" -c 'echo $DWRELEASE' 2>/dev/null)

    if [[ -n "$DWVERSION" ]]; then
        f_log "DegreeWorks version: $DWVERSION" green
    else
        f_log "Could not detect DWRELEASE variable for $DEGREEWORKSUSER" red
    fi
}

# Check DGWBASE variable
check_dgwbase() {
    f_log "Checking DGWBASE variable..."
    
    DGWBASE_VAL=$(su - "$DEGREEWORKSUSER" -c 'echo $DGWBASE' 2>/dev/null)
    
    if [[ -n "$DGWBASE_VAL" ]]; then
        f_log "DGWBASE variable: $DGWBASE_VAL" green
    else
        f_log "DGWBASE variable is not set for user $DEGREEWORKSUSER" yellow
    fi
}

# Check if RabbitMQ service is running

check_rabbitmq_status() {
    f_log "Checking RabbitMQ service status..."
    if systemctl is-active --quiet rabbitmq-server; then
        f_log "RabbitMQ service is running" green
    else
        f_log "RabbitMQ service is NOT running" red
    fi
}

# Get RabbitMQ server version
check_rabbitmq_server_version() {
    f_log "Getting RabbitMQ server version..."
    if command -v rabbitmqctl &>/dev/null; then
        RABBIT_VERSION=$(rabbitmqctl version 2>/dev/null)
        if [[ -n "$RABBIT_VERSION" ]]; then
            f_log "RabbitMQ server version: $RABBIT_VERSION" green
        else
            f_log "Could not detect RabbitMQ server version" red
        fi
    else
        f_log "rabbitmqctl command not found" red
    fi
}

# List RabbitMQ client versions installed under /opt
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

# Check Java version
check_java_version() {
    f_log "Checking Java version as $DEGREEWORKSUSER..."

    # Run java -version as DW user
    JAVA_VER=$(su - "$DEGREEWORKSUSER" -c "java -version" 2>&1 | head -n 1)

    if [[ -n "$JAVA_VER" ]]; then
        f_log "Java version detected: $JAVA_VER" green
    else
        f_log "Java is not installed or not in PATH for $DEGREEWORKSUSER" red
    fi
}

# Check Apache FOP installation and version
check_apache_fop() {
    f_log "Checking Apache FOP..."
    FOP_PATH=$(su - "$DEGREEWORKSUSER" -c 'which fop' 2>/dev/null)

    if [[ -n "$FOP_PATH" ]]; then
        f_log "Apache FOP found: $FOP_PATH" green
    else
        f_log "Apache FOP not found for user $DEGREEWORKSUSER" red
    fi
}

# Check GCC version
check_gcc() {
    f_log "Checking GCC version..."
    if command -v gcc &>/dev/null; then
        GCC_VER=$(gcc -v 2>&1 | grep "gcc version" | head -n 1)
        if [[ -n "$GCC_VER" ]]; then
            f_log "GCC version detected: $GCC_VER" green
        else
            f_log "Could not detect GCC version" red
        fi
    else
        f_log "GCC is not installed or not in PATH" red
    fi
}

# Check OpenSSL version
check_openssl() {
    f_log "Checking OpenSSL version..."
    if command -v openssl &>/dev/null; then
        OPENSSL_VER=$(openssl version 2>/dev/null)
        if [[ -n "$OPENSSL_VER" ]]; then
            f_log "OpenSSL version detected: $OPENSSL_VER" green
        else
            f_log "Could not detect OpenSSL version" red
        fi
    else
        f_log "OpenSSL is not installed or not in PATH" red
    fi
}

# Check Perl version
check_perl() {
    f_log "Checking Perl version..."
    if command -v perl &>/dev/null; then
        # Option 1: simple version
        PERL_VER=$(perl -e 'printf "%vd\n", $^V' 2>/dev/null)
        
        if [[ -n "$PERL_VER" ]]; then
            f_log "Perl version detected: $PERL_VER" green
        else
            f_log "Could not detect Perl version" red
        fi
    else
        f_log "Perl is not installed or not in PATH" red
    fi
}

# Check DW database connection with jdbcverify
check_dw_db() {
    f_log "Checking DW database connection with jdbcverify..."
    
    DB_OUTPUT=$(su - "$DEGREEWORKSUSER" -c 'jdbcverify --verbose' 2>&1)
    DB_EXIT=$?

    if [[ $DB_EXIT -eq 0 ]]; then
        f_log "Database connection is OK. Output:" green
        echo "$DB_OUTPUT"
    else
        f_log "Database connection failed. Output:" red
        echo "$DB_OUTPUT"
        f_log "DW database connection is not good" red
    fi
}

# Check BLOB conversion requirement
check_blob_conversion() {
    f_log "Checking BLOB conversion requirement..."

    if [[ -z "$DWVERSION" ]]; then
        f_log "DWVERSION is not set. Skipping BLOB conversion check." red
        return
    fi

    # Single-line SQL queries
    SQL_NON_BLOB="select count(*) from DAP_AUDIT_DTL where DAP_CREATE_WHO!='BLOB';"
    SQL_BLOB="select count(*) from DAP_AUDIT_DTL where DAP_CREATE_WHO='BLOB';"

    # Print DW_AUDIT_BLOB variable
    f_log "DW_AUDIT_BLOB: $DW_AUDIT_BLOB"

    # Run NON-BLOB query
    NON_BLOB_OUTPUT=$(su - "$DEGREEWORKSUSER" -c "runsql \"$SQL_NON_BLOB\"" 2>&1)
    if echo "$NON_BLOB_OUTPUT" | grep -q "Cannot open select"; then
        f_log "Could not run SQL automatically. Please run manually as $DEGREEWORKSUSER:" red
        f_log "$SQL_NON_BLOB" red
        return
    fi
    COUNT_NON_BLOB=$(echo "$NON_BLOB_OUTPUT" | grep -v -E '^$|^runsql:|^-ksh:' | head -n 1)

    # Run BLOB query
    BLOB_OUTPUT=$(su - "$DEGREEWORKSUSER" -c "runsql \"$SQL_BLOB\"" 2>&1)
    if echo "$BLOB_OUTPUT" | grep -q "Cannot open select"; then
        f_log "Could not run SQL automatically. Please run manually as $DEGREEWORKSUSER:" red
        f_log "$SQL_BLOB" red
        return
    fi
    COUNT_BLOB=$(echo "$BLOB_OUTPUT" | grep -v -E '^$|^runsql:|^-ksh:' | head -n 1)

    # Print results with version logic
    if [[ "$(printf '%s\n' "$DWVERSION" "5.1.5" | sort -V | head -n1)" == "$DWVERSION" ]]; then
        f_log "Count of non-BLOB records: $COUNT_NON_BLOB → BLOB conversion is suggested" yellow
    else
        f_log "Count of non-BLOB records: $COUNT_NON_BLOB → BLOB conversion is mandatory" red
    fi

    f_log "Count of BLOB records: $COUNT_BLOB" green
}


# Check DAP_EXCEPT_DTL duplicates
check_duplicate_exceptions() {
    f_log "Checking for duplicate exceptions in DAP_EXCEPT_DTL..."

    if [[ -z "$DWVERSION" ]]; then
        f_log "DWVERSION is not set. Cannot apply version-specific duplicate exception check." yellow
    fi

    # Single-line SQL
    SQL_QUERY="select dap_stu_id, dap_exc_num, count(*) cnt from dap_except_dtl group by dap_stu_id, dap_exc_num having count(*) > 1 order by 1, 2;"

    # Run SQL as DW user
    SQL_OUTPUT=$(su - "$DEGREEWORKSUSER" -c "runsql \"$SQL_QUERY\"" 2>&1)

    # Check for runsql failure
    if echo "$SQL_OUTPUT" | grep -q "Cannot open select"; then
        f_log "Could not run SQL automatically. Please run the following SQL manually as $DEGREEWORKSUSER:" red
        f_log "$SQL_QUERY" red
        return
    fi

    # Print SQL output for debugging
    f_log "SQL output:\n$SQL_OUTPUT"

    # Count only valid rows
    ROW_COUNT=$(echo "$SQL_OUTPUT" | grep -v -E '^$|^runsql:|^-ksh:' | wc -l)

    if [[ $ROW_COUNT -gt 0 ]]; then
        if [[ "$(printf '%s\n' "$DWVERSION" "5.1.4" | sort -V | head -n1)" == "$DWVERSION" ]]; then
            f_log "Found $ROW_COUNT duplicate exception(s). Duplicates must be manually resolved before continuing with the update check with AL!" red
        else
            f_log "Found $ROW_COUNT duplicate exception(s) in DAP_EXCEPT_DTL." red
            f_log "Please review dap_except_dtl for details." red
        fi
    else
        f_log "No duplicate exceptions found in DAP_EXCEPT_DTL." green
    fi
}


# Check DAP_NOTE_DTL duplicates
check_duplicate_notes() {
    f_log "Checking for duplicate notes in DAP_NOTE_DTL..."

    if [[ -z "$DWVERSION" ]]; then
        f_log "DWVERSION is not set. Cannot apply version-specific duplicate note check." yellow
    fi

    # Single-line SQL
    SQL_QUERY="select dap_stu_id, dap_note_num, count(*) cnt from dap_note_dtl group by dap_stu_id, dap_note_num having count(*) > 1 order by 1, 2;"

    # Run SQL as DW user
    SQL_OUTPUT=$(su - "$DEGREEWORKSUSER" -c "runsql \"$SQL_QUERY\"" 2>&1)

    # Check for runsql failure
    if echo "$SQL_OUTPUT" | grep -q "Cannot open select"; then
        f_log "Could not run SQL automatically. Please run the following SQL manually as $DEGREEWORKSUSER:" red
        f_log "$SQL_QUERY" red
        return
    fi

    # Print SQL output for debugging
    f_log "SQL output:\n$SQL_OUTPUT"

    # Count only valid rows
    ROW_COUNT=$(echo "$SQL_OUTPUT" | grep -v -E '^$|^runsql:|^-ksh:' | wc -l)

    if [[ $ROW_COUNT -gt 0 ]]; then
        if [[ "$(printf '%s\n' "$DWVERSION" "5.1.4" | sort -V | head -n1)" == "$DWVERSION" ]]; then
            f_log "Found $ROW_COUNT duplicate note(s). Duplicates must be manually resolved before continuing with the update check with AL!" red
        else
            f_log "Found $ROW_COUNT duplicate note(s) in DAP_NOTE_DTL." red
            f_log "Please review dap_note_dtl for details." red
        fi
    else
        f_log "No duplicate notes found in DAP_NOTE_DTL." green
    fi
}



####### MAIN PROGRAM #######
f_log "---------------------------------------------"
f_log "START - checking $APP Environment ..." green

# Comment out the ones you don’t want
check_root
check_args "$@"
check_os
check_storage
check_dw_version
check_dgwbase
check_rabbitmq_status
check_rabbitmq_server_version
check_rabbitmq_client_versions
check_java_version
check_apache_fop
check_gcc
check_openssl
check_perl
check_dw_db
check_blob_conversion
check_duplicate_exceptions
check_duplicate_notes

f_log "---------------------------------------------"
f_log "Discovery completed for $APP." green

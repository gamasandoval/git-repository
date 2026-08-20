#!/bin/bash
#
# tomcat-upgrade.sh
#
# Generic Apache Tomcat minor/patch upgrade utility.
#
# Supported service types:
#
#   SERVICE_TYPE="systemd"
#   SERVICE_TYPE="service"
#
# Supported actions:
#
#   --check
#   --dryrun
#   --upgrade
#
# Application configuration:
#
#   /u01/app/tomcat/upgrade-config/<app>.conf
#
# Examples:
#
#   ./tomcat-upgrade.sh --app brim --check
#   ./tomcat-upgrade.sh --app bep --dryrun
#   ./tomcat-upgrade.sh --app wf --upgrade
#
# Important requirements:
#
#   - Application config file must exist.
#   - Tomcat must be running before check/dryrun/upgrade.
#   - Health URL must be healthy before upgrade.
#   - CATALINA_HOME and CATALINA_BASE must be separate.
#   - CATALINA_HOME must use the managed TOMCAT_LINK.
#   - Only upgrades within the same Tomcat branch are allowed.
#
# TOMCAT_LINK:
#
#   If explicitly configured:
#
#       TOMCAT_LINK="/u01/app/tomcat/latest"
#
#   that exact symlink is used.
#
#   If not configured:
#
#       Tomcat 9  -> ${TOMCAT_ROOT}/latest9
#       Tomcat 10 -> ${TOMCAT_ROOT}/latest10
#       Tomcat 11 -> ${TOMCAT_ROOT}/latest11
#
# Shared links:
#
#   Default:
#
#       ALLOW_SHARED_LINK="false"
#
#   If the managed link is referenced by multiple services,
#   the upgrade is blocked.
#
#   To explicitly allow a shared link:
#
#       ALLOW_SHARED_LINK="true"
#
#   WARNING:
#   Every service using that symlink will use the new Tomcat
#   version the next time that service starts.
#
# Supported upgrade examples:
#
#   9.0.x  -> 9.0.x   ALLOWED
#   10.1.x -> 10.1.x  ALLOWED
#
# Unsupported examples:
#
#   9.x    -> 10.x    BLOCKED
#   10.0.x -> 10.1.x  BLOCKED
#

set -Eeuo pipefail


# ============================================================
# GLOBAL CONFIGURATION
# ============================================================

CONFIG_DIR="/u01/app/tomcat/upgrade-config"

APACHE_BASE_URL="https://downloads.apache.org/tomcat"

WORK_ROOT="/tmp"

CURL_TIMEOUT=60
START_TIMEOUT=60

FAIL_ON_LOG_ERRORS="false"

#
# Safe default. An application .conf may explicitly override this.
#
ALLOW_SHARED_LINK="false"


# ============================================================
# COMMAND-LINE VARIABLES
# ============================================================

APP=""
ACTION=""


# ============================================================
# APPLICATION CONFIGURATION
# ============================================================

SERVICE_TYPE=""
SERVICE_NAME=""

TOMCAT_ROOT=""
TOMCAT_LINK=""
BACKUP_ROOT=""

CATALINA_HOME=""
CATALINA_BASE=""

HEALTH_URL=""
STARTUP_DELAY=""


# ============================================================
# RUNTIME VARIABLES
# ============================================================

CONFIGURED_HOME=""
CONFIGURED_BASE=""

REAL_HOME=""
REAL_BASE=""

CURRENT_VERSION=""
CURRENT_VERSION_COMPARE=""
CURRENT_MAJOR=""
CURRENT_BRANCH=""

LATEST_VERSION=""

TOMCAT_LINK_TARGET=""

NEW_HOME=""

SERVICE_USER=""
SERVICE_GROUP=""

JAVA_BIN=""
JAVA_HOME=""

RUNNING_PID=""
PROCESS_HOME=""
PROCESS_BASE=""

BACKUP_DIR=""
WORK_DIR=""

JULI_PRESENT="false"
JULI_BACKUP=""
JULI_MODE=""

WARNINGS=0
ERRORS=0


# ============================================================
# OUTPUT FUNCTIONS
# ============================================================

info()
{
    echo "[INFO] $*"
}


warn()
{
    echo "[WARN] $*"
    WARNINGS=$((WARNINGS + 1))
}


error()
{
    echo "[ERROR] $*" >&2
    ERRORS=$((ERRORS + 1))
}


die()
{
    echo "[ERROR] $*" >&2
    exit 1
}


line()
{
    printf '%*s\n' 72 '' | tr ' ' '='
}


# ============================================================
# APPLICATION VALIDATION
# ============================================================

validate_application()
{
    local config_file

    #
    # Allow only safe filename characters.
    #
    if [[ ! "${APP}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        die "Invalid application name: ${APP}"
    fi

    config_file="${CONFIG_DIR}/${APP}.conf"

    [[ -f "${config_file}" ]] || \
        die "Application configuration not found: ${config_file}"
}


# ============================================================
# APPLICATION CONFIGURATION
# ============================================================

load_application_config()
{
    local config_file

    config_file="${CONFIG_DIR}/${APP}.conf"

    info "Loading application configuration:"
    info "${config_file}"

    # shellcheck disable=SC1090
    source "${config_file}"

    [[ -n "${SERVICE_TYPE}" ]] || \
        die "SERVICE_TYPE is not defined in ${config_file}"

    [[ -n "${SERVICE_NAME}" ]] || \
        die "SERVICE_NAME is not defined in ${config_file}"

    [[ -n "${TOMCAT_ROOT}" ]] || \
        die "TOMCAT_ROOT is not defined in ${config_file}"

    [[ -n "${CATALINA_BASE}" ]] || \
        die "CATALINA_BASE is not defined in ${config_file}"

    [[ -n "${HEALTH_URL}" ]] || \
        die "HEALTH_URL is not defined in ${config_file}"

    [[ -d "${TOMCAT_ROOT}" ]] || \
        die "TOMCAT_ROOT does not exist: ${TOMCAT_ROOT}"

    BACKUP_ROOT="${TOMCAT_ROOT}/upgrade-backups"

    #
    # Application-specific defaults.
    #
    STARTUP_DELAY="${STARTUP_DELAY:-10}"
    ALLOW_SHARED_LINK="${ALLOW_SHARED_LINK:-false}"

    if [[ ! "${STARTUP_DELAY}" =~ ^[0-9]+$ ]]; then
        die "STARTUP_DELAY must be a non-negative integer."
    fi

    case "${ALLOW_SHARED_LINK}" in
        true|false)
            ;;
        *)
            die "ALLOW_SHARED_LINK must be true or false."
            ;;
    esac

    case "${SERVICE_TYPE}" in

        systemd)
            ;;

        service)

            [[ -n "${CATALINA_HOME}" ]] || \
                die "CATALINA_HOME is required when SERVICE_TYPE=service"
            ;;

        *)

            die "Invalid SERVICE_TYPE: ${SERVICE_TYPE}. Supported values: systemd, service"
            ;;
    esac
}


# ============================================================
# REQUIREMENTS
# ============================================================

require_command()
{
    command -v "$1" >/dev/null 2>&1 || \
        die "Required command not found: $1"
}


check_requirements()
{
    require_command curl
    require_command awk
    require_command grep
    require_command sed
    require_command sort
    require_command readlink
    require_command sha512sum
    require_command tar
    require_command install
    require_command stat
    require_command tr
    require_command cut
    require_command head
    require_command tail
    require_command wc
    require_command cp
    require_command ln
    require_command pgrep
    require_command ps
    require_command id
    require_command sleep

    case "${SERVICE_TYPE}" in

        systemd)
            require_command systemctl
            require_command journalctl
            ;;

        service)

            [[ -x "/usr/sbin/service" ]] || \
                die "/usr/sbin/service was not found or is not executable."
            ;;

    esac

    [[ -d "${TOMCAT_ROOT}" ]] || \
        die "Tomcat root directory does not exist: ${TOMCAT_ROOT}"

    [[ -d "${CATALINA_BASE}" ]] || \
        die "CATALINA_BASE does not exist: ${CATALINA_BASE}"
}


require_root()
{
    if [[ "$(id -u)" -ne 0 ]]; then
        die "--upgrade must be executed as root."
    fi
}


# ============================================================
# SERVICE ABSTRACTION
# ============================================================

service_start()
{
    case "${SERVICE_TYPE}" in

        systemd)
            systemctl start "${SERVICE_NAME}"
            ;;

        service)
            /usr/sbin/service "${SERVICE_NAME}" start
            ;;

        *)
            die "Unsupported SERVICE_TYPE: ${SERVICE_TYPE}"
            ;;
    esac
}


service_stop()
{
    case "${SERVICE_TYPE}" in

        systemd)
            systemctl stop "${SERVICE_NAME}"
            ;;

        service)
            /usr/sbin/service "${SERVICE_NAME}" stop
            ;;

        *)
            die "Unsupported SERVICE_TYPE: ${SERVICE_TYPE}"
            ;;
    esac
}


service_is_active()
{
    case "${SERVICE_TYPE}" in

        systemd)

            systemctl is-active --quiet "${SERVICE_NAME}"
            ;;

        service)

            /usr/sbin/service "${SERVICE_NAME}" status \
                >/dev/null 2>&1
            ;;

        *)

            return 1
            ;;
    esac
}


get_service_pid()
{
    case "${SERVICE_TYPE}" in

        systemd)

            systemctl show \
                "${SERVICE_NAME}" \
                -p MainPID \
                --value 2>/dev/null
            ;;

        service)

            pgrep -f "\-Dcatalina.base=${CATALINA_BASE}" \
                | head -1 || true
            ;;

    esac
}


# ============================================================
# SYSTEMD HELPERS
# ============================================================

get_systemd_property()
{
    local property="$1"

    systemctl show \
        "${SERVICE_NAME}" \
        -p "${property}" \
        --value 2>/dev/null
}


get_systemd_environment_value()
{
    local variable="$1"
    local environment

    environment="$(
        systemctl show \
            "${SERVICE_NAME}" \
            -p Environment \
            --value 2>/dev/null
    )"

    printf '%s\n' "${environment}" \
        | tr ' ' '\n' \
        | sed 's/^"//;s/"$//' \
        | grep "^${variable}=" \
        | head -1 \
        | cut -d= -f2-
}


# ============================================================
# SERVICE VALIDATION
# ============================================================

validate_service()
{
    case "${SERVICE_TYPE}" in

        systemd)

            if ! systemctl cat "${SERVICE_NAME}" >/dev/null 2>&1; then
                die "systemd service not found: ${SERVICE_NAME}"
            fi
            ;;

        service)

            if [[ ! -e "/etc/init.d/${SERVICE_NAME}" ]]; then
                die "service not found: ${SERVICE_NAME}"
            fi
            ;;

    esac
}


validate_service_running()
{
    if ! service_is_active; then
        die "Precheck failed: ${SERVICE_NAME} is not running."
    fi

    RUNNING_PID="$(get_service_pid)"

    if [[ -z "${RUNNING_PID}" || "${RUNNING_PID}" == "0" ]]; then
        die "Precheck failed: ${SERVICE_NAME} is active but no valid Tomcat PID was found."
    fi

    if [[ ! -d "/proc/${RUNNING_PID}" ]]; then
        die "Precheck failed: Tomcat PID ${RUNNING_PID} does not exist."
    fi

    info "Service precheck passed:"
    info "${SERVICE_NAME} is running with PID ${RUNNING_PID}"
}


# ============================================================
# PROCESS IDENTITY
# ============================================================

detect_process_identity()
{
    RUNNING_PID="$(get_service_pid)"

    [[ -n "${RUNNING_PID}" ]] || \
        die "Could not determine Tomcat PID for ${SERVICE_NAME}"

    SERVICE_USER="$(
        ps -o user= -p "${RUNNING_PID}" |
        awk '{$1=$1; print}'
    )"

    [[ -n "${SERVICE_USER}" ]] || \
        die "Could not determine service user from PID ${RUNNING_PID}"

    SERVICE_GROUP="$(
        id -gn "${SERVICE_USER}"
    )"

    [[ -n "${SERVICE_GROUP}" ]] || \
        die "Could not determine service group for ${SERVICE_USER}"

    if [[ -e "/proc/${RUNNING_PID}/exe" ]]; then

        JAVA_BIN="$(
            readlink -f "/proc/${RUNNING_PID}/exe"
        )"

        if [[ "${JAVA_BIN}" == */bin/java ]]; then
            JAVA_HOME="${JAVA_BIN%/bin/java}"
        fi
    fi
}


# ============================================================
# SERVICE CONFIGURATION
# ============================================================

read_service_configuration()
{
    case "${SERVICE_TYPE}" in

        systemd)

            SERVICE_USER="$(get_systemd_property User)"
            SERVICE_GROUP="$(get_systemd_property Group)"

            CONFIGURED_HOME="$(
                get_systemd_environment_value CATALINA_HOME
            )"

            CONFIGURED_BASE="$(
                get_systemd_environment_value CATALINA_BASE
            )"

            JAVA_HOME="$(
                get_systemd_environment_value JAVA_HOME
            )"

            [[ -n "${SERVICE_USER}" ]] || \
                die "Could not determine systemd service user."

            [[ -n "${SERVICE_GROUP}" ]] || \
                die "Could not determine systemd service group."

            [[ -n "${CONFIGURED_HOME}" ]] || \
                die "CATALINA_HOME was not found in ${SERVICE_NAME}"

            [[ -n "${CONFIGURED_BASE}" ]] || \
                die "CATALINA_BASE was not found in ${SERVICE_NAME}"

            if [[ "${CONFIGURED_BASE}" != "${CATALINA_BASE}" ]]; then

                die "CATALINA_BASE mismatch. Expected ${CATALINA_BASE}, found ${CONFIGURED_BASE}"

            fi

            if [[ -n "${JAVA_HOME}" && -e "${JAVA_HOME}/bin/java" ]]; then

                JAVA_BIN="$(
                    readlink -f "${JAVA_HOME}/bin/java"
                )"

            fi
            ;;


        service)

            CONFIGURED_HOME="${CATALINA_HOME}"
            CONFIGURED_BASE="${CATALINA_BASE}"

            detect_process_identity
            ;;

    esac

    [[ -e "${CONFIGURED_HOME}" ]] || \
        die "Configured CATALINA_HOME does not exist: ${CONFIGURED_HOME}"

    [[ -d "${CONFIGURED_BASE}" ]] || \
        die "Configured CATALINA_BASE does not exist: ${CONFIGURED_BASE}"

    REAL_HOME="$(readlink -f "${CONFIGURED_HOME}")"
    REAL_BASE="$(readlink -f "${CONFIGURED_BASE}")"

    [[ -n "${REAL_HOME}" ]] || \
        die "Could not resolve CATALINA_HOME: ${CONFIGURED_HOME}"

    [[ -n "${REAL_BASE}" ]] || \
        die "Could not resolve CATALINA_BASE: ${CONFIGURED_BASE}"

    [[ -d "${REAL_HOME}" ]] || \
        die "Resolved CATALINA_HOME is invalid: ${REAL_HOME}"

    [[ -d "${REAL_BASE}" ]] || \
        die "Resolved CATALINA_BASE is invalid: ${REAL_BASE}"
}


# ============================================================
# HOME / BASE VALIDATION
# ============================================================

validate_home_base_layout()
{
    if [[ "${REAL_HOME}" == "${REAL_BASE}" ]]; then

        die "CATALINA_HOME and CATALINA_BASE resolve to the same directory: ${REAL_HOME}. Automatic upgrade requires separate HOME and BASE directories."

    fi

    info "CATALINA_HOME and CATALINA_BASE are separate."
}


# ============================================================
# TOMCAT VERSION
# ============================================================

get_tomcat_version()
{
    local home="$1"

    "${home}/bin/version.sh" 2>/dev/null \
        | awk -F':' '
            /Server number/ {
                gsub(/^[[:space:]]+/, "", $2)
                gsub(/[[:space:]]+$/, "", $2)
                print $2
                exit
            }
        '
}


normalize_version()
{
    printf '%s\n' "$1" \
        | awk -F. '
            {
                if (NF == 4 && $4 == 0)
                    print $1 "." $2 "." $3
                else
                    print
            }
        '
}


detect_current_version()
{
    [[ -x "${REAL_HOME}/bin/version.sh" ]] || \
        die "Tomcat version.sh not found under ${REAL_HOME}"

    CURRENT_VERSION="$(get_tomcat_version "${REAL_HOME}")"

    [[ -n "${CURRENT_VERSION}" ]] || \
        die "Could not determine installed Tomcat version."

    if [[ ! "${CURRENT_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
        die "Unexpected Tomcat version format: ${CURRENT_VERSION}"
    fi

    CURRENT_VERSION_COMPARE="$(
        normalize_version "${CURRENT_VERSION}"
    )"

    CURRENT_MAJOR="${CURRENT_VERSION%%.*}"

    CURRENT_BRANCH="$(
        printf '%s\n' "${CURRENT_VERSION}" |
        cut -d. -f1-2
    )"
}


# ============================================================
# MANAGED TOMCAT SYMLINK
# ============================================================

detect_managed_link()
{
    #
    # Explicit TOMCAT_LINK takes precedence.
    #
    # If not defined, use latest<major>.
    #
    if [[ -z "${TOMCAT_LINK:-}" ]]; then

        TOMCAT_LINK="${TOMCAT_ROOT}/latest${CURRENT_MAJOR}"

        info "TOMCAT_LINK not defined in application configuration."
        info "Using default managed Tomcat link:"
        info "${TOMCAT_LINK}"

    else

        info "Using TOMCAT_LINK from application configuration:"
        info "${TOMCAT_LINK}"

    fi

    [[ -L "${TOMCAT_LINK}" ]] || \
        die "Managed Tomcat path does not exist or is not a symbolic link: ${TOMCAT_LINK}"

    TOMCAT_LINK_TARGET="$(readlink -f "${TOMCAT_LINK}")"

    [[ -n "${TOMCAT_LINK_TARGET}" ]] || \
        die "Could not resolve managed Tomcat symlink: ${TOMCAT_LINK}"

    [[ -d "${TOMCAT_LINK_TARGET}" ]] || \
        die "Managed Tomcat symlink target does not exist: ${TOMCAT_LINK_TARGET}"

    info "Managed Tomcat symlink detected:"
    info "${TOMCAT_LINK} -> ${TOMCAT_LINK_TARGET}"
}


validate_managed_link()
{
    if [[ "${CONFIGURED_HOME}" != "${TOMCAT_LINK}" ]]; then

        die "Configured CATALINA_HOME is not using the managed Tomcat link. Expected=${TOMCAT_LINK}, Found=${CONFIGURED_HOME}"

    fi

    if [[ "${TOMCAT_LINK_TARGET}" != "${REAL_HOME}" ]]; then

        die "Managed symlink target does not match the active Tomcat HOME. Link=${TOMCAT_LINK_TARGET}, Active=${REAL_HOME}"

    fi

    info "Service is using the expected managed Tomcat symlink."
}


# ============================================================
# SHARED LINK VALIDATION
# ============================================================

check_shared_link()
{
    local matches=""
    local count=0

    if [[ "${SERVICE_TYPE}" == "systemd" ]]; then

        matches="$(
            grep -l \
                "CATALINA_HOME=${TOMCAT_LINK}" \
                /etc/systemd/system/*.service \
                2>/dev/null || true
        )"

    else

        matches="$(
            grep -l \
                "CATALINA_HOME=${TOMCAT_LINK}" \
                /etc/init.d/* \
                2>/dev/null || true
        )"

    fi

    count="$(
        printf '%s\n' "${matches}" |
        sed '/^[[:space:]]*$/d' |
        wc -l
    )"

    if (( count > 1 )); then

        warn "${TOMCAT_LINK} is referenced by multiple services:"
        printf '%s\n' "${matches}"

        if [[ "${ALLOW_SHARED_LINK}" == "true" ]]; then

            warn "Shared Tomcat link explicitly allowed by application configuration."
            warn "All services using ${TOMCAT_LINK} will use the new Tomcat version the next time they start."

        else

            die "Upgrade refused because the managed Tomcat symlink is shared. Set ALLOW_SHARED_LINK=true in the application configuration only if this is intentional."

        fi

    elif (( count == 1 )); then

        info "Managed Tomcat symlink is used by one service:"
        info "${matches}"

    else

        info "No additional service references to ${TOMCAT_LINK} were detected."

    fi
}


# ============================================================
# APACHE VERSION CHECK
# ============================================================

get_latest_version()
{
    local repository_url
    local available_versions
    local latest_branch

    repository_url="${APACHE_BASE_URL}/tomcat-${CURRENT_MAJOR}/"

    info "Querying Apache Tomcat repository..."
    info "Repository: ${repository_url}"

    available_versions="$(
        curl \
            --fail \
            --silent \
            --show-error \
            --location \
            --max-time "${CURL_TIMEOUT}" \
            "${repository_url}" \
        | grep -oE \
            "v${CURRENT_BRANCH//./\\.}\.[0-9]+/" \
        | sed 's/^v//' \
        | sed 's:/$::' \
        | sort -Vu
    )"

    [[ -n "${available_versions}" ]] || \
        die "Could not find Tomcat ${CURRENT_BRANCH}.x releases on Apache."

    LATEST_VERSION="$(
        printf '%s\n' "${available_versions}" |
        sort -V |
        tail -1
    )"

    [[ -n "${LATEST_VERSION}" ]] || \
        die "Could not determine latest Tomcat version."

    latest_branch="$(
        printf '%s\n' "${LATEST_VERSION}" |
        cut -d. -f1-2
    )"

    if [[ "${latest_branch}" != "${CURRENT_BRANCH}" ]]; then
        die "Tomcat branch change prohibited: ${CURRENT_BRANCH} -> ${latest_branch}"
    fi
}


# ============================================================
# INSTANCE FILES
# ============================================================

check_instance_files()
{
    if [[ -f "${CATALINA_BASE}/bin/setenv.sh" ]]; then

        info "Instance setenv.sh detected:"
        info "${CATALINA_BASE}/bin/setenv.sh"

    else

        warn "No instance setenv.sh detected."

    fi

    if [[ -f "${CATALINA_BASE}/bin/tomcat-juli.jar" ]]; then

        JULI_PRESENT="true"

        JULI_MODE="$(
            stat -c '%a' \
            "${CATALINA_BASE}/bin/tomcat-juli.jar"
        )"

        info "Instance-specific tomcat-juli.jar detected:"
        info "${CATALINA_BASE}/bin/tomcat-juli.jar"
        info "tomcat-juli.jar mode: ${JULI_MODE}"

    else

        JULI_PRESENT="false"
        JULI_MODE=""

        info "No instance-specific tomcat-juli.jar detected."

    fi
}


# ============================================================
# RUNNING JVM VALIDATION
# ============================================================

check_running_process()
{
    RUNNING_PID="$(get_service_pid)"

    [[ -n "${RUNNING_PID}" ]] || \
        die "Could not determine running Tomcat PID."

    [[ -r "/proc/${RUNNING_PID}/cmdline" ]] || \
        die "Cannot read command line for PID ${RUNNING_PID}."

    PROCESS_HOME="$(
        tr '\0' '\n' < "/proc/${RUNNING_PID}/cmdline" \
            | grep '^-Dcatalina.home=' \
            | head -1 \
            | cut -d= -f2-
    )"

    PROCESS_BASE="$(
        tr '\0' '\n' < "/proc/${RUNNING_PID}/cmdline" \
            | grep '^-Dcatalina.base=' \
            | head -1 \
            | cut -d= -f2-
    )"

    if [[ "${PROCESS_HOME}" != "${CONFIGURED_HOME}" ]]; then

        die "Running JVM CATALINA_HOME mismatch. Configured=${CONFIGURED_HOME}, Process=${PROCESS_HOME}"

    fi

    if [[ "${PROCESS_BASE}" != "${CONFIGURED_BASE}" ]]; then

        die "Running JVM CATALINA_BASE mismatch. Configured=${CONFIGURED_BASE}, Process=${PROCESS_BASE}"

    fi

    info "Running JVM HOME/BASE validation passed."
}


# ============================================================
# HEALTH CHECK
# ============================================================

validate_health_url()
{
    info "Checking application health URL:"
    info "${HEALTH_URL}"

    curl \
        --fail \
        --silent \
        --show-error \
        --max-time 15 \
        "${HEALTH_URL}" \
        >/dev/null
}


validate_preupgrade_health()
{
    if validate_health_url; then

        info "Application health precheck passed."

    else

        die "Precheck failed: application health URL is not responding successfully: ${HEALTH_URL}"

    fi
}


validate_health_url_retry()
{
    local elapsed=0

    info "Waiting ${STARTUP_DELAY} seconds before application health check..."

    sleep "${STARTUP_DELAY}"

    while (( elapsed < START_TIMEOUT )); do

        if validate_health_url; then
            return 0
        fi

        sleep 3
        elapsed=$((elapsed + 3))
    done

    return 1
}


# ============================================================
# CHECK REPORT
# ============================================================

show_check_report()
{
    echo
    line
    echo " TOMCAT UPGRADE CHECK"
    line
    echo

    printf "%-28s : %s\n" "Application" "${APP}"
    printf "%-28s : %s\n" "Service type" "${SERVICE_TYPE}"
    printf "%-28s : %s\n" "Service" "${SERVICE_NAME}"
    printf "%-28s : %s\n" "Service status" "ACTIVE"
    printf "%-28s : %s\n" "Service user" "${SERVICE_USER:-unknown}"
    printf "%-28s : %s\n" "Service group" "${SERVICE_GROUP:-unknown}"
    printf "%-28s : %s\n" "Main PID" "${RUNNING_PID}"

    echo

    printf "%-28s : %s\n" "JAVA_HOME" "${JAVA_HOME:-unknown}"
    printf "%-28s : %s\n" "Java binary" "${JAVA_BIN:-unknown}"

    echo

    printf "%-28s : %s\n" "Tomcat root" "${TOMCAT_ROOT}"
    printf "%-28s : %s\n" "Configured HOME" "${CONFIGURED_HOME}"
    printf "%-28s : %s\n" "Resolved HOME" "${REAL_HOME}"
    printf "%-28s : %s\n" "Configured BASE" "${CONFIGURED_BASE}"
    printf "%-28s : %s\n" "Resolved BASE" "${REAL_BASE}"

    echo

    printf "%-28s : %s\n" "Managed link" "${TOMCAT_LINK}"
    printf "%-28s : %s\n" "Managed link target" "${TOMCAT_LINK_TARGET}"
    printf "%-28s : %s\n" "Allow shared link" "${ALLOW_SHARED_LINK}"

    echo

    printf "%-28s : %s\n" "Running JVM HOME" "${PROCESS_HOME}"
    printf "%-28s : %s\n" "Running JVM BASE" "${PROCESS_BASE}"

    echo

    printf "%-28s : %s\n" "Installed version" "${CURRENT_VERSION}"
    printf "%-28s : %s\n" "Normalized version" "${CURRENT_VERSION_COMPARE}"
    printf "%-28s : %s\n" "Tomcat major" "${CURRENT_MAJOR}"
    printf "%-28s : %s.x\n" "Tomcat branch" "${CURRENT_BRANCH}"
    printf "%-28s : %s\n" "Latest available" "${LATEST_VERSION}"
    printf "%-28s : %s\n" "Health URL" "${HEALTH_URL}"
    printf "%-28s : %s seconds\n" "Startup delay" "${STARTUP_DELAY}"

    echo
    line

    if [[ "${CURRENT_VERSION_COMPARE}" == "${LATEST_VERSION}" ]]; then

        echo " NO UPGRADE REQUIRED"

    else

        echo " UPGRADE AVAILABLE"
        echo
        echo " ${CURRENT_VERSION} -> ${LATEST_VERSION}"

    fi

    line
    echo

    printf "%-28s : %s\n" "Warnings" "${WARNINGS}"
    printf "%-28s : %s\n" "Errors" "${ERRORS}"

    echo
}


# ============================================================
# COMMON PRECHECK
# ============================================================

run_prechecks()
{
    check_requirements
    validate_service
    validate_service_running
    read_service_configuration
    validate_home_base_layout
    detect_current_version
    detect_managed_link
    validate_managed_link
    check_instance_files
    check_running_process
    validate_preupgrade_health
    get_latest_version
}


# ============================================================
# CHECK MODE
# ============================================================

perform_check()
{
    run_prechecks
    show_check_report
}


# ============================================================
# DRY RUN
# ============================================================

perform_dryrun()
{
    run_prechecks
    check_shared_link

    NEW_HOME="${TOMCAT_ROOT}/apache-tomcat-${LATEST_VERSION}"

    local filename
    local download_url
    local checksum_url
    local step=1

    filename="apache-tomcat-${LATEST_VERSION}.tar.gz"

    download_url="${APACHE_BASE_URL}/tomcat-${CURRENT_MAJOR}/v${LATEST_VERSION}/bin/${filename}"
    checksum_url="${download_url}.sha512"

    echo
    line
    echo " TOMCAT UPGRADE DRY RUN"
    line
    echo

    printf "%-28s : %s\n" "Application" "${APP}"
    printf "%-28s : %s\n" "Service type" "${SERVICE_TYPE}"
    printf "%-28s : %s\n" "Service" "${SERVICE_NAME}"
    printf "%-28s : %s\n" "Current version" "${CURRENT_VERSION}"
    printf "%-28s : %s\n" "Target version" "${LATEST_VERSION}"
    printf "%-28s : %s.x\n" "Tomcat branch" "${CURRENT_BRANCH}"
    printf "%-28s : %s\n" "Tomcat root" "${TOMCAT_ROOT}"
    printf "%-28s : %s\n" "Current HOME" "${REAL_HOME}"
    printf "%-28s : %s\n" "New HOME" "${NEW_HOME}"
    printf "%-28s : %s\n" "Managed link" "${TOMCAT_LINK}"
    printf "%-28s : %s\n" "Allow shared link" "${ALLOW_SHARED_LINK}"
    printf "%-28s : %s\n" "CATALINA_BASE" "${CATALINA_BASE}"
    printf "%-28s : %s\n" "Health URL" "${HEALTH_URL}"
    printf "%-28s : %s seconds\n" "Startup delay" "${STARTUP_DELAY}"

    echo
    line
    echo

    if [[ "${CURRENT_VERSION_COMPARE}" == "${LATEST_VERSION}" ]]; then

        echo "No upgrade is required."
        echo
        line
        echo " DRY RUN COMPLETE - NO CHANGES WERE MADE"
        line
        echo

        return 0
    fi

    echo "STEP ${step} - Validate service is running and healthy"
    echo
    echo "  Service: ${SERVICE_NAME}"
    echo "  PID: ${RUNNING_PID}"
    echo "  Health URL: ${HEALTH_URL}"
    echo

    step=$((step + 1))

    echo "STEP ${step} - Validate HOME / BASE layout"
    echo
    echo "  HOME: ${REAL_HOME}"
    echo "  BASE: ${REAL_BASE}"
    echo

    step=$((step + 1))

    if [[ "${ALLOW_SHARED_LINK}" == "true" ]]; then

        echo "STEP ${step} - Shared managed link acknowledged"
        echo
        echo "  ${TOMCAT_LINK} is allowed to be shared."
        echo
        echo "  WARNING:"
        echo "  All services referencing this link will use the new"
        echo "  Tomcat version the next time they start."
        echo

        step=$((step + 1))
    fi

    echo "STEP ${step} - Download Tomcat ${LATEST_VERSION}"
    echo
    echo "  curl --fail --location --show-error \\"
    echo "    ${download_url} \\"
    echo "    -o /tmp/${filename}"
    echo

    step=$((step + 1))

    echo "STEP ${step} - Download SHA-512 checksum"
    echo
    echo "  curl --fail --location --show-error \\"
    echo "    ${checksum_url} \\"
    echo "    -o /tmp/${filename}.sha512"
    echo

    step=$((step + 1))

    echo "STEP ${step} - Validate SHA-512 checksum"
    echo
    echo "  sha512sum -c ${filename}.sha512"
    echo

    step=$((step + 1))

    echo "STEP ${step} - Extract new Tomcat"
    echo
    echo "  tar -xzf /tmp/${filename} -C ${TOMCAT_ROOT}"
    echo

    step=$((step + 1))

    echo "STEP ${step} - Set ownership"
    echo
    echo "  chown -R ${SERVICE_USER}:${SERVICE_GROUP} ${NEW_HOME}"
    echo

    step=$((step + 1))

    echo "STEP ${step} - Create backup"
    echo
    echo "  mkdir -p ${BACKUP_ROOT}/${APP}/<timestamp>"
    echo "  tar -C ${CATALINA_BASE} -czf <backup>/catalina-base-conf.tar.gz conf"

    if [[ "${JULI_PRESENT}" == "true" ]]; then

        echo
        echo "  cp -p ${CATALINA_BASE}/bin/tomcat-juli.jar \\"
        echo "    <backup>/tomcat-juli.jar"

    fi

    echo

    step=$((step + 1))

    echo "STEP ${step} - Stop Tomcat"
    echo

    case "${SERVICE_TYPE}" in

        systemd)
            echo "  systemctl stop ${SERVICE_NAME}"
            ;;

        service)
            echo "  /usr/sbin/service ${SERVICE_NAME} stop"
            ;;

    esac

    echo

    step=$((step + 1))

    if [[ "${JULI_PRESENT}" == "true" ]]; then

        echo "STEP ${step} - Update tomcat-juli.jar"
        echo
        echo "  install \\"
        echo "    -o ${SERVICE_USER} \\"
        echo "    -g ${SERVICE_GROUP} \\"
        echo "    -m ${JULI_MODE} \\"
        echo "    ${NEW_HOME}/bin/tomcat-juli.jar \\"
        echo "    ${CATALINA_BASE}/bin/tomcat-juli.jar"
        echo

        step=$((step + 1))
    fi

    echo "STEP ${step} - Switch Tomcat symlink"
    echo
    echo "  ln -sfn ${NEW_HOME} ${TOMCAT_LINK}"
    echo

    step=$((step + 1))

    echo "STEP ${step} - Start Tomcat"
    echo

    case "${SERVICE_TYPE}" in

        systemd)
            echo "  systemctl start ${SERVICE_NAME}"
            ;;

        service)
            echo "  /usr/sbin/service ${SERVICE_NAME} start"
            ;;

    esac

    echo

    step=$((step + 1))

    echo "STEP ${step} - Validate running JVM"
    echo
    echo "  Expected HOME: ${TOMCAT_LINK}"
    echo "  Expected BASE: ${CATALINA_BASE}"
    echo

    step=$((step + 1))

    echo "STEP ${step} - Validate upgraded Tomcat version"
    echo
    echo "  ${TOMCAT_LINK}/bin/version.sh"
    echo
    echo "  Expected version: ${LATEST_VERSION}"
    echo

    step=$((step + 1))

    echo "STEP ${step} - Wait for application deployment"
    echo
    echo "  sleep ${STARTUP_DELAY}"
    echo

    step=$((step + 1))

    echo "STEP ${step} - Validate application health"
    echo
    echo "  curl --fail --silent --show-error \\"
    echo "    --max-time 15 \\"
    echo "    ${HEALTH_URL}"
    echo
    echo "  Retry every 3 seconds for up to ${START_TIMEOUT} seconds."
    echo

    step=$((step + 1))

    if [[ "${SERVICE_TYPE}" == "systemd" ]]; then

        echo "STEP ${step} - Validate startup logs"
        echo
        echo "  journalctl -u ${SERVICE_NAME} --since '-5 minutes' --no-pager"
        echo

        step=$((step + 1))
    fi

    echo "STEP ${step} - Rollback automatically if validation fails"
    echo

    case "${SERVICE_TYPE}" in

        systemd)
            echo "  systemctl stop ${SERVICE_NAME}"
            ;;

        service)
            echo "  /usr/sbin/service ${SERVICE_NAME} stop"
            ;;

    esac

    if [[ "${JULI_PRESENT}" == "true" ]]; then

        echo
        echo "  cp -p <backup>/tomcat-juli.jar \\"
        echo "    ${CATALINA_BASE}/bin/tomcat-juli.jar"

    fi

    echo
    echo "  ln -sfn ${REAL_HOME} ${TOMCAT_LINK}"

    case "${SERVICE_TYPE}" in

        systemd)
            echo "  systemctl start ${SERVICE_NAME}"
            ;;

        service)
            echo "  /usr/sbin/service ${SERVICE_NAME} start"
            ;;

    esac

    echo
    echo "  sleep ${STARTUP_DELAY}"
    echo "  curl --fail ${HEALTH_URL}"

    echo
    line
    echo " DRY RUN COMPLETE - NO COMMANDS ABOVE WERE EXECUTED"
    line
    echo
}


# ============================================================
# DOWNLOAD
# ============================================================

download_new_tomcat()
{
    local filename
    local url

    filename="apache-tomcat-${LATEST_VERSION}.tar.gz"

    url="${APACHE_BASE_URL}/tomcat-${CURRENT_MAJOR}/v${LATEST_VERSION}/bin/${filename}"

    WORK_DIR="${WORK_ROOT}/tomcat-upgrade-${APP}-${LATEST_VERSION}-$$"

    mkdir -p "${WORK_DIR}"

    info "Downloading Tomcat ${LATEST_VERSION}..."

    curl \
        --fail \
        --location \
        --show-error \
        --max-time "${CURL_TIMEOUT}" \
        "${url}" \
        -o "${WORK_DIR}/${filename}"

    info "Downloading SHA-512 checksum..."

    curl \
        --fail \
        --location \
        --show-error \
        --max-time "${CURL_TIMEOUT}" \
        "${url}.sha512" \
        -o "${WORK_DIR}/${filename}.sha512"
}


verify_checksum()
{
    local filename

    filename="apache-tomcat-${LATEST_VERSION}.tar.gz"

    info "Validating SHA-512 checksum..."

    (
        cd "${WORK_DIR}"
        sha512sum -c "${filename}.sha512"
    )

    info "SHA-512 validation passed."
}


# ============================================================
# INSTALL
# ============================================================

extract_new_tomcat()
{
    NEW_HOME="${TOMCAT_ROOT}/apache-tomcat-${LATEST_VERSION}"

    if [[ -e "${NEW_HOME}" ]]; then
        die "Target Tomcat directory already exists: ${NEW_HOME}"
    fi

    info "Extracting Tomcat ${LATEST_VERSION}..."

    tar \
        -xzf "${WORK_DIR}/apache-tomcat-${LATEST_VERSION}.tar.gz" \
        -C "${TOMCAT_ROOT}"

    [[ -d "${NEW_HOME}" ]] || \
        die "Tomcat extraction failed."

    chown -R "${SERVICE_USER}:${SERVICE_GROUP}" "${NEW_HOME}"

    local detected_version

    detected_version="$(
        get_tomcat_version "${NEW_HOME}"
    )"

    detected_version="$(
        normalize_version "${detected_version}"
    )"

    [[ "${detected_version}" == "${LATEST_VERSION}" ]] || \
        die "Extracted Tomcat version mismatch."

    info "New Tomcat installation validated."
}


# ============================================================
# BACKUP
# ============================================================

create_backup()
{
    local timestamp

    timestamp="$(date '+%Y%m%d_%H%M%S')"

    BACKUP_DIR="${BACKUP_ROOT}/${APP}/${timestamp}"

    mkdir -p "${BACKUP_DIR}"

    info "Creating upgrade backup:"
    info "${BACKUP_DIR}"

    cat > "${BACKUP_DIR}/upgrade.info" <<EOF
APPLICATION=${APP}
SERVICE_TYPE=${SERVICE_TYPE}
SERVICE_NAME=${SERVICE_NAME}
TOMCAT_ROOT=${TOMCAT_ROOT}
TOMCAT_LINK=${TOMCAT_LINK}
ALLOW_SHARED_LINK=${ALLOW_SHARED_LINK}
CATALINA_HOME=${CONFIGURED_HOME}
CATALINA_BASE=${CATALINA_BASE}
OLD_HOME=${REAL_HOME}
OLD_VERSION=${CURRENT_VERSION}
NEW_HOME=${NEW_HOME}
NEW_VERSION=${LATEST_VERSION}
SERVICE_USER=${SERVICE_USER}
SERVICE_GROUP=${SERVICE_GROUP}
JAVA_HOME=${JAVA_HOME}
JAVA_BIN=${JAVA_BIN}
HEALTH_URL=${HEALTH_URL}
STARTUP_DELAY=${STARTUP_DELAY}
EOF

    case "${SERVICE_TYPE}" in

        systemd)

            systemctl cat "${SERVICE_NAME}" \
                > "${BACKUP_DIR}/service-definition.txt"
            ;;

        service)

            cp -p \
                "/etc/init.d/${SERVICE_NAME}" \
                "${BACKUP_DIR}/service-definition.txt"
            ;;

    esac

    tar \
        -C "${CATALINA_BASE}" \
        -czf "${BACKUP_DIR}/catalina-base-conf.tar.gz" \
        conf

    if [[ "${JULI_PRESENT}" == "true" ]]; then

        JULI_BACKUP="${BACKUP_DIR}/tomcat-juli.jar"

        cp -p \
            "${CATALINA_BASE}/bin/tomcat-juli.jar" \
            "${JULI_BACKUP}"

    fi
}


# ============================================================
# TOMCAT-JULI
# ============================================================

update_instance_juli()
{
    [[ "${JULI_PRESENT}" == "true" ]] || return 0

    [[ -f "${NEW_HOME}/bin/tomcat-juli.jar" ]] || \
        die "New Tomcat tomcat-juli.jar not found."

    info "Updating instance-specific tomcat-juli.jar..."

    install \
        -o "${SERVICE_USER}" \
        -g "${SERVICE_GROUP}" \
        -m "${JULI_MODE}" \
        "${NEW_HOME}/bin/tomcat-juli.jar" \
        "${CATALINA_BASE}/bin/tomcat-juli.jar"
}


restore_instance_juli()
{
    [[ "${JULI_PRESENT}" == "true" ]] || return 0
    [[ -f "${JULI_BACKUP}" ]] || return 0

    info "Restoring previous tomcat-juli.jar..."

    cp -p \
        "${JULI_BACKUP}" \
        "${CATALINA_BASE}/bin/tomcat-juli.jar"
}


# ============================================================
# SERVICE CONTROL
# ============================================================

stop_service()
{
    info "Stopping ${SERVICE_NAME}..."

    service_stop

    if service_is_active; then
        die "Tomcat service failed to stop."
    fi

    info "Tomcat stopped."
}


start_service()
{
    info "Starting ${SERVICE_NAME}..."

    service_start
}


# ============================================================
# SYMLINK
# ============================================================

switch_to_new_tomcat()
{
    info "Switching managed Tomcat symlink..."

    ln -sfn \
        "${NEW_HOME}" \
        "${TOMCAT_LINK}"

    TOMCAT_LINK_TARGET="$(readlink -f "${TOMCAT_LINK}")"

    [[ "${TOMCAT_LINK_TARGET}" == "${NEW_HOME}" ]] || \
        die "Failed to switch ${TOMCAT_LINK}"

    info "${TOMCAT_LINK} -> ${NEW_HOME}"
}


switch_to_old_tomcat()
{
    info "Restoring previous Tomcat symlink..."

    ln -sfn \
        "${REAL_HOME}" \
        "${TOMCAT_LINK}"

    TOMCAT_LINK_TARGET="$(readlink -f "${TOMCAT_LINK}")"

    [[ "${TOMCAT_LINK_TARGET}" == "${REAL_HOME}" ]]
}


# ============================================================
# POST-UPGRADE VALIDATION
# ============================================================

wait_for_service()
{
    local elapsed=0

    while (( elapsed < START_TIMEOUT )); do

        if service_is_active; then

            RUNNING_PID="$(get_service_pid)"

            if [[ -n "${RUNNING_PID}" && "${RUNNING_PID}" != "0" ]]; then
                return 0
            fi
        fi

        sleep 2
        elapsed=$((elapsed + 2))
    done

    return 1
}


validate_running_jvm()
{
    RUNNING_PID="$(get_service_pid)"

    [[ -n "${RUNNING_PID}" ]] || return 1
    [[ -r "/proc/${RUNNING_PID}/cmdline" ]] || return 1

    PROCESS_HOME="$(
        tr '\0' '\n' < "/proc/${RUNNING_PID}/cmdline" \
            | grep '^-Dcatalina.home=' \
            | head -1 \
            | cut -d= -f2-
    )"

    PROCESS_BASE="$(
        tr '\0' '\n' < "/proc/${RUNNING_PID}/cmdline" \
            | grep '^-Dcatalina.base=' \
            | head -1 \
            | cut -d= -f2-
    )"

    [[ "${PROCESS_HOME}" == "${TOMCAT_LINK}" ]] || return 1
    [[ "${PROCESS_BASE}" == "${CATALINA_BASE}" ]] || return 1

    return 0
}


validate_new_version()
{
    local active_home
    local active_version

    active_home="$(readlink -f "${TOMCAT_LINK}")"

    active_version="$(
        get_tomcat_version "${active_home}"
    )"

    active_version="$(
        normalize_version "${active_version}"
    )"

    [[ "${active_version}" == "${LATEST_VERSION}" ]]
}


validate_logs()
{
    if [[ "${SERVICE_TYPE}" != "systemd" ]]; then

        info "journalctl validation skipped for SERVICE_TYPE=service."

        return 0
    fi

    local log_file

    log_file="${BACKUP_DIR}/post-upgrade-journal.log"

    journalctl \
        -u "${SERVICE_NAME}" \
        --since "-5 minutes" \
        --no-pager \
        > "${log_file}" || true

    if grep -Ei \
        'SEVERE|OutOfMemoryError|BindException|Address already in use|LifecycleException' \
        "${log_file}" \
        >/dev/null
    then

        warn "Potential Tomcat errors found in systemd journal."
        warn "Review: ${log_file}"

        if [[ "${FAIL_ON_LOG_ERRORS}" == "true" ]]; then
            return 1
        fi
    fi

    return 0
}


post_upgrade_validation()
{
    echo
    line
    echo " POST-UPGRADE VALIDATION"
    line
    echo

    if wait_for_service; then
        printf "%-34s PASS\n" "Service status"
    else
        printf "%-34s FAIL\n" "Service status"
        return 1
    fi

    if validate_running_jvm; then
        printf "%-34s PASS\n" "Running JVM configuration"
    else
        printf "%-34s FAIL\n" "Running JVM configuration"
        return 1
    fi

    if validate_new_version; then
        printf "%-34s PASS\n" "Tomcat version"
    else
        printf "%-34s FAIL\n" "Tomcat version"
        return 1
    fi

    if validate_health_url_retry; then
        printf "%-34s PASS\n" "Application health check"
    else
        printf "%-34s FAIL\n" "Application health check"
        return 1
    fi

    if validate_logs; then
        printf "%-34s PASS\n" "Log validation"
    else
        printf "%-34s FAIL\n" "Log validation"
        return 1
    fi

    echo
    line
}


# ============================================================
# ROLLBACK
# ============================================================

rollback()
{
    echo
    line
    echo " ROLLBACK"
    line
    echo

    warn "Rolling back to Tomcat ${CURRENT_VERSION}..."

    service_stop || true

    restore_instance_juli

    if ! switch_to_old_tomcat; then

        error "Could not restore previous Tomcat symlink."
        return 1
    fi

    service_start || true

    if ! wait_for_service; then

        error "ROLLBACK FAILED: previous Tomcat did not start."
        return 1
    fi

    if ! validate_running_jvm; then

        error "ROLLBACK FAILED: JVM validation failed."
        return 1
    fi

    if ! validate_health_url_retry; then

        error "ROLLBACK FAILED: application health check failed."
        return 1
    fi

    info "Rollback completed successfully."

    echo

    printf "%-28s : %s\n" "Restored version" "${CURRENT_VERSION}"
    printf "%-28s : %s\n" "Restored HOME" "${REAL_HOME}"
    printf "%-28s : %s\n" "Managed link" "${TOMCAT_LINK}"

    echo
    line
}


# ============================================================
# UPGRADE
# ============================================================

perform_upgrade()
{
    require_root

    run_prechecks
    check_shared_link

    echo
    line
    echo " TOMCAT UPGRADE"
    line
    echo

    printf "%-28s : %s\n" "Application" "${APP}"
    printf "%-28s : %s\n" "Service type" "${SERVICE_TYPE}"
    printf "%-28s : %s\n" "Service" "${SERVICE_NAME}"
    printf "%-28s : %s\n" "Current version" "${CURRENT_VERSION}"
    printf "%-28s : %s\n" "Target version" "${LATEST_VERSION}"
    printf "%-28s : %s\n" "Tomcat root" "${TOMCAT_ROOT}"
    printf "%-28s : %s\n" "Managed link" "${TOMCAT_LINK}"
    printf "%-28s : %s\n" "Allow shared link" "${ALLOW_SHARED_LINK}"
    printf "%-28s : %s\n" "Current HOME" "${REAL_HOME}"
    printf "%-28s : %s\n" "CATALINA_BASE" "${CATALINA_BASE}"
    printf "%-28s : %s\n" "Service user" "${SERVICE_USER}"
    printf "%-28s : %s\n" "Service group" "${SERVICE_GROUP}"
    printf "%-28s : %s\n" "JAVA_HOME" "${JAVA_HOME:-unknown}"
    printf "%-28s : %s\n" "Java binary" "${JAVA_BIN:-unknown}"
    printf "%-28s : %s\n" "Health URL" "${HEALTH_URL}"
    printf "%-28s : %s seconds\n" "Startup delay" "${STARTUP_DELAY}"

    echo
    line
    echo

    if [[ "${CURRENT_VERSION_COMPARE}" == "${LATEST_VERSION}" ]]; then

        info "Tomcat is already up to date."
        exit 0
    fi

    NEW_HOME="${TOMCAT_ROOT}/apache-tomcat-${LATEST_VERSION}"

    download_new_tomcat
    verify_checksum
    extract_new_tomcat
    create_backup

    stop_service
    update_instance_juli
    switch_to_new_tomcat
    start_service

    if ! post_upgrade_validation; then

        error "Post-upgrade validation failed."

        if rollback; then

            echo
            line
            echo " UPGRADE FAILED - ROLLBACK SUCCESSFUL"
            line

        else

            echo
            line
            echo " UPGRADE FAILED - ROLLBACK FAILED"
            line

        fi

        exit 1
    fi

    echo
    line
    echo " UPGRADE SUCCESSFUL"
    line
    echo

    printf "%-28s : %s\n" "Application" "${APP}"
    printf "%-28s : %s\n" "Previous version" "${CURRENT_VERSION}"
    printf "%-28s : %s\n" "Current version" "${LATEST_VERSION}"
    printf "%-28s : %s\n" "Managed link" "${TOMCAT_LINK}"
    printf "%-28s : %s\n" "Current HOME" "${NEW_HOME}"
    printf "%-28s : %s\n" "Previous HOME" "${REAL_HOME}"
    printf "%-28s : %s\n" "Backup" "${BACKUP_DIR}"

    echo
    line
    echo

    rm -rf "${WORK_DIR}"
}


# ============================================================
# USAGE
# ============================================================

usage()
{
    echo
    echo "Usage:"
    echo
    echo "  $0 --app <application> --check"
    echo "  $0 --app <application> --dryrun"
    echo "  $0 --app <application> --upgrade"
    echo
    echo "Application configuration:"
    echo
    echo "  ${CONFIG_DIR}/<application>.conf"
    echo
}


# ============================================================
# MAIN
# ============================================================

main()
{
    if [[ $# -ne 3 ]]; then

        usage
        exit 1
    fi

    if [[ "$1" != "--app" ]]; then

        usage
        exit 1
    fi

    APP="$2"
    ACTION="$3"

    validate_application
    load_application_config

    case "${ACTION}" in

        --check)
            perform_check
            ;;

        --dryrun)
            perform_dryrun
            ;;

        --upgrade)
            perform_upgrade
            ;;

        *)
            usage
            exit 1
            ;;

    esac
}


main "$@"
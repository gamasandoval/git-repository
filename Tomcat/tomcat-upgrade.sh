#!/bin/bash
#
# tomcat-upgrade.sh
#
# Generic Apache Tomcat minor/patch upgrade utility.
#
# Supported service managers:
#   SERVICE_TYPE="systemd"
#   SERVICE_TYPE="service"
#
# Actions:
#   --check
#   --dryrun
#   --upgrade
#
# Configuration:
#   /u01/app/tomcat/upgrade-config/<app>.conf
#
# Optional functional health validation:
#
#   HEALTH_URL="https://host:port/application"
#
# If HEALTH_URL is configured:
#   - pre-upgrade HTTP health is required
#   - post-upgrade HTTP health is required
#   - failure causes rollback
#
# If HEALTH_URL is omitted:
#   - service startup is still required
#   - JVM HOME/BASE validation is still required
#   - Tomcat version validation is still required
#   - HTTP validation is skipped
#
# Shared Tomcat:
#
#   ALLOW_SHARED_LINK="true"
#   SHARED_APPS="app1 app2 app3"
#
# Every member of the shared group must declare the same SHARED_APPS
# value in the same order.
#
# SHARED_APPS order controls sequential startup/validation.
#

set -Eeuo pipefail


# ============================================================
# GLOBAL CONFIGURATION
# ============================================================

CONFIG_DIR="/u01/app/tomcat/upgrade-config"

# Version discovery.
APACHE_BASE_URL="https://dlcdn.apache.org/tomcat"

# Binary download.
APACHE_DOWNLOAD_URL="https://archive.apache.org/dist/tomcat"

WORK_ROOT="/tmp"

# Archive downloads can be slow.
CURL_TIMEOUT=600

# Maximum time to wait for a Tomcat process to become active.
START_TIMEOUT=60


# ============================================================
# COMMAND-LINE VARIABLES
# ============================================================

APP=""
ACTION=""


# ============================================================
# PRIMARY APPLICATION CONFIGURATION
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

ALLOW_SHARED_LINK="false"
SHARED_APPS=""


# ============================================================
# PRIMARY APPLICATION RUNTIME
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
# SHARED APPLICATION RUNTIME
# ============================================================

declare -a SHARED_APP_LIST=()

declare -A SH_SERVICE_TYPE
declare -A SH_SERVICE_NAME

declare -A SH_TOMCAT_ROOT
declare -A SH_TOMCAT_LINK

declare -A SH_CATALINA_HOME
declare -A SH_CATALINA_BASE

declare -A SH_HEALTH_URL
declare -A SH_STARTUP_DELAY

declare -A SH_SERVICE_USER
declare -A SH_SERVICE_GROUP

declare -A SH_PID
declare -A SH_REAL_HOME

declare -A SH_JULI_PRESENT
declare -A SH_JULI_MODE
declare -A SH_JULI_BACKUP

declare -A SH_BACKUP_DIR

SHARED_APPS_EXPECTED=""
SHARED_TOMCAT_LINK_EXPECTED=""


# ============================================================
# OUTPUT
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
# APPLICATION CONFIGURATION
# ============================================================

validate_app_name()
{
    local app="$1"

    if [[ ! "${app}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        die "Invalid application name: ${app}"
    fi
}


validate_application()
{
    local config_file

    validate_app_name "${APP}"

    config_file="${CONFIG_DIR}/${APP}.conf"

    [[ -f "${config_file}" ]] || \
        die "Application configuration not found: ${config_file}"
}


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

    [[ -d "${TOMCAT_ROOT}" ]] || \
        die "TOMCAT_ROOT does not exist: ${TOMCAT_ROOT}"

    BACKUP_ROOT="${TOMCAT_ROOT}/upgrade-backups"

    HEALTH_URL="${HEALTH_URL:-}"
    STARTUP_DELAY="${STARTUP_DELAY:-10}"
    ALLOW_SHARED_LINK="${ALLOW_SHARED_LINK:-false}"
    SHARED_APPS="${SHARED_APPS:-}"

    [[ "${STARTUP_DELAY}" =~ ^[0-9]+$ ]] || \
        die "STARTUP_DELAY must be a non-negative integer."

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
    local command

    for command in \
        curl awk grep sed sort readlink sha512sum tar install stat \
        tr cut head tail wc cp ln pgrep ps id sleep date
    do
        require_command "${command}"
    done

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
    [[ "$(id -u)" -eq 0 ]] || \
        die "--upgrade must be executed as root."
}


# ============================================================
# SERVICE ABSTRACTION
# ============================================================

service_start_values()
{
    local type="$1"
    local name="$2"

    case "${type}" in
        systemd)
            systemctl start "${name}"
            ;;
        service)
            /usr/sbin/service "${name}" start
            ;;
        *)
            return 1
            ;;
    esac
}


service_stop_values()
{
    local type="$1"
    local name="$2"

    case "${type}" in
        systemd)
            systemctl stop "${name}"
            ;;
        service)
            /usr/sbin/service "${name}" stop
            ;;
        *)
            return 1
            ;;
    esac
}


service_is_active_values()
{
    local type="$1"
    local name="$2"

    case "${type}" in
        systemd)
            systemctl is-active --quiet "${name}"
            ;;
        service)
            /usr/sbin/service "${name}" status >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}


get_service_pid_values()
{
    local type="$1"
    local name="$2"
    local base="$3"

    case "${type}" in
        systemd)
            systemctl show \
                "${name}" \
                -p MainPID \
                --value 2>/dev/null
            ;;

        service)
            pgrep -f "\-Dcatalina.base=${base}" \
                | head -1 || true
            ;;
    esac
}


service_start()
{
    service_start_values \
        "${SERVICE_TYPE}" \
        "${SERVICE_NAME}"
}


service_stop()
{
    service_stop_values \
        "${SERVICE_TYPE}" \
        "${SERVICE_NAME}"
}


service_is_active()
{
    service_is_active_values \
        "${SERVICE_TYPE}" \
        "${SERVICE_NAME}"
}


get_service_pid()
{
    get_service_pid_values \
        "${SERVICE_TYPE}" \
        "${SERVICE_NAME}" \
        "${CATALINA_BASE}"
}


# ============================================================
# SYSTEMD HELPERS
# ============================================================

get_systemd_property_values()
{
    local service="$1"
    local property="$2"

    systemctl show \
        "${service}" \
        -p "${property}" \
        --value 2>/dev/null
}


get_systemd_environment_value_values()
{
    local service="$1"
    local variable="$2"
    local environment

    environment="$(
        systemctl show \
            "${service}" \
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


get_systemd_property()
{
    get_systemd_property_values \
        "${SERVICE_NAME}" \
        "$1"
}


get_systemd_environment_value()
{
    get_systemd_environment_value_values \
        "${SERVICE_NAME}" \
        "$1"
}


# ============================================================
# SERVICE VALIDATION
# ============================================================

validate_service()
{
    case "${SERVICE_TYPE}" in
        systemd)
            systemctl cat "${SERVICE_NAME}" >/dev/null 2>&1 || \
                die "systemd service not found: ${SERVICE_NAME}"
            ;;
        service)
            [[ -e "/etc/init.d/${SERVICE_NAME}" ]] || \
                die "service not found: ${SERVICE_NAME}"
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

    [[ -d "/proc/${RUNNING_PID}" ]] || \
        die "Precheck failed: Tomcat PID ${RUNNING_PID} does not exist."

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

    SERVICE_GROUP="$(id -gn "${SERVICE_USER}")"

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

            [[ "${CONFIGURED_BASE}" == "${CATALINA_BASE}" ]] || \
                die "CATALINA_BASE mismatch. Expected ${CATALINA_BASE}, found ${CONFIGURED_BASE}"

            if [[ -n "${JAVA_HOME}" &&
                  -e "${JAVA_HOME}/bin/java" ]]
            then
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

    [[ -d "${REAL_HOME}" ]] || \
        die "Resolved CATALINA_HOME is invalid: ${REAL_HOME}"

    [[ -d "${REAL_BASE}" ]] || \
        die "Resolved CATALINA_BASE is invalid: ${REAL_BASE}"
}


validate_home_base_layout()
{
    [[ "${REAL_HOME}" != "${REAL_BASE}" ]] || \
        die "CATALINA_HOME and CATALINA_BASE resolve to the same directory: ${REAL_HOME}"

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

    CURRENT_VERSION="$(
        get_tomcat_version "${REAL_HOME}"
    )"

    [[ -n "${CURRENT_VERSION}" ]] || \
        die "Could not determine installed Tomcat version."

    [[ "${CURRENT_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || \
        die "Unexpected Tomcat version format: ${CURRENT_VERSION}"

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
# MANAGED TOMCAT LINK
# ============================================================

detect_managed_link()
{
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

    TOMCAT_LINK_TARGET="$(
        readlink -f "${TOMCAT_LINK}"
    )"

    [[ -d "${TOMCAT_LINK_TARGET}" ]] || \
        die "Managed Tomcat symlink target does not exist: ${TOMCAT_LINK_TARGET}"

    info "Managed Tomcat symlink detected:"
    info "${TOMCAT_LINK} -> ${TOMCAT_LINK_TARGET}"
}


validate_managed_link()
{
    [[ "${CONFIGURED_HOME}" == "${TOMCAT_LINK}" ]] || \
        die "Configured CATALINA_HOME is not using the managed Tomcat link. Expected=${TOMCAT_LINK}, Found=${CONFIGURED_HOME}"

    [[ "${TOMCAT_LINK_TARGET}" == "${REAL_HOME}" ]] || \
        die "Managed symlink target does not match the active Tomcat HOME."

    info "Service is using the expected managed Tomcat symlink."
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
# RUNNING JVM
# ============================================================

get_process_home()
{
    local pid="$1"

    tr '\0' '\n' < "/proc/${pid}/cmdline" \
        | grep '^-Dcatalina.home=' \
        | head -1 \
        | cut -d= -f2-
}


get_process_base()
{
    local pid="$1"

    tr '\0' '\n' < "/proc/${pid}/cmdline" \
        | grep '^-Dcatalina.base=' \
        | head -1 \
        | cut -d= -f2-
}


check_running_process()
{
    RUNNING_PID="$(get_service_pid)"

    [[ -n "${RUNNING_PID}" ]] || \
        die "Could not determine running Tomcat PID."

    [[ -r "/proc/${RUNNING_PID}/cmdline" ]] || \
        die "Cannot read command line for PID ${RUNNING_PID}."

    PROCESS_HOME="$(get_process_home "${RUNNING_PID}")"
    PROCESS_BASE="$(get_process_base "${RUNNING_PID}")"

    [[ "${PROCESS_HOME}" == "${CONFIGURED_HOME}" ]] || \
        die "Running JVM CATALINA_HOME mismatch. Configured=${CONFIGURED_HOME}, Process=${PROCESS_HOME}"

    [[ "${PROCESS_BASE}" == "${CONFIGURED_BASE}" ]] || \
        die "Running JVM CATALINA_BASE mismatch. Configured=${CONFIGURED_BASE}, Process=${PROCESS_BASE}"

    info "Running JVM HOME/BASE validation passed."
}


# ============================================================
# HEALTH CHECK
# ============================================================

health_url_check()
{
    local url="$1"

    curl \
        --fail \
        --silent \
        --show-error \
        --max-time 15 \
        "${url}" \
        >/dev/null
}


validate_health_url()
{
    [[ -n "${HEALTH_URL:-}" ]] || return 0

    info "Checking application health URL:"
    info "${HEALTH_URL}"

    health_url_check "${HEALTH_URL}"
}


validate_preupgrade_health()
{
    if [[ -z "${HEALTH_URL:-}" ]]; then

        info "No HEALTH_URL configured."
        info "Application functional health precheck will be skipped."

        return 0
    fi

    if validate_health_url; then
        info "Application health precheck passed."
    else
        die "Precheck failed: application health URL is not responding successfully: ${HEALTH_URL}"
    fi
}


health_url_retry_values()
{
    local url="$1"
    local delay="$2"
    local elapsed=0

    [[ -n "${url}" ]] || return 0

    info "Waiting ${delay} seconds before application health check..."

    sleep "${delay}"

    while (( elapsed < START_TIMEOUT )); do

        if health_url_check "${url}"; then
            return 0
        fi

        sleep 3
        elapsed=$((elapsed + 3))
    done

    return 1
}


validate_health_url_retry()
{
    if [[ -z "${HEALTH_URL:-}" ]]; then

        info "No HEALTH_URL configured."
        info "Application functional health validation skipped."

        return 0
    fi

    health_url_retry_values \
        "${HEALTH_URL}" \
        "${STARTUP_DELAY}"
}


# ============================================================
# APACHE VERSION DISCOVERY
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

    latest_branch="$(
        printf '%s\n' "${LATEST_VERSION}" |
        cut -d. -f1-2
    )"

    [[ "${latest_branch}" == "${CURRENT_BRANCH}" ]] || \
        die "Tomcat branch change prohibited: ${CURRENT_BRANCH} -> ${latest_branch}"
}


# ============================================================
# SHARED LINK DISCOVERY
# ============================================================

get_link_references()
{
    local matches=""

    matches="$(
        grep -Rl \
            "CATALINA_HOME=${TOMCAT_LINK}" \
            /etc/systemd/system/*.service \
            /etc/init.d/* \
            2>/dev/null || true
    )"

    printf '%s\n' "${matches}" \
        | sed '/^[[:space:]]*$/d' \
        | sort -u
}


# ============================================================
# SHARED APPLICATION CONFIG
# ============================================================

load_shared_app_config()
{
    local app="$1"
    local config_file

    local c_service_type=""
    local c_service_name=""
    local c_tomcat_root=""
    local c_tomcat_link=""
    local c_catalina_home=""
    local c_catalina_base=""
    local c_health_url=""
    local c_startup_delay=""
    local c_allow_shared=""
    local c_shared_apps=""

    local pid=""
    local process_home=""
    local process_base=""
    local real_home=""
    local app_version=""
    local app_version_normalized=""
    local app_branch=""
    local app_major=""
    local user=""
    local group=""

    #
    # Preserve primary application globals.
    #
    local saved_SERVICE_TYPE="${SERVICE_TYPE}"
    local saved_SERVICE_NAME="${SERVICE_NAME}"
    local saved_TOMCAT_ROOT="${TOMCAT_ROOT}"
    local saved_TOMCAT_LINK="${TOMCAT_LINK}"
    local saved_CATALINA_HOME="${CATALINA_HOME}"
    local saved_CATALINA_BASE="${CATALINA_BASE}"
    local saved_HEALTH_URL="${HEALTH_URL}"
    local saved_STARTUP_DELAY="${STARTUP_DELAY}"
    local saved_ALLOW_SHARED_LINK="${ALLOW_SHARED_LINK}"
    local saved_SHARED_APPS="${SHARED_APPS}"

    validate_app_name "${app}"

    config_file="${CONFIG_DIR}/${app}.conf"

    [[ -f "${config_file}" ]] || \
        die "Shared application config not found: ${config_file}"

    SERVICE_TYPE=""
    SERVICE_NAME=""
    TOMCAT_ROOT=""
    TOMCAT_LINK=""
    CATALINA_HOME=""
    CATALINA_BASE=""
    HEALTH_URL=""
    STARTUP_DELAY=""
    ALLOW_SHARED_LINK="false"
    SHARED_APPS=""

    # shellcheck disable=SC1090
    source "${config_file}"

    c_service_type="${SERVICE_TYPE}"
    c_service_name="${SERVICE_NAME}"
    c_tomcat_root="${TOMCAT_ROOT}"
    c_tomcat_link="${TOMCAT_LINK:-}"
    c_catalina_home="${CATALINA_HOME:-}"
    c_catalina_base="${CATALINA_BASE}"
    c_health_url="${HEALTH_URL:-}"
    c_startup_delay="${STARTUP_DELAY:-10}"
    c_allow_shared="${ALLOW_SHARED_LINK:-false}"
    c_shared_apps="${SHARED_APPS:-}"

    [[ "${c_allow_shared}" == "true" ]] || \
        die "${app}.conf must define ALLOW_SHARED_LINK=true."

    [[ "${c_shared_apps}" == "${SHARED_APPS_EXPECTED}" ]] || \
        die "Shared application configuration mismatch. ${app}.conf declares SHARED_APPS=\"${c_shared_apps}\" but expected \"${SHARED_APPS_EXPECTED}\"."

    [[ -n "${c_service_type}" ]] || \
        die "SERVICE_TYPE missing from ${app}.conf"

    [[ -n "${c_service_name}" ]] || \
        die "SERVICE_NAME missing from ${app}.conf"

    [[ -n "${c_tomcat_root}" ]] || \
        die "TOMCAT_ROOT missing from ${app}.conf"

    [[ -n "${c_catalina_base}" ]] || \
        die "CATALINA_BASE missing from ${app}.conf"

    [[ "${c_startup_delay}" =~ ^[0-9]+$ ]] || \
        die "Invalid STARTUP_DELAY in ${app}.conf"

    case "${c_service_type}" in

        systemd)

            systemctl cat "${c_service_name}" >/dev/null 2>&1 || \
                die "systemd service not found for ${app}: ${c_service_name}"

            c_catalina_home="$(
                get_systemd_environment_value_values \
                    "${c_service_name}" \
                    CATALINA_HOME
            )"

            local systemd_base

            systemd_base="$(
                get_systemd_environment_value_values \
                    "${c_service_name}" \
                    CATALINA_BASE
            )"

            [[ "${systemd_base}" == "${c_catalina_base}" ]] || \
                die "${app}: systemd CATALINA_BASE mismatch."

            user="$(
                get_systemd_property_values \
                    "${c_service_name}" \
                    User
            )"

            group="$(
                get_systemd_property_values \
                    "${c_service_name}" \
                    Group
            )"
            ;;

        service)

            [[ -e "/etc/init.d/${c_service_name}" ]] || \
                die "service not found for ${app}: ${c_service_name}"

            [[ -n "${c_catalina_home}" ]] || \
                die "${app}: CATALINA_HOME required for service mode."
            ;;

        *)
            die "${app}: unsupported SERVICE_TYPE=${c_service_type}"
            ;;
    esac

    service_is_active_values \
        "${c_service_type}" \
        "${c_service_name}" || \
        die "${app}: service is not running."

    pid="$(
        get_service_pid_values \
            "${c_service_type}" \
            "${c_service_name}" \
            "${c_catalina_base}"
    )"

    [[ -n "${pid}" && "${pid}" != "0" ]] || \
        die "${app}: could not determine Tomcat PID."

    [[ -r "/proc/${pid}/cmdline" ]] || \
        die "${app}: cannot read PID ${pid}."

    process_home="$(get_process_home "${pid}")"
    process_base="$(get_process_base "${pid}")"

    [[ "${process_home}" == "${c_catalina_home}" ]] || \
        die "${app}: running CATALINA_HOME mismatch."

    [[ "${process_base}" == "${c_catalina_base}" ]] || \
        die "${app}: running CATALINA_BASE mismatch."

    real_home="$(readlink -f "${c_catalina_home}")"

    [[ -d "${real_home}" ]] || \
        die "${app}: resolved Tomcat HOME does not exist."

    app_version="$(get_tomcat_version "${real_home}")"

    [[ -n "${app_version}" ]] || \
        die "${app}: could not determine Tomcat version."

    app_version_normalized="$(
        normalize_version "${app_version}"
    )"

    app_major="${app_version_normalized%%.*}"

    app_branch="$(
        printf '%s\n' "${app_version_normalized}" |
        cut -d. -f1-2
    )"

    if [[ -z "${c_tomcat_link}" ]]; then
        c_tomcat_link="${c_tomcat_root}/latest${app_major}"
    fi

    [[ "${c_catalina_home}" == "${c_tomcat_link}" ]] || \
        die "${app}: CATALINA_HOME does not match managed TOMCAT_LINK."

    [[ "${c_tomcat_link}" == "${SHARED_TOMCAT_LINK_EXPECTED}" ]] || \
        die "${app}: managed Tomcat link differs from shared group."

    [[ "${real_home}" == "${REAL_HOME}" ]] || \
        die "${app}: physical Tomcat HOME differs from shared group."

    [[ "${app_version_normalized}" == "${CURRENT_VERSION_COMPARE}" ]] || \
        die "${app}: Tomcat version differs from shared group."

    [[ "${app_branch}" == "${CURRENT_BRANCH}" ]] || \
        die "${app}: Tomcat branch differs from shared group."

    if [[ "${c_service_type}" == "service" ]]; then

        user="$(
            ps -o user= -p "${pid}" |
            awk '{$1=$1; print}'
        )"

        group="$(id -gn "${user}")"
    fi

    #
    # Functional health is optional.
    #
    if [[ -n "${c_health_url}" ]]; then

        info "Checking shared application health: ${app}"
        info "${c_health_url}"

        health_url_check "${c_health_url}" || \
            die "${app}: application health precheck failed."

        info "${app}: application health precheck passed."

    else

        info "${app}: no HEALTH_URL configured."
        info "${app}: functional health precheck skipped."
    fi

    SH_SERVICE_TYPE["${app}"]="${c_service_type}"
    SH_SERVICE_NAME["${app}"]="${c_service_name}"

    SH_TOMCAT_ROOT["${app}"]="${c_tomcat_root}"
    SH_TOMCAT_LINK["${app}"]="${c_tomcat_link}"

    SH_CATALINA_HOME["${app}"]="${c_catalina_home}"
    SH_CATALINA_BASE["${app}"]="${c_catalina_base}"

    SH_HEALTH_URL["${app}"]="${c_health_url}"
    SH_STARTUP_DELAY["${app}"]="${c_startup_delay}"

    SH_SERVICE_USER["${app}"]="${user}"
    SH_SERVICE_GROUP["${app}"]="${group}"

    SH_PID["${app}"]="${pid}"
    SH_REAL_HOME["${app}"]="${real_home}"

    if [[ -f "${c_catalina_base}/bin/tomcat-juli.jar" ]]; then

        SH_JULI_PRESENT["${app}"]="true"

        SH_JULI_MODE["${app}"]="$(
            stat -c '%a' \
                "${c_catalina_base}/bin/tomcat-juli.jar"
        )"

    else

        SH_JULI_PRESENT["${app}"]="false"
        SH_JULI_MODE["${app}"]=""
    fi

    #
    # Restore primary application globals.
    #
    SERVICE_TYPE="${saved_SERVICE_TYPE}"
    SERVICE_NAME="${saved_SERVICE_NAME}"
    TOMCAT_ROOT="${saved_TOMCAT_ROOT}"
    TOMCAT_LINK="${saved_TOMCAT_LINK}"
    CATALINA_HOME="${saved_CATALINA_HOME}"
    CATALINA_BASE="${saved_CATALINA_BASE}"
    HEALTH_URL="${saved_HEALTH_URL}"
    STARTUP_DELAY="${saved_STARTUP_DELAY}"
    ALLOW_SHARED_LINK="${saved_ALLOW_SHARED_LINK}"
    SHARED_APPS="${saved_SHARED_APPS}"

    info "${app}: shared application precheck passed."
}


# ============================================================
# SHARED GROUP VALIDATION
# ============================================================

validate_shared_group()
{
    local app
    local references
    local reference_count
    local found_primary="false"

    SHARED_APP_LIST=()

    read -r -a SHARED_APP_LIST <<< "${SHARED_APPS}"

    (( ${#SHARED_APP_LIST[@]} >= 2 )) || \
        die "SHARED_APPS must contain at least two applications."

    for app in "${SHARED_APP_LIST[@]}"; do
        [[ "${app}" == "${APP}" ]] && found_primary="true"
    done

    [[ "${found_primary}" == "true" ]] || \
        die "Primary application ${APP} is not present in SHARED_APPS."

    SHARED_APPS_EXPECTED="${SHARED_APPS}"
    SHARED_TOMCAT_LINK_EXPECTED="${TOMCAT_LINK}"

    echo
    line
    echo " SHARED TOMCAT PRECHECK"
    line
    echo

    printf "%-28s : %s\n" "Managed link" "${TOMCAT_LINK}"
    printf "%-28s : %s\n" "Current version" "${CURRENT_VERSION_COMPARE}"
    printf "%-28s : %s\n" "Shared applications" "${SHARED_APPS}"

    echo

    for app in "${SHARED_APP_LIST[@]}"; do

        info "Validating shared application: ${app}"

        load_shared_app_config "${app}"
    done

    references="$(get_link_references)"

    reference_count="$(
        printf '%s\n' "${references}" |
        sed '/^[[:space:]]*$/d' |
        wc -l
    )"

    if (( reference_count > 1 )); then

        warn "${TOMCAT_LINK} is referenced by multiple services:"
        printf '%s\n' "${references}"

        warn "Shared Tomcat link explicitly allowed."
        warn "Upgrade will coordinate all applications declared in SHARED_APPS."
    fi

    echo
    line
    echo " SHARED TOMCAT PRECHECK PASSED"
    line
    echo
}


check_shared_link()
{
    local references
    local count

    references="$(get_link_references)"

    count="$(
        printf '%s\n' "${references}" |
        sed '/^[[:space:]]*$/d' |
        wc -l
    )"

    if (( count <= 1 )); then

        if (( count == 1 )); then
            info "Managed Tomcat symlink is used by one service:"
            info "${references}"
        fi

        return 0
    fi

    warn "${TOMCAT_LINK} is referenced by multiple services:"
    printf '%s\n' "${references}"

    [[ "${ALLOW_SHARED_LINK}" == "true" ]] || \
        die "Upgrade refused because the managed Tomcat symlink is shared."

    [[ -n "${SHARED_APPS}" ]] || \
        die "Managed Tomcat link is shared and ALLOW_SHARED_LINK=true, but SHARED_APPS is not configured."

    validate_shared_group
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
    printf "%-28s : %s\n" "Shared applications" "${SHARED_APPS:-none}"

    echo

    printf "%-28s : %s\n" "Running JVM HOME" "${PROCESS_HOME}"
    printf "%-28s : %s\n" "Running JVM BASE" "${PROCESS_BASE}"

    echo

    printf "%-28s : %s\n" "Installed version" "${CURRENT_VERSION}"
    printf "%-28s : %s\n" "Normalized version" "${CURRENT_VERSION_COMPARE}"
    printf "%-28s : %s\n" "Tomcat major" "${CURRENT_MAJOR}"
    printf "%-28s : %s.x\n" "Tomcat branch" "${CURRENT_BRANCH}"
    printf "%-28s : %s\n" "Latest available" "${LATEST_VERSION}"

    if [[ -n "${HEALTH_URL:-}" ]]; then
        printf "%-28s : %s\n" "Health URL" "${HEALTH_URL}"
        printf "%-28s : %s\n" "Health validation" "ENABLED"
    else
        printf "%-28s : %s\n" "Health URL" "not configured"
        printf "%-28s : %s\n" "Health validation" "DISABLED"
    fi

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
    local filename
    local download_url
    local checksum_url
    local step=1
    local app

    run_prechecks
    check_shared_link

    NEW_HOME="${TOMCAT_ROOT}/apache-tomcat-${LATEST_VERSION}"

    filename="apache-tomcat-${LATEST_VERSION}.tar.gz"

    download_url="${APACHE_DOWNLOAD_URL}/tomcat-${CURRENT_MAJOR}/v${LATEST_VERSION}/bin/${filename}"
    checksum_url="${download_url}.sha512"

    echo
    line
    echo " TOMCAT UPGRADE DRY RUN"
    line
    echo

    printf "%-28s : %s\n" "Application" "${APP}"
    printf "%-28s : %s\n" "Current version" "${CURRENT_VERSION_COMPARE}"
    printf "%-28s : %s\n" "Target version" "${LATEST_VERSION}"
    printf "%-28s : %s\n" "Managed link" "${TOMCAT_LINK}"
    printf "%-28s : %s\n" "Current HOME" "${REAL_HOME}"
    printf "%-28s : %s\n" "New HOME" "${NEW_HOME}"

    if [[ -n "${SHARED_APPS}" ]]; then
        printf "%-28s : %s\n" "Shared applications" "${SHARED_APPS}"
    fi

    echo
    line
    echo

    if [[ "${CURRENT_VERSION_COMPARE}" == "${LATEST_VERSION}" ]]; then

        echo "No upgrade is required."
        echo
        line
        echo " DRY RUN COMPLETE - NO CHANGES WERE MADE"
        line

        return 0
    fi

    echo "STEP ${step} - Download Tomcat ${LATEST_VERSION}"
    echo
    echo "  ${download_url}"
    echo
    step=$((step + 1))

    echo "STEP ${step} - Download and validate SHA-512 checksum"
    echo
    echo "  ${checksum_url}"
    echo "  sha512sum -c ${filename}.sha512"
    echo
    step=$((step + 1))

    echo "STEP ${step} - Extract and validate Tomcat"
    echo
    echo "  ${NEW_HOME}"
    echo
    step=$((step + 1))

    if [[ -n "${SHARED_APPS}" &&
          "${ALLOW_SHARED_LINK}" == "true" ]]
    then

        echo "STEP ${step} - Create backups for all shared applications"
        echo

        for app in "${SHARED_APP_LIST[@]}"; do
            echo "  ${app}"
            echo "    BASE    : ${SH_CATALINA_BASE[$app]}"
            echo "    SERVICE : ${SH_SERVICE_NAME[$app]}"
        done

        echo
        step=$((step + 1))

        echo "STEP ${step} - Stop ALL shared applications"
        echo

        for app in "${SHARED_APP_LIST[@]}"; do

            case "${SH_SERVICE_TYPE[$app]}" in
                systemd)
                    echo "  systemctl stop ${SH_SERVICE_NAME[$app]}"
                    ;;
                service)
                    echo "  /usr/sbin/service ${SH_SERVICE_NAME[$app]} stop"
                    ;;
            esac
        done

        echo
        step=$((step + 1))

        echo "STEP ${step} - Switch shared Tomcat link"
        echo
        echo "  ln -sfn ${NEW_HOME} ${TOMCAT_LINK}"
        echo
        step=$((step + 1))

        for app in "${SHARED_APP_LIST[@]}"; do

            echo "STEP ${step} - Start and validate ${app}"
            echo
            echo "  Start      : ${SH_SERVICE_NAME[$app]}"
            echo "  HOME       : ${SH_TOMCAT_LINK[$app]}"
            echo "  BASE       : ${SH_CATALINA_BASE[$app]}"
            echo "  Version    : ${LATEST_VERSION}"

            if [[ -n "${SH_HEALTH_URL[$app]:-}" ]]; then
                echo "  Wait       : ${SH_STARTUP_DELAY[$app]} seconds"
                echo "  Health URL : ${SH_HEALTH_URL[$app]}"
                echo "  Health     : REQUIRED"
            else
                echo "  Health URL : not configured"
                echo "  Health     : SKIPPED"
            fi

            echo
            echo "  Service/JVM/Tomcat validation is always REQUIRED."
            echo "  If a required validation fails, rollback starts immediately."
            echo

            step=$((step + 1))
        done

        echo "STEP ${step} - Shared rollback if ANY required validation fails"
        echo
        echo "  Stop all shared applications"
        echo "  Restore ${TOMCAT_LINK} -> ${REAL_HOME}"
        echo "  Restore per-instance tomcat-juli.jar when applicable"
        echo
        echo "  Restart and validate applications sequentially:"
        echo

        for app in "${SHARED_APP_LIST[@]}"; do
            echo "    ${app}"
        done

    else

        echo "STEP ${step} - Create application backup"
        echo
        echo "  ${BACKUP_ROOT}/${APP}/<timestamp>"
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
            echo "  ${NEW_HOME}/bin/tomcat-juli.jar"
            echo "    -> ${CATALINA_BASE}/bin/tomcat-juli.jar"
            echo

            step=$((step + 1))
        fi

        echo "STEP ${step} - Switch Tomcat link"
        echo
        echo "  ln -sfn ${NEW_HOME} ${TOMCAT_LINK}"
        echo
        step=$((step + 1))

        echo "STEP ${step} - Start and validate ${APP}"
        echo
        echo "  Service : ${SERVICE_NAME}"

        if [[ -n "${HEALTH_URL:-}" ]]; then
            echo "  Wait       : ${STARTUP_DELAY} seconds"
            echo "  Health URL : ${HEALTH_URL}"
            echo "  Health     : REQUIRED"
        else
            echo "  Health URL : not configured"
            echo "  Health     : SKIPPED"
        fi

        echo
        echo "  Service/JVM/Tomcat validation is always REQUIRED."
        echo
        step=$((step + 1))

        echo "STEP ${step} - Rollback automatically on required validation failure"
        echo
        echo "  Restore ${TOMCAT_LINK} -> ${REAL_HOME}"
        echo "  Restart ${SERVICE_NAME}"
    fi

    echo
    line
    echo " DRY RUN COMPLETE - NO COMMANDS ABOVE WERE EXECUTED"
    line
    echo
}


# ============================================================
# DOWNLOAD / CHECKSUM / EXTRACT
# ============================================================

download_new_tomcat()
{
    local filename
    local url

    filename="apache-tomcat-${LATEST_VERSION}.tar.gz"

    url="${APACHE_DOWNLOAD_URL}/tomcat-${CURRENT_MAJOR}/v${LATEST_VERSION}/bin/${filename}"

    WORK_DIR="${WORK_ROOT}/tomcat-upgrade-${APP}-${LATEST_VERSION}-$$"

    mkdir -p "${WORK_DIR}"

    info "Downloading Tomcat ${LATEST_VERSION}..."
    info "${url}"

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


extract_new_tomcat()
{
    local detected_version

    NEW_HOME="${TOMCAT_ROOT}/apache-tomcat-${LATEST_VERSION}"

    [[ ! -e "${NEW_HOME}" ]] || \
        die "Target Tomcat directory already exists: ${NEW_HOME}"

    info "Extracting Tomcat ${LATEST_VERSION}..."

    tar \
        -xzf "${WORK_DIR}/apache-tomcat-${LATEST_VERSION}.tar.gz" \
        -C "${TOMCAT_ROOT}"

    [[ -d "${NEW_HOME}" ]] || \
        die "Tomcat extraction failed."

    chown -R \
        "${SERVICE_USER}:${SERVICE_GROUP}" \
        "${NEW_HOME}"

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
# BACKUPS
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
SHARED_APPS=${SHARED_APPS}
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


create_shared_backups()
{
    local app
    local timestamp

    timestamp="$(date '+%Y%m%d_%H%M%S')"

    for app in "${SHARED_APP_LIST[@]}"; do

        SH_BACKUP_DIR["${app}"]="${BACKUP_ROOT}/${app}/${timestamp}"

        mkdir -p "${SH_BACKUP_DIR[$app]}"

        info "Creating backup for ${app}:"
        info "${SH_BACKUP_DIR[$app]}"

        tar \
            -C "${SH_CATALINA_BASE[$app]}" \
            -czf "${SH_BACKUP_DIR[$app]}/catalina-base-conf.tar.gz" \
            conf

        if [[ "${SH_JULI_PRESENT[$app]}" == "true" ]]; then

            SH_JULI_BACKUP["${app}"]="${SH_BACKUP_DIR[$app]}/tomcat-juli.jar"

            cp -p \
                "${SH_CATALINA_BASE[$app]}/bin/tomcat-juli.jar" \
                "${SH_JULI_BACKUP[$app]}"
        fi

        cat > "${SH_BACKUP_DIR[$app]}/upgrade.info" <<EOF
APPLICATION=${app}
SERVICE_TYPE=${SH_SERVICE_TYPE[$app]}
SERVICE_NAME=${SH_SERVICE_NAME[$app]}
CATALINA_HOME=${SH_CATALINA_HOME[$app]}
CATALINA_BASE=${SH_CATALINA_BASE[$app]}
TOMCAT_LINK=${TOMCAT_LINK}
OLD_HOME=${REAL_HOME}
OLD_VERSION=${CURRENT_VERSION}
NEW_HOME=${NEW_HOME}
NEW_VERSION=${LATEST_VERSION}
HEALTH_URL=${SH_HEALTH_URL[$app]}
STARTUP_DELAY=${SH_STARTUP_DELAY[$app]}
SHARED_APPS=${SHARED_APPS}
EOF
    done
}


# ============================================================
# TOMCAT-JULI
# ============================================================

update_instance_juli()
{
    [[ "${JULI_PRESENT}" == "true" ]] || return 0

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

    cp -p \
        "${JULI_BACKUP}" \
        "${CATALINA_BASE}/bin/tomcat-juli.jar"
}


update_shared_juli()
{
    local app

    for app in "${SHARED_APP_LIST[@]}"; do

        [[ "${SH_JULI_PRESENT[$app]}" == "true" ]] || continue

        info "Updating tomcat-juli.jar for ${app}..."

        install \
            -o "${SH_SERVICE_USER[$app]}" \
            -g "${SH_SERVICE_GROUP[$app]}" \
            -m "${SH_JULI_MODE[$app]}" \
            "${NEW_HOME}/bin/tomcat-juli.jar" \
            "${SH_CATALINA_BASE[$app]}/bin/tomcat-juli.jar"
    done
}


restore_shared_juli()
{
    local app

    for app in "${SHARED_APP_LIST[@]}"; do

        [[ "${SH_JULI_PRESENT[$app]}" == "true" ]] || continue
        [[ -f "${SH_JULI_BACKUP[$app]:-}" ]] || continue

        info "Restoring tomcat-juli.jar for ${app}..."

        cp -p \
            "${SH_JULI_BACKUP[$app]}" \
            "${SH_CATALINA_BASE[$app]}/bin/tomcat-juli.jar"
    done
}


# ============================================================
# SYMLINK
# ============================================================

switch_to_new_tomcat()
{
    info "Switching managed Tomcat symlink..."

    [[ -n "${NEW_HOME}" ]] || \
        die "NEW_HOME is empty. Refusing to modify Tomcat symlink."

    [[ -n "${TOMCAT_LINK}" ]] || \
        die "TOMCAT_LINK is empty. Refusing to modify Tomcat symlink."

    [[ -d "${NEW_HOME}" ]] || \
        die "New Tomcat HOME does not exist: ${NEW_HOME}"

    info "New HOME     : ${NEW_HOME}"
    info "Managed link : ${TOMCAT_LINK}"

    ln -sfn \
        "${NEW_HOME}" \
        "${TOMCAT_LINK}"

    TOMCAT_LINK_TARGET="$(
        readlink -f "${TOMCAT_LINK}"
    )"

    [[ "${TOMCAT_LINK_TARGET}" == "${NEW_HOME}" ]] || \
        die "Failed to switch ${TOMCAT_LINK}"

    info "${TOMCAT_LINK} -> ${NEW_HOME}"
}


switch_to_old_tomcat()
{
    info "Restoring previous Tomcat symlink..."

    [[ -n "${REAL_HOME}" ]] || \
        die "REAL_HOME is empty. Cannot rollback Tomcat symlink."

    [[ -n "${TOMCAT_LINK}" ]] || \
        die "TOMCAT_LINK is empty. Cannot rollback Tomcat symlink."

    [[ -d "${REAL_HOME}" ]] || \
        die "Previous Tomcat HOME does not exist: ${REAL_HOME}"

    info "Previous HOME : ${REAL_HOME}"
    info "Managed link  : ${TOMCAT_LINK}"

    ln -sfn \
        "${REAL_HOME}" \
        "${TOMCAT_LINK}"

    TOMCAT_LINK_TARGET="$(
        readlink -f "${TOMCAT_LINK}"
    )"

    [[ "${TOMCAT_LINK_TARGET}" == "${REAL_HOME}" ]] || \
        die "Failed to restore ${TOMCAT_LINK}"

    info "${TOMCAT_LINK} -> ${REAL_HOME}"
}


# ============================================================
# WAIT / VALIDATION
# ============================================================

wait_for_service_values()
{
    local type="$1"
    local name="$2"
    local base="$3"

    local elapsed=0
    local pid=""

    while (( elapsed < START_TIMEOUT )); do

        if service_is_active_values "${type}" "${name}"; then

            pid="$(
                get_service_pid_values \
                    "${type}" \
                    "${name}" \
                    "${base}"
            )"

            if [[ -n "${pid}" && "${pid}" != "0" ]]; then
                return 0
            fi
        fi

        sleep 2
        elapsed=$((elapsed + 2))
    done

    return 1
}


validate_application_runtime()
{
    local app="$1"
    local expected_version="$2"

    local type="${SH_SERVICE_TYPE[$app]}"
    local name="${SH_SERVICE_NAME[$app]}"
    local base="${SH_CATALINA_BASE[$app]}"
    local home="${SH_TOMCAT_LINK[$app]}"
    local url="${SH_HEALTH_URL[$app]:-}"
    local delay="${SH_STARTUP_DELAY[$app]}"

    local pid
    local process_home
    local process_base
    local active_home
    local active_version

    info "Validating ${app}..."

    if ! wait_for_service_values \
        "${type}" \
        "${name}" \
        "${base}"
    then
        error "${app}: service failed to start."
        return 1
    fi

    pid="$(
        get_service_pid_values \
            "${type}" \
            "${name}" \
            "${base}"
    )"

    [[ -r "/proc/${pid}/cmdline" ]] || {
        error "${app}: cannot read JVM process."
        return 1
    }

    process_home="$(get_process_home "${pid}")"
    process_base="$(get_process_base "${pid}")"

    [[ "${process_home}" == "${home}" ]] || {
        error "${app}: running CATALINA_HOME validation failed."
        return 1
    }

    [[ "${process_base}" == "${base}" ]] || {
        error "${app}: running CATALINA_BASE validation failed."
        return 1
    }

    active_home="$(readlink -f "${home}")"

    active_version="$(
        get_tomcat_version "${active_home}"
    )"

    active_version="$(
        normalize_version "${active_version}"
    )"

    [[ "${active_version}" == "${expected_version}" ]] || {
        error "${app}: Tomcat version validation failed. Expected=${expected_version}, Found=${active_version}"
        return 1
    }

    info "${app}: service/JVM/Tomcat validation PASSED."

    if [[ -n "${url}" ]]; then

        info "${app}: validating application health."
        info "${app}: ${url}"

        if ! health_url_retry_values \
            "${url}" \
            "${delay}"
        then
            error "${app}: application health validation failed."
            return 1
        fi

        info "${app}: application health validation PASSED."

    else

        info "${app}: application health validation SKIPPED."
        info "${app}: no HEALTH_URL configured."
    fi

    info "${app}: validation PASSED."

    return 0
}


# ============================================================
# SINGLE POST-UPGRADE VALIDATION
# ============================================================

post_upgrade_validation()
{
    local pid
    local process_home
    local process_base
    local active_version

    echo
    line
    echo " POST-UPGRADE VALIDATION"
    line
    echo

    if ! wait_for_service_values \
        "${SERVICE_TYPE}" \
        "${SERVICE_NAME}" \
        "${CATALINA_BASE}"
    then
        printf "%-34s FAIL\n" "Service status"
        return 1
    fi

    printf "%-34s PASS\n" "Service status"

    pid="$(get_service_pid)"

    process_home="$(get_process_home "${pid}")"
    process_base="$(get_process_base "${pid}")"

    if [[ "${process_home}" != "${TOMCAT_LINK}" ||
          "${process_base}" != "${CATALINA_BASE}" ]]
    then
        printf "%-34s FAIL\n" "Running JVM configuration"
        return 1
    fi

    printf "%-34s PASS\n" "Running JVM configuration"

    active_version="$(
        get_tomcat_version "$(readlink -f "${TOMCAT_LINK}")"
    )"

    active_version="$(normalize_version "${active_version}")"

    if [[ "${active_version}" != "${LATEST_VERSION}" ]]; then
        printf "%-34s FAIL\n" "Tomcat version"
        return 1
    fi

    printf "%-34s PASS\n" "Tomcat version"

    if [[ -n "${HEALTH_URL:-}" ]]; then

        if ! validate_health_url_retry; then
            printf "%-34s FAIL\n" "Application health check"
            return 1
        fi

        printf "%-34s PASS\n" "Application health check"

    else
        printf "%-34s SKIPPED\n" "Application health check"
    fi

    echo
    line

    return 0
}


# ============================================================
# SINGLE ROLLBACK
# ============================================================

rollback()
{
    warn "Rolling back to Tomcat ${CURRENT_VERSION_COMPARE}..."

    service_stop || true

    restore_instance_juli

    switch_to_old_tomcat || return 1

    service_start || true

    if ! wait_for_service_values \
        "${SERVICE_TYPE}" \
        "${SERVICE_NAME}" \
        "${CATALINA_BASE}"
    then
        error "ROLLBACK FAILED: previous Tomcat did not start."
        return 1
    fi

    if [[ -n "${HEALTH_URL:-}" ]]; then

        if ! validate_health_url_retry; then
            error "ROLLBACK FAILED: application health check failed."
            return 1
        fi

    else
        info "Rollback functional health validation skipped."
        info "No HEALTH_URL configured."
    fi

    info "Rollback completed successfully."

    return 0
}


# ============================================================
# SHARED STOP / START
# ============================================================

stop_shared_apps()
{
    local app

    info "Stopping all shared Tomcat applications..."

    for app in "${SHARED_APP_LIST[@]}"; do

        info "Stopping ${app}: ${SH_SERVICE_NAME[$app]}"

        service_stop_values \
            "${SH_SERVICE_TYPE[$app]}" \
            "${SH_SERVICE_NAME[$app]}" || \
            die "Failed to stop ${app}."
    done

    for app in "${SHARED_APP_LIST[@]}"; do

        if service_is_active_values \
            "${SH_SERVICE_TYPE[$app]}" \
            "${SH_SERVICE_NAME[$app]}"
        then
            die "${app} is still running after stop."
        fi
    done
}


start_validate_shared_apps()
{
    local app

    for app in "${SHARED_APP_LIST[@]}"; do

        echo
        line
        echo " STARTING SHARED APPLICATION: ${app}"
        line
        echo

        info "Starting ${SH_SERVICE_NAME[$app]}..."

        if ! service_start_values \
            "${SH_SERVICE_TYPE[$app]}" \
            "${SH_SERVICE_NAME[$app]}"
        then
            error "${app}: service start command failed."
            return 1
        fi

        if ! validate_application_runtime \
            "${app}" \
            "${LATEST_VERSION}"
        then
            error "${app}: validation failed."
            error "Remaining shared applications will NOT be started."
            return 1
        fi
    done

    return 0
}


# ============================================================
# SHARED ROLLBACK
# ============================================================

rollback_shared()
{
    local app

    echo
    line
    echo " SHARED TOMCAT ROLLBACK"
    line
    echo

    warn "Rolling back shared Tomcat to ${CURRENT_VERSION_COMPARE}..."

    for app in "${SHARED_APP_LIST[@]}"; do

        service_stop_values \
            "${SH_SERVICE_TYPE[$app]}" \
            "${SH_SERVICE_NAME[$app]}" \
            >/dev/null 2>&1 || true
    done

    restore_shared_juli

    if ! switch_to_old_tomcat; then
        error "CRITICAL: Could not restore previous Tomcat symlink."
        return 1
    fi

    for app in "${SHARED_APP_LIST[@]}"; do

        echo
        info "Rollback start: ${app}"

        if ! service_start_values \
            "${SH_SERVICE_TYPE[$app]}" \
            "${SH_SERVICE_NAME[$app]}"
        then
            error "ROLLBACK CRITICAL FAILURE"
            error "Application: ${app}"
            error "Service failed to start."
            error "Remaining applications were NOT started."
            return 1
        fi

        if ! validate_application_runtime \
            "${app}" \
            "${CURRENT_VERSION_COMPARE}"
        then
            error "ROLLBACK CRITICAL FAILURE"
            error "Application: ${app}"
            error "Previous Tomcat validation failed."
            error "Remaining applications were NOT started."
            error "Manual intervention required."
            return 1
        fi
    done

    info "Shared Tomcat rollback completed successfully."

    return 0
}


# ============================================================
# SHARED UPGRADE
# ============================================================

perform_shared_upgrade()
{
    local app
    local number=1

    echo
    line
    echo " SHARED TOMCAT UPGRADE"
    line
    echo

    printf "%-28s : %s\n" "Managed link" "${TOMCAT_LINK}"
    printf "%-28s : %s\n" "Current version" "${CURRENT_VERSION_COMPARE}"
    printf "%-28s : %s\n" "Target version" "${LATEST_VERSION}"
    printf "%-28s : %s\n" "Applications" "${SHARED_APPS}"

    echo
    echo "Startup / validation order:"

    for app in "${SHARED_APP_LIST[@]}"; do

        printf "  %d. %s (%s)" \
            "${number}" \
            "${app}" \
            "${SH_SERVICE_NAME[$app]}"

        if [[ -n "${SH_HEALTH_URL[$app]:-}" ]]; then
            printf " [health required]\n"
        else
            printf " [health skipped]\n"
        fi

        number=$((number + 1))
    done

    echo
    line
    echo

    NEW_HOME="${TOMCAT_ROOT}/apache-tomcat-${LATEST_VERSION}"

    download_new_tomcat
    verify_checksum
    extract_new_tomcat

    create_shared_backups

    stop_shared_apps

    update_shared_juli

    switch_to_new_tomcat

    if ! start_validate_shared_apps; then

        error "Shared Tomcat upgrade validation failed."

        if rollback_shared; then
            echo
            line
            echo " UPGRADE FAILED - SHARED ROLLBACK SUCCESSFUL"
            line
        else
            echo
            line
            echo " UPGRADE FAILED - SHARED ROLLBACK FAILED"
            echo " MANUAL INTERVENTION REQUIRED"
            line
        fi

        exit 1
    fi

    echo
    line
    echo " SHARED TOMCAT UPGRADE SUCCESSFUL"
    line
    echo

    printf "%-28s : %s\n" "Previous version" "${CURRENT_VERSION_COMPARE}"
    printf "%-28s : %s\n" "Current version" "${LATEST_VERSION}"
    printf "%-28s : %s\n" "Managed link" "${TOMCAT_LINK}"
    printf "%-28s : %s\n" "Current HOME" "${NEW_HOME}"
    printf "%-28s : %s\n" "Applications" "${SHARED_APPS}"

    echo
    echo "Functional validation:"

    for app in "${SHARED_APP_LIST[@]}"; do

        if [[ -n "${SH_HEALTH_URL[$app]:-}" ]]; then
            printf "  %-24s PASS\n" "${app}"
        else
            printf "  %-24s SKIPPED\n" "${app}"
        fi
    done

    echo
    line

    rm -rf "${WORK_DIR}"
}


# ============================================================
# SINGLE UPGRADE
# ============================================================

perform_single_upgrade()
{
    NEW_HOME="${TOMCAT_ROOT}/apache-tomcat-${LATEST_VERSION}"

    download_new_tomcat
    verify_checksum
    extract_new_tomcat
    create_backup

    service_stop

    update_instance_juli

    switch_to_new_tomcat

    service_start

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
    printf "%-28s : %s\n" "Previous version" "${CURRENT_VERSION_COMPARE}"
    printf "%-28s : %s\n" "Current version" "${LATEST_VERSION}"
    printf "%-28s : %s\n" "Managed link" "${TOMCAT_LINK}"
    printf "%-28s : %s\n" "Current HOME" "${NEW_HOME}"
    printf "%-28s : %s\n" "Previous HOME" "${REAL_HOME}"
    printf "%-28s : %s\n" "Backup" "${BACKUP_DIR}"

    if [[ -n "${HEALTH_URL:-}" ]]; then
        printf "%-28s : %s\n" "Functional health" "PASS"
    else
        printf "%-28s : %s\n" "Functional health" "SKIPPED"
    fi

    echo
    line

    rm -rf "${WORK_DIR}"
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
    printf "%-28s : %s\n" "Current version" "${CURRENT_VERSION_COMPARE}"
    printf "%-28s : %s\n" "Target version" "${LATEST_VERSION}"
    printf "%-28s : %s\n" "Managed link" "${TOMCAT_LINK}"
    printf "%-28s : %s\n" "Allow shared link" "${ALLOW_SHARED_LINK}"
    printf "%-28s : %s\n" "Shared applications" "${SHARED_APPS:-none}"

    echo
    line
    echo

    if [[ "${CURRENT_VERSION_COMPARE}" == "${LATEST_VERSION}" ]]; then
        info "Tomcat is already up to date."
        exit 0
    fi

    if [[ -n "${SHARED_APPS}" &&
          "${ALLOW_SHARED_LINK}" == "true" &&
          ${#SHARED_APP_LIST[@]} -gt 1 ]]
    then
        perform_shared_upgrade
    else
        perform_single_upgrade
    fi
}


# ============================================================
# USAGE / MAIN
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

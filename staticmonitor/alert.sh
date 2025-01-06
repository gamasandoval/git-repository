#!/usr/bin/env bash

# alert.sh
# Author: gsandoval
# This script will call create function and SN ticket will be created
#
# The MY_HOSTNAME_STATUS_DOWN downtime file is searched with grep.
# If the seconds of the downtime are greater than or equal to the defined seconds MY_ALERT_SEC,
# a ServiceNow ticket will be created.
# Usage: alert.sh 
# Usage: alert.sh debug|help 
#
# Add this script to your crontab. Example:
# */1 8-22 * * * bash alarm.sh -c "127.0.0.1" -m "nils@localhost" -d 60
# */1    * * * * bash alarm.sh -c "nc;www.heise.de" -m "other@email.local"
#

MY_SCRIPT_NAME=$(basename "$0")
BASE_PATH=$(dirname "$0")

################################################################################
#### Configuration Section
################################################################################

# Tip: You can also outsource configuration to an extra configuration file.
#      Just create a file named 'config' at the location of this script.

# if a config file has been specified with MY_STATUS_CONFIG=myfile use this one, otherwise default to config
if [[ -z "$MY_STATUS_CONFIG" ]]; then
	MY_STATUS_CONFIG="$BASE_PATH/config_alert"
fi
if [ -e "$MY_STATUS_CONFIG" ]; then
	# ignore SC1090
	# shellcheck source=/dev/null
	source "$MY_STATUS_CONFIG"
fi

# Check if term MY_CHECK can be found in the MY_HOSTNAME_STATUS_DOWN downtime file for failures
#MY_CHECK=${MY_CHECK:-"http-status"}
# Example:
#   Check if 'http-status' can be found and save the 805 seconds in MY_DOWN_SEC variable
#   status_hostname_down.txt:
#       http-status;http://ansible-master:8080/index1.html;200;75

# Send notification if downtime is greater than
#MY_ALERT_SEC=${MY_ALERT_SEC:-"300"} # 5 Minutes

# Location for the downtime status file
#MY_STATUS_CONFIG_DIR="/u01/app/staticmonitor"
#MY_HOSTNAME_STATUS_DOWN=${MY_HOSTNAME_STATUS_DOWN:-"$MY_STATUS_CONFIG_DIR/status_hostname_down.txt"}


################################################################################
#### END Configuration Section
################################################################################


################################################################################
# Usage
################################################################################

function usage {
	returnCode="$1"
	echo -e "Usage: $ME [OPTION]:
	OPTION is one of the following:
	\\t debug   displays all variables
	\\t help    displays help (this message)"
	exit "$returnCode"
}

################################################################################
# SN Functions
################################################################################


# debug_variables() print all script global variables to ease debugging
debug_variables() {
	echo
	echo "MY_SCRIPT_NAME: $MY_SCRIPT_NAME"
	echo "MY_CHECK: $MY_CHECK"
	echo "BASE_PATH: $BASE_PATH"
	echo "MY_ALERT_SEC: $MY_ALERT_SEC"
	
}	


#Fuction for logging pusposes, it receives script name and text to log
function f_log {
        MSG=$1
        COLOR=$2

        # String and set color
                if [[ -z "$COLOR" ]]; then
                       echo "$(eval "$MY_DATE"): $MSG"
                                elif [[ -n "$COLOR" && $COLOR == "green"  ]]; then
                                echo -e "$(eval "$MY_DATE"): ${GREEN}$MSG${CLEAR}"
                                elif [[ "$COLOR == red" ]]; then
                                echo -e "$(eval "$MY_DATE"): ${RED}$MSG${CLEAR}"
                else
                echo "This never happens"
                fi

}

function f_checkfile {
# Check downtime file
if [ ! -r "$MY_HOSTNAME_STATUS_DOWN" ]; then
	echo "Can not read downtime file '$MY_HOSTNAME_STATUS_DOWN'"
	exit 1
fi
}

function f_createticket {
SEVERITY="$1"
SNDATE=$(echo -e "$(eval "$MY_DATE")")

SN_CURL=$(curl -s --header "Content-Type: application/json" --header "x-api-key: $APIKEY" --request POST --data '{ "platform": "'$PLATFORM'", "app": "'$APP'", "instance": "'$INSTANCE'", "customer_shortname": "'$CUSTOMER_SHORTNAME'", "date": "'"$SNDATE"'", "host": "'$SNHOST'", "servicenow": {"short_description": "'"$SHORT_DESCRIPTION"'", "customer": "'"$CUSTOMER"'", "priority" : '$PRIORITY', "environment": "'$ENVIRONMENT'", "assignment_group": "'"$ASSIGNMENT_GROUP"'", "description": "'"$DESCRIPTION"'"}, "severity": "'$SEVERITY'"}' $ENDPOINT)
CURL_STATUS=$?
 #curl --header "Content-Type: application/json" --header "x-api-key: $apikey" --request POST --data '{ "platform": "'$platform'", "app": "'$app'", "instance": "'$instance'", "customer_shortname": "'$customer_shortname'", "date": "'"$sndate"'", "host": "'$snhost'", "servicenow": {"short_description": "'"$short_description"'", "customer": "'"$customer"'", "priority" : '$priority', "environment": "'$environment'", "assignment_group": "'"$assignment_group"'", "description": "'"$description"'"}, "severity": "'$severity'"}' $endpoint
SNINC_NUM=$(echo -e "$SN_CURL" | grep INC | awk -F ':' '{print $2}' | awk -F',' '{print $1}' | tr -d '"')
SNINC_STATE=$(echo -e "$SN_CURL" | grep INC | awk -F ':' '{print $3}' | awk -F',' '{print $1}' | tr -d '"')
#f_log "Curl Incident: $sninc_num ..."
#f_log "Curl State: $sninc_state ..."


    #Validate if ticket was created with output status
        if [ $CURL_STATUS -ne 0 ]; then
          f_log "Failed to create ticket ..."
          #f_log "Curl status from error $curlstatus ..."
          else
            #f_log "Curl status from else $curlstatus ..."
                if [ -z "$SNINC_NUM" ]; then
                    f_log "No need to create ticket, Service is running fine" "green"
                    #f_log "Curl Incident from -z : $SNINC_NUM ..."
                elif  [[ -n "$SNINC_NUM" && "$SNINC_STATE" -eq "1"  ]]; then
                         ticketMsj="Ticket number $SNINC_NUM has been created."
                         f_log "$ticketMsj" "red"
                         entryList+=( "<tr bgColor=$tableBGColorNoOK> <td>$SNINC_NUM</td> <td> " $ticketMsj " </td> </tr>" )
                         echo "$SNINC_NUM" > $inc_lock
                         f_log "Creating lockfile $inc_lock with incident $sninSNINC_NUMc_num" "green"
                        # f_log "Curl Incident from state 1: $SNINC_NUM ..."
                        # f_log "Curl State from state 1: $SNINC_STATE ..."
                elif [[ -n "$SNINC_NUM" && "$SNINC_STATE" -eq "6" ]]; then
                         ticketMsj="Ticket number $SNINC_NUM has been closed."
                         entryList+=( "<tr bgColor=$tableBGColorOK> <td>$SNINC_NUM</td> <td> " $ticketMsj " </td> </tr>" )
                         f_log "$ticketMsj" "green"
                         rm -f $inc_lock
                         f_log "Removing lockfile $inc_lock" "green"
                         #f_log "Curl Incident from state 6: $SNINC_NUM ..."
                         #f_log "Curl State from state 6: $SNINC_STATE ..."
                fi

   fi

}


function f_readerrors()
{

# Check if the file exists
if [ -f "$MY_HOSTNAME_STATUS_DOWN" ]; then
    f_log "Parsing filename: $MY_HOSTNAME_STATUS_DOWN"
    # Parsing file with Client and Environment
    TMP_HOSTS_DOWN=$(mktemp)
    cat $MY_HOSTNAME_STATUS_DOWN | grep $MY_CHECK > "$TMP_HOSTS_DOWN"
    while read line;
                do
                        MY_URL=$(echo "$line" | awk -F ';' '{print $2}' )
						MY_DOWNTIME=$(echo "$line" | awk -F ';' '{print $4}' )
                        #f_log "URL: $MY_URL"
                        #f_log "DOWNTIME: $MY_DOWNTIME"
						if [[ $MY_ALERT_SEC -lt $MY_DOWNTIME ]]; then
						#MY_ALERT_SEC (300) 5m 
						echo "$MY_URL current downtime: $((MY_DOWNTIME/60))m creating ticket ..."
						else
						echo "$MY_URL has been down less than $((MY_ALERT_SEC/60))m current downtime: $((MY_DOWNTIME/60))m"
						fi
        done < "$TMP_HOSTS_DOWN"
#    f_Run_Cmd rm -f "$temp_urlfile"
else
    f_log "Error - File does not exist: $URL_FILE"
    f_log " - END - "
    exit 0
fi

}




################################################################################
# MAIN
################################################################################

case "$1" in
"")
	# called without arguments
	;;
"debug")
	ONLY_OUTPUT_DEBUG_VARIABLES="yes"
	;;
"h" | "help" | "-h" | "-help" | "-?" | *)
	usage 0
	;;
esac

if [[ -n "$ONLY_OUTPUT_DEBUG_VARIABLES" ]]; then
	debug_variables
	exit
fi


f_log "Checking if URL file exist ..."
f_checkfile
f_log "Reading $MY_HOSTNAME_STATUS_DOWN ..."
f_readerrors

# Check term with grep
#MY_CHECK_MD5=$(echo "$MY_CHECK" | md5sum | grep -E -o '[a-z,0-9]+')
#MY_HOSTNAME_STATUS_ALERT="/tmp/status_hostname_alert_$MY_CHECK_MD5"
MY_DOWN_SEC=$(grep "$MY_CHECK" < "$MY_HOSTNAME_STATUS_DOWN" | grep -E -o '[0-9]+$')
#MY_DEGRADED_BEFORE="false"
MY_ALERT_NOW="false"



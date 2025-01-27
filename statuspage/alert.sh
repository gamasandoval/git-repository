#!/usr/bin/env bash

# alert.sh 
# Author: gsandoval
# This script will call create function and SN ticket will be created
#
# The MY_HOSTNAME_STATUS_DOWN downtime file is reviewed to create the tickets.
# The MY_HOSTNAME_STATUS_OK file is reviewed to resolve the tickets.
# If the seconds of the downtime are greater than or equal to the defined seconds MY_ALERT_SEC,
# a ServiceNow ticket will be created.
# Usage: alert.sh 
# Usage: alert.sh debug|help 
#
# Add this script to your crontab. Example:
# */1    * * * * bash alarm.sh 
#

MY_SCRIPT_NAME=$(basename "$0")
BASE_PATH=$(dirname "$0")

################################################################################
#### Configuration Section
################################################################################

# Tip: You can also outsource configuration to an extra configuration file.
#      Just create a file named 'config' at the location of this script.

# if a config file has been specified with MY_STATUS_CONFIG=myfile use this one, otherwise default to config
MY_STATUS_CONFIG="$BASE_PATH/config_status"
MY_STATUS_CONFIG_ALERT="$BASE_PATH/config_alert"
source "$MY_STATUS_CONFIG"
source "$MY_STATUS_CONFIG_ALERT"




# Check if term MY_CHECK can be found in the MY_HOSTNAME_STATUS_DOWN downtime file for failures
#MY_CHECK=${MY_CHECK:-"http-status"}
MY_INC=${MY_INC:-""}

#MY_DATE_TIME=$(date "+%Y-%m-%d %H:%M:%S")
# Example:
#   Check if 'http-status' can be found and save the 805 seconds in MY_DOWN_SEC variable
#   status_hostname_down.txt:
#       http-status;http://ansible-master:8080/index1.html;200;75

# Send notification if downtime is greater than
#MY_ALERT_SEC=${MY_ALERT_SEC:-"100"} # 1 seg

# Location for the downtime status file

#MY_STATUS_CONFIG_DIR="/home/mobaxterm"
#MY_HOSTNAME_STATUS_OK="status_hostname_ok.txt"
#MY_HOSTNAME_STATUS_DOWN="status_hostname_down.txt"


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
	echo "MY_STATUS_CONFIG_DIR: $MY_STATUS_CONFIG_DIR"
	echo "MY_STATUS_CONFIG: $MY_STATUS_CONFIG"
	echo "MY_HOSTNAME_STATUS_OK: $MY_HOSTNAME_STATUS_OK"
	echo "MY_HOSTNAME_STATUS_DOWN: $MY_HOSTNAME_STATUS_DOWN"
	echo "MY_HOSTNAME_STATUS_INC: $MY_HOSTNAME_STATUS_INC"
	echo "MY_HOSTNAME_STATUS_INC_TMP: $MY_HOSTNAME_STATUS_INC_TMP"
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
                                elif [[ "$COLOR" == "red" ]]; then
                                echo -e "$(eval "$MY_DATE"): ${RED}$MSG${CLEAR}"
                else
                echo "This never happens"
                fi

}

function f_checkmaintenance {
	if [ -f "$MY_MAINTENANCE_TEXT_FILE" ]; then
		f_log "Maintenance file $MY_MAINTENANCE_TEXT_FILE exists... Alerts will not be created"
        f_log "END of script"
        exit 0;
	fi
}

function f_cleanfile {
#f_log ""
#f_log "removing content of : $1 "
rm -f "$1"; touch "$1"
}

function f_resetfilefromtmp {
f_log ""
#f_log "removing content of : $1 "
if cp "$MY_HOSTNAME_STATUS_INC_TMP" "$MY_HOSTNAME_STATUS_INC" &> /dev/null; then
		f_log "Copied tmp file to inc and then cleaned the tmp file"
		f_cleanfile "$MY_HOSTNAME_STATUS_INC_TMP"
else
	f_log "Could not reset tmp file "
	exit 1
fi
}

function f_copyincfile {
if cp "$MY_HOSTNAME_STATUS_INC" "$MY_HOSTNAME_STATUS_INC_TMP" &> /dev/null; then
	#f_log "Copied inc file to tmp and then cleaned the incfile"
    f_cleanfile "$MY_HOSTNAME_STATUS_INC"
	else
	f_log "Could not copy file: $MY_HOSTNAME_STATUS_INC "
	exit 1
	fi	
}

function f_createticket {
MY_RANDOM_INC="$((RANDOM%1000))"
#f_log "Ticket created : "INC$MY_RANDOM_INC""
#f_log "from function INC: $MY_INC "
echo "INC$MY_RANDOM_INC"
}

#Function for Sending mails
function f_sendmail {
BODY_MSG=$(cat "${MY_STATUS_HTML}")
if [[ -n "$SEND_MAIL" ]]; then
/usr/sbin/sendmail -a "$RECIPIENTS" <<EOF
subject:$SUBJECT
from:$FROM
to:$RECIPIENTS
Content-Type: text/html
MIME-Version: 1.0

$BODY_MSG

EOF
f_log "email sent from f_sendmail to $RECIPIENTS"	
fi
exit
}

function f_sn_ticket {
#f_log ""
#f_log "Function sn_ticket"

MY_SN_STRING="$1" # remove alternative display textS
MY_SN_URL="${MY_SN_STRING%%|*}"
MY_SN_SEVERITY="$2"
MY_SN_DOWNTIME="$3"
MY_SN_HOST=$(echo $MY_SN_URL | cut -d'/' -f3 | cut -d':' -f1)
MY_SN_APP=$(grep "$MY_SN_URL" "$MY_HOSTNAME_LIST_GROUPS" | awk -F ';' '{print $2}')
MY_SN_AG=$(grep "$MY_SN_URL" "$MY_HOSTNAME_LIST_GROUPS" | awk -F ';' '{print $3}')
MY_SN_DATE=$(echo -e "$(eval "$MY_DATE")")
MY_SN_SHORTDESCRIPTION="$CUSTOMER_SHORTNAME - $INSTANCE - URL down on host $MY_SN_HOST"
MY_SN_DESCRIPTION="URL: $MY_SN_URL has been down for $MY_SN_DOWNTIME segs. Please review or take necessary actions."

#f_log "MY_SN_STRING : $MY_SN_STRING"
#f_log "MY_SN_URL : $MY_SN_URL"
#f_log "APIKEY : $APIKEY"
#f_log "PLATFORM : $PLATFORM"
#f_log "MY_SN_APP : $MY_SN_APP"
#f_log "INSTANCE : $INSTANCE"
#f_log "CUSTOMER_SHORTNAME : $CUSTOMER_SHORTNAME"
#f_log "MY_SN_DATE : $MY_SN_DATE"
#f_log "MY_SN_HOST : $MY_SN_HOST"
#f_log "MY_SN_SHORTDESCRIPTION : $MY_SN_SHORTDESCRIPTION"
#f_log "CUSTOMER : $CUSTOMER"
#f_log "PRIORITY : $PRIORITY"
#f_log "ENVIRONMENT : $ENVIRONMENT"
#f_log "MY_SN_AG : $MY_SN_AG"
#f_log "ENVIRONMENT : $ENVIRONMENT"
#f_log "MY_SN_DESCRIPTION : $MY_SN_DESCRIPTION"
#f_log "MY_SN_SEVERITY : $MY_SN_SEVERITY"
#f_log "ENDPOINT : $ENDPOINT"

MY_SN_CURL=$(curl -s --header "Content-Type: application/json" --header "x-api-key: $APIKEY" --request POST --data '{ "platform": "'$PLATFORM'", "app": "'$MY_SN_APP'", "instance": "'$INSTANCE'", "customer_shortname": "'$CUSTOMER_SHORTNAME'", "date": "'"$MY_SN_DATE"'", "host": "'$MY_SN_HOST'", "servicenow": {"short_description": "'"$MY_SN_SHORTDESCRIPTION"'", "customer": "'"$CUSTOMER"'", "priority" : '$PRIORITY', "environment": "'$ENVIRONMENT'", "assignment_group": "'"$MY_SN_AG"'", "description": "'"$MY_SN_DESCRIPTION"'"}, "severity": "'$MY_SN_SEVERITY'"}' $ENDPOINT)
MY_SN_CURLSTATUS=$?
MY_SN_INC=$(echo -e "$MY_SN_CURL" | grep INC | awk -F ':' '{print $2}' | awk -F',' '{print $1}' | tr -d '"')
MY_SN_STATE=$(echo -e "$MY_SN_CURL" | grep INC | awk -F ':' '{print $3}' | awk -F',' '{print $1}' | tr -d '"')

#f_log "MY_SN_CURL : $MY_SN_CURL"
#f_log "MY_SN_CURLSTATUS : $MY_SN_CURLSTATUS"
#f_log "MY_SN_INC : $MY_SN_INC"
#f_log "MY_SN_STATE : $MY_SN_STATE"

    #Validate if ticket was created with output status
        if [ $MY_SN_CURLSTATUS -ne 0 ]; then
          f_log "Failed to create ticket ..."
		  exit 1;
          else
            if  [[ -n "$MY_SN_INC" && "$MY_SN_STATE" -eq "1" ]]; then
                   echo "$MY_SN_INC"
			elif  [[ -n "$MY_SN_INC" && "$MY_SN_STATE" -eq "6" ]]; then
                   f_log "Ticket $MY_SN_INC has been closed"	   
            fi
	    fi

}

function f_save_incidents() {
	MY_SAVE_COMMAND="$1"
	MY_SAVE_HOSTNAME="$2"
	MY_SAVE_PORT="$3"
	MY_SAVE_DOwNTIME="$4"
    MY_SAVE_INC="$5"
#f_log ""
#f_log "Starting function save_incidents"
#f_log "Saving Line: $MY_SAVE_COMMAND $MY_SAVE_HOSTNAME $MY_SAVE_PORT $MY_SAVE_DOwNTIME $MY_SAVE_INC "
printf "\\n%s;%s;%s;%s;%s" "$MY_SAVE_COMMAND" "$MY_SAVE_HOSTNAME" "$MY_SAVE_PORT" "$MY_SAVE_DOwNTIME" "$MY_SAVE_INC" >> "$MY_HOSTNAME_STATUS_INC"
}

function f_isticketopen() {
	MY_DOWN_HOSTNAME="$1"
	MY_DOWN_HOSTNAME_TICKET=$(grep "$MY_DOWN_HOSTNAME" "$MY_HOSTNAME_STATUS_INC_TMP" | awk -F ';' '{print $5}')
	#f_log ""
	#f_log "Checking if ticket is open"
	LINE=$(grep "$MY_DOWN_HOSTNAME" "$MY_HOSTNAME_STATUS_INC_TMP")
	#f_log "LINE : $LINE"
	#f_log "MY_DOWN_HOSTNAME: $MY_DOWN_HOSTNAME"
	#f_log "MY_DOWN_HOSTNAME_TICKET: $MY_DOWN_HOSTNAME_TICKET"
	if [ -n "$MY_DOWN_HOSTNAME_TICKET" ]; then
		MY_INC="$MY_DOWN_HOSTNAME_TICKET"
		f_log "MY_DOWN_HOSTNAME_TICKET: $MY_INC"
	else
    	#f_log "ticket is empty"   
		MY_INC="" 
	fi
	#f_log ""
	#f_log "End of ticket open"
}

#
# Check and save status
#
function f_read_errors() {
#f_log ""
#f_log "Starting function f_read_errors"
MY_HOSTNAME_COUNT=0
while IFS=';' read -r MY_DOWN_COMMAND MY_DOWN_HOSTNAME_STRING MY_DOWN_PORT MY_DOWN_TIME|| [[ -n "$MY_DOWN_COMMAND" ]]; do
	MY_DOWN_HOSTNAME="${MY_DOWN_HOSTNAME_STRING%%|*}" # remove alternative display textS
    if [[ "$MY_DOWN_COMMAND" = "http-status" ]]; then
		(( MY_HOSTNAME_COUNT++))
		#f_log ""
		#f_log "Line: $MY_HOSTNAME_COUNT "
		# Check status change
		f_log "ERROR Line: $MY_DOWN_COMMAND $MY_DOWN_HOSTNAME_STRING $MY_DOWN_PORT $MY_DOWN_TIME "
		f_isticketopen "$MY_DOWN_HOSTNAME_STRING"

			if [[ $MY_DOWN_TIME -gt $MY_ALERT_SEC && -z $MY_INC ]]; then #50000 & ticket empty
			    f_log "$MY_DOWN_HOSTNAME current downtime: $MY_DOWN_TIME and MY_ALERT_SEC $MY_ALERT_SEC creating ticket ..."
				MY_INC=$(f_sn_ticket "$MY_DOWN_HOSTNAME" "critical" "$MY_DOWN_TIME")
				f_log "New incident created: $MY_INC "
				f_save_incidents "$MY_DOWN_COMMAND" "$MY_DOWN_HOSTNAME_STRING" "$MY_DOWN_PORT" "$MY_DOWN_TIME" "$MY_INC" 
				else
					if [[ $MY_DOWN_TIME -lt $MY_ALERT_SEC  ]]; then
			    	f_log "$MY_URL has been down less than $MY_ALERT_SEC current downtime: $MY_DOWN_TIME"     
						elif [[ -n "$MY_INC" ]]; then
						f_save_incidents "$MY_DOWN_COMMAND" "$MY_DOWN_HOSTNAME_STRING" "$MY_DOWN_PORT" "$MY_DOWN_TIME" "$MY_INC" 
					fi
							
			fi	
    fi        
done <"$MY_HOSTNAME_STATUS_DOWN"
}

function f_read_ok() {
#f_log ""	
#f_log "Starting function f_read_ok"
MY_HOSTNAME_COUNT=0
while IFS=';' read -r MY_OK_COMMAND MY_OK_HOSTNAME_STRING MY_OK_PORT|| [[ -n "$MY_OK_COMMAND" ]]; do
	MY_OK_HOSTNAME="${MY_OK_HOSTNAME_STRING%%|*}" # remove alternative display textS
    if [[ "$MY_OK_COMMAND" = "http-status" ]]; then
		(( MY_HOSTNAME_COUNT++))
		#f_log ""
		#f_log "Line: $MY_HOSTNAME_COUNT "
        f_log "OK Line: $MY_OK_COMMAND $MY_OK_HOSTNAME_STRING $MY_OK_PORT "
		f_isticketopen "$MY_OK_HOSTNAME_STRING"
			if [[ -z "$MY_INC" ]]; then #if ticket is empty
			    f_log "MY_OK_HOSTNAME: $MY_OK_HOSTNAME_STRING is up and no previous ticket"  
				else
            	f_log "MY_OK_HOSTNAME: $MY_OK_HOSTNAME_STRING is up resolving ticket $MY_INC"
				f_sn_ticket "$MY_OK_HOSTNAME_STRING" "clear" ""
				f_save_incidents "$MY_OK_COMMAND" "$MY_OK_HOSTNAME_STRING" "$MY_OK_PORT" "" "" 
				
			fi
			
    fi        
done <"$MY_HOSTNAME_STATUS_OK"
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
"sendmail")
	SEND_MAIL="yes"
	;;
"h" | "help" | "-h" | "-help" | "-?" | *)
	usage 0
	;;
esac

if [[ -n "$ONLY_OUTPUT_DEBUG_VARIABLES" ]]; then
	debug_variables
	exit
fi
f_log ""
f_log "START of script"
f_log ""
f_checkmaintenance
check_file "$MY_HOSTNAME_STATUS_INC"
check_file "$MY_HOSTNAME_STATUS_INC_TMP"
check_config "$MY_HOSTNAME_LIST_GROUPS"
f_copyincfile
f_sendmail
f_read_errors
f_read_ok
f_log ""
f_log "END of script"



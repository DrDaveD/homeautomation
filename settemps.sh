#!/bin/bash
RETRYDELAY=2
MAXTRIES=5

HERE="$(dirname $0)"
ME="$(basename $0 .sh)"
exec >>/var/log/$ME.log 2>&1
echo
echo "Datetime: $(date)"
if [ $# != 2 ]; then
    echo "Usage: $ME heatSetpoint coolSetpoint"
    exit
fi

# Make other scripts wait until we are finished
FLOCKFILE=/dev/shm/homeautomation.flock
exec 3<>$FLOCKFILE
flock 3
# Leave some time for them to catch up so they will run ASAP
# after this script is finished
sleep 3

CURL="curl -sm 15"

REFRESHTOKEN="$(sed -n 's/^refresh_token: //p' $HERE/secrets)"
AUTHORIZATION="$(sed -n 's/^Authorization: //p' $HERE/secrets)"
CLIENTID="$(sed -n 's/^client_id: //p' $HERE/secrets)"
LOCATIONID="$(sed -n 's/^locationID: //p' $HERE/secrets)"
DEVICEID="$(sed -n 's/^deviceID: //p' $HERE/secrets)"
EMAIL="$(sed -n 's/^email: //p' $HERE/secrets)"
TOKENS="$($CURL -X POST -H "Authorization: $AUTHORIZATION" --header "Content-Type: application/x-www-form-urlencoded" -d "grant_type=refresh_token&refresh_token=$REFRESHTOKEN" "https://api.honeywell.com/oauth2/token")"
ACCESSTOKEN="$(echo "$TOKENS"|jq -r .access_token)"

mailmsg()
{
    echo "Mailing to $EMAIL: $*"
    (cat; echo "See /var/log/$ME.log for details")|mail -s "$ME: $*" $EMAIL
}

TRY=0
while true; do
    STATUS="$($CURL -H "Authorization: Bearer $ACCESSTOKEN" "https://api.honeywell.com/v2/devices/thermostats/$DEVICEID?apikey=$CLIENTID&locationId=$LOCATIONID")"
    INDOORTEMP="$(echo "$STATUS"|jq -r .indoorTemperature)"
    if [ -z "$INDOORTEMP" ] || [ "$INDOORTEMP" = null ]; then
	let TRY+=1
	if [ "$TRY" -lt "$MAXTRIES" ]; then
	    echo "Looking up status failed, waiting to try again"
	    sleep $RETRYDELAY
	    continue
	fi
	echo "Failed to read thermostat status after $MAXTRIES tries"|mailmsg "Failed to set temperatures to $1 $2"
	exit
    fi
    break
done

VALUES="$(echo "$STATUS"|jq .changeableValues)"
PRESERVEVALS="heatSetpoint coolSetpoint thermostatSetpointStatus nextPeriodTime mode autoChangeoverActive emergencyHeatActive"
for VAR in $PRESERVEVALS; do
    eval $VAR="\`echo \"\$VALUES\"|jq -r .$VAR\`"
    LASTVAR=$VAR
done

NOCHANGE=true
if [ "$heatSetpoint" != "$1" ]; then
    echo "Changing heatSetpoint from $heatSetpoint to $1"
    heatSetpoint="$1"
    NOCHANGE=false
else
    echo "Leaving heatSetpoint at $1"
fi
if [ "$coolSetpoint" != "$2" ]; then
    echo "Changing coolSetpoint from $coolSetpoint to $2"
    coolSetpoint="$2"
    NOCHANGE=false
else
    echo "Leaving coolSetpoint at $2"
fi
if $NOCHANGE; then
    exit
fi
INPUT="$(
    echo '{'
    COMMA=","
    for VAR in $PRESERVEVALS; do 
	if [ "$VAR" = "$LASTVAR" ]; then
	    COMMA=""
	fi
	eval echo "\"  \\\"$VAR\\\": \\\"\$$VAR\\\"$COMMA\""
    done
    echo '}'
)"
TRY=0
while true; do
    echo "$INPUT"|$CURL -f -X POST -H "Authorization: Bearer $ACCESSTOKEN" -H "Content-Type: application/json" "https://api.honeywell.com/v2/devices/thermostats/$DEVICEID?apikey=$CLIENTID&locationId=$LOCATIONID" -d @-
    RET=$?
    if [ "$RET" = 0 ]; then
	echo Succeeded
	break
    fi
    echo "curl exited with code $RET"
    let TRY+=1
    if [ "$TRY" -lt "$MAXTRIES" ]; then
	echo "Setting temperature failed, waiting to try again"
	sleep $RETRYDELAY
	continue
    fi
    echo "Failed to set thermostat temperatures after $MAXTRIES tries"|mailmsg "Failed to set temperatures to $1 $2"
    exit
done

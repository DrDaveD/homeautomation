#!/bin/bash
MAXPRICE=6
LOWPRICE=4

HERE="$(dirname $0)"
ME="$(basename $0 .sh)"
exec >>/var/log/$ME.log 2>&1
# Wait until other scripts are finished, after giving them a chance to start
sleep 2
FLOCKFILE=/dev/shm/homeautomation.flock
exec 3<>$FLOCKFILE
flock 3

echo
echo "Datetime: $(date)"

CURL="curl -sm 15"

REFRESHTOKEN="$(sed -n 's/^refresh_token: //p' $HERE/secrets)"
AUTHORIZATION="$(sed -n 's/^Authorization: //p' $HERE/secrets)"
CLIENTID="$(sed -n 's/^client_id: //p' $HERE/secrets)"
LOCATIONID="$(sed -n 's/^locationID: //p' $HERE/secrets)"
DEVICEID="$(sed -n 's/^deviceID: //p' $HERE/secrets)"
EMAIL="$(sed -n 's/^email: //p' $HERE/secrets)"
TOKENS="$($CURL -X POST -H "Authorization: $AUTHORIZATION" --header "Content-Type: application/x-www-form-urlencoded" -d "grant_type=refresh_token&refresh_token=$REFRESHTOKEN" "https://api.honeywell.com/oauth2/token")"
ACCESSTOKEN="$(echo "$TOKENS"|jq -r .access_token)"

PRICE="$($CURL "https://hourlypricing.comed.com/api?type=currenthouraverage"|jq -r ".[].price")"
STATUS="$($CURL -H "Authorization: Bearer $ACCESSTOKEN" "https://api.honeywell.com/v2/devices/thermostats/$DEVICEID?apikey=$CLIENTID&locationId=$LOCATIONID")"
INDOORTEMP="$(echo "$STATUS"|jq -r .indoorTemperature)"
OUTDOORTEMP="$(echo "$STATUS"|jq -r .outdoorTemperature)"

echo "Price: $PRICE"
echo "Indoor temperature: $INDOORTEMP"
echo "Outdoor temperature: $OUTDOORTEMP"

MAILEDERROR=false
LASTERROR=false
LASTHIGHPRICE=false
LASTCATCHUP=false
LASTSWITCHERROR=false
if [ -f $HERE/.status ]; then
    . $HERE/.status
fi

HIGHPRICE=$LASTHIGHPRICE
CATCHUP=$LASTCATCHUP
ERROR=false
SWITCHERROR=false
trap '(echo LASTERROR=$ERROR
       echo MAILEDERROR=$MAILEDERROR
       echo LASTHIGHPRICE=$HIGHPRICE
       echo LASTCATCHUP=$CATCHUP
       echo LASTSWITCHERROR=$SWITCHERROR
       ) >$HERE/.status.new && mv $HERE/.status.new $HERE/.status; exit 0' 0
MSG=""
if [ -z "$PRICE" ] || [ "$PRICE" = null ]; then
    ERROR=true
    MSG="Could not look up electricity hourly price"
fi
if [ -z "$INDOORTEMP" ] || [ "$INDOORTEMP" = null ]; then
    ERROR=true
    MSG="Could not look up thermostat status"
fi
mailmsg()
{
    echo "Mailing to $EMAIL: $*"
    (cat; echo "See /var/log/$ME.log for details")|mail -s "$ME: $*" $EMAIL
}
mailprice()
{
    echo "Current electricity price: $PRICE"|mailmsg "$*"
}
if $ERROR; then
    echo "$MSG"
    if $LASTERROR; then
	if ! $MAILEDERROR; then
	    echo "$MSG"|mailmsg "Information unavailable twice"
	    MAILEDERROR=true
	fi
    else
	echo "Not mailing because there weren't yet two errors in a row"
    fi
    echo "STATUS:"
    echo "$STATUS"
    exit
elif ! $LASTERROR; then
    if $MAILEDERROR; then
	mailprice "Information available twice again"
	MAILEDERROR=false
    fi
elif $MAILEDERROR; then
    echo "Information available again but waiting for another cycle"
fi

if [[ "${PRICE%.*}" -ge "$MAXPRICE" ]]; then
    HIGHPRICE=true
elif $HIGHPRICE && [[ "${PRICE%.*}" -lt "$LOWPRICE" ]]; then
    HIGHPRICE=false
fi
echo "HIGHPRICE: $HIGHPRICE"

VALUES="$(echo "$STATUS"|jq .changeableValues)"
PRESERVEVALS="heatCoolMode heatSetpoint coolSetpoint thermostatSetpointStatus nextPeriodTime"
for VAR in mode emergencyHeatActive autoChangeoverActive $PRESERVEVALS; do
    eval $VAR="\`echo \"\$VALUES\"|jq -r .$VAR\`"
    eval echo "\$VAR: \$$VAR"
done

let TEMPDIFF="$heatSetpoint - $INDOORTEMP"
if $LASTCATCHUP; then
    if [ $TEMPDIFF -le 0 ]; then
	CATCHUP=false
    fi
else
    if [ $TEMPDIFF -ge 2 ]; then
	CATCHUP=true
    fi
fi
echo "CATCHUP: $CATCHUP"

if [ "$HIGHPRICE" = "$LASTHIGHPRICE" ]; then
    echo "No change in HIGHPRICE mode"
    if [ "$CATCHUP" = "$LASTCATCHUP" ]; then
	echo "No change in CATCHUP mode"
	exit
    fi
fi

if [ "$heatCoolMode" != Heat ] || [ $TEMPDIFF -le -2 ] ; then
    # don't turn on emergency heat when in cool mode or more than 2
    # degrees over heat set point
    if [ "$HIGHPRICE" != "$LASTHIGHPRICE" ]; then
	if $HIGHPRICE; then 
	    mailprice "Electricity price has exceeded $MAXPRICE"
	else
	    mailprice "Electricity price is low again"
	fi
    fi
    if [ "$CATCHUP" = "$LASTCATCHUP" ]; then
	exit
    fi
fi

if [ "$HIGHPRICE" != "$LASTHIGHPRICE" ]; then
    if $HIGHPRICE; then
	mailprice "Switching on emergency heat"
    else
	mailprice "Switching off emergency heat"
    fi
else
    # must be a catchup mode transition
    if $CATCHUP; then
	echo "Switching on emergency heat"
    else
	echo "Switching off emergency heat"
    fi
fi
INPUT="$(
    echo '{'
    for VAR in $PRESERVEVALS; do 
	eval echo "\"  \\\"$VAR\\\": \\\"\$$VAR\\\",\""
    done
    if $HIGHPRICE || $CATCHUP; then
	echo '  "mode": "EmergencyHeat",'
	echo '  "autoChangeoverActive": false,'
	echo '  "emergencyHeatActive": true'
    else
	echo '  "mode": "Auto",'
	echo '  "autoChangeoverActive": true,'
	echo '  "emergencyHeatActive": false'
    fi
    echo '}'
)"
echo "$INPUT"|$CURL -f -X POST -H "Authorization: Bearer $ACCESSTOKEN" -H "Content-Type: application/json" "https://api.honeywell.com/v2/devices/thermostats/$DEVICEID?apikey=$CLIENTID&locationId=$LOCATIONID" -d @-
if [ "$?" != 0 ]; then
    SWITCHERROR=true
    if $LASTSWITCHERROR; then
	echo "Switching thermostat mode failed again"
    else
	mailprice "Switching thermostat mode failed"
    fi
    HIGHPRICE=$LASTHIGHPRICE
    CATCHUP=$LASTCATCHUP
fi

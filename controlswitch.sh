#!/bin/bash
# For ComEd hourly pricing and
# Delivery Time of Day with a json file created with comed-rates.js
# Controls Shelly Plug US Gen 4
# Written by Dave Dykstra, 11/11/26

MAXPRICE=18
LOWPRICE=10

HERE="$(dirname $0)"
ME="$(basename $0 .sh)"
exec >>/var/log/$ME.log 2>&1

echo
echo "Datetime: $(date)"

EMAIL="$(sed -n 's/^user: //p' $HERE/secrets)"
USER="$(sed -n 's/^user: //p' $HERE/secrets)"
PASSWORD="$(sed -n 's/^password: //p' $HERE/secrets)"
API="$(sed -n 's/^api: //p' $HERE/secrets)"
DTODPATH="$(sed -n 's/^dtodpath: //p' $HERE/secrets)"

CURL="curl -sm 15"
HOURLYPRICE="$($CURL "https://hourlypricing.comed.com/api?type=currenthouraverage"|jq -r ".[].price")"

export PASSWORD
CURL="$CURL --variable %PASSWORD --digest --expand-user "$USER:{{PASSWORD}}""

SYSSTATUS="$($CURL "$API/Sys.GetStatus")"
UPTIME="$(echo "$SYSSTATUS"|jq -r .uptime)"
RESET_REASON="$(echo "$SYSSTATUS"|jq -r .reset_reason)"
SWITCHSTATUS="$($CURL "$API/Switch.GetStatus?id=0")"
POWEREDON="$(echo "$SWITCHSTATUS"|jq -r .output)"
POWER="$(echo "$SWITCHSTATUS"|jq -r .apower)"
ENERGY="$(echo "$SWITCHSTATUS"|jq -r .aenergy.total)"

TOD=""
case $(date +%H) in
    6|7|8|9|10|11|12)     TOD="morning";;
    13|14|15|16|17|18)    TOD="mid_day_peak";;
    19|20)                TOD="evening";;
    21|22|23|0|1|2|3|4|5) TOD="overnight";;
esac

DTODPRICE="$(jq -r .rates.$TOD $DTODPATH)"
PRICE="$(awk 'BEGIN{print int(0.5 + '$DTODPRICE' + '$HOURLYPRICE')}')"

echo "Hourly Price: $HOURLYPRICE"
echo "TOD: $TOD"
echo "DTOD Price: $DTODPRICE"
echo "Price: $PRICE"
echo "Uptime: $UPTIME"
echo "Reset reason: $RESET_REASON"
echo "Powered on: $POWEREDON"
echo "Power: $POWER"
echo "Energy: $ENERGY"

MAILEDERROR=false
LASTERROR=false
LASTHIGHPRICE=false
LASTSWITCHERROR=false
if [ -f $HERE/.status ]; then
    . $HERE/.status
fi

HIGHPRICE=$LASTHIGHPRICE
ERROR=false
SWITCHERROR=false
trap '(echo LASTERROR=$ERROR
       echo MAILEDERROR=$MAILEDERROR
       echo LASTHIGHPRICE=$HIGHPRICE
       echo LASTSWITCHERROR=$SWITCHERROR
       ) >$HERE/.status.new && mv $HERE/.status.new $HERE/.status; exit 0' 0
MSG=""
if [ -z "$HOURLYPRICE" ] || [ "$HOURLYPRICE" = null ]; then
    ERROR=true
    MSG="Could not look up electricity hourly price"
fi
if [ -z "$POWEREDON" ] || [ "$POWEREDON" = null ]; then
    ERROR=true
    MSG="Could not look up switch status"
fi
mailmsg()
{
    echo "Mailing to $EMAIL: $*"
    (cat; echo "See /var/log/$ME.log for details")|mail -s "$ME: $*" $EMAIL
}
mailprice()
{
    echo "Current electricity (hourly + DTOD) price: $PRICE"|mailmsg "$*"
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

if [ "$HIGHPRICE" = "$LASTHIGHPRICE" ]; then
    echo "No change in HIGHPRICE mode"
    exit
fi

ON=""
if $HIGHPRICE; then
    mailprice "Switching off power"
    ON=false
else
    mailprice "Switching on power"
    ON=true
fi
$CURL -f "$API/Switch.Set?id=0&on=$ON"
if [ "$?" != 0 ]; then
    SWITCHERROR=true
    if $LASTSWITCHERROR; then
	echo "Switching switch mode failed again"
    else
	mailprice "Switching switch mode failed"
    fi
    HIGHPRICE=$LASTHIGHPRICE
fi
echo

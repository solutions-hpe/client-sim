#!/bin/bash
version=.01
echo --------------------------| tee /usr/local/scripts/sim.log
echo System Monitor Script Version $version | tee -a /usr/local/scripts/sim.log
echo $(date) | tee -a /usr/local/scripts/sim.log
echo --------------------------| tee -a /usr/local/scripts/sim.log
LOG_FILE="/var/log/messages"  # Replace with the actual log file path
KEYWORD="kernel"  # Replace with the message to trigger the reboot

tail -f $LOG_FILE | while read LOGLINE; do
    if [[ "$LOGLINE" == *"$KEYWORD"* ]]; then
        echo "Failure message Found" | tee -a /usr/local/scripts/sim.log
        echo "Rebooting system" | tee -a /usr/local/scripts/sim.log
        sudo systemctl reboot
    fi
done
exit

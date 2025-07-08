#!/bin/bash
version=.03
echo --------------------------| tee /usr/local/scripts/sim_reboot.log
echo System Monitor Script Version $version | tee -a /usr/local/scripts/sim_reboot.log
echo $(date) | tee -a /usr/local/scripts/sim_reboot.log
echo --------------------------| tee -a /usr/local/scripts/sim_reboot.log
LOG_FILE="/var/log/messages"  # Replace with the actual log file path
KEYWORD="Call Trace:"  # Replace with the message to trigger the reboot

tail -f $LOG_FILE | while read LOGLINE; do
    if [[ "$LOGLINE" == *"$KEYWORD"* ]]; then
        echo "Failure message Found" | tee -a /usr/local/scripts/sim_reboot.log
        echo "Rebooting system" | tee -a /usr/local/scripts/sim_reboot.log
        sudo systemctl --force reboot
    fi
done
exit

#!/bin/bash
version=.03
log_file="/var/log/messages"  # Replace with the actual log file path
error_search="Call Trace:"  # Replace with the message to trigger the reboot
tail -f $log_file | while read logline; do
    if [[ "$logline" == *"$error_search"* ]]; then
        echo "Failure message Found" | tee -a /usr/local/scripts/sim_reboot.log
        echo "Rebooting system" | tee -a /usr/local/scripts/sim_reboot.log
        echo $(date) | tee -a /usr/local/scripts/sim_reboot.log
        echo --------------------------| tee -a /usr/local/scripts/sim_reboot.log
        reboot
    fi
done
exit

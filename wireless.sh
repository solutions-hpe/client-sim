#!/bin/bash
echo "Script Version .05" | tee /usr/scripts/wireless.log
echo "Starting Wireless Simulations" | tee -a /usr/scripts/wireless.log
#Scheduled Reboot
sudo shutdown -r +45000
sudo ifconfig enp6s18 down
sudo ifconfig wlp6s16 down
#--------------------------------------------------------------------------------------------------------
#Start  Loop for 12 hours then reboot
 for (( x = 1; x <= 360; x++ ))
  do
   echo "Starting DHCPCD Daemon" | tee -a /usr/scripts/wireless.log
   sudo dhcpcd -b
   sudo ifconfig enp6s18 down
   echo "Killing WPA Supplicant" | tee -a /usr/scripts/wireless.log
   sudo pkill wpa_supplicant
   echo "Starting Main Loop " $x | tee -a /usr/scripts/wireless.log
   echo "Step 1 - Shutting down interfaces" | tee -a /usr/scripts/wireless.log
   echo "Starting WPA Supplicant" | tee -a /usr/scripts/wireless.log
   #Loop to Shutdown Adapters
   for (( h = 1; h <= 9; h++ ))
    do
     echo "Starting WPA Supplicant" 
     sudo wpa_supplicant -c /etc/wpa.conf -B -i vwlan$h
     sleep 2
     sudo wpa_supplicant -c /etc/wpa.conf -B -i vwlan1$h
     sleep 2
     #Bringing all Interfaces down
     #echo "Shutting down interface " vwlan$h 
     #sudo ifconfig vwlan$h down
     #sleep 2
     #echo "Shutting down interface " vwlan1$h 
     #sudo ifconfig vwlan1$h down
     #sleep 2
    done
   sudo ifconfig enp6s18 down
   active=$((RANDOM%19+1))
   #Generate a random number to select a random interface to bring online
   #Only 1 interface can pass traffic at a time
   echo "Step 1 - Bringing up random interface" | tee -a /usr/scripts/wireless.log
   echo "Active WLAN Interface " vlwan$active | tee -a /usr/scripts/wireless.log
   sudo ifconfig vwlan$active up
   echo "Waiting 60 seconds" | tee -a /usr/scripts/wireless.log
   echo "connecting to WiFi" | tee -a /usr/scripts/wireless.log
   sleep 60
#--------------------------------------------------------------------------------------------------------  
   echo "Running DHCP Simulation" | tee -a /usr/scripts/wireless.log
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan1 -c 60,str,"MercurySD" -l 0103061c
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan2 -c 60,str,"LiftMaster" -l 0103061c
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan3 -c 60,str,"RingDevice" -l 0103061c
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan4 -c 60,str,"AppleIPad" -l 060301790f6c7277fc
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan5 -c 60,str,"SamsungTV" -l 0103061c
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan6 -c 60,str,"SONOS" -l 0103061c
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan7 -c 60,str,"Hewlett-Packard JetDirect" -l 0603010f42430d2c770c51fc
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan8 -c 60,str,"PolycomIPPhone" -l 0103061c
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan9 -c 60,str,"AXIS,NetworkCamera,P3375-V,7.25.1.1" -l 0103061afc2a0f0c
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan11 -c 60,str,"AppleIPhone" -l 0103061c
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan12 -c 60,str,"RingDevice" -l 0103061c
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan13 -c 60,str,"Resideo" -l 010306
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan14 -c 60,str,"BarcoShare" -l 0103061afc2a0f0c
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan15 -c 60,str,"WePresentGW" -l 0103061afc2a0f0c
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan16 -c 60,str,"DensitySensor" -l 0103061afc2a0f0c
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan17 -c 60,str,"Meta OculusVR" -l 0103061afc2a0f0c
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan18 -c 60,str,"Tesla,Inc" -l 0103061afc2a0f0c
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan19 -c 60,str,"udhcp 1.4.2" -l 0103060c0f1c28292a7d
#--------------------------------------------------------------------------------------------------------
   echo "Step 2 - Starting Interfaces" | tee -a /usr/scripts/wireless.log
   for (( h = 1; h <= 9; h++ ))
    do
     #Bringing up all interfaces after a random interface was selected to pass traffic (First Interface Online)
     echo "Bringing up interface " vwlan$h 
     sudo ifconfig vwlan$h up
     sleep 2
     echo "Bringing up interface " vwlan1$h 
     sudo ifconfig vwlan1$h up
     sleep 2
    done
#--------------------------------------------------------------------------------------------------------   
   echo "Running DHCP Simulation" | tee -a /usr/scripts/wireless.log
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan1 -c 60,str,"MercurySD" -l 01061c
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan2 -c 60,str,"LiftMaster" -l 01061c
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan3 -c 60,str,"RingDevice" -l 01061c
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan4 -c 60,str,"AppleIPad" -l 0601790f6c7277fc
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan5 -c 60,str,"SamsungTV" -l 01061c
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan6 -c 60,str,"SONOS" -l 01061c
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan7 -c 60,str,"Hewlett-Packard JetDirect" -l 06010f42430d2c770c51fc
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan8 -c 60,str,"PolycomIPPhone" -l 01061c
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan9 -c 60,str,"AXIS,NetworkCamera,P3375-V,7.25.1.1" -l 01061afc2a0f0c
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan11 -c 60,str,"AppleIPhone" -l 01061c
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan12 -c 60,str,"RingDevice" -l 01061c
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan13 -c 60,str,"Resideo" -l 0106
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan14 -c 60,str,"BarcoShare" -l 01061afc2a0f0c
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan15 -c 60,str,"WePresentGW" -l 01061afc2a0f0c
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan16 -c 60,str,"DensitySensor" -l 01061afc2a0f0c
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan17 -c 60,str,"Meta OculusVR" -l 01061afc2a0f0c
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan18 -c 60,str,"Tesla,Inc" -l 01061afc2a0f0c
   sudo /usr/scripts/dhtest/dhtest -V -f -i vwlan19 -c 60,str,"udhcp 1.4.2" -l 01060c0f1c28292a7d
#--------------------------------------------------------------------------------------------------------
   echo "Step 3 - Resetting Routes" | tee -a /usr/scripts/wireless.log
   for (( h = 1; h <= 9; h++ ))
    do
     #Bringing up all interfaces after a random interface was selected to pass traffic (First Interface Online)
     echo "Changing route metric on interface " vwlan$h 
     sudo ifmetric vwlan$h 1000+$h
     sleep 2
     echo "Changing route metric on interface " vwlan1$h 
     sudo ifmetric vwlan$h 1010+$h
     sleep 2
    done
    echo "Setting Primary Interface to " vwlan1$h
    echo "Changing route metric on interface " vwlan1$h
    sudo ifmetric vwlan$active 10
#--------------------------------------------------------------------------------------------------------  
  sudo ifconfig enp6s18 down 
  echo "Step 3 - Running Simulations" | tee -a /usr/scripts/wireless.log
  #Loop to run tests
  case "$active" in
   1)
     echo "Running MercurySD Simulations" | tee -a /usr/scripts/wireless.log
     ;;
   2)
     echo "Running LiftMaster Simulations" | tee -a /usr/scripts/wireless.log
     dig connect-ca.myqdevice.com
     curl --insecure -o /tmp/liftmaster.file https://40.117.182.120:8883
     curl --insecure -o /tmp/liftmaster.file https://connect-ca.myqdevice.com:8883
     ;;
   3)
     echo "Running RING Simulations" | tee -a /usr/scripts/wireless.log
     sleep 5
     dig ec2-3-235-249-68.prd.rings.solutions
     dig api.prod.signalling.ring.devices.a2z.com
     dig alexa.na.gateway.devices.a2z.com
     dig spectrum.s3.amazonaws.com
     dig api.amazon.com
     dig amzn-sidewalk-events-us-east-1-prod.s3.amazonaws.com
     dig stickupcammini.devices.prod.rss.ring.amazon.dev
     dig fw-eventstream.ring.com
     curl -o /tmp/ring.file https://api.prod.signalling.ring.devices.a2z.com
     curl -o /tmp/ring.file https://alexa.na.gateway.devices.a2z.com
     curl -o /tmp/ring.file http://spectrum.s3.amazonaws.com
     curl -o /tmp/ring.file https://api.amazon.comonaws.com
     curl -o /tmp/ring.file https://api.amazon.com
     curl -o /tmp/ring.file https://amzn-sidewalk-events-us-east-1-prod.s3.amazonaws.com
     curl -o /tmp/ring.file https://fw-eventstream.ring.com
     ping -c 600 10.0.0.10
     ;;
   4)
     echo "Running iPad Simulations" | tee -a /usr/scripts/wireless.log
     ;;
   5)
     echo "Running SamsungTV Simulations" | tee -a /usr/scripts/wireless.log
     ;;
   6)
     echo "Running SONOS Simulations" | tee -a /usr/scripts/wireless.log
     dig onn-i-09007be6d9db10869-us-east-1.lechmere.prod.ws.sonos.com
     dig feature-config.sslauth.sonos.com
     curl --insecure -o /tmp/sonos.file https://conn-i-09007be6d9db10869-us-east-1.lechmere.prod.ws.sonos.com
     curl -o /tmp/sonos.file https://feature-config.sslauth.sonos.com
     ping -c 600 feature-config.sslauth.sonos.com
     ;;
   7)
     echo "Running HPPrinter Simulations" | tee -a /usr/scripts/wireless.log
     ;;
   8)
     echo "Running PolycomIPPhone Simulations" | tee -a /usr/scripts/wireless.log
     ;;
   9)
     echo "Running AxisNetCam Simulations" | tee -a /usr/scripts/wireless.log
     ;;
   11)
     echo "Running AppleIPhone Simulations" | tee -a /usr/scripts/wireless.log
     ;;
   12)
     echo "Running Ring Simulations" | tee -a /usr/scripts/wireless.log
     ;;
   13)
     echo "Running Resideo Simulations" | tee -a /usr/scripts/wireless.log
     dig lcc-prodsf-lcc03sf-iothub.azure-devices.net
     dig weather02.clouddevice.io
     curl -o /tmp/resideo.file http://lcc-prodsf-lcc03sf-iothub.azure-devices.net:5671
     curl -o /tmp/resideo.file https://weather02.clouddevice.io
     ping -c 600 weather02.clouddevice.io
     ;;
   14)
     echo "Running BarcoShare Simulations" | tee -a /usr/scripts/wireless.log
     ;;
   15)
     echo "Running WePresentGW Simulations" | tee -a /usr/scripts/wireless.log
     ;;
   16)
     echo "Running DensitySensor Simulations" | tee -a /usr/scripts/wireless.log
     ;;
   17)
     echo "Running OculusVR Simulations" | tee -a /usr/scripts/wireless.log
     ;;
   18)
     echo "Running Tesla Simulations" | tee -a /usr/scripts/wireless.log
     curl --insecure -o /tmp/tesla.file https://x3-prod.obs.tesla.com
     curl --insecure -o /tmp/tesla.file https://hermes-prd.ap.tesla.services
     curl --insecure -o /tmp/tesla.file https://maps-prd.go.tesla.services
     curl --insecure -o /tmp/tesla.file https://telemetry-prd.vn.tesla.services
     ;;
   19)
     echo "Running Crestron Simulations" | tee -a /usr/scripts/wireless.log
     dig api.my.crestron.com
     dig fc.crestron.io
     ping -c 5 5.161.114.106
     ping -c 5 16.110.135.52
     ping -c 5 16.110.135.51
     ;;
  esac
#--------------------------------------------------------------------------------------------------------  
  echo "Generating DNS Traffic &" | tee -a /usr/scripts/wireless.log
  echo "ICMP for Central Stats" | tee -a /usr/scripts/wireless.log
  for (( i = 1; i <= 9; i++ ))
   do
   #Generating DNS Traffic for stats in Central
   nslookup www.microsoft.com 8.8.8.8 
   nslookup www.nbc.com 1.1.1.1
   nslookup www.aol.com 9.9.9.9
   nslookup www.apple.com 10.0.0.10
   nslookup www.hpe.com 10.0.0.10
   nslookup www.vmware.com 10.0.0.10
   #Traffic for stats in central - ICMP and random file downloads
   ping -c 10 10.0.0.10
   sudo ifconfig enp6s18 up
   sleep 30
   echo "Updating Simulation Script" | tee -a /usr/scripts/wireless.log 
   sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/wireless.sh -O /tmp/wireless.sh
   #Checking to see if the file downloaded from GitHub is 0 Bytes, if so deleting it as the download failed
   sudo find /tmp -type f -size 0 | sudo xargs -r -o rm -v -f
   sudo mv -f /tmp/wireless.sh /usr/scripts/wireless.sh
   sudo chmod 777 /usr/scripts/wireless.sh
   sudo ifconfig enp6s18 down
   echo "Simulation Script Sleeping" | tee -a /usr/scripts/wireless.log 
  done
  #sudo dhcpcd -k
  sudo ifconfig enp6s18 down
done
sudo reboot now

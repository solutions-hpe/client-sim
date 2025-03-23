#!/bin/bash
echo "Script Version .16" | tee /usr/scripts/wireless.log
echo "Starting Wireless Simulations" | tee -a /usr/scripts/wireless.log
#Scheduled Reboot
sudo shutdown -r +45000
sudo ifconfig enp6s18 down
sudo ifconfig wlp6s16 down
#--------------------------------------------------------------------------------------------------------
 for (( x = 1; x <= 5; x++ ))
  do
   echo "Starting DHCPCD Daemon" | tee -a /usr/scripts/wireless.log
   sudo dhcpcd
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
    done
   sudo ifconfig enp6s18 down
   active=$((RANDOM%19+1))
   #Generate a random number to select a random interface to bring online
   echo "Active WLAN Interface " vlwan$active | tee -a /usr/scripts/wireless.log
   echo "Waiting for network Connection" | tee -a /usr/scripts/wireless.log
   sleep 120
#--------------------------------------------------------------------------------------------------------   
   echo "Step 2 - Running DHCP Simulation" | tee -a /usr/scripts/wireless.log
   sudo dhcpcd -h MercurySD -i Mercury -o 1,3,6 vwlan1
   sudo dhcpcd -h Liftmaster -i Automation -o 1,3,6 vwlan2
   sudo dhcpcd -h Ring -i RingDevice -o 1,3,6 vwlan3
   sudo dhcpcd -h iPad -i Apple -o 1,3,6 vwlan4
   sudo dhcpcd -h Samsung -i SamsungTV -o 1,3,6 vwlan5
   sudo dhcpcd -h SONOS -i SonosAudio -o 1,3,6 vwlan6
   sudo dhcpcd -h HPPrinter -i HPJetDirect -o 1,3,6 vwlan7
   sudo dhcpcd -h PolyCom -i IPPhone -o 1,3,6 vwlan8
   sudo dhcpcd -h AxisCam -i AxisSecurity -o 1,3,6 vwlan9
   sudo dhcpcd -h MacBook -i Apple -o 1,3,6 vwlan11
   sudo dhcpcd -h Ring -i RingDevice -o 1,3,6 vwlan12
   sudo dhcpcd -h Resideo -i TempControl -o 1,3,6 vwlan13
   sudo dhcpcd -h BarcoShare -i Barco -o 1,3,6 vwlan14
   sudo dhcpcd -h WePresentGW -i Presentation -o 1,3,6 vwlan15
   sudo dhcpcd -h Desnity -i Sensor -o 1,3,6 vwlan16
   sudo dhcpcd -h Oculus -i MetaVR -o 1,3,6 vwlan17
   sudo dhcpcd -h Tesla -i Automobile -o 1,3,6 vwlan18
   sudo dhcpcd -h Crestron -i Conference -o 1,3,6 vwlan19
   #DHTest Code not working right
   #sudo /usr/scripts/dhtest/dhtest -t 15 -i vwlan2 -h LiftMaster -c 60,str,"LiftMaster" -c 55,hex,0103061c
   #sudo /usr/scripts/dhtest/dhtest -t 15 -i vwlan3 -h RingDevice -c 60,str,"RingDevice" -c 55,hex,0103061c
   #sudo /usr/scripts/dhtest/dhtest -t 15 -i vwlan4 -h AppleIPad -c 60,str,"AppleIPad" -c 55,hex,010306796c0f7277fc
   #sudo /usr/scripts/dhtest/dhtest -t 15 -i vwlan5 -h SamsungTV -c 60,str,"SamsungTV" -c 55,hex,0103061c
   #sudo /usr/scripts/dhtest/dhtest -t 15 -i vwlan6 -h SONOS -c 60,str,"SONOS" -c 55,hex,0103061c
   #sudo /usr/scripts/dhtest/dhtest -t 15 -i vwlan7 -h HPPrinter -c 60,str,"Hewlett-Packard JetDirect" -c 55,hex,06010f42430d2c770c51fc
   #sudo /usr/scripts/dhtest/dhtest -t 15 -i vwlan8 -h Polycom -c 60,str,"PolycomIPPhone" -c 55,hex,0103061c
   #sudo /usr/scripts/dhtest/dhtest -t 15 -i vwlan9 -h Axis -c 60,str,"AXIS,NetworkCamera,P3375-V,7.25.1.1" -c 55,hex,0103061afc2a0f0c
   #sudo /usr/scripts/dhtest/dhtest -t 15 -i vwlan11 -h AppleMAC -c 60,str,"AppleMAC" -c 55,hex,017903060f6c7277fc5f2c2e
   #sudo /usr/scripts/dhtest/dhtest -t 15 -i vwlan12 -h RingDevice -c 60,str,"RingDevice" -c 55,hex,0103061c
   #sudo /usr/scripts/dhtest/dhtest -t 15 -i vwlan13 -h Resideo -c 60,str,"Resideo" -c 55,hex,010306
   #sudo /usr/scripts/dhtest/dhtest -t 15 -i vwlan14 -h BarcoShare -c 60,str,"BarcoShare" -c 55,hex,0103061afc2a0f0c
   #sudo /usr/scripts/dhtest/dhtest -t 15 -i vwlan15 -h WePresentGW -c 60,str,"WePresentGW" -c 55,hex,0103061afc2a0f0c
   #sudo /usr/scripts/dhtest/dhtest -t 15 -i vwlan16 -h Density -c 60,str,"DensitySensor" -c 55,hex,0103061afc2a0f0c
   #sudo /usr/scripts/dhtest/dhtest -t 15 -i vwlan17 -h Oculus -c 60,str,"Meta OculusVR" -c 55,hex,0103061afc2a0f0c
   #sudo /usr/scripts/dhtest/dhtest -t 15 -i vwlan18 -h Tesla -c 60,str,"Tesla,Inc" -c 55,hex,0103061afc2a0f0c
   #sudo /usr/scripts/dhtest/dhtest -t 15 -i vwlan19 -h Crestron -c 60,str,"udhcp 1.4.2" -c 55,hex,0103060c0f1c28292a7d
#--------------------------------------------------------------------------------------------------------
   echo "Step 3 - Resetting Routes" | tee -a /usr/scripts/wireless.log
   for (( h = 1; h <= 9; h++ ))
    do
     #Bringing up all interfaces after a random interface was selected to pass traffic (First Interface Online)
     echo "Changing route metric on interface " vwlan$h 
     sudo ifmetric vwlan$h 1000
     sleep 2
     echo "Changing route metric on interface " vwlan1$h 
     sudo ifmetric vwlan1$h 1010
     sleep 2
    done
   echo "Setting Primary Interface to " vwlan1$h
   echo "Changing route metric on interface " vwlan1$h
   sudo ifmetric vwlan$active 20
#--------------------------------------------------------------------------------------------------------  
   sudo ifconfig enp6s18 down 
   echo "Step 4 - Running Simulations" | tee -a /usr/scripts/wireless.log
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
      wget -r -l 2 -np -k http://www.liftmaster.com/
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
      wget -r -l 2-np -k http://ring.com/
      ping -c 600 10.0.0.10
     ;;
    4)
      echo "Running iPad Simulations" | tee -a /usr/scripts/wireless.log
      wget -r -l 2 -np -k http://www.apple.com/
     ;;
    5)
      echo "Running SamsungTV Simulations" | tee -a /usr/scripts/wireless.log
      wget -r -l 2 -np -k http://www.samsung.com/
     ;;
    6)
      echo "Running SONOS Simulations" | tee -a /usr/scripts/wireless.log
      dig onn-i-09007be6d9db10869-us-east-1.lechmere.prod.ws.sonos.com
      dig feature-config.sslauth.sonos.com
      curl --insecure -o /tmp/sonos.file https://conn-i-09007be6d9db10869-us-east-1.lechmere.prod.ws.sonos.com
      curl -o /tmp/sonos.file https://feature-config.sslauth.sonos.com
      ping -c 600 feature-config.sslauth.sonos.com
      wget -r -l 2 -np -k http://www.sonos.com/
     ;;
    7)
      echo "Running HPPrinter Simulations" | tee -a /usr/scripts/wireless.log
     ;;
    8)
      echo "Running PolycomIPPhone Simulations" | tee -a /usr/scripts/wireless.log
      wget -r -l 2 -np -k https://www.hp.com/us-en/poly.html
     ;;
    9)
      echo "Running AxisNetCam Simulations" | tee -a /usr/scripts/wireless.log
     ;;
    11)
      echo "Running AppleIPhone Simulations" | tee -a /usr/scripts/wireless.log
     ;;
    12)
      echo "Running Ring Simulations" | tee -a /usr/scripts/wireless.log
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
  done
#--------------------------------------------------------------------------------------------------------  
 sudo ifconfig enp6s18 up
 sleep 30
 sudo ifmetric enp6s18 10
 echo "Updating Simulation Script" | tee -a /usr/scripts/wireless.log 
 sudo wget https://raw.githubusercontent.com/solutions-hpe/client-sim/main/wireless.sh -O /tmp/wireless.sh
 #Checking to see if the file downloaded from GitHub is 0 Bytes, if so deleting it as the download failed
 sudo find /tmp -type f -size 0 | sudo xargs -r -o rm -v -f
 sudo mv -f /tmp/wireless.sh /usr/scripts/wireless.sh
 sudo chmod 777 /usr/scripts/wireless.sh
 sudo apt remove isc-dhcp-client -y
 sudo ifconfig enp6s18 down
 echo "Simulation Script Sleeping" | tee -a /usr/scripts/wireless.log 
 sudo ifconfig enp6s18 down
done
bash /usr/scripts/wireless.sh

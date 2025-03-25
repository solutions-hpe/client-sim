#!/bin/bash
scriptver=".44"
echo "Script Version " $scriptver | tee /usr/scripts/wireless.log
echo "Starting DHCP Daemon" | tee -a /usr/scripts/wireless.log
sudo dhcpcd --inactive
#System level changes - checking at every start
#Shutting down the MDNS responder
sudo systemctl stop avahi-daemon.socket avahi-daemon.service
sudo systemctl disable avahi-daemon.socket avahi-daemon.service
#Disabling IPV6 system wide
echo 'blacklist ipv6' | sudo tee -a '/etc/modprobe.d/blacklist.local' >/dev/null
#Disabling parent WLAN Adapter for simulation
sudo ifconfig wlp6s16 down
#Clearing out any WPA supplicant configuration
echo "Killing WPA Supplicant" | tee -a /usr/scripts/wireless.log
sudo pkill wpa_supplicant
echo "Waiting for Network Connection" | tee -a /usr/scripts/wireless.log
sleep 30
echo "Starting WPA Supplicant" | tee -a /usr/scripts/wireless.log
#Loop to Shutdown Adapters
for (( h = 1; h <= 9; h++ ))
 do
  echo "Starting WPA Supplicant"
  sudo wpa_supplicant -c /etc/wpa.conf -B -i vwlan$h
  sudo wpa_supplicant -c /etc/wpa.conf -B -i vwlan1$h
 done
echo "Waiting for network connection" | tee -a /usr/scripts/wireless.log
echo "Sleeping for 5 minutes" | tee -a /usr/scripts/wireless.log
sleep 300
echo "Starting DHCP Simulation"
sudo dhcpcd -h MercurySD -i Mercury -o 1,3,6 vwlan1
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
#Variable for how long to wait for HTTP/HTTPS timeout in wget command
httpretry=1
#Variable for how many recursive directories WGET attempts to download
httpdepth=1
#Variable for how long to wait for IP address after running dhcpcd command before running simulation
dhcpsleep=15
#--------------------------------------------------------------------------------------------------------
 for (( x = 1; x <= 5; x++ ))
  do
   active=$((RANDOM%19+1))
   #Generate a random number to select a random interface to bring online
   echo "Script Version " $scriptver | tee /usr/scripts/wireless.log
   echo "Active WLAN Interface " vlwan$active | tee -a /usr/scripts/wireless.log
   echo "Set random interface" | tee -a /usr/scripts/wireless.log 
   ip a | grep NO-CARRIER
   ip route | grep "metric 20"
   sudo dhcpcd -k vwlan$active
   sleep $dhcpsleep
#--------------------------------------------------------------------------------------------------------  
   echo "Running Simulations" | tee -a /usr/scripts/wireless.log
   #Loop to run tests
   case "$active" in
    1)
      sudo dhcpcd -h MercurySD -i "dhcpcd-5.5.6:Mercury-6.99.5:i386:i386" -o 1,3,6 -m 20 vwlan1
      echo "Waiting for network connection" | tee -a /usr/scripts/wireless.log
      sleep $dhcpsleep
      sudo ifmetric vwlan$active 20
      echo "Running MercurySD Simulations" | tee -a /usr/scripts/wireless.log
     ;;
    2)
      sudo dhcpcd -h Liftmaster -i "dhcpcd-5.5.6:busybox-6.99.5:i386:i386" -o 1,3,6 -m 20 vwlan2
      echo "Waiting for network connection" | tee -a /usr/scripts/wireless.log
      sleep $dhcpsleep
      sudo ifmetric vwlan$active 20
      echo "Running LiftMaster Simulations" | tee -a /usr/scripts/wireless.log
      dig connect-ca.myqdevice.com
      curl --insecure -o /tmp/liftmaster.file https://40.117.182.120:8883
      curl --insecure -o /tmp/liftmaster.file https://connect-ca.myqdevice.com:8883
      wget -r -t $httpretry -l $httpdepth -np --delete-after --random-wait -e robots=off -k https://www.liftmaster.com/
     ;;
    3)
      sudo dhcpcd -h BrightSign -i "BrightSign XT1144" -o 1,3,6,12,15,26,28,33,42,43,51,58,59,119,121 -m 20 vwlan3
      echo "Waiting for network connection" | tee -a /usr/scripts/wireless.log
      sleep $dhcpsleep
      sudo ifmetric vwlan$active 20
      echo "Running BrightSign Simulations" | tee -a /usr/scripts/wireless.log
      sleep 5
     ;;
    4)
      sudo dhcpcd -h iPad -i "darwin-6.99.5:i386:i386" -o 1,3,6 -m 20 vwlan4
      echo "Waiting for network connection" | tee -a /usr/scripts/wireless.log
      sleep $dhcpsleep
      sudo ifmetric vwlan$active 20
      echo "Running iPad Simulations" | tee -a /usr/scripts/wireless.log
      wget -r -t $httpretry -l $httpdepth -np --delete-after --random-wait -e robots=off -k https://www.apple.com/
     ;;
    5)
      sudo dhcpcd -h Samsung -i "dhcpcd-5.5.6:linux-6.99.5:i386:i386" -o 1,3,6 -m 20 vwlan5
      echo "Waiting for network connection" | tee -a /usr/scripts/wireless.log
      sleep $dhcpsleep
      sudo ifmetric vwlan$active 20
      echo "Running SamsungTV Simulations" | tee -a /usr/scripts/wireless.log
      wget -r -t $httpretry -l $httpdepth -np --delete-after --random-wait -e robots=off -k https://www.samsung.com/
     ;;
    6)
      sudo dhcpcd -h SONOS -i "dhcpcd-5.5.6:SONOS-6.99.5:i386:i386" -o 1,3,6 -m 20 vwlan6
      echo "Waiting for network connection" | tee -a /usr/scripts/wireless.log
      sleep $dhcpsleep
      sudo ifmetric vwlan$active 20
      echo "Running SONOS Simulations" | tee -a /usr/scripts/wireless.log
      dig onn-i-09007be6d9db10869-us-east-1.lechmere.prod.ws.sonos.com
      dig feature-config.sslauth.sonos.com
      curl --insecure -o /tmp/sonos.file https://conn-i-09007be6d9db10869-us-east-1.lechmere.prod.ws.sonos.com
      curl -o /tmp/sonos.file https://feature-config.sslauth.sonos.com
      ping -c 600 feature-config.sslauth.sonos.com
      wget -r -t $httpretry -l $httpdepth -np --delete-after --random-wait -e robots=off -k https://www.sonos.com/
     ;;
    7)
      sudo dhcpcd -h HPPrinter -i "Hewlett-Packard JetDirect" -o 1,3,6 -m 20 vwlan7
      echo "Waiting for network connection" | tee -a /usr/scripts/wireless.log
      sleep $dhcpsleep
      sudo ifmetric vwlan$active 20
      echo "Running HPPrinter Simulations" | tee -a /usr/scripts/wireless.log
     ;;
    8)
      sudo dhcpcd -h PolyCom -i "dhcpcd-5.2.10:Linux-2.6.37+:armv7l:ti8168evm" -o 1,3,6 -m 20 vwlan8
      echo "Waiting for network connection" | tee -a /usr/scripts/wireless.log
      sleep $dhcpsleep
      sudo ifmetric vwlan$active 20
      echo "Running PolycomIPPhone Simulations" | tee -a /usr/scripts/wireless.log
      #wget -r -l $httpwait -np --delete-after --random-wait -e robots=off -k https://www.hp.com/us-en/poly.html
     ;;
    9)
      sudo dhcpcd -h AxisCam -i "Axis,Dome Camera,P3265-LV,10.12.165" -o 1,3,6 -m 20 vwlan9
      echo "Waiting for network connection" | tee -a /usr/scripts/wireless.log
      sleep $dhcpsleep
      sudo ifmetric vwlan$active 20
      echo "Running AxisNetCam Simulations" | tee -a /usr/scripts/wireless.log
     ;;
    11)
      sudo dhcpcd -h MacBook -i "darwin" -o 1,3,6 -m 20 vwlan11
      echo "Waiting for network connection" | tee -a /usr/scripts/wireless.log
      sleep $dhcpsleep
      sudo ifmetric vwlan$active 20
      echo "Running AppleIPhone Simulations" | tee -a /usr/scripts/wireless.log
      wget -r -t $httpretry -l $httpdepth -np --delete-after --random-wait -e robots=off -k https://www.apple.com/
     ;;
    12)
      sudo dhcpcd -h Ring -i "busybox" -o 1,3,6 -m 20 vwlan12
      echo "Waiting for network connection" | tee -a /usr/scripts/wireless.log
      sleep $dhcpsleep
      sudo ifmetric vwlan$active 20
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
      wget -r -t $httpretry -l $httpdepth -np --delete-after --random-wait -e robots=off -k https://ring.com/
      ;;
    13)
      sudo dhcpcd -h Resideo -i "bsd-kernel:6.9.9" -o 1,3,6 -m 20 vwlan13
      echo "Waiting for network connection" | tee -a /usr/scripts/wireless.log
      sleep $dhcpsleep
      sudo ifmetric vwlan$active 20
      echo "Running Resideo Simulations" | tee -a /usr/scripts/wireless.log
      dig lcc-prodsf-lcc03sf-iothub.azure-devices.net
      dig weather02.clouddevice.io
      curl -o /tmp/resideo.file http://lcc-prodsf-lcc03sf-iothub.azure-devices.net:5671
      curl -o /tmp/resideo.file https://weather02.clouddevice.io
      wget -r -t $httpretry -l $httpdepth -np --delete-after --random-wait -e robots=off -k https://www.resideo.com/
     ;;
    14)
      sudo dhcpcd -h BarcoShare -i "Barco-linux-bsd:6.9.9" -o 1,3,6 -m 20 vwlan14
      echo "Waiting for network connection" | tee -a /usr/scripts/wireless.log
      sleep $dhcpsleep
      sudo ifmetric vwlan$active 20
      echo "Running BarcoShare Simulations" | tee -a /usr/scripts/wireless.log
     ;;
    15)
      sudo dhcpcd -h WePresentGW -i "udhcp 0.9.9-pre" -o 1,3,6 -m 20 vwlan15
      echo "Waiting for network connection" | tee -a /usr/scripts/wireless.log
      sleep $dhcpsleep
      sudo ifmetric vwlan$active 20
      echo "Running WePresentGW Simulations" | tee -a /usr/scripts/wireless.log
     ;;
    16)
      sudo dhcpcd -h Desnity -i "Density Device" -o 1,3,6 -m 20 vwlan16
      echo "Waiting for network connection" | tee -a /usr/scripts/wireless.log
      sleep $dhcpsleep
      sudo ifmetric vwlan$active 20
      echo "Running DensitySensor Simulations" | tee -a /usr/scripts/wireless.log
     ;;
    17)
      sudo dhcpcd -h Oculus -i "android-dhcp-12" -o 1,3,6 -m 20 vwlan17
      echo "Waiting for network connection" | tee -a /usr/scripts/wireless.log
      sleep $dhcpsleep
      sudo ifmetric vwlan$active 20
      echo "Running OculusVR Simulations" | tee -a /usr/scripts/wireless.log
      wget -r -t $httpretry -l $httpdepth -np --delete-after --random-wait -e robots=off -k https://www.meta.com/
     ;;
    18)
      sudo dhcpcd -h Tesla -i "tesla-busybox-1.9.9" -o 1,3,6 -m 20 vwlan18
      echo "Waiting for network connection" | tee -a /usr/scripts/wireless.log
      sleep $dhcpsleep
      sudo ifmetric vwlan$active 20
      echo "Running Tesla Simulations" | tee -a /usr/scripts/wireless.log
      curl --insecure -o /tmp/tesla.file https://x3-prod.obs.tesla.com
      curl --insecure -o /tmp/tesla.file https://hermes-prd.ap.tesla.services
      curl --insecure -o /tmp/tesla.file https://maps-prd.go.tesla.services
      curl --insecure -o /tmp/tesla.file https://telemetry-prd.vn.tesla.services
      #wget -r -t $httpretry -l $httpdepth -np --delete-after --random-wait -e robots=off -k https://www.tesla.com/
     ;;
    19)
      sudo dhcpcd -h Crestron -i "freebsd-kernel:3.9.1" -o 1,3,6 -m 20 vwlan19
      echo "Waiting for network connection" | tee -a /usr/scripts/wireless.log
      sleep $dhcpsleep
      sudo ifmetric vwlan$active 20
      echo "Running Crestron Simulations" | tee -a /usr/scripts/wireless.log
      dig api.my.crestron.com
      dig fc.crestron.io
      wget -r -t $httpretry -l $httpdepth -np --delete-after --random-wait -e robots=off -k https://www.crestron.com/
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
  done
#--------------------------------------------------------------------------------------------------------
#Resetting DHCP Status on all interfaces
 sudo dhcpcd -k vwlan$active
 sleep 2
 sudo dhcpcd -x
 sleep 2
 sudo dhcpcd --inactive
 sleep 2
 sudo dhcpcd -h MercurySD -i Mercury -o 1,3,6 vwlan1
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
done
bash /usr/scripts/update_script.sh

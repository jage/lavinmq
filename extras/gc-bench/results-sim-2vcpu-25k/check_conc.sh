#!/bin/bash
# Artifact check: the 5-minute runs lose ~1,500 connections to TCP keepalive timeouts 90 s after
# the storm. Rerun main with 50 handshakes in flight instead of 500 and compare the kernel's listen
# overflow and keepalive abort counters.
res=$(cd "$(dirname "$0")" && pwd)
ov() { awk '/^TcpExt:/{if(!h){split($0,k);h=1}else{split($0,v); for(i in k) if(k[i]=="ListenOverflows"||k[i]=="TCPAbortOnTimeout") printf "%s=%s ", k[i], v[i]}}' /proc/net/netstat; echo; }
echo "before $(ov)" > $res/check-conc50.txt
CONC=25 $res/run_sim.sh main $SCRATCH/runs/check-conc50-main 150 >> $res/check-conc50.txt
echo "after $(ov)" >> $res/check-conc50.txt
echo "keepalive-timeout disconnects (duration 1:3x): $(grep -c 'duration=00:01:3' $SCRATCH/runs/check-conc50-main/broker.log)" >> $res/check-conc50.txt
echo "connections per scrape: $(awk '{print $5}' $SCRATCH/runs/check-conc50-main/scrapes.txt | tr '\n' ' ')" >> $res/check-conc50.txt

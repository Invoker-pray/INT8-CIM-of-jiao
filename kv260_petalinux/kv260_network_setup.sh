#!/bin/bash
# Run on PC side: enable NAT so KV260 can access internet through PC
# KV260 default IP: 192.168.2.99
sudo sysctl -w net.ipv4.ip_forward=1
IFACE=$(ip route | grep default | awk '{print $5}')
sudo iptables -t nat -A POSTROUTING -o "$IFACE" -j MASQUERADE
sudo iptables -A FORWARD -j ACCEPT
echo "KV260: ssh root@192.168.2.99  (default IP)"
echo "SCP:  scp file root@192.168.2.99:/home/root/"

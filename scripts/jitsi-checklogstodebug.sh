#!/bin/bash

echo "=== Prosody ==="
systemctl status prosody --no-pager

echo
echo "=== Jicofo ==="
systemctl status jicofo --no-pager

echo
echo "=== Videobridge ==="
systemctl status jitsi-videobridge2 --no-pager

echo
echo "=== Ports ==="
ss -tulpn | grep 10000

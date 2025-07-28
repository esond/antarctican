#!/bin/bash

# Define variables
days_from=0
days_to=2 
host_ip=192.168.1.100
qbittorrent_port=8080
user="your_user"
password="your_password"
cache_mount="/mnt/cache"

# Notify start
/usr/local/emhttp/plugins/dynamix/scripts/notify -s "qBittorrent Mover" -d "qBittorrent Mover starting @ $(date +%H:%M:%S)."

# Run the mover script
echo "Executing script to pause torrents and run mover."
python3 /mnt/user/data/scripts/mover.py \
    --host "$host_ip:$qbittorrent_port" \
    --user "$user" \
    --password "$password" \
    --cache-mount "$cache_mount" \
    --days_from "$days_from" \
    --days_to "$days_to"

# Notify completion
echo "qBittorrent-mover completed and resumed all paused torrents."
/usr/local/emhttp/plugins/dynamix/scripts/notify -s "qBittorrent Mover" -d "qBittorrent Mover completed @ $(date +%H:%M:%S)."

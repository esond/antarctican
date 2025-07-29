#!/bin/bash

# Replace with the name of the share you want to clean.
share_name="data"

# Notify start
/usr/local/emhttp/plugins/dynamix/scripts/notify \
  -s "Clean empty directories" \
  -d "Empty directory cleaner starting @ $(date +%H:%M:%S)."

for disk_path in /mnt/disk[0-9]*; do
  # Skip non-directories, if they were to exist for some reason.
  [ -d "$disk_path" ] || continue

  target_path="$disk_path/$share_name"

  echo "Deleting empty directories from $target_path..."
  
  # `find` can only delete empty directories, so this should be safe.
  [ -d "$target_path" ] && find "$target_path" -type d -empty -print
  
  # Uncomment this line to actually delete the directories
  # [ -d "$target_path" ] && find "$target_path" -type d -empty -print -delete
done

# Notify end
/usr/local/emhttp/plugins/dynamix/scripts/notify \
  -s "Clean empty directories" \
  -d "Empty directory cleaner finished @ $(date +%H:%M:%S)."

#!/bin/bash


# TODO:

# Get monitor resolution
monitor_info=$(xrandr --listmonitors | awk '/^[ ]/ {print $4}')

# Parse monitor information
IFS=$'\n'
monitors=()
for line in $monitor_info; do
    monitors+=("$line")
done

# Open Firefox windows on each monitor
for monitor in "${monitors[@]}"; do
    # Parse monitor resolution
    width=$(echo "$monitor" | cut -d'/' -f1 | cut -d'x' -f1)
    height=$(echo "$monitor" | cut -d'/' -f1 | cut -d'x' -f2)
    
    # Calculate Firefox window position
    x=$((width / 4))  # adjust as needed
    y=$((height / 4)) # adjust as needed
    width=$((width / 2))  # adjust as needed
    height=$((height / 2)) # adjust as needed
    
    # Open Firefox window on current monitor
    firefox &
    sleep 1  # Adjust as needed to give Firefox time to open
    xdotool search --sync --onlyvisible --class "firefox" windowmove --sync $x $y windowsize --sync $width $height
done

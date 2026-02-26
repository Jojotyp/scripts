#!/bin/sh
# original script that gets executed on user login is in ~/.config/autostart-scripts/ or in ~/.config/old-autostart-scripts/

# script for the Linux Debian Lenovo ThinkPad P50 Laptop to load providers for graphics correctly:
# NVIDIA for external displays
# Intel ("modesetting") for internal display

# $ xrandr --listproviders
# Providers: number : 2
# Provider 0: id: 0x42 cap: 0xf, Source Output, Sink Output, Source Offload, Sink Offload crtcs: 3 outputs: 1 associated providers: 1 name:modesetting
# Provider 1: id: 0x29c cap: 0x2, Sink Output crtcs: 4 outputs: 6 associated providers: 1 name:NVIDIA-G0

xrandr --setprovideroutputsource NVIDIA-G0 modesetting
xrandr --auto

#!/usr/bin/env bash
# record_selected_window.sh

source "/home/fabi/Programming/scripts/utils/bash_utils.sh"

window_to_record() {
    echo "Click the window you want to record..."
    win=$(xdotool selectwindow)           # you click the target window
    eval "$(xdotool getwindowgeometry --shell $win)"
    # now WIDTH, HEIGHT, X, Y are set

    echo "Stop recording by pressing q or CTRL+C in the terminal window"
    echo "Recording window id $win (${WIDTH}x${HEIGHT}+${X},${Y}) to $out"
    seperator "-" 100
}

out=~/Videos/window_$(date +%Y%m%d-%H%M%S).mkv

seperator "-" 100

if confirm_default_yes "Record audio?"; then
    window_to_record
    ffmpeg -video_size ${WIDTH}x${HEIGHT} -framerate 25 -f x11grab -i :0.0+${X},${Y} \
       -f pulse -i default -c:v libx264 -preset veryfast -crf 18 "$out"
else
    window_to_record
    ffmpeg -video_size ${WIDTH}x${HEIGHT} -framerate 25 -f x11grab -i :0.0+${X},${Y} \
       -f pulse -i default -c:v libx264 -preset veryfast -crf 18 -an "$out"
fi

# echo "Click the window you want to record..."
# win=$(xdotool selectwindow)           # you click the target window
# eval "$(xdotool getwindowgeometry --shell $win)"
# # now WIDTH, HEIGHT, X, Y are set

# echo "Stop recording by pressing q or CTRL+C in the terminal window"
# echo "Recording window id $win (${WIDTH}x${HEIGHT}+${X},${Y}) to $out"


# ffmpeg -video_size ${WIDTH}x${HEIGHT} -framerate 25 -f x11grab -i :0.0+${X},${Y} \
#        -f pulse -i default -c:v libx264 -preset veryfast -crf 18 "$out"

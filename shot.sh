#!/bin/bash
# usage: shot.sh view out.png [w h]
G=/tmp/claude-0/-home-user-minis-pro/13675e20-5bb0-5214-96c6-047f001eab07/scratchpad/godot/Godot_v4.4.1-stable_linux.x86_64
P=$(dirname "$0")
W=${3:-1280}; H=${4:-720}
timeout 600 xvfb-run -a -s "-screen 0 ${W}x${H}x24" $G --path $P --rendering-driver vulkan --resolution ${W}x${H} -- --view=$1 --shot=$2 2>&1 | grep -E "SCRIPT ERROR|ERROR|Parse|at:" | grep -v -E "alsa|audio" | head -30

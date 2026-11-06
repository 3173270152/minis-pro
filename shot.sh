#!/bin/bash
# usage: shot.sh view out.png [extra user args...]
G=/tmp/claude-0/-home-user-minis-pro/13675e20-5bb0-5214-96c6-047f001eab07/scratchpad/godot/Godot_v4.4.1-stable_linux.x86_64
P=$(dirname "$0"); V=$1; O=$2; shift 2
timeout 900 xvfb-run -a -s "-screen 0 1280x720x24" $G --path $P --rendering-driver vulkan --resolution 1280x720 -- --view=$V --shot=$O "$@" 2>&1 | grep -E "SCRIPT ERROR|at: GD|Parse" | head -20

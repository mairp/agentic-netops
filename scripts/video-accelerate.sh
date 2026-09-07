#!/usr/bin/env bash
# Speed up a silent screen recording by an integer factor, re-encoding for
# GitHub playback: video-accelerate.sh <in.mp4> <out.mp4> [factor=6]
# Frames are dropped, not blended, so text stays crisp; audio (none) is dropped.
set -euo pipefail
in=${1:?input mp4}; out=${2:?output mp4}; f=${3:-6}
ffmpeg -y -v error -i "$in" -an -vf "setpts=PTS/${f}" -r 30 \
  -c:v libx264 -preset slow -crf 22 -pix_fmt yuv420p -movflags +faststart "$out"
ffprobe -v error -show_entries format=duration,size:stream=width,height -of default=nw=1 "$out"

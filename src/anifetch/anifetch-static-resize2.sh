#!/bin/bash

FRAME_DIR="$HOME/.local/share/anifetch/output"
STATIC_TEMPLATE_FILE="$HOME/.local/share/anifetch/template.txt"

# check for num of args
if [[ $# -ne 6 && $# -ne 7 && $# -ne 8 ]]; then
  echo "Usage: $0 <framerate> <top> <left> <right> <bottom> <template_actual_width> [soundname] [--key-exit]"
  exit 1
fi

framerate=$1
top=$2
left=$3
right=$4
bottom=$5
template_actual_width=$6
soundname=$7

# Check if key-exit functionality is enabled
key_exit_enabled=false
if [[ "${!#}" == "--key-exit" ]]; then
  key_exit_enabled=true
fi

num_lines=$((bottom - top))
sleep_time=$(echo "scale=4; 1 / $framerate" | bc)
adjusted_sleep_time=$(echo "$sleep_time / $num_lines" | bc -l)

# Buffer for storing processed template, only compute when necessary
declare -a template_buffer
# last terminal width
last_term_width=0

# Hide cursor
tput civis

# Global variable to store the pressed key
pressed_key=""

# exit handler
cleanup() {
  tput cnorm         # Show cursor
  if [ -t 0 ]; then
    stty echo        # Restore echo
    stty icanon
  fi
  tput sgr0          # Reset terminal attributes
  
  cursor_pos=$((bottom + 5))
  tput cup $cursor_pos 0
  
  # Echo the captured key in background after a delay (only if key-exit is enabled)
  if [ "$key_exit_enabled" = true ] && [ -n "$pressed_key" ]; then
    wtype "$pressed_key"
  fi
  
  exit 0
}
trap cleanup SIGINT SIGTERM
stty -echo  # won't allow ^C to be printed when SIGINT signal comes.
stty -icanon

# Process the template once and store in memory buffer
process_template() {
  local term_width=$(tput cols)

  # Only reprocess if terminal width has changed
  if [ "$term_width" -ne "$last_term_width" ]; then
    # Clear the buffer
    template_buffer=()

    # Make sure we're working with a valid width
    if [ "$term_width" -lt 1 ]; then
      term_width=1
    fi

    # Process each line and store in buffer
    local line_num=0
    while IFS= read -r line || [ -n "$line" ]; do
      # Process the line and store in buffer
      template_buffer[$line_num]=$(truncate_line "$line" "$term_width")
      ((line_num++))
    done < "$STATIC_TEMPLATE_FILE"

    # Update the last terminal width
    last_term_width=$term_width
  fi
}

# Function to truncate a line while preserving the ANSI color codes
truncate_line() {
  local line="$1"
  local max_width="$2"

  # Don't process empty lines
  if [ -z "$line" ]; then
    echo -n ""
    return
  fi

  # Remove ANSI codes to get visible text length
  local stripped=$(printf "%b" "$line" | sed 's/\x1b\[[0-9;]*m//g')

  # Calculate visible length while also considering Unicode characters
  local visible_length=$(printf "%b" "$stripped" | wc -m)

  if [ "$visible_length" -le "$max_width" ]; then
    # Line is already short so add terminal control to prevent wrapping
    printf "%b\r" "$line"
  else
    # keep ANSI codes while truncating
    local result=""
    local current_length=0
    local i=0
    local char
    local in_escape=0
    local escape_sequence=""

    while [ $current_length -lt "$max_width" ] && [ $i -lt ${#line} ]; do
      char="${line:$i:1}"

      if [ $in_escape -eq 1 ]; then
        escape_sequence+="$char"
        if [[ "$char" =~ [a-zA-Z] ]]; then
          # End of escape sequence
          result+="$escape_sequence"
          escape_sequence=""
          in_escape=0
        fi
      else
        if [ "$char" = $'\e' ]; then
          # Start of escape sequence
          escape_sequence="$char"
          in_escape=1
        else
          result+="$char"
          ((current_length++))
        fi
      fi

      ((i++))
    done

    # Add any remaining escape sequences
    if [ -n "$escape_sequence" ]; then
      result+="$escape_sequence"
    fi

    # Add reset code at the end for proper termination
    result+="\033[0m"

    # prevent wrapping
    printf "%b\r" "$result"
  fi
}

# Draw the static template
draw_static_template() {
  # Process template first
  process_template

  # Clear screen and position cursor
  tput clear
  tput cup $top 0

  # Print the buffer in one go(faster than one by line)
  for line in "${template_buffer[@]}"; do
    # Clear to end of line before printing to eliminate any potential artifacts
    tput el
    printf "%b\n" "$line"
  done
}

resize_requested=false
resize_in_progress=false
resize_delay=0.2  # seconds
last_resize_time=0

on_resize() {
  resize_requested=true
}

process_resize_if_needed() {
  current_time=$(date +%s.%N)

  # If we're already processing a resize, don't start working on another one
  if [ "$resize_in_progress" = true ]; then
    return
  fi

  if [ "$resize_requested" = false ]; then
    return
  fi

  # Check if enough time has passed since last resize
  if [ "$last_resize_time" != "0" ]; then
    time_diff=$(echo "$current_time - $last_resize_time" | bc)
    if (( $(echo "$time_diff < $resize_delay" | bc -l) )); then
      # Not enough time has passed, wait more
      return
    fi
  fi

  # we can process
  resize_in_progress=true
  resize_requested=false
  last_resize_time=$current_time

  new_width=$(tput cols)
  new_height=$(tput lines)

  # calculate the new template
  process_template

  tput clear
  tput cup $top 0

  # Print buffer all at once with terminal control codes to prevent wrapping
  for line in "${template_buffer[@]}"; do
    # First clear to end of line to ensure no artifacts
    tput el
    printf "%b\n" "$line"
  done

  # Reset flag
  resize_in_progress=false
}

# Trap the SIGWINCH signal (window size change)
trap 'on_resize' SIGWINCH

# Initial draw
draw_static_template

# Start audio if sound is provided
if [ $# -eq 7 ]; then
  ffplay -nodisp -autoexit -loop 0 -loglevel quiet "$soundname" &
fi

i=1
wanted_epoch=0
start_time=$(date +%s.%N)
while true; do
  # Check for any key press (non-blocking) - only if key-exit is enabled
  if read -t 0 -n 1 pressed_key && [ "$key_exit_enabled" = true ]; then
    cleanup
  fi
  
  for frame in $(ls "$FRAME_DIR" | sort -n); do
    lock=true
    current_top=$top
    while IFS= read -r line; do
        tput cup "$current_top" "$left"
        echo -ne "$line"
        current_top=$((current_top + 1))
        if [[ $current_top -gt $bottom ]]; then
            break
        fi
    done < "$FRAME_DIR/$frame"
    lock=false
    
    wanted_epoch=$(echo "$i/$framerate" | bc -l)

    # current time in seconds (with fractional part)
    now=$(date +%s.%N)

    # Calculate how long to sleep to stay in sync
    sleep_duration=$(echo "$wanted_epoch - ($now - $start_time)" | bc -l)

    # Only sleep if ahead of schedule
    if [ "$key_exit_enabled" = true ]; then
      if (( $(echo "$sleep_duration > 0" | bc -l) )); then
          # Check for key press during sleep
          if read -t "$sleep_duration" -n 1 pressed_key; then
              cleanup
          fi
      else
          # Check for key press (non-blocking)
          if read -t 0 -n 1 pressed_key; then
              cleanup
          fi
      fi
    else
      # If key-exit is not enabled, just sleep normally
      if (( $(echo "$sleep_duration > 0" | bc -l) )); then
          sleep "$sleep_duration"
      fi
    fi

    i=$((i + 1))
    
    process_resize_if_needed
  done
  sleep 0.005
done

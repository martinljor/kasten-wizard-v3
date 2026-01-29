#!/usr/bin/env bash
set -u

# =========================
# CONFIG
# =========================
PANEL_WIDTH=80
PANEL_HEIGHT=14        
CONSOLE_MARGIN=2   
PANEL_TOP=2  

# =========================
# COLORS
# =========================
BG_GREEN="\033[42m"
BG_RED="\033[41m"
FG_BLACK="\033[30m"
FG_WHITE="\033[97m"
RESET="\033[0m"

# =========================
# TERMINAL HELPERS
# =========================
cols() { tput cols; }
lines() { tput lines; }

hide_cursor() { tput civis; }
show_cursor() { tput cnorm; }

panel_left() {
  local term_cols
  term_cols=$(cols)
  echo $(( (term_cols - PANEL_WIDTH) / 2 ))
}

panel_top() {
  local term_lines
  term_lines=$(lines)
  echo $(( (term_lines - PANEL_HEIGHT) / 2 ))
}


panel_bottom() {
  echo $((PANEL_HEIGHT))
}

console_top() {
  echo $((PANEL_HEIGHT + CONSOLE_MARGIN))
}

# =========================
# PANEL DRAW
# =========================
draw_green_panel() {
  local left
  left=$(panel_left)

  for ((r=0; r<PANEL_HEIGHT; r++)); do
    tput cup "$((PANEL_TOP + r))" "$left"
    printf "${BG_GREEN}%*s${RESET}" "$PANEL_WIDTH" ""
  done
}

draw_red_panel() {
  local left
  left=$(panel_left)

  for ((r=0; r<PANEL_HEIGHT; r++)); do
    tput cup "$((PANEL_TOP + r))" "$left"
    printf "${BG_RED}%*s${RESET}" "$PANEL_WIDTH" ""
  done
}

clear_console_area() {
  local start end cols
  start=$(console_top)
  end=$(lines)
  cols=$(cols)

  for ((r=start; r<end; r++)); do
    tput cup "$r" 0
    printf "%*s" "$cols" ""
  done
}

disable_terminal_input() { stty -echo; }
enable_terminal_input() { stty echo; }

# =========================
# PRINT HELPERS (PANEL)
# =========================
print_green_line() {
  local text="$1"
  local row="$2"
  local left
  left=$(panel_left)

  tput cup "$row" "$((left + 2))"
  printf "${BG_GREEN}${FG_BLACK} %-*s ${RESET}" "$((PANEL_WIDTH - 4))" "$text"
}

print_red_line() {
  local text="$1"
  local row="$2"
  local left
  left=$(panel_left)

  tput cup "$row" "$((left + 2))"
  printf "${BG_RED}${FG_WHITE} %-*s ${RESET}" "$((PANEL_WIDTH - 4))" "$text"
}

# =========================
# PRINT HELPERS (CONSOLE)
# =========================
print_console() {
  local text="$1"
  tput cup "$(console_top)" 0
  echo "$text"
}

# =========================
# CONFIRM START
# =========================
confirm_start() {
  hide_cursor
  clear
  draw_green_panel
  disable_terminal_input

 local row=$((PANEL_TOP + 2))
  print_green_line "KASTEN LAB INSTALLATION" "$row"; ((row+=2))
  print_green_line "This process will install and configure" "$row"; ((row++))
  print_green_line "a local Kasten lab environment." "$row"; ((row+=2))
  print_green_line "Once started, the process MUST NOT" "$row"; ((row++))
  print_green_line "be interrupted." "$row"; ((row+=2))
  print_green_line "Do you want to continue? (yes/no)" "$row"; ((row+=2))

  local left
  left=$(panel_left)
  tput cup "$row" "$((left + 2))"
  printf "${BG_GREEN}${FG_BLACK}> ${RESET}"

  read -r answer
  enable_terminal_input

  case "$answer" in
    yes|YES) return 0 ;;
    no|NO)
      clear
      draw_green_panel
      print_green_line "Installation aborted by user." 6
      show_cursor
      exit 0
      ;;
    *)
      clear
      draw_green_panel
      print_red_line "Invalid answer. Please run the installer again." 6
      show_cursor
      exit 1
      ;;
  esac
}

# =========================
# STEP SCREEN
# =========================
draw_step() {
  local step="$1"
  local total="$2"
  local title="$3"
  local percent="$4"

  hide_cursor
  clear
  draw_green_panel
  
local row=$((PANEL_TOP + 2))
  print_green_line "KASTEN LAB INSTALLATION" "$row"; ((row+=2))
  print_green_line "STEP $step / $total" "$row"; ((row++))
  print_green_line "$title" "$row"; ((row+=2))

  local bar_width=40
  local filled=$((percent * bar_width / 100))
  local bar
  bar=$(printf "%-${filled}s" "#" | tr ' ' '#')
  bar="${bar}$(printf "%-$((bar_width - filled))s" " ")"

  print_green_line "[${bar}] ${percent}%" "$row"; ((row+=2))
  print_green_line "WARNING: DO NOT INTERRUPT THIS PROCESS - WAIT!" "$row"
}

# =========================
# ERROR SCREEN
# =========================
draw_error() {
  local step="$1"
  local total="$2"
  local title="$3"
  local log="$4"

  hide_cursor
  clear
  draw_red_panel

  local row=$((PANEL_TOP + 2))

  print_red_line "KASTEN LAB INSTALLATION" "$row"; ((row+=2))
  print_red_line "STEP $step / $total" "$row"; ((row++))
  print_red_line "$title" "$row"; ((row+=2))
  print_red_line "EXECUTION FAILED" "$row"; ((row+=2))
  print_red_line "See log file:" "$row"; ((row++))
  print_red_line "$log" "$row"

  # Zona negra inferior (mensajes)
  tput cup "$((PANEL_TOP + PANEL_HEIGHT + 1))" 2
  echo -e "\033[31mERROR: execution failed. Check logs above.\033[0m"

  show_cursor
  exit 1
}

draw_abort() {
  local step="$1"
  local total="$2"
  local title="$3"

  hide_cursor
  clear
  draw_red_panel

  local row=$((PANEL_TOP + 3))
  print_red_line "KASTEN LAB INSTALLATION" "$row"; ((row+=2))
  print_red_line "STEP $step / $total" "$row"; ((row++))
  print_red_line "$title" "$row"; ((row+=2))
  print_red_line "Execution was interrupted by user." "$row"; ((row+=2))
  print_red_line "No further actions were executed." "$row"

  tput cup "$((PANEL_TOP + PANEL_HEIGHT + 1))" 2
  echo -e "\033[33mABORTED by user (Ctrl+C)\033[0m"

  show_cursor
}



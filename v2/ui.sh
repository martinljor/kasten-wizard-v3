#!/usr/bin/env bash
set -u

# =========================
# CONFIG
# =========================
PANEL_WIDTH=80

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

# =========================
# PANEL DRAW
# =========================
draw_green_panel() {
  local rows left
  rows=$(lines)
  left=$(panel_left)

  for ((r=0; r<rows; r++)); do
    tput cup "$r" "$left"
    printf "${BG_GREEN}%*s${RESET}" "$PANEL_WIDTH" ""
  done
}

disable_terminal_input() {
  stty -echo
}

enable_terminal_input() {
  stty echo
}

# =========================
# PRINT HELPERS
# =========================
print_green_line() {
  local text="$1"
  local row="$2"
  local left
  left=$(panel_left)

  tput cup "$row" "$((left + 2))"
  printf "${BG_GREEN}${FG_BLACK} %-*s ${RESET}" "$((PANEL_WIDTH - 4))" "$text"
}

print_green_empty() {
  local row="$1"
  local left
  left=$(panel_left)

  tput cup "$row" "$left"
  printf "${BG_GREEN}%*s${RESET}" "$PANEL_WIDTH" ""
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
# CONFIRM START
# =========================
confirm_start() {
  hide_cursor
  draw_green_panel
  disable_terminal_input
  local row=4

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
  case "$answer" in
    yes|YES)
      return 0
      ;;
    no|NO)
      draw_green_panel
      row=6
      print_green_line "Installation aborted by user." "$row"; ((row++))
      print_green_line "No changes were made to the system." "$row"
      show_cursor
      exit 0
      ;;
    *)
      draw_green_panel
      row=6
      print_red_line "Invalid answer. Please run the installer again." "$row"
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
  draw_green_panel

  local row=3
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
  #print_green_line "Whats going on? open new term and run: tail -f $log"
}

# =========================
# ERROR SCREEN
# =========================
draw_error() {
  local step="$1"
  local title="$2"
  local log="$3"

  hide_cursor
  draw_green_panel

  local row=4
  print_red_line "KASTEN LAB INSTALLATION" "$row"; ((row++))
  print_red_line "STEP $step - $title" "$row"; ((row+=2))
  print_red_line "EXECUTION FAILED" "$row"; ((row+=2))
  print_red_line "An unexpected error occurred." "$row"; ((row++))
  print_red_line "Please review the log file:" "$row"; ((row++))
  print_red_line "$log" "$row"; ((row+=2))
  print_red_line "Developed by MJ (martin.jorge@veeam.com)" "$row"

  show_cursor
  exit 1
}


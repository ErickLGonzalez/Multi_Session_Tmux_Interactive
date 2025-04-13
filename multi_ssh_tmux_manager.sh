#!/bin/bash

LAYOUTS_DIR="$HOME/.tmux_layouts"
THEMES_DIR="$HOME/.tmux_themes"
LOG_DIR="$HOME/server-logs"
mkdir -p "$LAYOUTS_DIR" "$THEMES_DIR" "$LOG_DIR"

function ensure_dependency() {
  local cmd="$1"
  local pkg="$2"

  if ! command -v "$cmd" &>/dev/null; then
    if whiptail --title "Missing Dependency" --yesno "$cmd is not installed. Install it now?" 10 60; then
      if command -v apt &>/dev/null; then
        sudo apt update && sudo apt install -y "$pkg"
      elif command -v yum &>/dev/null; then
        sudo yum install -y "$pkg"
      elif command -v dnf &>/dev/null; then
        sudo dnf install -y "$pkg"
      elif command -v pacman &>/dev/null; then
        sudo pacman -Sy "$pkg" --noconfirm
      else
        echo "Cannot determine package manager. Please install $pkg manually."
        exit 1
      fi
    else
      echo "$cmd is required. Exiting."
      exit 1
    fi
  fi
}

ensure_dependency "tmux" "tmux"
ensure_dependency "whiptail" "dialog"
ensure_dependency "rsync" "rsync"

function clone_community_themes() {
  if [[ ! -d "$THEMES_DIR" ]]; then
    echo "Cloning community tmux themes..."
    git clone https://github.com/oh-my-tmux/oh-my-tmux.git "$THEMES_DIR/oh-my-tmux"
    git clone https://github.com/tmux-plugins/tpm "$THEMES_DIR/tpm"
  fi
}

function load_layouts_menu() {
  local files=("$LAYOUTS_DIR"/*.layout)
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "No saved layouts."
    return 1
  fi

  local options=()
  for file in "${files[@]}"; do
    name=$(basename "$file" .layout)
    options+=("$name" "")
  done

  CHOICE=$(whiptail --title "Load Layout" --menu "Select a layout to load:" 20 60 10 "${options[@]}" 3>&1 1>&2 2>&3)

  if [[ -n "$CHOICE" ]]; then
    run_layout "$CHOICE"
    exit 0
  fi
}

function run_layout() {
  local name="$1"
  local file="$LAYOUTS_DIR/$name.layout"
  local session="multi_ssh_$name"

  tmux new-session -d -s "$session"
  local index=0

  while IFS='|' read -r server win_name command; do
    tmux new-window -t "$session:$index" -n "$win_name"
    tmux send-keys -t "$session:$index" "ssh $server -t '$command'" C-m
    ((index++))
  done < "$file"

  tmux select-window -t "$session:0"
  tmux attach-session -t "$session"
}

function create_new_layout() {
  INVENTORY_FILE=$(whiptail --title "Server Inventory" --inputbox "Enter the path to the server inventory file:" 10 60 "$HOME/servers.txt" 3>&1 1>&2 2>&3)

  if [[ ! -f "$INVENTORY_FILE" ]]; then
    whiptail --title "Error" --msgbox "The inventory file $INVENTORY_FILE does not exist. Exiting." 10 50
    exit 1
  fi

  LAYOUT_NAME=$(whiptail --inputbox "Name for this layout (used to save it):" 10 60 "default" 3>&1 1>&2 2>&3)
  LAYOUT_FILE="$LAYOUTS_DIR/$LAYOUT_NAME.layout"
  > "$LAYOUT_FILE"

  SESSION_NAME="multi_ssh_$LAYOUT_NAME"
  tmux new-session -d -s "$SESSION_NAME"
  INDEX=0

  while IFS= read -r SERVER; do
    [[ -z "$SERVER" ]] && continue

    # First SSH window
    tmux new-window -t "$SESSION_NAME:$INDEX" -n "$SERVER"
    tmux send-keys -t "$SESSION_NAME:$INDEX" "ssh $SERVER" C-m
    echo "$SERVER|$SERVER|bash" >> "$LAYOUT_FILE"
    ((INDEX++))

    # Add more windows
    NUM_WINDOWS=$(whiptail --inputbox "How many additional windows for $SERVER?" 10 50 2 3>&1 1>&2 2>&3)
    [[ ! "$NUM_WINDOWS" =~ ^[0-9]+$ ]] && NUM_WINDOWS=0

    for ((i = 1; i <= NUM_WINDOWS; i++)); do
      CMD=$(whiptail --inputbox "Command for window $i on $SERVER:" 10 60 "cd ~" 3>&1 1>&2 2>&3)
      WIN_NAME=$(whiptail --inputbox "Window name (e.g. $SERVER-logs):" 10 60 "$SERVER-cmd$i" 3>&1 1>&2 2>&3)
      tmux new-window -t "$SESSION_NAME:$INDEX" -n "$WIN_NAME"
      tmux send-keys -t "$SESSION_NAME:$INDEX" "ssh $SERVER -t '$CMD'" C-m
      echo "$SERVER|$WIN_NAME|$CMD" >> "$LAYOUT_FILE"
      ((INDEX++))
    done
  done < "$INVENTORY_FILE"

  tmux select-window -t "$SESSION_NAME:0"
  tmux attach-session -t "$SESSION_NAME"
}

function choose_theme() {
  THEME_OPTIONS=()
  for theme_dir in "$THEMES_DIR"/*; do
    [[ -d "$theme_dir" ]] && THEME_OPTIONS+=("$(basename "$theme_dir")" "")
  done

  SELECTED_THEME=$(whiptail --title "Choose Tmux Theme" --menu "Select a theme:" 20 60 10 "${THEME_OPTIONS[@]}" 3>&1 1>&2 2>&3)

  if [[ -n "$SELECTED_THEME" ]]; then
    cp "$THEMES_DIR/$SELECTED_THEME/.tmux.conf" "$HOME/.tmux.conf"
    echo "Theme $SELECTED_THEME applied."
  else
    echo "No theme selected."
  fi
}

function sync_logs() {
  local SYNC_METHOD=$(whiptail --title "Log Sync Method" --menu "Choose a method to sync logs:" 15 60 2 \
    "1" "rsync" \
    "2" "scp" 3>&1 1>&2 2>&3)

  if [[ "$SYNC_METHOD" == "1" ]]; then
    for SERVER in $(cat "$HOME/servers.txt"); do
      rsync -avz "$SERVER:/var/log/" "$LOG_DIR/$SERVER/"
    done
  elif [[ "$SYNC_METHOD" == "2" ]]; then
    for SERVER in $(cat "$HOME/servers.txt"); do
      scp -r "$SERVER:/var/log/" "$LOG_DIR/$SERVER/"
    done
  fi
}

# Check if this is the first run
if [[ ! -f "$HOME/.tmux.conf" ]]; then
  clone_community_themes
  choose_theme
fi

# Initial menu
ACTION=$(whiptail --title "SSH Tmux Manager" --menu "Choose an option:" 15 60 4 \
  "1" "Create New Layout" \
  "2" "Load Saved Layout" \
  "3" "Sync Logs" 3>&1 1>&2 2>&3)

case "$ACTION" in
  "1") create_new_layout ;;
  "2") load_layouts_menu ;;
  "3") sync_logs ;;
  *) exit 0 ;;
esac

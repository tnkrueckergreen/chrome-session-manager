#!/usr/bin/env bash

# ==============================================================================
# 🌐 Chrome Session Manager
# A user-friendly script for macOS to backup, restore, and manage Chrome
# windows and tabs with an easy-to-use menu interface.
#
# Dependencies:
# - macOS (relies on osascript for AppleScript/JXA)
# - Python 3 (for JSON parsing and script generation)
#
# Tip: To set a permanent custom backup location, add this to your shell
# profile (e.g., ~/.zshrc or ~/.bash_profile):
# export CHROME_SESSION_BACKUP_DIR="/path/to/your/custom/directory"
# ==============================================================================

# --- Colors and Emojis for a better UX ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Configuration ---
BACKUP_DIR="${CHROME_SESSION_BACKUP_DIR:-$HOME/Documents/chrome-session-backups}"
mkdir -p "$BACKUP_DIR"

# --- Dependency Check ---
check_dependencies() {
    local missing_deps=0
    if ! command -v osascript &>/dev/null; then
        print_error "ERROR: 'osascript' is required. This script is for macOS only." >&2
        missing_deps=1
    fi
    if ! command -v python3 &>/dev/null; then
        print_error "ERROR: 'python3' is required but not found in your PATH." >&2
        missing_deps=1
    fi
    if [ "$missing_deps" -ne 0 ]; then
        exit 1
    fi
}

# --- Utility Functions ---
print_header() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║    🌐  Chrome Session Manager        ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
    echo
}

print_success() { echo -e "${GREEN}✅  $1${NC}"; }
print_error()   { echo -e "${RED}❌  $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_info()    { echo -e "${BLUE}ℹ️  $1${NC}"; }
press_enter()   { echo; echo -e "${YELLOW}Press Enter to continue...${NC}"; read -r; }

# --- Core Logic Functions ---
is_chrome_running() {
    # Returns "true" or "false"
    /usr/bin/osascript -e 'tell application "System Events" to exists (processes where name is "Google Chrome")' 2>/dev/null
}

# Helper to get a sorted list of backup files (newest first) - FIXED VERSION
_get_backup_files() {
    # Print matching files, newest first, one per line (portable on macOS)
    ls -1t "$BACKUP_DIR"/chrome-session-*.json 2>/dev/null || true
}

# Refactored helper to execute the entire restore process from a file
_execute_restore() {
    local backup_file="$1"

    if [ ! -s "$backup_file" ]; then # Check if file exists and is not empty
        print_error "Backup file is invalid or not found."
        press_enter
        return 1
    fi

    if [ "$(is_chrome_running)" = "true" ]; then
        print_warning "Chrome is running. The restore will create new windows."
        echo -n "👉  Continue? (Y/n) "
        read -r response
        if [[ "$response" =~ ^[Nn]$ ]]; then
            print_info "Restore cancelled."
            press_enter
            return 1
        fi
    fi
    
    print_info "Restoring session from $(basename "$backup_file")..."
    
    if python3 - "$backup_file" <<'PYSCRIPT'
import json, subprocess, sys

if len(sys.argv) < 2:
    sys.stderr.write("Error: Backup file path not provided to Python script.\n")
    sys.exit(1)

backup_file = sys.argv[1]
try:
    with open(backup_file, 'r', encoding='utf-8') as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError) as e:
    sys.stderr.write(f"Error reading or parsing backup file '{backup_file}': {e}\n")
    sys.exit(1)

lines = ['tell application "Google Chrome" to activate', 'tell application "Google Chrome"']

for idx, win in enumerate(data.get('windows', []), start=1):
    tabs = win.get('tabs', [])
    if not tabs:
        lines.append(f'\tmake new window with properties {{visible:true}}')
        continue

    lines.append(f'\tset newWin{idx} to (make new window)')
    lines.append(f'\ttell newWin{idx}')
    
    first_tab_url = tabs[0].get('url', 'about:blank').replace('"', '\\"')
    lines.append(f'\t\tset URL of active tab to "{first_tab_url}"')
    if tabs[0].get('pinned'):
        lines.append(f'\t\ttry\n\t\t\tset pinned of active tab to true\n\t\tend try')

    for tab_idx, tab in enumerate(tabs[1:], start=2):
        url = tab.get("url", "about:blank").replace('"', '\\"')
        # Use unique variable names for tabs to avoid AppleScript conflicts
        lines.append(f'\t\tset newTab_{idx}_{tab_idx} to (make new tab at end of tabs with properties {{URL:"{url}"}})')
        if tab.get('pinned'):
            lines.append(f'\t\ttry\n\t\t\tset pinned of newTab_{idx}_{tab_idx} to true\n\t\tend try')
            
    lines.append('\tend tell')

    bounds = win.get('bounds')
    if isinstance(bounds, list) and len(bounds) == 4:
        bounds_str = f'{{{", ".join(map(str, bounds))}}}'
        lines.append(f'\ttry\n\t\tset bounds of newWin{idx} to {bounds_str}\n\tend try')

    if win.get('minimized'):
        lines.append(f'\ttry\n\t\tset minimized of newWin{idx} to true\n\t\tend try')

lines.append('end tell')

script = "\n".join(lines)
proc = subprocess.run(["/usr/bin/osascript", "-"], input=script, capture_output=True, text=True)

if proc.returncode != 0:
    sys.stderr.write("AppleScript Error:\n")
    sys.stderr.write(proc.stderr)
    sys.exit(1)
PYSCRIPT
    then
        print_success "Session restored successfully!"
    else
        print_error "Failed to restore session. See error message above."
    fi
    press_enter
}

# --- Menu Functions ---

backup_session() {
    print_header
    echo -e "${BLUE}💾  Create Chrome Session Backup${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if [ "$(is_chrome_running)" != "true" ]; then
        print_warning "Chrome is not running. The backup will be empty."
        echo -n "👉  Continue anyway? (y/N) "
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            return
        fi
    fi

    TIMESTAMP=$(date +"%Y-%m-%dT%H-%M-%S")
    OUTFILE="$BACKUP_DIR/chrome-session-$TIMESTAMP.json"
    
    print_info "Capturing Chrome session data..."
    
    JSON_CONTENT=$(/usr/bin/osascript -l JavaScript <<'JXA'
(function(){
  var Chrome = Application('Google Chrome');
  Chrome.includeStandardAdditions = true;
  if (!Chrome.running()) {
    return JSON.stringify({windows:[]}, null, 2);
  }
  var wins = Chrome.windows();
  var data = { createdAt: (new Date()).toISOString(), windows: [] };
  for (var i = 0; i < wins.length; i++) {
    var w = wins[i];
    var tabs = w.tabs();
    var tabArray = [];
    for (var t = 0; t < tabs.length; t++) {
      var tab = tabs[t];
      var tabObj = { url: String(tab.url()), title: String(tab.title()) };
      try { if (typeof tab.pinned === 'function') tabObj.pinned = !!tab.pinned(); } catch(e){}
      tabArray.push(tabObj);
    }
    var minimized = false;
    try { minimized = !!w.minimized(); } catch (e) {}
    var bounds = null;
    try { bounds = w.bounds(); } catch (e) {}
    data.windows.push({ index: i+1, minimized: minimized, bounds: bounds, tabs: tabArray });
  }
  return JSON.stringify(data, null, 2);
})();
JXA
)

    if [ -z "$JSON_CONTENT" ]; then
        print_error "Failed to capture Chrome session data."
        press_enter
        return
    fi

    echo "$JSON_CONTENT" > "$OUTFILE"
    if [ ! -s "$OUTFILE" ]; then
        print_error "Failed to write session backup file."
        press_enter
        return
    fi

    local num_windows=$(echo "$JSON_CONTENT" | python3 -c "import sys, json; print(len(json.load(sys.stdin).get('windows', [])))")
    local num_tabs=$(echo "$JSON_CONTENT" | python3 -c "import sys, json; data=json.load(sys.stdin); print(sum(len(w.get('tabs', [])) for w in data.get('windows', [])))")

    print_success "Session saved! ($num_windows windows, $num_tabs tabs)"
    print_info "File: $(basename "$OUTFILE")"
    echo
    
    if [ "$(is_chrome_running)" = "true" ]; then
        echo "What would you like to do now?"
        echo "1) 🙈  Hide Chrome (keep running)"
        echo "2) 🛑  Quit Chrome completely"
        echo "3) ✨  Leave Chrome as-is"
        echo
        echo -n "👉  Choose an option (1-3): "
        read -r choice
        
        case "$choice" in
            1)
                print_info "Hiding Chrome..."
                if /usr/bin/osascript -e 'tell application "System Events" to set visible of process "Google Chrome" to false' 2>/dev/null; then
                    print_success "Chrome hidden."
                else
                    print_error "Failed to hide Chrome."
                fi
                ;;
            2)
                print_info "Closing Chrome..."
                /usr/bin/osascript <<'APPLESCRIPT'
tell application "Google Chrome" to quit
APPLESCRIPT
                print_success "Chrome closed."
                ;;
            3)
                print_info "Chrome left as-is."
                ;;
            *)
                print_warning "Invalid choice. Chrome left as-is."
                ;;
        esac
    fi
    press_enter
}

restore_latest_session() {
    print_header
    echo -e "${BLUE}🔄  Restore Latest Session${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    local latest_file=$(_get_backup_files | head -n 1)
    
    if [ -z "$latest_file" ]; then
        print_warning "No backup files found in $BACKUP_DIR"
        press_enter
        return
    fi
    
    local basename_file=$(basename "$latest_file")
    local friendly_date=$(date -j -f "%Y-%m-%dT%H-%M-%S" "$(echo "$basename_file" | sed -e 's/chrome-session-//' -e 's/\.json//')" "+%B %d, %Y at %I:%M %p" 2>/dev/null || echo "$basename_file")
    local file_size=$(ls -lh "$latest_file" | awk '{print $5}')
    
    print_info "Found latest backup:"
    echo "  📅  Date: $friendly_date"
    echo "  📦  Size: $file_size"
    echo
    
    echo -n "👉  Restore this session? (Y/n) "
    read -r response
    if [[ "$response" =~ ^[Nn]$ ]]; then
        print_info "Restore cancelled."
        press_enter
        return
    fi
    
    _execute_restore "$latest_file"
}

restore_session() {
    print_header
    echo -e "${BLUE}📜  Restore Specific Session${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Use a while-read loop for compatibility instead of mapfile
    local backup_files=()
    while IFS= read -r file; do
        backup_files+=("$file")
    done < <(_get_backup_files)

    if [ ${#backup_files[@]} -eq 0 ]; then
        print_warning "No backup files found in $BACKUP_DIR"
        press_enter
        return
    fi
    
    echo "Available backups (newest first):"
    echo
    for i in "${!backup_files[@]}"; do
        local file="${backup_files[$i]}"
        local basename_file=$(basename "$file")
        local friendly_date=$(date -j -f "%Y-%m-%dT%H-%M-%S" "$(echo "$basename_file" | sed -e 's/chrome-session-//' -e 's/\.json//')" "+%B %d, %Y at %I:%M %p" 2>/dev/null || echo "$basename_file")
        local file_size=$(ls -lh "$file" | awk '{print $5}')
        printf "  %2d) %s (%s)\n" $((i+1)) "$friendly_date" "$file_size"
    done
    
    echo
    echo -n "👉  Select a backup to restore (1-${#backup_files[@]}), or 0 to cancel: "
    read -r choice
    
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#backup_files[@]} ]; then
        if [ "$choice" -ne 0 ]; then
             print_error "Invalid selection."
             press_enter
        fi
        return
    fi
    
    local selected_file="${backup_files[$((choice-1))]}"
    echo
    
    _execute_restore "$selected_file"
}

manage_backups() {
    while true; do
        print_header
        echo -e "${BLUE}🗂️  Backup Management${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        # Use while-read loops for compatibility
        local all_files=()
        while IFS= read -r file; do
            all_files+=("$file")
        done < <(_get_backup_files)

        local old_files=()
        while IFS= read -r file; do
            old_files+=("$file")
        done < <(find "$BACKUP_DIR" -name "chrome-session-*.json" -mtime +30 -print)

        local total_backups=${#all_files[@]}
        local old_backups=${#old_files[@]}
        
        echo "📍  Location: $BACKUP_DIR"
        echo "🗃️  Total backups: $total_backups"
        echo
        echo "1) 📜  List all backups"
        echo "2) 🗑️  Delete backups older than 30 days ($old_backups found)"
        echo "3) 🚮  Delete a specific backup"
        echo "4) 📁  Change backup directory (this session only)"
        echo "5) ↩️  Back to main menu"
        echo
        echo -n "👉  Choose an option (1-5): "
        read -r choice
        
        case "$choice" in
            1) # List all
                print_header
                echo -e "${BLUE}📜  All Backups${NC}"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                if [ "$total_backups" -eq 0 ]; then
                    print_warning "No backup files found."
                else
                    for file in "${all_files[@]}"; do
                        local basename_file=$(basename "$file")
                        local friendly_date=$(date -j -f "%Y-%m-%dT%H-%M-%S" "$(echo "$basename_file" | sed -e 's/chrome-session-//' -e 's/\.json//')" "+%B %d, %Y, %I:%M %p" 2>/dev/null || echo "$basename_file")
                        local file_size=$(ls -lh "$file" | awk '{print $5}')
                        local file_mod_time=$(stat -f%m "$file")
                        local current_time=$(date +%s)
                        local age_days=$(((current_time - file_mod_time) / 86400))
                        printf "  📅  %-30s  📦  %-7s  ⏳  %s days old\n" "$friendly_date" "$file_size" "$age_days"
                    done
                fi
                press_enter
                ;;
            2) # Delete old
                if [ "$old_backups" -eq 0 ]; then
                    print_info "No backups older than 30 days to delete."
                else
                    echo
                    print_warning "This will permanently delete $old_backups backup(s)."
                    echo -n "👉  Are you absolutely sure? (y/N) "
                    read -r response
                    if [[ "$response" =~ ^[Yy]$ ]]; then
                        local deleted_count=0
                        for file in "${old_files[@]}"; do
                            if rm "$file"; then
                                ((deleted_count++))
                            fi
                        done
                        print_success "Deleted $deleted_count old backup(s)."
                    else
                        print_info "Deletion cancelled."
                    fi
                fi
                press_enter
                ;;
            3) # Delete specific
                print_header
                echo -e "${BLUE}🚮  Delete Specific Backup${NC}"
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                if [ "$total_backups" -eq 0 ]; then
                    print_warning "No backups to delete."
                    press_enter
                    continue
                fi
                
                for i in "${!all_files[@]}"; do
                    local file="${all_files[$i]}"
                    local basename_file=$(basename "$file")
                    local friendly_date=$(date -j -f "%Y-%m-%dT%H-%M-%S" "$(echo "$basename_file" | sed -e 's/chrome-session-//' -e 's/\.json//')" "+%B %d, %Y at %I:%M %p" 2>/dev/null || echo "$basename_file")
                    printf "  %2d) %s\n" $((i+1)) "$friendly_date"
                done
                
                echo
                echo -n "👉  Select a backup to DELETE (1-$total_backups), or 0 to cancel: "
                read -r del_choice
                
                if [[ "$del_choice" =~ ^[0-9]+$ ]] && [[ "$del_choice" -eq 0 ]]; then continue; fi

                if [[ "$del_choice" =~ ^[0-9]+$ ]] && [ "$del_choice" -ge 1 ] && [ "$del_choice" -le "$total_backups" ]; then
                    local selected_file="${all_files[$((del_choice-1))]}"
                    echo
                    print_warning "Permanently delete $(basename "$selected_file")?"
                    echo -n "👉  This cannot be undone. (y/N) "
                    read -r response
                    if [[ "$response" =~ ^[Yy]$ ]]; then
                        if rm "$selected_file"; then
                            print_success "Backup deleted."
                        else
                            print_error "Failed to delete backup."
                        fi
                    else
                        print_info "Deletion cancelled."
                    fi
                else
                    print_error "Invalid selection."
                fi
                press_enter
                ;;
            4) # Change directory
                 print_header
                 echo -e "${BLUE}📁  Change Backup Directory${NC}"
                 echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                 echo "Current backup directory: $BACKUP_DIR"
                 echo
                 echo "Enter new backup directory path (or press Enter to cancel):"
                 read -er new_dir
                 
                 if [ -n "$new_dir" ]; then
                    # Safely expand tilde and resolve path
                    new_dir=$(eval echo "$new_dir")
                     if mkdir -p "$new_dir" 2>/dev/null; then
                         BACKUP_DIR="$new_dir"
                         print_success "Backup directory changed to: $BACKUP_DIR"
                         print_info "Note: This change is for this session only."
                         print_info "To make it permanent, set the CHROME_SESSION_BACKUP_DIR variable."
                     else
                         print_error "Failed to create or access directory: $new_dir"
                     fi
                 fi
                 press_enter
                ;;
            5) # Back to main
                break
                ;;
            *)
                print_error "Invalid choice. Please try again."
                sleep 1
                ;;
        esac
    done
}

chrome_controls() {
    while true; do
        print_header
        echo -e "${BLUE}🔧  Chrome Controls${NC}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        
        if [ "$(is_chrome_running)" = "true" ]; then
            echo -e "Status: ${GREEN}✅  Running${NC}"
        else
            echo -e "Status: ${RED}🛑  Not Running${NC}"
        fi
        echo
        
        echo "1) 🙈  Hide Chrome"
        echo "2) 👀  Show/Focus Chrome"
        echo "3) 🛑  Quit Chrome"
        echo "4) 🚀  Launch Chrome"
        echo "5) ↩️  Back to main menu"
        echo
        echo -n "👉  Choose an option (1-5): "
        read -r choice
        
        case "$choice" in
            1) # Hide
                if [ "$(is_chrome_running)" = "true" ]; then
                    print_info "Hiding Chrome..."
                    if /usr/bin/osascript -e 'tell application "System Events" to set visible of process "Google Chrome" to false'; then
                        print_success "Chrome is now hidden."
                    else
                        print_error "Failed to hide Chrome."
                    fi
                else
                    print_warning "Chrome is not running."
                fi
                press_enter
                ;;
            2) # Show
                if [ "$(is_chrome_running)" = "true" ]; then
                    print_info "Bringing Chrome to the front..."
                    /usr/bin/osascript -e 'tell application "Google Chrome" to activate'
                    print_success "Chrome is now visible and active."
                else
                    print_warning "Chrome is not running."
                fi
                press_enter
                ;;
            3) # Quit
                if [ "$(is_chrome_running)" = "true" ]; then
                    print_info "Quitting Chrome..."
                    /usr/bin/osascript -e 'tell application "Google Chrome" to quit'
                    sleep 1 # Give it a moment to close
                    print_success "Chrome has been closed."
                else
                    print_warning "Chrome is not running."
                fi
                press_enter
                ;;
            4) # Launch
                if [ "$(is_chrome_running)" != "true" ]; then
                    print_info "Launching Chrome..."
                    open -a "Google Chrome"
                    sleep 2 # Give it a moment to launch
                    print_success "Chrome launched."
                else
                    print_warning "Chrome is already running."
                fi
                press_enter
                ;;
            5) # Back
                break
                ;;
            *)
                print_error "Invalid choice. Please try again."
                sleep 1
                ;;
        esac
    done
}

show_main_menu() {
    print_header
    echo -e "${BLUE}Welcome to your Chrome assistant!${NC}"
    echo
    
    if [ "$(is_chrome_running)" = "true" ]; then
        echo -e "Status: ${GREEN}✅  Chrome is Running${NC}"
    else
        echo -e "Status: ${RED}🛑  Chrome is Not Running${NC}"
    fi

    local backup_count=$(_get_backup_files | wc -l | tr -d ' ')
    echo "Backups: 🗃️  $backup_count available"
    echo "Location: 📍  $BACKUP_DIR"
    echo "────────────────────────────────────────"
    
    echo "1) 💾  Backup Current Session"
    echo "2) 🔄  Restore Latest Backup"
    echo "3) 📜  Restore from a List"
    echo "4) 🔧  Chrome Controls (Show/Hide/Quit)"
    echo "5) 🗂️  Manage Backups (List/Delete)"
    echo "6) 🚪  Exit"
    echo
    echo -n "👉  What would you like to do? (1-6) "
}

# --- Main Program Loop ---
check_dependencies
while true; do
    show_main_menu
    read -r choice
    
    case "$choice" in
        1) backup_session ;;
        2) restore_latest_session ;;
        3) restore_session ;;
        4) chrome_controls ;;
        5) manage_backups ;;
        6)
            print_header
            print_success "All done. Have a great day! 👋"
            echo
            exit 0
            ;;
        *)
            print_error "Invalid choice. Please try again."
            sleep 1
            ;;
    esac
done
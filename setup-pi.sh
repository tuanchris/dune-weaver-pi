#!/bin/bash
#
# Dune Weaver Raspberry Pi Setup Script
#
# ONE-COMMAND INSTALL (recommended):
#   curl -fsSL https://raw.githubusercontent.com/tuanchris/dune-weaver-pi/main/setup-pi.sh | bash
#
# OR from existing clone:
#   git clone https://github.com/tuanchris/dune-weaver-pi --single-branch
#   cd dune-weaver-pi
#   bash setup-pi.sh
#
# Options:
#   --no-wifi-fix         Skip WiFi stability fix
#   --no-hotspot          Skip autohotspot setup
#   --no-system-update    Skip 'apt update' package list refresh
#   --help                Show help
#

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default options
FIX_WIFI=true  # Applied by default for stability
SETUP_HOTSPOT=true  # Autohotspot for first-time WiFi setup
UPDATE_SYSTEM=true  # Refresh apt package lists before installing deps
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(eval echo ~"$REAL_USER")"
# Fallback: if tilde didn't expand, read from /etc/passwd
if [[ "$REAL_HOME" == "~$REAL_USER" ]]; then
    REAL_HOME="$(grep "^$REAL_USER:" /etc/passwd | cut -d: -f6)"
fi
INSTALL_DIR="$REAL_HOME/dune-weaver-pi"
REPO_URL="https://github.com/tuanchris/dune-weaver-pi"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-wifi-fix)
            FIX_WIFI=false
            shift
            ;;
        --no-hotspot)
            SETUP_HOTSPOT=false
            shift
            ;;
        --no-system-update)
            UPDATE_SYSTEM=false
            shift
            ;;
        --help|-h)
            echo "Dune Weaver Raspberry Pi Setup Script"
            echo ""
            echo "One-command install:"
            echo "  curl -fsSL https://raw.githubusercontent.com/tuanchris/dune-weaver-pi/main/setup-pi.sh | bash"
            echo ""
            echo "Or from existing clone:"
            echo "  cd ~/dune-weaver-pi && bash setup-pi.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --no-wifi-fix        Skip WiFi stability fix (applied by default)"
            echo "  --no-hotspot         Skip autohotspot setup"
            echo "  --no-system-update   Skip 'apt update' package list refresh"
            echo "  --help, -h           Show this help message"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# ── Permission helpers ──────────────────────────────────────────────
# Run a command as the real (non-root) user.
# When the script is invoked with sudo, commands like git clone, pip install,
# and venv creation should run as the real user so files are owned correctly
# from the start — no chown needed afterward.
run_as_user() {
    if [[ $EUID -eq 0 && -n "$SUDO_USER" ]]; then
        sudo -u "$SUDO_USER" -- "$@"
    else
        "$@"
    fi
}

# Ensure the entire repo tree is owned by the real user.
# Call this as a safety net after any operation that may have created
# files as root (e.g. an older version of this script, or a plugin).
fix_repo_ownership() {
    if [[ $EUID -eq 0 && -n "$SUDO_USER" ]]; then
        chown -R "$SUDO_USER:$SUDO_USER" "$INSTALL_DIR"
    fi
}
# ────────────────────────────────────────────────────────────────────

# Helper functions
print_step() {
    echo -e "\n${BLUE}==>${NC} ${GREEN}$1${NC}"
}

print_warning() {
    echo -e "${YELLOW}Warning:${NC} $1"
}

print_error() {
    echo -e "${RED}Error:${NC} $1"
}

print_success() {
    echo -e "${GREEN}$1${NC}"
}

# Install system dependencies
install_system_deps() {
    print_step "Installing system dependencies..."
    if [[ "$UPDATE_SYSTEM" == "true" ]]; then
        sudo apt update
    else
        echo "Skipping 'apt update' (--no-system-update)"
    fi
    sudo DEBIAN_FRONTEND=noninteractive apt install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
        python3-venv python3-pip python3-dev \
        gcc g++ make \
        libjpeg-dev zlib1g-dev \
        nginx git vim
    print_success "System dependencies installed"
}

# Stop any running Dune Weaver services before touching the repo.
# A running backend or touch app can hold port 8080, keep files open, or race
# with the git pull/clone below — stop them up front for a clean setup. Unit
# names are fixed (dune-weaver, dune-weaver-touch) regardless of install dir.
stop_existing_services() {
    print_step "Stopping any running Dune Weaver services..."

    local stopped=false
    for svc in dune-weaver dune-weaver-touch; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            echo "Stopping ${svc}.service..."
            sudo systemctl stop "$svc" 2>/dev/null || true
            stopped=true
        fi
    done

    if [[ "$stopped" == "false" ]]; then
        echo "No running services found"
    fi
}

# Check if running on Raspberry Pi
check_raspberry_pi() {
    print_step "Checking system compatibility..."

    if [[ ! -f /proc/device-tree/model ]]; then
        print_warning "Could not detect Raspberry Pi model. Continuing anyway..."
        return
    fi

    MODEL=$(tr -d '\0' < /proc/device-tree/model)
    echo "Detected: $MODEL"

    # Check for 64-bit OS
    ARCH=$(uname -m)
    if [[ "$ARCH" != "aarch64" && "$ARCH" != "arm64" ]]; then
        print_error "64-bit OS required. Detected: $ARCH"
        echo "Please reinstall Raspberry Pi OS (64-bit) using Raspberry Pi Imager"
        exit 1
    fi
    print_success "64-bit OS detected ($ARCH)"
}

# Disable WLAN power save
disable_wlan_powersave() {
    print_step "Disabling WLAN power save for better stability..."

    # Check if already disabled
    if iwconfig wlan0 2>/dev/null | grep -q "Power Management:off"; then
        echo "WLAN power save already disabled"
        return
    fi

    # Create config to persist across reboots
    sudo tee /etc/NetworkManager/conf.d/wifi-powersave-off.conf > /dev/null << 'EOF'
[connection]
wifi.powersave = 2
EOF

    # Also try immediate disable
    sudo iwconfig wlan0 power off 2>/dev/null || true

    print_success "WLAN power save disabled"
}

# Apply WiFi stability fix
apply_wifi_fix() {
    print_step "Applying WiFi stability fix..."

    CMDLINE_FILE="/boot/firmware/cmdline.txt"
    if [[ ! -f "$CMDLINE_FILE" ]]; then
        CMDLINE_FILE="/boot/cmdline.txt"
    fi

    if [[ ! -f "$CMDLINE_FILE" ]]; then
        print_warning "Could not find cmdline.txt, skipping WiFi fix"
        return
    fi

    # Check if fix already applied
    if grep -q "brcmfmac.feature_disable=0x82000" "$CMDLINE_FILE"; then
        echo "WiFi fix already applied"
        return
    fi

    # Backup and apply fix
    sudo cp "$CMDLINE_FILE" "${CMDLINE_FILE}.backup"
    sudo sed -i 's/$/ brcmfmac.feature_disable=0x82000/' "$CMDLINE_FILE"

    print_success "WiFi fix applied. A reboot is recommended after setup."
    NEEDS_REBOOT=true
}

# Verify we're in the dune-weaver directory
ensure_repo() {
    print_step "Setting up dune-weaver repository..."

    # Check if we're already in the dune-weaver directory
    if [[ -f "main.py" ]] && [[ -f "requirements.txt" ]]; then
        INSTALL_DIR="$(pwd)"
        print_success "Using existing repo at $INSTALL_DIR"
        fix_repo_ownership
        return
    fi

    # Check if repo exists in home directory
    if [[ -d "$INSTALL_DIR" ]] && [[ -f "$INSTALL_DIR/main.py" ]]; then
        print_success "Found existing repo at $INSTALL_DIR"
        cd "$INSTALL_DIR"
        echo "Pulling latest changes..."
        run_as_user git pull
        fix_repo_ownership
        return
    fi

    # Clone the repository as the real user so files are owned correctly
    print_step "Cloning dune-weaver repository..."
    run_as_user git clone "$REPO_URL" --single-branch "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    print_success "Cloned to $INSTALL_DIR"
}

# Deploy native (venv + systemd + nginx)
deploy_native() {
    print_step "Setting up Python virtual environment..."

    cd "$INSTALL_DIR"

    # Safety net: fix ownership in case repo was cloned/pulled as root
    # by an older version of this script or manual sudo git operations
    fix_repo_ownership

    # Create venv as real user
    run_as_user python3 -m venv .venv
    source .venv/bin/activate

    # Install dependencies as real user (pip writes to user-owned .venv)
    print_step "Installing Python packages..."
    run_as_user .venv/bin/pip install --upgrade pip
    run_as_user .venv/bin/pip install -r requirements.txt

    # Ensure nginx (www-data) can traverse to static files
    # chmod o+x grants traversal only, not directory listing
    local dir="$INSTALL_DIR"
    while [[ "$dir" != "/" ]]; do
        sudo chmod o+x "$dir"
        dir=$(dirname "$dir")
    done

    # Configure nginx
    print_step "Configuring nginx..."
    sudo cp "$INSTALL_DIR/nginx/dune-weaver.conf" /etc/nginx/sites-available/dune-weaver.conf
    sudo sed -i "s|INSTALL_DIR_PLACEHOLDER|$INSTALL_DIR|g" /etc/nginx/sites-available/dune-weaver.conf
    sudo ln -sf /etc/nginx/sites-available/dune-weaver.conf /etc/nginx/sites-enabled/dune-weaver.conf
    sudo rm -f /etc/nginx/sites-enabled/default
    sudo nginx -t
    sudo systemctl restart nginx
    sudo systemctl enable nginx

    # Create systemd service
    print_step "Creating systemd service..."
    sudo cp "$INSTALL_DIR/dune-weaver.service" /etc/systemd/system/dune-weaver.service
    sudo sed -i "s|INSTALL_DIR_PLACEHOLDER|$INSTALL_DIR|g" /etc/systemd/system/dune-weaver.service

    # Enable and start service
    sudo systemctl daemon-reload
    sudo systemctl enable dune-weaver
    sudo systemctl start dune-weaver

    # Create sudoers entry for passwordless systemctl commands
    # Use REAL_USER (not $USER which is root under sudo)
    print_step "Configuring sudo permissions..."
    sudo tee /etc/sudoers.d/dune-weaver > /dev/null << EOF
$REAL_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart dune-weaver
$REAL_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop dune-weaver
$REAL_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl start dune-weaver
$REAL_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl poweroff
$REAL_USER ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart nginx
EOF
    sudo chmod 0440 /etc/sudoers.d/dune-weaver

    print_success "Native deployment complete!"
}

# Install dw CLI command
install_cli() {
    print_step "Installing 'dw' command..."

    # Overwrite any existing dw. Use a temp file + atomic mv (fresh inode)
    # instead of cp-in-place: `dw install` runs this script while
    # /usr/local/bin/dw is still the live parent process, and truncating its
    # script file mid-run can corrupt it. mv keeps the running inode intact and
    # swaps in the new version for the next invocation.
    local tmp
    tmp=$(sudo mktemp /usr/local/bin/.dw.XXXXXX)
    sudo cp "$INSTALL_DIR/dw" "$tmp"
    sudo chmod 0755 "$tmp"
    sudo mv -f "$tmp" /usr/local/bin/dw

    print_success "'dw' command installed (overwrote any previous version)"
}

# Setup autohotspot
setup_autohotspot() {
    print_step "Setting up autohotspot..."

    if [[ ! -f "$INSTALL_DIR/wifi/setup-wifi.sh" ]]; then
        print_warning "wifi/setup-wifi.sh not found, skipping autohotspot setup"
        return
    fi

    bash "$INSTALL_DIR/wifi/setup-wifi.sh"
    print_success "Autohotspot setup complete"
}

# Clean up UART overlays left over from pre-5.0 (serial/USB) setups.
# Dune Weaver 5.0 talks to the DLC32/ESP32 firmware over Wi-Fi (HTTP) — there is
# no serial or GPIO connection to the board — so any UART overlays a previous
# install added to config.txt are now dead weight.
cleanup_legacy_uart() {
    local CONFIG_FILE="/boot/firmware/config.txt"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        CONFIG_FILE="/boot/config.txt"
    fi
    [[ -f "$CONFIG_FILE" ]] || return

    local has_uart=false
    for overlay in "dtoverlay=pi3-miniuart-bt" "dtoverlay=miniuart-bt" "enable_uart=1"; do
        if grep -q "^${overlay}$" "$CONFIG_FILE" 2>/dev/null; then
            has_uart=true
            break
        fi
    done

    [[ "$has_uart" == "true" ]] || return

    print_step "Removing legacy UART overlays (board is now driven over Wi-Fi)..."
    sudo sed -i '/^dtoverlay=pi3-miniuart-bt$/d' "$CONFIG_FILE"
    sudo sed -i '/^dtoverlay=miniuart-bt$/d' "$CONFIG_FILE"
    sudo sed -i '/^enable_uart=1$/d' "$CONFIG_FILE"
    NEEDS_REBOOT=true
    print_success "Legacy UART overlays removed. A reboot is recommended."
}

# Remove software that is no longer needed on the Pi
cleanup_unused() {
    print_step "Cleaning up unused software..."

    # Remove Node.js / npm if present from a prior install
    if dpkg -l nodejs 2>/dev/null | grep -q '^ii'; then
        echo "Removing Node.js (no longer needed — frontend is pre-built)..."
        sudo apt purge -y nodejs || true
        sudo rm -f /etc/apt/sources.list.d/nodesource.list \
                    /etc/apt/keyrings/nodesource.gpg 2>/dev/null || true
        sudo apt autoremove -y
        print_success "Node.js removed"
    fi

    # Remove Docker if present from old Docker-based deployment
    if dpkg -l docker-ce 2>/dev/null | grep -q '^ii'; then
        echo "Removing Docker (old deployment method)..."
        # Stop running containers
        sudo docker stop $(sudo docker ps -aq) 2>/dev/null || true
        sudo apt purge -y docker-ce docker-ce-cli containerd.io docker-compose-plugin 2>/dev/null || true
        sudo rm -rf /var/lib/docker
        sudo apt autoremove -y
        print_success "Docker removed"
    fi
}

# Get IP address
get_ip_address() {
    # Try multiple methods to get IP
    IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    if [[ -z "$IP" ]]; then
        IP=$(ip route get 1 2>/dev/null | awk '{print $7}' | head -1)
    fi
    if [[ -z "$IP" ]]; then
        IP="<your-pi-ip>"
    fi
    echo "$IP"
}

# Print final instructions
print_final_instructions() {
    IP=$(get_ip_address)
    HOSTNAME=$(hostname)

    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}   Dune Weaver Setup Complete!${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo -e "Access the web interface at:"
    echo -e "  ${BLUE}http://$IP${NC}"
    echo -e "  ${BLUE}http://$HOSTNAME.local${NC}"
    echo ""

    echo "Manage with the 'dw' command:"
    echo "  dw logs        View live logs"
    echo "  dw restart     Restart Dune Weaver"
    echo "  dw update      Pull latest and restart"
    echo "  dw stop        Stop Dune Weaver"
    echo "  dw status      Show status"
    echo "  dw wifi help   WiFi and hotspot management"
    echo "  dw help        Show all commands"
    echo ""

    if [[ "$SETUP_HOTSPOT" == "true" ]]; then
        echo -e "${BLUE}Autohotspot:${NC} If no known WiFi is found on boot,"
        echo "a 'Dune Weaver' hotspot will be created automatically."
        echo "Connect to it and open the app to configure WiFi."
        echo ""
    fi

    if [[ "$NEEDS_REBOOT" == "true" ]]; then
        print_warning "A reboot is required to apply configuration changes"
        read -p "Reboot now? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            sudo reboot
        fi
    fi
}

# Main installation flow
main() {
    echo -e "${GREEN}"
    echo "  ____                   __        __                        "
    echo " |  _ \ _   _ _ __   ___\ \      / /__  __ ___   _____ _ __ "
    echo " | | | | | | | '_ \ / _ \\ \ /\ / / _ \/ _\` \ \ / / _ \ '__|"
    echo " | |_| | |_| | | | |  __/ \ V  V /  __/ (_| |\ V /  __/ |   "
    echo " |____/ \__,_|_| |_|\___|  \_/\_/ \___|\__,_| \_/ \___|_|   "
    echo -e "${NC}"
    echo "Raspberry Pi Setup Script"
    echo ""
    echo "Install directory: $INSTALL_DIR"
    echo ""

    # Run setup steps
    stop_existing_services
    check_raspberry_pi
    install_system_deps
    ensure_repo
    disable_wlan_powersave
    cleanup_legacy_uart

    if [[ "$FIX_WIFI" == "true" ]]; then
        apply_wifi_fix
    fi

    if [[ "$SETUP_HOTSPOT" == "true" ]]; then
        setup_autohotspot
    fi

    deploy_native
    install_cli
    cleanup_unused
    print_final_instructions
}

# Run main
main

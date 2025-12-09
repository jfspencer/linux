#!/usr/bin/env bash
#
# System Setup Script
# Configures a fresh Ubuntu/Pop!_OS installation with common development tools
#
# Usage: ./system-setup.sh [OPTIONS]
#   --force-system76     Force System76 driver installation (auto-detected by default)
#   --skip-system76      Skip System76 driver installation even if detected
#   --skip-system76-nvidia        Skip NVIDIA driver installation
#   --skip-flatpak       Skip Flatpak and GNOME Circle apps
#   --skip-reboot-pause  Skip the reboot pause after Flatpak setup
#   --dry-run            Show what would be installed without making changes
#   --help               Show this help message
#

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SETUP_ARTIFACTS_DIR="${SCRIPT_DIR}/setup_artifacts"
readonly LOG_FILE="${SCRIPT_DIR}/setup-$(date +%Y%m%d-%H%M%S).log"

# Feature flags (can be overridden via command line)
INSTALL_SYSTEM76="auto"  # auto, true, or false
INSTALL_SYSTEM76_NVIDIA=true
INSTALL_FLATPAK=true
PAUSE_FOR_REBOOT=true
DRY_RUN=false

# =============================================================================
# Application Lists
# =============================================================================

# Flatpak applications to install
readonly FLATPAK_APPS=(
    "org.gnome.World.PikaBackup|Pika Backup"
    "io.github.fizzyizzy05.binary|Binary"
    "dev.geopjr.Collision|Collision"
    "com.github.huluti.Curtail|Curtail"
    "app.drey.Dialect|Dialect"
    "org.gnome.design.Emblem|Emblem"
    "io.github.mrvladus.List|List (Errands)"
    "com.github.finefindus.eyedropper|Eyedropper"
    "org.gnome.World.Iotas|Iotas"
    "se.sjoerd.Graphs|Graphs"
    "de.schmidhuberj.DieBahn|Die Bahn"
    "org.gnome.Solanum|Solanum"
    "io.gitlab.adhami3310.Converter|Converter"
    "io.github.idevecore.Valuta|Valuta"
    "org.gnome.gitlab.YaLTeR.VideoTrimmer|Video Trimmer"
    "app.drey.Warp|Warp"
    "dev.mufeed.Wordbook|Wordbook"
)

# NPM global packages to install
readonly NPM_PACKAGES=(
    "@webos-tools/cli"
    "pnpm"
)

# =============================================================================
# Logging & Output
# =============================================================================

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly GRAY='\033[0;90m'
readonly NC='\033[0m'

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[${timestamp}] [${level}] ${message}" >> "${LOG_FILE}"
}

print_status() {
    echo -e "${BLUE}[*]${NC} $1"
    log "INFO" "$1"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
    log "SUCCESS" "$1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
    log "WARNING" "$1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1" >&2
    log "ERROR" "$1"
}

print_skip() {
    echo -e "${GRAY}[−]${NC} $1 ${GRAY}(already installed)${NC}"
    log "SKIP" "$1"
}

print_dry_run() {
    echo -e "${CYAN}[DRY]${NC} Would: $1"
    log "DRY_RUN" "$1"
}

print_section() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    log "SECTION" "$1"
}

# =============================================================================
# Error Handling
# =============================================================================

cleanup() {
    local exit_code=$?
    if [[ ${exit_code} -ne 0 ]]; then
        print_error "Script failed with exit code ${exit_code}"
        print_error "Check log file for details: ${LOG_FILE}"
    fi
    cd "${SCRIPT_DIR}" 2>/dev/null || true
}

trap cleanup EXIT

handle_error() {
    local line_number="$1"
    local command="$2"
    local exit_code="$3"
    print_error "Command failed at line ${line_number}: ${command} (exit code: ${exit_code})"
}

trap 'handle_error ${LINENO} "${BASH_COMMAND}" $?' ERR

# =============================================================================
# Detection & Check Functions
# =============================================================================

command_exists() {
    command -v "$1" &>/dev/null
}

package_installed() {
    dpkg -l "$1" 2>/dev/null | grep -q "^ii"
}

ppa_exists() {
    local ppa_name="$1"
    grep -rq "${ppa_name}" /etc/apt/sources.list.d/ 2>/dev/null
}

flatpak_installed() {
    local app_id="$1"
    flatpak list --app 2>/dev/null | grep -q "${app_id}"
}

flatpak_remote_exists() {
    local remote_name="$1"
    flatpak remotes 2>/dev/null | grep -q "^${remote_name}"
}

gpg_key_exists() {
    local keyring="$1"
    [[ -f "${keyring}" ]]
}

is_system76_hardware() {
    # Check sysfs for System76 identification (instant, no sudo needed)
    [[ -f /sys/class/dmi/id/sys_vendor ]] && grep -qi "system76" /sys/class/dmi/id/sys_vendor 2>/dev/null
}

has_nvidia_gpu() {
    lspci 2>/dev/null | grep -qi "nvidia"
}

require_file() {
    local file="$1"
    local description="${2:-file}"
    if [[ ! -f "${file}" ]]; then
        print_error "Required ${description} not found: ${file}"
        return 1
    fi
    return 0
}

confirm_action() {
    local prompt="$1"
    local default="${2:-n}"
    local response

    if [[ "${default}" == "y" ]]; then
        read -rp "${prompt} [Y/n]: " response
        response="${response:-y}"
    else
        read -rp "${prompt} [y/N]: " response
        response="${response:-n}"
    fi

    [[ "${response}" =~ ^[Yy] ]]
}

# =============================================================================
# Package Management Functions (Idempotent)
# =============================================================================

apt_update() {
    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "apt update"
        return 0
    fi
    print_status "Updating package lists..."
    sudo apt update -qq
    print_success "Package lists updated"
}

apt_upgrade() {
    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "apt upgrade"
        return 0
    fi
    print_status "Upgrading installed packages..."
    sudo apt upgrade -y
    print_success "Packages upgraded"
}

apt_install() {
    local packages_to_install=()

    for pkg in "$@"; do
        if package_installed "${pkg}"; then
            print_skip "${pkg}"
        else
            packages_to_install+=("${pkg}")
        fi
    done

    if [[ ${#packages_to_install[@]} -eq 0 ]]; then
        return 0
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "apt install ${packages_to_install[*]}"
        return 0
    fi

    print_status "Installing packages: ${packages_to_install[*]}"
    sudo apt install -y "${packages_to_install[@]}"
    print_success "Packages installed: ${packages_to_install[*]}"
}

apt_install_deb() {
    local deb_file="$1"
    local package_name="${2:-$(basename "${deb_file}" .deb)}"

    # Extract package name from .deb to check if installed
    local pkg_name
    pkg_name=$(dpkg-deb -f "${deb_file}" Package 2>/dev/null || echo "${package_name}")

    if package_installed "${pkg_name}"; then
        print_skip "${package_name}"
        return 0
    fi

    if ! require_file "${deb_file}" "package file"; then
        return 1
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "apt install ${deb_file}"
        return 0
    fi

    print_status "Installing ${package_name} from .deb file..."
    sudo apt install -y "${deb_file}"
    print_success "${package_name} installed"
}

flatpak_install() {
    local app_id="$1"
    local app_name="${2:-${app_id}}"

    if flatpak_installed "${app_id}"; then
        print_skip "${app_name}"
        return 0
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "flatpak install ${app_id}"
        return 0
    fi

    print_status "Installing Flatpak: ${app_name}..."
    if flatpak install -y flathub "${app_id}"; then
        print_success "${app_name} installed"
        return 0
    else
        print_warning "Failed to install ${app_name}"
        return 1
    fi
}

add_apt_repository() {
    local repo="$1"
    local ppa_name="$2"
    local description="${3:-repository}"

    # Extract PPA identifier for checking (e.g., "system76-dev/stable" from "ppa:system76-dev/stable")
    local ppa_id="${repo#ppa:}"

    if ppa_exists "${ppa_id}"; then
        print_skip "${description}"
        return 0
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "apt-add-repository ${repo}"
        return 0
    fi

    print_status "Adding ${description}..."
    sudo apt-add-repository -y "${repo}"
    print_success "${description} added"
}

# =============================================================================
# Installation Functions (Idempotent)
# =============================================================================

install_system76_drivers() {
    print_section "System76 Drivers"

    # Handle auto-detection
    if [[ "${INSTALL_SYSTEM76}" == "auto" ]]; then
        print_status "Checking for System76 hardware..."
        if is_system76_hardware; then
            print_success "System76 hardware detected"
            INSTALL_SYSTEM76=true
        else
            print_status "No System76 hardware detected, skipping drivers"
            INSTALL_SYSTEM76=false
            return 0
        fi
    fi

    if [[ "${INSTALL_SYSTEM76}" != true ]]; then
        print_warning "Skipping System76 drivers (disabled)"
        return 0
    fi

    add_apt_repository "ppa:system76-dev/stable" "system76-dev/stable" "System76 PPA"
    apt_install system76-driver

    if [[ "${INSTALL_SYSTEM76_NVIDIA}" == true ]]; then
        if ! is_system76_hardware; then
            print_status "Not System76 hardware, skipping System76 NVIDIA drivers"
        elif has_nvidia_gpu; then
            print_status "NVIDIA GPU detected, installing System76 NVIDIA drivers..."
            apt_install system76-driver-nvidia
        else
            print_status "No NVIDIA GPU detected, skipping NVIDIA drivers"
        fi
    else
        print_warning "Skipping NVIDIA drivers (disabled)"
    fi
}

install_flatpak() {
    print_section "Flatpak Setup"

    if [[ "${INSTALL_FLATPAK}" != true ]]; then
        print_warning "Skipping Flatpak setup (disabled)"
        return 0
    fi

    # Check if flatpak is already installed and configured
    local flatpak_needs_install=false
    local flathub_needs_add=false

    if command_exists flatpak; then
        print_skip "Flatpak"
    else
        flatpak_needs_install=true
    fi

    if [[ "${flatpak_needs_install}" == false ]] && flatpak_remote_exists "flathub"; then
        print_skip "Flathub repository"
    else
        flathub_needs_add=true
    fi

    # Install flatpak if needed
    if [[ "${flatpak_needs_install}" == true ]]; then
        apt_install flatpak gnome-software-plugin-flatpak
    else
        # Still check gnome-software-plugin-flatpak
        apt_install gnome-software-plugin-flatpak
    fi

    # Add flathub if needed
    if [[ "${flathub_needs_add}" == true ]]; then
        if [[ "${DRY_RUN}" == true ]]; then
            print_dry_run "flatpak remote-add flathub"
        else
            print_status "Adding Flathub repository..."
            flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
            print_success "Flathub repository configured"
        fi
    fi

    # Only pause if we actually installed flatpak for the first time
    if [[ "${flatpak_needs_install}" == true ]] && [[ "${PAUSE_FOR_REBOOT}" == true ]] && [[ "${DRY_RUN}" != true ]]; then
        echo ""
        print_warning "Flatpak was just installed. A system restart is recommended."
        print_warning "Flatpak apps may not work correctly until you reboot."
        echo ""
        if confirm_action "Would you like to continue without rebooting?" "y"; then
            print_status "Continuing without reboot..."
        else
            print_status "Please reboot your system and run this script again"
            exit 0
        fi
    fi
}

install_brave() {
    print_section "Brave Browser"

    if command_exists brave-browser; then
        print_skip "Brave browser"
        return 0
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "Install Brave browser via install script"
        return 0
    fi

    print_status "Installing Brave browser..."
    curl -fsS https://dl.brave.com/install.sh | sh
    print_success "Brave browser installed"
}

install_google_chrome() {
    print_section "Google Chrome"

    if command_exists google-chrome || package_installed google-chrome-stable; then
        print_skip "Google Chrome"
        return 0
    fi

    local keyring="/usr/share/keyrings/google-chrome-keyring.gpg"
    local sources_file="/etc/apt/sources.list.d/google-chrome.list"

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "Install Google Chrome (add GPG key, repo, and install package)"
        return 0
    fi

    # Add GPG key if not present
    if ! gpg_key_exists "${keyring}"; then
        print_status "Adding Google Chrome GPG key..."
        curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | \
            sudo gpg --dearmor --output "${keyring}"
        print_success "GPG key added"
    else
        print_skip "Google Chrome GPG key"
    fi

    # Add repository if not present
    if [[ ! -f "${sources_file}" ]]; then
        print_status "Adding Google Chrome repository..."
        echo "deb [arch=$(dpkg --print-architecture) signed-by=${keyring}] https://dl.google.com/linux/chrome/deb/ stable main" | \
            sudo tee "${sources_file}" > /dev/null
        print_success "Repository added"
    else
        print_skip "Google Chrome repository"
    fi

    apt_update
    apt_install google-chrome-stable
}

install_chromium() {
    print_section "Chromium Browser"

    if command_exists chromium-browser || command_exists chromium || package_installed chromium-browser; then
        print_skip "Chromium browser"
        return 0
    fi

    apt_install chromium-browser
}

install_slack() {
    print_section "Slack"

    # Check if Slack desktop is already installed
    if command_exists slack || package_installed slack-desktop; then
        print_skip "Slack"
        return 0
    fi

    local slack_deb="${SETUP_ARTIFACTS_DIR}/slack-desktop-4.46.101-amd64.deb"

    if [[ ! -f "${slack_deb}" ]]; then
        print_warning "Slack .deb not found: ${slack_deb}"
        print_warning "Download from https://slack.com/downloads/linux"
        return 1
    fi

    apt_install_deb "${slack_deb}" "Slack"
}

install_cursor() {
    print_section "Cursor IDE"

    # Check if cursor is already installed
    if command_exists cursor || package_installed cursor; then
        print_skip "Cursor IDE"
        return 0
    fi

    local cursor_deb
    cursor_deb=$(find "${SETUP_ARTIFACTS_DIR}" -name "cursor*.deb" 2>/dev/null | head -n1)

    if [[ -z "${cursor_deb}" ]]; then
        print_warning "Cursor .deb not found in ${SETUP_ARTIFACTS_DIR}"
        print_warning "Download from https://cursor.sh"
        return 1
    fi

    apt_install_deb "${cursor_deb}" "Cursor IDE"
}

install_1password() {
    print_section "1Password"

    if package_installed 1password; then
        print_skip "1Password"
        return 0
    fi

    local keyring="/usr/share/keyrings/1password-archive-keyring.gpg"
    local sources_file="/etc/apt/sources.list.d/1password.list"

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "Install 1Password (add GPG key, repo, and install package)"
        return 0
    fi

    # Add GPG key if not present
    if ! gpg_key_exists "${keyring}"; then
        print_status "Adding 1Password GPG key..."
        curl -sS https://downloads.1password.com/linux/keys/1password.asc | \
            sudo gpg --dearmor --output "${keyring}"
        print_success "GPG key added"
    else
        print_skip "1Password GPG key"
    fi

    # Add repository if not present
    if [[ ! -f "${sources_file}" ]]; then
        print_status "Adding 1Password repository..."
        echo "deb [arch=$(dpkg --print-architecture) signed-by=${keyring}] https://downloads.1password.com/linux/debian/$(dpkg --print-architecture) stable main" | \
            sudo tee "${sources_file}" > /dev/null
        print_success "Repository added"
    else
        print_skip "1Password repository"
    fi

    # Setup debsig verification
    local debsig_policy_dir="/etc/debsig/policies/AC2D62742012EA22"
    local debsig_keyring_dir="/usr/share/debsig/keyrings/AC2D62742012EA22"

    if [[ ! -f "${debsig_policy_dir}/1password.pol" ]]; then
        print_status "Setting up debsig verification..."
        sudo mkdir -p "${debsig_policy_dir}"
        curl -sS https://downloads.1password.com/linux/debian/debsig/1password.pol | \
            sudo tee "${debsig_policy_dir}/1password.pol" > /dev/null
        sudo mkdir -p "${debsig_keyring_dir}"
        curl -sS https://downloads.1password.com/linux/keys/1password.asc | \
            sudo gpg --dearmor --output "${debsig_keyring_dir}/debsig.gpg"
        print_success "Debsig verification configured"
    else
        print_skip "1Password debsig verification"
    fi

    apt_update
    apt_install 1password
}

install_drawio() {
    print_section "draw.io (diagrams.net)"

    # Check if draw.io is already installed
    if command_exists drawio || package_installed drawio; then
        print_skip "draw.io"
        return 0
    fi

    local drawio_deb
    drawio_deb=$(find "${SETUP_ARTIFACTS_DIR}" -name "drawio*.deb" 2>/dev/null | head -n1)

    if [[ -z "${drawio_deb}" ]]; then
        print_warning "draw.io .deb not found in ${SETUP_ARTIFACTS_DIR}"
        print_warning "Download from https://github.com/jgraph/drawio-desktop/releases"
        return 1
    fi

    apt_install_deb "${drawio_deb}" "draw.io"
}

install_flatpaks() {
    print_section "Install Flatpak Apps"

    if [[ "${INSTALL_FLATPAK}" != true ]]; then
        print_warning "Skipping Flatpak apps (Flatpak disabled)"
        return 0
    fi

    if ! command_exists flatpak; then
        print_warning "Flatpak not available, skipping"
        return 0
    fi

    local failed_apps=()
    local installed_count=0
    local skipped_count=0

    for app_entry in "${FLATPAK_APPS[@]}"; do
        local app_id="${app_entry%%|*}"
        local app_name="${app_entry##*|}"

        if flatpak_installed "${app_id}"; then
            print_skip "${app_name}"
            # Use assignment form to avoid set -e exit on zero increment
            skipped_count=$((skipped_count + 1))
        elif flatpak_install "${app_id}" "${app_name}"; then
            installed_count=$((installed_count + 1))
        else
            failed_apps+=("${app_name}")
            log "ERROR" "Failed to install flatpak: ${app_id} (${app_name})"
        fi
    done

    echo ""
    if [[ ${installed_count} -gt 0 ]]; then
        print_success "Newly installed: ${installed_count} apps"
    fi
    if [[ ${skipped_count} -gt 0 ]]; then
        print_status "Already installed: ${skipped_count} apps"
    fi
    if [[ ${#failed_apps[@]} -gt 0 ]]; then
        print_warning "Failed to install: ${failed_apps[*]}"
    fi
}

install_jetbrains_toolbox() {
    print_section "JetBrains Toolbox"

    local apps_dir="${HOME}/Apps"
    local install_dir="${apps_dir}/jetbrains-toolbox"
    local toolbox_binary="${install_dir}/bin/jetbrains-toolbox"

    # Check if already installed
    if [[ -d "${install_dir}" ]] || command_exists jetbrains-toolbox; then
        print_skip "JetBrains Toolbox"
        return 0
    fi

    local toolbox_archive
    toolbox_archive=$(find "${SETUP_ARTIFACTS_DIR}" -name "jetbrains-toolbox-*.tar.gz" 2>/dev/null | head -n1)

    if [[ -z "${toolbox_archive}" ]]; then
        print_warning "JetBrains Toolbox archive not found in ${SETUP_ARTIFACTS_DIR}"
        print_warning "Download from https://www.jetbrains.com/toolbox-app/"
        return 1
    fi

    # Install dependencies (idempotent via apt_install)
    print_status "Checking JetBrains Toolbox dependencies..."
    apt_install libfuse2 libxi6 libxrender1 libxtst6 mesa-utils libfontconfig libgtk-3-bin tar dbus-user-session

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "Extract JetBrains Toolbox to ${install_dir} and add to PATH"
        return 0
    fi

    # Create Apps directory if it doesn't exist
    if [[ ! -d "${apps_dir}" ]]; then
        print_status "Creating ${apps_dir} directory..."
        mkdir -p "${apps_dir}"
    fi

    # Extract the archive directly to the install location
    print_status "Extracting JetBrains Toolbox to ${install_dir}..."
    mkdir -p "${install_dir}"
    tar -xzf "${toolbox_archive}" -C "${install_dir}" --strip-components=1

    # Add to PATH in .bashrc if not already present
    local path_entry="export PATH=\"\${HOME}/Apps/jetbrains-toolbox/bin:\${PATH}\""
    local bashrc="${HOME}/.bashrc"

    if ! grep -qF "Apps/jetbrains-toolbox/bin" "${bashrc}" 2>/dev/null; then
        print_status "Adding JetBrains Toolbox to PATH in .bashrc..."
        echo "" >> "${bashrc}"
        echo "# JetBrains Toolbox" >> "${bashrc}"
        echo "${path_entry}" >> "${bashrc}"
        print_success "Added JetBrains Toolbox to PATH"
    else
        print_skip "JetBrains Toolbox PATH entry"
    fi

    print_status "Launching JetBrains Toolbox..."
    "${toolbox_binary}" &
    local toolbox_pid=$!
    print_status "JetBrains Toolbox started with PID: ${toolbox_pid}"

    # Wait 5 seconds before closing
    sleep 5
    if kill -0 "${toolbox_pid}" 2>/dev/null; then
        print_status "Closing JetBrains Toolbox after 5 seconds..."
        kill "${toolbox_pid}"
        print_success "JetBrains Toolbox closed"
    else
        print_warning "JetBrains Toolbox already exited"
    fi

    print_success "JetBrains Toolbox installed to ${install_dir}"
}

install_vmware() {
    print_section "VMware Workstation"

    # Check if VMware is already installed
    if command_exists vmware || command_exists vmplayer; then
        print_skip "VMware"
        return 0
    fi

    local vmware_bundle="${SETUP_ARTIFACTS_DIR}/VMware-Workstation-25H2.x86_64.bundle"

    if [[ ! -f "${vmware_bundle}" ]]; then
        print_warning "VMware installer not found: ${vmware_bundle}"
        print_warning "Download from https://www.vmware.com/products/workstation-pro.html"
        return 1
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "Install VMware from ${vmware_bundle}"
        return 0
    fi

    print_status "Installing VMware from ${vmware_bundle}..."
    chmod +x "${vmware_bundle}"
    sudo "${vmware_bundle}"
    print_success "VMware installation completed"
}

install_jdk() {
    print_section "Java Development Kit (JDK)"

    # Check if java and javac are already installed
    if command_exists java && command_exists javac; then
        local java_version
        java_version=$(java -version 2>&1 | head -n 1 | awk -F '"' '{print $2}')
        print_skip "JDK (Java ${java_version})"
        return 0
    fi

    # Install OpenJDK (using default JDK package)
    apt_install default-jdk

    # Verify installation
    if command_exists java && command_exists javac; then
        local java_version
        java_version=$(java -version 2>&1 | head -n 1 | awk -F '"' '{print $2}')
        print_success "JDK installed (Java ${java_version})"
    else
        print_warning "JDK installation completed but java/javac not found in PATH"
    fi
}

install_tizen_studio() {
    print_section "Tizen Studio Web CLI"

    # Check if sdb is already installed (check both PATH and file location)
    local sdb_path="${HOME}/tizen-studio/tools/sdb"
    if command_exists sdb || [[ -f "${sdb_path}" ]]; then
        print_skip "Tizen Studio Web CLI"
        return 0
    fi

    # Check for JDK dependency
    if ! command_exists java || ! command_exists javac; then
        print_error "JDK is required for Tizen Studio but not found"
        print_error "Please install JDK first (run install_jdk)"
        return 1
    fi

    local tizen_installer="${SETUP_ARTIFACTS_DIR}/web-cli_Tizen_Studio_6.1_ubuntu-64.bin"

    if [[ ! -f "${tizen_installer}" ]]; then
        print_warning "Tizen Studio installer not found: ${tizen_installer}"
        print_warning "Download from https://developer.tizen.org/development/tizen-studio/download"
        return 1
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "Install Tizen Studio from ${tizen_installer}"
        print_dry_run "Add Tizen Studio sdb to PATH in .bashrc"
        return 0
    fi

    print_status "Installing Tizen Studio Web CLI from ${tizen_installer}..."
    chmod +x "${tizen_installer}"
    "${tizen_installer}"
    print_success "Tizen Studio installation completed"

    # Add sdb to PATH in .bashrc if not already present
    local path_entry="export PATH=\"\${HOME}/tizen-studio/tools:\${PATH}\""
    local bashrc="${HOME}/.bashrc"

    if ! grep -qF "tizen-studio/tools" "${bashrc}" 2>/dev/null; then
        print_status "Adding Tizen Studio sdb to PATH in .bashrc..."
        echo "" >> "${bashrc}"
        echo "# Tizen Studio" >> "${bashrc}"
        echo "${path_entry}" >> "${bashrc}"
        print_success "Added Tizen Studio sdb to PATH"
    else
        print_skip "Tizen Studio PATH entry"
    fi
}

install_git() {
    print_section "Git"

    if command_exists git; then
        local git_version
        git_version=$(git --version | awk '{print $3}')
        print_skip "Git (version ${git_version})"
        return 0
    fi

    apt_install git
}

install_git_lfs() {
    print_section "Git LFS"

    if command_exists git-lfs; then
        local git_lfs_version
        git_lfs_version=$(git-lfs --version | awk '{print $1"/"$2}')
        print_skip "Git LFS (${git_lfs_version})"
        return 0
    fi

    # Install git-lfs package
    apt_install git-lfs

    # Initialize git-lfs for the user
    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "git lfs install"
        return 0
    fi

    if command_exists git-lfs; then
        print_status "Configuring Git LFS for user..."
        git lfs install
        print_success "Git LFS configured"
    else
        print_warning "Git LFS command not available after installation"
    fi
}

install_github_desktop() {
    print_section "GitHub Desktop"

    if command_exists github-desktop || package_installed github-desktop; then
        print_skip "GitHub Desktop"
        return 0
    fi

    local keyring="/usr/share/keyrings/mwt-desktop.gpg"
    local sources_file="/etc/apt/sources.list.d/mwt-desktop.list"

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "Install GitHub Desktop (add GPG key, repo, and install package)"
        return 0
    fi

    # Add GPG key if not present
    if ! gpg_key_exists "${keyring}"; then
        print_status "Adding GitHub Desktop GPG key..."
        wget -qO - https://mirror.mwt.me/shiftkey-desktop/gpgkey | \
            gpg --dearmor | sudo tee "${keyring}" > /dev/null
        print_success "GPG key added"
    else
        print_skip "GitHub Desktop GPG key"
    fi

    # Add repository if not present
    if [[ ! -f "${sources_file}" ]]; then
        print_status "Adding GitHub Desktop repository..."
        sudo sh -c 'echo "deb [arch=amd64 signed-by=/usr/share/keyrings/mwt-desktop.gpg] https://mirror.mwt.me/shiftkey-desktop/deb/ any main" > /etc/apt/sources.list.d/mwt-desktop.list'
        print_success "Repository added"
    else
        print_skip "GitHub Desktop repository"
    fi

    apt_update
    apt_install github-desktop
}

install_nodejs() {
    print_section "Node.js & npm"

    local target_node_version="20.19.5"
    local skip_install=false

    # Check if node and npm are already installed with correct version
    if command_exists node && command_exists npm; then
        local node_version
        local npm_version
        node_version=$(node --version | sed 's/^v//')
        npm_version=$(npm --version)
        
        if [[ "${node_version}" == "${target_node_version}" ]]; then
            print_skip "Node.js v${node_version} & npm ${npm_version}"
            skip_install=true
        else
            print_status "Current Node.js version: ${node_version}, target: ${target_node_version}"
        fi
    fi

    if [[ "${skip_install}" == false ]]; then
        # Check if NodeSource repository is already added
        local nodesource_list="/etc/apt/sources.list.d/nodesource.list"
        local needs_repo_setup=false

        if [[ ! -f "${nodesource_list}" ]]; then
            needs_repo_setup=true
        fi

        if [[ "${needs_repo_setup}" == true ]]; then
            if [[ "${DRY_RUN}" == true ]]; then
                print_dry_run "Add NodeSource repository and install Node.js (LTS)"
            else
                print_status "Adding NodeSource repository for Node.js LTS..."
                curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
                print_success "NodeSource repository added"
            fi
        else
            print_skip "NodeSource repository"
        fi

        # Install nodejs (npm is included automatically)
        apt_install nodejs

        # Verify npm is available
        if command_exists npm; then
            local npm_version
            npm_version=$(npm --version)
            print_success "npm ${npm_version} installed"
        fi

        # Install 'n' package manager globally
        if [[ "${DRY_RUN}" == true ]]; then
            print_dry_run "npm install -g n"
            print_dry_run "n ${target_node_version}"
        else
            if ! command_exists n; then
                print_status "Installing 'n' Node version manager..."
                sudo npm install -g n
                print_success "'n' installed"
            else
                print_skip "'n' Node version manager"
            fi

            # Use 'n' to install specific Node.js version
            print_status "Installing Node.js ${target_node_version} using 'n'..."
            sudo n "${target_node_version}"
            print_success "Node.js ${target_node_version} installed"

            # Update PATH for current shell session
            export PATH="/usr/local/bin:${PATH}"
            
            # Verify the correct version is now active
            if command_exists node; then
                local new_node_version
                new_node_version=$(node --version)
                print_success "Active Node.js version: ${new_node_version}"
            fi
        fi
    fi
}

install_npm_packages() {
    print_section "NPM Global Packages"

    if ! command_exists npm; then
        print_warning "npm not available, skipping npm packages"
        return 0
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "npm install -g ${NPM_PACKAGES[*]}"
        return 0
    fi

    local installed_count=0
    local skipped_count=0

    for package in "${NPM_PACKAGES[@]}"; do
        # Check if package is already installed globally
        if npm list -g "${package}" &>/dev/null; then
            print_skip "${package}"
            skipped_count=$((skipped_count + 1))
        else
            print_status "Installing npm package: ${package}..."
            if sudo npm install -g "${package}"; then
                print_success "${package} installed"
                installed_count=$((installed_count + 1))
            else
                print_warning "Failed to install ${package}"
            fi
        fi
    done

    echo ""
    if [[ ${installed_count} -gt 0 ]]; then
        print_success "Newly installed: ${installed_count} packages"
    fi
    if [[ ${skipped_count} -gt 0 ]]; then
        print_status "Already installed: ${skipped_count} packages"
    fi
}

install_bun() {
    print_section "Bun Runtime"

    # Check if bun is already installed (check both PATH and file location)
    local bun_path="${HOME}/.bun/bin/bun"
    if command_exists bun || [[ -f "${bun_path}" ]]; then
        local bun_version
        if command_exists bun; then
            bun_version=$(bun --version)
        else
            bun_version=$("${bun_path}" --version)
        fi
        print_skip "Bun (version ${bun_version})"
        return 0
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "Install Bun via official install script"
        print_dry_run "Add Bun to PATH in .bashrc"
        return 0
    fi

    print_status "Installing Bun runtime..."
    curl -fsSL https://bun.sh/install | bash
    print_success "Bun installed"

    # Add bun to PATH in .bashrc if not already present
    local path_entry="export PATH=\"\${HOME}/.bun/bin:\${PATH}\""
    local bashrc="${HOME}/.bashrc"

    if ! grep -qF ".bun/bin" "${bashrc}" 2>/dev/null; then
        print_status "Adding Bun to PATH in .bashrc..."
        echo "" >> "${bashrc}"
        echo "# Bun" >> "${bashrc}"
        echo "${path_entry}" >> "${bashrc}"
        print_success "Added Bun to PATH"
    else
        print_skip "Bun PATH entry"
    fi

    # Update PATH for current shell session
    export PATH="${HOME}/.bun/bin:${PATH}"

    # Verify installation
    if command_exists bun; then
        local bun_version
        bun_version=$(bun --version)
        print_success "Bun ${bun_version} installed successfully"
    else
        print_warning "Bun installed but not found in PATH (may need to restart shell)"
    fi
}

install_docker() {
    print_section "Docker & Docker Desktop"

    local docker_installed=false
    local docker_desktop_installed=false

    # Check if Docker is already installed
    if command_exists docker; then
        local docker_version
        docker_version=$(docker --version | awk '{print $3}' | sed 's/,//')
        print_skip "Docker Engine (version ${docker_version})"
        docker_installed=true
    fi

    # Check if Docker Desktop is already installed
    if command_exists docker-desktop || package_installed docker-desktop; then
        print_skip "Docker Desktop"
        docker_desktop_installed=true
    fi

    # If both are installed, we're done
    if [[ "${docker_installed}" == true ]] && [[ "${docker_desktop_installed}" == true ]]; then
        return 0
    fi

    # Install Docker Engine if not present
    if [[ "${docker_installed}" == false ]]; then
        local keyring="/usr/share/keyrings/docker-archive-keyring.gpg"
        local sources_file="/etc/apt/sources.list.d/docker.list"

        if [[ "${DRY_RUN}" == true ]]; then
            print_dry_run "Install Docker Engine (add GPG key, repo, and install packages)"
        else
            # Add Docker's official GPG key if not present
            if ! gpg_key_exists "${keyring}"; then
                print_status "Adding Docker GPG key..."
                curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
                    sudo gpg --dearmor --output "${keyring}"
                print_success "Docker GPG key added"
            else
                print_skip "Docker GPG key"
            fi

            # Add Docker repository if not present
            if [[ ! -f "${sources_file}" ]]; then
                print_status "Adding Docker repository..."
                echo "deb [arch=$(dpkg --print-architecture) signed-by=${keyring}] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
                    sudo tee "${sources_file}" > /dev/null
                print_success "Docker repository added"
            else
                print_skip "Docker repository"
            fi

            apt_update
        fi

        # Install Docker Engine packages
        apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

        if [[ "${DRY_RUN}" != true ]]; then
            # Add current user to docker group
            if groups "${USER}" | grep -qw docker; then
                print_skip "User '${USER}' in docker group"
            else
                print_status "Adding user '${USER}' to docker group..."
                sudo usermod -aG docker "${USER}"
                print_success "User added to docker group"
                print_warning "You'll need to log out and back in for group changes to take effect"
            fi

            # Start and enable Docker service
            if systemctl is-active --quiet docker; then
                print_skip "Docker service (already running)"
            else
                print_status "Starting Docker service..."
                sudo systemctl start docker
                sudo systemctl enable docker
                print_success "Docker service started and enabled"
            fi
        fi
    fi

    # Install Docker Desktop if not present
    if [[ "${docker_desktop_installed}" == false ]]; then
        local docker_desktop_deb
        docker_desktop_deb=$(find "${SETUP_ARTIFACTS_DIR}" -name "docker-desktop*.deb" 2>/dev/null | head -n1)

        if [[ -z "${docker_desktop_deb}" ]]; then
            print_warning "Docker Desktop .deb not found in ${SETUP_ARTIFACTS_DIR}"
            print_warning "Download from https://docs.docker.com/desktop/install/ubuntu/"
            return 1
        fi

        # Install Docker Desktop dependencies first
        apt_install pass gnome-keyring

        apt_install_deb "${docker_desktop_deb}" "Docker Desktop"
    fi

    if [[ "${docker_installed}" == false ]] && [[ "${DRY_RUN}" != true ]]; then
        echo ""
        print_success "Docker installation complete!"
        print_status "Docker version: $(docker --version 2>/dev/null || echo 'N/A')"
        print_status "Docker Compose version: $(docker compose version 2>/dev/null || echo 'N/A')"
        
        if [[ "${docker_desktop_installed}" == false ]]; then
            print_status "Docker Desktop can be launched from your applications menu"
        fi
    fi
}

install_twingate() {
    print_section "Twingate VPN Client"

    if command_exists twingate || package_installed twingate; then
        print_skip "Twingate"
        return 0
    fi

    local keyring="/usr/share/keyrings/twingate-client-keyring.gpg"
    local sources_file="/etc/apt/sources.list.d/twingate.list"

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "Install Twingate (add GPG key, repo, and install package)"
        return 0
    fi

    # Ensure required dependencies are installed
    print_status "Checking Twingate dependencies..."
    apt_install curl gpg ca-certificates

    # Add GPG key if not present
    if ! gpg_key_exists "${keyring}"; then
        print_status "Adding Twingate GPG key..."
        curl -fsSL https://packages.twingate.com/apt/gpg.key | \
            sudo gpg --dearmor -o "${keyring}"
        print_success "GPG key added"
    else
        print_skip "Twingate GPG key"
    fi

    # Add repository if not present
    if [[ ! -f "${sources_file}" ]]; then
        print_status "Adding Twingate repository..."
        echo "deb [signed-by=${keyring}] https://packages.twingate.com/apt/ * *" | \
            sudo tee "${sources_file}" > /dev/null
        print_success "Repository added"
    else
        print_skip "Twingate repository"
    fi

    apt_update
    apt_install twingate

    echo ""
    print_success "Twingate installed successfully!"
    print_warning "Configure Twingate by running: sudo twingate setup"
    print_status "Network name: angelstudios"
    echo ""
}

install_desktop_settings() {
    print_section "Desktop Settings (Ubuntu/Wayland)"

    if ! command_exists gsettings; then
        print_warning "gsettings not available, skipping desktop configuration"
        return 0
    fi

    # Check if running on Wayland
    local session_type="${XDG_SESSION_TYPE:-unknown}"
    if [[ "${session_type}" == "wayland" ]]; then
        print_status "Detected Wayland session"
    elif [[ "${session_type}" == "x11" ]]; then
        print_warning "Detected X11 session (Wayland recommended for Ubuntu)"
    else
        print_status "Session type: ${session_type}"
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "Configure Ubuntu desktop settings (dark mode, dock, icons)"
        return 0
    fi

    local changes_made=0

    # Set dark mode (Ubuntu GNOME with Yaru theme)
    local current_color_scheme
    current_color_scheme=$(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null || echo "")
    if [[ "${current_color_scheme}" != "'prefer-dark'" ]]; then
        print_status "Setting appearance to dark mode..."
        gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
        gsettings set org.gnome.desktop.interface gtk-theme 'Yaru-dark'
        gsettings set org.gnome.desktop.interface icon-theme 'Yaru-dark'
        # Also set legacy settings for older apps
        gsettings set org.gnome.desktop.wm.preferences theme 'Yaru-dark'
        print_success "Dark mode enabled (Yaru-dark theme)"
        changes_made=$((changes_made + 1))
    else
        print_skip "Dark mode (already enabled)"
    fi

    # Configure Ubuntu Dock (dash-to-dock is built into Ubuntu)
    # Ubuntu uses a forked version with schema: org.gnome.shell.extensions.dash-to-dock
    if gsettings list-schemas | grep -q "org.gnome.shell.extensions.dash-to-dock"; then
        local dock_schema="org.gnome.shell.extensions.dash-to-dock"
        
        # Enable auto-hide (intellihide is Ubuntu's default smart hide)
        local dock_fixed
        dock_fixed=$(gsettings get ${dock_schema} dock-fixed 2>/dev/null || echo "true")
        if [[ "${dock_fixed}" != "false" ]]; then
            print_status "Enabling dock auto-hide..."
            gsettings set ${dock_schema} dock-fixed false
            gsettings set ${dock_schema} autohide true
            gsettings set ${dock_schema} intellihide true
            gsettings set ${dock_schema} intellihide-mode 'ALL_WINDOWS'
            # Wayland-specific: ensure proper behavior
            gsettings set ${dock_schema} autohide-in-fullscreen false
            print_success "Dock auto-hide enabled (intellihide mode)"
            changes_made=$((changes_made + 1))
        else
            print_skip "Dock auto-hide (already enabled)"
        fi

        # Turn off panel mode (extend-height makes dock span full height)
        local extend_height
        extend_height=$(gsettings get ${dock_schema} extend-height 2>/dev/null || echo "true")
        if [[ "${extend_height}" != "false" ]]; then
            print_status "Disabling dock panel mode..."
            gsettings set ${dock_schema} extend-height false
            print_success "Panel mode disabled"
            changes_made=$((changes_made + 1))
        else
            print_skip "Panel mode (already disabled)"
        fi

        # Set icon size to smallest (Ubuntu default is 48, smallest practical is 24)
        local icon_size
        icon_size=$(gsettings get ${dock_schema} dash-max-icon-size 2>/dev/null || echo "48")
        if [[ "${icon_size}" != "16" ]]; then
            print_status "Setting dock icon size to smallest..."
            gsettings set ${dock_schema} dash-max-icon-size 16
            print_success "Icon size set to 16px (smallest)"
            changes_made=$((changes_made + 1))
        else
            print_skip "Icon size (already at smallest)"
        fi

        # Position dock to bottom
        local dock_position
        dock_position=$(gsettings get ${dock_schema} dock-position 2>/dev/null || echo "'LEFT'")
        if [[ "${dock_position}" != "'BOTTOM'" ]]; then
            print_status "Positioning dock to bottom..."
            gsettings set ${dock_schema} dock-position 'BOTTOM'
            print_success "Dock positioned to bottom"
            changes_made=$((changes_made + 1))
        else
            print_skip "Dock position (already at bottom)"
        fi

        changes_made=$((changes_made + 1))
    else
        print_warning "Ubuntu Dock (dash-to-dock) not found, skipping dock settings"
    fi

    # Set desktop icon position to top-right (Ubuntu 23.04+ uses DING extension)
    if gsettings list-schemas | grep -q "org.gnome.shell.extensions.ding"; then
        local start_corner
        start_corner=$(gsettings get org.gnome.shell.extensions.ding start-corner 2>/dev/null || echo "'top-left'")
        if [[ "${start_corner}" != "'top-right'" ]]; then
            print_status "Setting desktop icons to start from top-right..."
            gsettings set org.gnome.shell.extensions.ding start-corner 'top-right'
            # Also configure icon arrangement
            gsettings set org.gnome.shell.extensions.ding icon-size 'small'
            gsettings set org.gnome.shell.extensions.ding show-home false
            gsettings set org.gnome.shell.extensions.ding show-trash true
            gsettings set org.gnome.shell.extensions.ding show-volumes true
            print_success "Desktop icons set to top-right (DING extension)"
            changes_made=$((changes_made + 1))
        else
            print_skip "Desktop icons position (already top-right)"
        fi
    else
        print_warning "DING extension not found (Ubuntu desktop icons)"
    fi

    echo ""
    if [[ ${changes_made} -gt 0 ]]; then
        print_success "Ubuntu desktop settings configured (${changes_made} changes made)"
        if [[ "${session_type}" == "wayland" ]]; then
            print_status "Wayland detected - settings optimized for Wayland session"
        fi
        print_status "You may need to log out and back in for all changes to take effect"
    else
        print_status "All desktop settings already configured"
    fi
}

install_ffmpeg() {
    print_section "FFmpeg"

    if command_exists ffmpeg; then
        local ffmpeg_version
        ffmpeg_version=$(ffmpeg -version 2>&1 | head -n 1 | awk '{print $3}')
        print_skip "FFmpeg (version ${ffmpeg_version})"
        return 0
    fi

    apt_install ffmpeg
}

install_spotify() {
    print_section "Spotify"

    if command_exists spotify || package_installed spotify-client; then
        print_skip "Spotify"
        return 0
    fi

    local keyring="/etc/apt/trusted.gpg.d/spotify.gpg"
    local sources_file="/etc/apt/sources.list.d/spotify.list"

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "Install Spotify (add GPG key, repo, and install package)"
        return 0
    fi

    # Add GPG key if not present
    if ! gpg_key_exists "${keyring}"; then
        print_status "Adding Spotify GPG key..."
        curl -sS https://download.spotify.com/debian/pubkey_5384CE82BA52C83A.asc | \
            sudo gpg --dearmor --yes -o "${keyring}"
        print_success "GPG key added"
    else
        print_skip "Spotify GPG key"
    fi

    # Add repository if not present
    if [[ ! -f "${sources_file}" ]]; then
        print_status "Adding Spotify repository..."
        echo "deb https://repository.spotify.com stable non-free" | \
            sudo tee "${sources_file}" > /dev/null
        print_success "Repository added"
    else
        print_skip "Spotify repository"
    fi

    apt_update
    apt_install spotify-client
}

install_zoom() {
    print_section "Zoom Video Conferencing"

    # Check if Zoom is already installed
    if command_exists zoom || package_installed zoom; then
        print_skip "Zoom"
        return 0
    fi

    local zoom_deb
    zoom_deb=$(find "${SETUP_ARTIFACTS_DIR}" -name "zoom*.deb" 2>/dev/null | head -n1)

    if [[ -z "${zoom_deb}" ]]; then
        print_warning "Zoom .deb not found in ${SETUP_ARTIFACTS_DIR}"
        print_warning "Download from https://zoom.us/download?os=linux"
        return 1
    fi

    apt_install_deb "${zoom_deb}" "Zoom"
}

install_protonmail() {
    print_section "Proton Mail Desktop"

    # Check if Proton Mail is already installed
    if command_exists proton-mail || package_installed proton-mail; then
        print_skip "Proton Mail"
        return 0
    fi

    local protonmail_deb
    protonmail_deb=$(find "${SETUP_ARTIFACTS_DIR}" -name "ProtonMail*.deb" -o -name "protonmail*.deb" 2>/dev/null | head -n1)

    if [[ -z "${protonmail_deb}" ]]; then
        print_warning "Proton Mail .deb not found in ${SETUP_ARTIFACTS_DIR}"
        print_warning "Download from https://proton.me/mail/download"
        return 1
    fi

    apt_install_deb "${protonmail_deb}" "Proton Mail"
}

install_gimp() {
    print_section "GIMP Image Editor"

    if command_exists gimp || package_installed gimp; then
        print_skip "GIMP"
        return 0
    fi

    apt_install gimp
}

# =============================================================================
# Main Execution
# =============================================================================

show_help() {
    sed -n '2,14p' "$0" | sed 's/^#//'
    exit 0
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force-system76)
                INSTALL_SYSTEM76=true
                shift
                ;;
            --skip-system76)
                INSTALL_SYSTEM76=false
                shift
                ;;
            --skip-system76-nvidia)
                INSTALL_SYSTEM76_NVIDIA=false
                shift
                ;;
            --skip-flatpak)
                INSTALL_FLATPAK=false
                shift
                ;;
            --skip-reboot-pause)
                PAUSE_FOR_REBOOT=false
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --help|-h)
                show_help
                ;;
            *)
                print_error "Unknown option: $1"
                show_help
                ;;
        esac
    done
}

main() {
    parse_arguments "$@"

    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              System Setup Script                           ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    if [[ "${DRY_RUN}" == true ]]; then
        echo -e "${YELLOW}>>> DRY RUN MODE - No changes will be made <<<${NC}"
        echo ""
    fi

    print_status "Log file: ${LOG_FILE}"
    print_status "Setup artifacts directory: ${SETUP_ARTIFACTS_DIR}"
    echo ""

    # Verify we have necessary permissions (skip in dry run)
    if [[ "${DRY_RUN}" != true ]]; then
        if ! sudo -v; then
            print_error "Failed to obtain sudo privileges"
            exit 1
        fi

        # Keep sudo alive throughout the script
        while true; do
            sudo -n true
            sleep 60
            kill -0 "$$" || exit
        done 2>/dev/null &
    fi

    # Create artifacts directory if it doesn't exist
    mkdir -p "${SETUP_ARTIFACTS_DIR}"

    # Ensure curl is installed (required for various setup operations)
    if ! command_exists curl; then
        print_status "Installing curl (required dependency)..."
        if [[ "${DRY_RUN}" != true ]]; then
            sudo apt update -qq
            sudo apt install -y curl
            print_success "curl installed"
        else
            print_dry_run "apt install curl"
        fi
    else
        print_skip "curl"
    fi

    # Run installation steps
    print_section "System Updates"
    apt_update
    apt_upgrade

    install_system76_drivers
    install_flatpak
    install_git
    install_git_lfs
    install_github_desktop
    install_nodejs
    install_npm_packages
    install_bun
    install_docker
    install_brave
    install_google_chrome
    install_chromium
    install_slack
    install_cursor
    install_drawio
    install_1password
    install_flatpaks
    install_jetbrains_toolbox
    install_vmware
    install_jdk
    install_tizen_studio
    install_twingate
    install_desktop_settings
    install_ffmpeg
    install_spotify
    install_zoom
    install_protonmail
    install_gimp

    # Cleanup
    print_section "System Cleanup"
    print_status "Running apt auto cleanup..."
    sudo apt autoremove -y 2>&1 | tee -a "${LOG_FILE}"
    sudo apt autoclean -y 2>&1 | tee -a "${LOG_FILE}"
    print_success "Cleanup completed"

    # Final summary
    print_section "Setup Complete"
    print_success "System setup finished successfully!"
    print_status "Log file saved to: ${LOG_FILE}"
    echo ""
    print_warning "Recommended: Restart your computer to ensure all changes take effect"
    echo ""
}

main "$@"

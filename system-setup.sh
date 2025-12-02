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

    local apps=(
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
        "io.github.shiftey.Desktop|GitHub Desktop"
    )

    local failed_apps=()
    local installed_count=0
    local skipped_count=0

    for app_entry in "${apps[@]}"; do
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

    local packages=(
        "@webos-tools/cli"
        "pnpm"
    )

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "npm install -g ${packages[*]}"
        return 0
    fi

    local installed_count=0
    local skipped_count=0

    for package in "${packages[@]}"; do
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
    install_nodejs
    install_npm_packages
    install_brave
    install_slack
    install_cursor
    install_1password
    install_flatpaks
    install_jetbrains_toolbox
    install_vmware

    # Final summary
    print_section "Setup Complete"
    print_success "System setup finished successfully!"
    print_status "Log file saved to: ${LOG_FILE}"
    echo ""
    print_warning "Recommended: Restart your computer to ensure all changes take effect"
    echo ""
}

main "$@"

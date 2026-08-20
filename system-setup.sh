#!/usr/bin/env bash
#
# System Setup Script
# Configures a fresh Ubuntu/Pop!_OS installation with common development tools
#
# Usage: ./system-setup.sh [OPTIONS]
#   --force-system76          Force System76 driver installation (auto-detected by default)
#   --skip-system76           Skip System76 driver installation even if detected
#   --skip-system76-nvidia    Skip NVIDIA driver installation
#   --skip-flatpak            Skip Flatpak and GNOME Circle apps
#   --skip-reboot-pause       Skip the reboot pause after Flatpak setup
#   --dry-run                 Show what would be installed without making changes
#   --help                    Show this help message
#

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="${SCRIPT_DIR}/setup-$(date +%Y%m%d-%H%M%S).log"

# Feature flags (can be overridden via command line)
INSTALL_SYSTEM76="auto"  # auto, true, or false
INSTALL_SYSTEM76_NVIDIA=true
INSTALL_FLATPAK=true
PAUSE_FOR_REBOOT=true
DRY_RUN=false

# Configurable versions and values
readonly TARGET_NODE_VERSION="20.19.5"
readonly TWINGATE_NETWORK="angelstudios"

# =============================================================================
# Application Lists (edit these to customize your installation)
# =============================================================================

# Signed-repo apps: "label|gpg_url|keyring|sources_file|repo_line|packages"
#
# Placeholders expanded at runtime:
#   {ARCH}     = $(dpkg --print-architecture)
#   {CODENAME} = $(lsb_release -cs)
#   {KEYRING}  = the keyring path from this entry
#
# Apps in SIMPLE_SIGNED_REPO_APPS are installed automatically with no extra
# logic. Others have dedicated install functions for post-install steps.
readonly SIGNED_REPO_APPS=(
    # Browsers
    "Google Chrome|https://dl.google.com/linux/linux_signing_key.pub|/usr/share/keyrings/google-chrome-keyring.gpg|/etc/apt/sources.list.d/google-chrome.list|deb [arch={ARCH} signed-by={KEYRING}] https://dl.google.com/linux/chrome/deb/ stable main|google-chrome-stable"
    # Version control
    "GitHub CLI|https://cli.github.com/packages/githubcli-archive-keyring.gpg|/usr/share/keyrings/githubcli-archive-keyring.gpg|/etc/apt/sources.list.d/github-cli.list|deb [arch={ARCH} signed-by={KEYRING}] https://cli.github.com/packages stable main|gh"
    "GitHub Desktop|https://mirror.mwt.me/shiftkey-desktop/gpgkey|/usr/share/keyrings/mwt-desktop.gpg|/etc/apt/sources.list.d/mwt-desktop.list|deb [arch={ARCH} signed-by={KEYRING}] https://mirror.mwt.me/shiftkey-desktop/deb/ any main|github-desktop"
    # Containers (post-install: usermod, systemctl)
    "Docker|https://download.docker.com/linux/ubuntu/gpg|/usr/share/keyrings/docker-archive-keyring.gpg|/etc/apt/sources.list.d/docker.list|deb [arch={ARCH} signed-by={KEYRING}] https://download.docker.com/linux/ubuntu {CODENAME} stable|docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
    # VPN (post-install: setup message)
    "Twingate|https://packages.twingate.com/apt/gpg.key|/usr/share/keyrings/twingate-client-keyring.gpg|/etc/apt/sources.list.d/twingate.list|deb [signed-by={KEYRING}] https://packages.twingate.com/apt/ * *|twingate"
    # Media
    "Spotify|https://download.spotify.com/debian/pubkey_5384CE82BA52C83A.asc|/usr/share/keyrings/spotify-archive-keyring.gpg|/etc/apt/sources.list.d/spotify.list|deb [signed-by={KEYRING}] https://repository.spotify.com stable non-free|spotify-client"
    # Security (post-install: debsig verification)
    "1Password|https://downloads.1password.com/linux/keys/1password.asc|/usr/share/keyrings/1password-archive-keyring.gpg|/etc/apt/sources.list.d/1password.list|deb [arch={ARCH} signed-by={KEYRING}] https://downloads.1password.com/linux/debian/{ARCH} stable main|1password"
    # Databases (post-install: systemctl)
    "PostgreSQL|https://www.postgresql.org/media/keys/ACCC4CF8.asc|/usr/share/keyrings/pgdg-archive-keyring.gpg|/etc/apt/sources.list.d/pgdg.list|deb [signed-by={KEYRING}] https://apt.postgresql.org/pub/repos/apt {CODENAME}-pgdg main|postgresql postgresql-contrib"
    # Databases
    "pgAdmin 4|https://www.pgadmin.org/static/packages_pgadmin_org.pub|/usr/share/keyrings/pgadmin4-archive-keyring.gpg|/etc/apt/sources.list.d/pgadmin4.list|deb [signed-by={KEYRING}] https://ftp.postgresql.org/pub/pgadmin/pgadmin4/apt/{CODENAME} pgadmin4 main|pgadmin4-desktop"
    # Editors
    "VSCodium|https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg|/usr/share/keyrings/vscodium-archive-keyring.gpg|/etc/apt/sources.list.d/vscodium.list|deb [ signed-by={KEYRING} ] https://download.vscodium.com/debs vscodium main|codium"
    # Dev tools
    "ngrok|https://ngrok-agent.s3.amazonaws.com/ngrok.asc|/usr/share/keyrings/ngrok-archive-keyring.gpg|/etc/apt/sources.list.d/ngrok.list|deb [signed-by={KEYRING}] https://ngrok-agent.s3.amazonaws.com buster main|ngrok"
)

# Labels of SIGNED_REPO_APPS entries that need no post-install hooks.
# These are installed automatically by install_signed_repo_apps().
readonly SIMPLE_SIGNED_REPO_APPS=(
    "Google Chrome"
    "GitHub CLI"
    "GitHub Desktop"
    "Spotify"
    "pgAdmin 4"
    "ngrok"
    "VSCodium"
)

# Simple APT packages (default repos, no custom repo needed):
# "command_name|package_name|display_name"
readonly SIMPLE_APT_APPS=(
    "chromium-browser|chromium-browser|Chromium Browser"
    "ffmpeg|ffmpeg|FFmpeg"
    "gimp|gimp|GIMP Image Editor"
    "go|golang-go|Go Programming Language"
)

# Flatpak applications: "app.id|Display Name"
readonly FLATPAK_APPS=(
    "org.gnome.World.PikaBackup|Pika Backup"
    "io.github.fizzyizzy05.binary|Binary"
    "dev.geopjr.Collision|Collision"
    "io.github.wartybix.Constrict|Constrict"
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
    "org.libreoffice.LibreOffice|LibreOffice"
    "com.slack.Slack|Slack"
    "com.jgraph.drawio.desktop|draw.io"
    "us.zoom.Zoom|Zoom"
    "me.proton.Mail|Proton Mail"
    "com.valvesoftware.Steam|Steam"
    "org.videolan.VLC|VLC Media Player"
)

# NPM global packages
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

SUDO_KEEPALIVE_PID=""

cleanup() {
    local exit_code=$?
    # Kill sudo keepalive background process
    if [[ -n "${SUDO_KEEPALIVE_PID}" ]]; then
        kill "${SUDO_KEEPALIVE_PID}" 2>/dev/null || true
        wait "${SUDO_KEEPALIVE_PID}" 2>/dev/null || true
    fi
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
    [[ -f /sys/class/dmi/id/sys_vendor ]] && grep -qi "system76" /sys/class/dmi/id/sys_vendor 2>/dev/null
}

has_nvidia_gpu() {
    lspci 2>/dev/null | grep -qi "nvidia"
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
    local apt_output
    if apt_output=$(sudo apt update -qq 2>&1); then
        print_success "Package lists updated"
    else
        local exit_code=$?
        log "ERROR" "apt update output: ${apt_output}"
        print_error "apt update failed (exit code ${exit_code}). Output:"
        echo "${apt_output}" >&2
        return ${exit_code}
    fi
}

apt_upgrade() {
    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "apt upgrade"
        return 0
    fi
    print_status "Upgrading installed packages..."
    local apt_output
    if apt_output=$(sudo apt upgrade -y 2>&1); then
        print_success "Packages upgraded"
    else
        local exit_code=$?
        log "ERROR" "apt upgrade output: ${apt_output}"
        print_error "apt upgrade failed (exit code ${exit_code}). Output:"
        echo "${apt_output}" >&2
        return ${exit_code}
    fi
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
    local apt_output
    if apt_output=$(sudo apt install -y "${packages_to_install[@]}" 2>&1); then
        print_success "Packages installed: ${packages_to_install[*]}"
    else
        local exit_code=$?
        log "ERROR" "apt install output: ${apt_output}"
        print_error "apt install failed for ${packages_to_install[*]} (exit code ${exit_code}). Output:"
        echo "${apt_output}" >&2
        return ${exit_code}
    fi
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
# Signed Repository Helper Functions
# =============================================================================

NEEDS_APT_UPDATE=false

apt_update_if_needed() {
    if [[ "${NEEDS_APT_UPDATE}" == true ]]; then
        apt_update
        NEEDS_APT_UPDATE=false
    fi
}

# add_signed_repo LABEL GPG_URL KEYRING SOURCES_FILE REPO_LINE
#
# Idempotently adds a GPG key and apt sources file for a signed repository.
# Sets NEEDS_APT_UPDATE=true if a new repo was added.
add_signed_repo() {
    local label="$1"
    local gpg_url="$2"
    local keyring="$3"
    local sources_file="$4"
    local repo_line="$5"

    # Expand placeholders
    local arch codename
    arch="$(dpkg --print-architecture)"
    codename="$(lsb_release -cs)"
    repo_line="${repo_line//\{ARCH\}/${arch}}"
    repo_line="${repo_line//\{CODENAME\}/${codename}}"
    repo_line="${repo_line//\{KEYRING\}/${keyring}}"

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "Add ${label} GPG key and repository"
        return 0
    fi

    # Ensure keyring parent directory exists
    local keyring_dir
    keyring_dir="$(dirname "${keyring}")"
    if [[ ! -d "${keyring_dir}" ]]; then
        sudo mkdir -p "${keyring_dir}"
    fi

    # Add GPG key if not present
    if ! gpg_key_exists "${keyring}"; then
        print_status "Adding ${label} GPG key..."
        curl -fsSL "${gpg_url}" | sudo gpg --dearmor --yes --output "${keyring}"
        print_success "${label} GPG key added"
    else
        print_skip "${label} GPG key"
    fi

    # Add repository if not present
    if [[ ! -f "${sources_file}" ]]; then
        print_status "Adding ${label} repository..."
        echo "${repo_line}" | sudo tee "${sources_file}" > /dev/null
        print_success "${label} repository added"
        NEEDS_APT_UPDATE=true
    else
        print_skip "${label} repository"
    fi
}

# Looks up a SIGNED_REPO_APPS entry by label and calls add_signed_repo().
add_signed_repo_by_name() {
    local target_label="$1"
    local entry
    for entry in "${SIGNED_REPO_APPS[@]}"; do
        if [[ "${entry%%|*}" == "${target_label}" ]]; then
            local label gpg_url keyring sources_file repo_line packages
            IFS='|' read -r label gpg_url keyring sources_file repo_line packages <<< "${entry}"
            add_signed_repo "${label}" "${gpg_url}" "${keyring}" "${sources_file}" "${repo_line}"
            return $?
        fi
    done
    print_error "No SIGNED_REPO_APPS entry found for: ${target_label}"
    return 1
}

# =============================================================================
# Installation Functions
# =============================================================================

install_system76_drivers() {
    print_section "System76 Drivers"

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

setup_flatpak() {
    print_section "Flatpak Setup"

    if [[ "${INSTALL_FLATPAK}" != true ]]; then
        print_warning "Skipping Flatpak setup (disabled)"
        return 0
    fi

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

    if [[ "${flatpak_needs_install}" == true ]]; then
        apt_install flatpak gnome-software-plugin-flatpak
    else
        apt_install gnome-software-plugin-flatpak
    fi

    if [[ "${flathub_needs_add}" == true ]]; then
        if [[ "${DRY_RUN}" == true ]]; then
            print_dry_run "flatpak remote-add flathub"
        else
            print_status "Adding Flathub repository..."
            flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
            print_success "Flathub repository configured"
        fi
    fi

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
    local tmp_installer
    tmp_installer="$(mktemp)"
    curl -fsSL -o "${tmp_installer}" https://dl.brave.com/install.sh
    sh "${tmp_installer}"
    rm -f "${tmp_installer}"
    print_success "Brave browser installed"
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

    apt_install git-lfs

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

install_gitkraken() {
    print_section "GitKraken Desktop"

    if command_exists gitkraken || package_installed gitkraken; then
        print_skip "GitKraken"
        return 0
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "Download and install GitKraken .deb from release.gitkraken.com"
        return 0
    fi

    local gitkraken_deb
    gitkraken_deb="$(mktemp --suffix=.deb)"

    print_status "Downloading GitKraken..."
    curl -fsSL -o "${gitkraken_deb}" https://release.gitkraken.com/linux/gitkraken-amd64.deb
    print_success "GitKraken downloaded"

    print_status "Installing GitKraken..."
    sudo apt install -y "${gitkraken_deb}"
    rm -f "${gitkraken_deb}"
    print_success "GitKraken installed"
}

install_nodejs() {
    print_section "Node.js & npm"

    local skip_install=false

    if command_exists node && command_exists npm; then
        local node_version npm_version
        node_version=$(node --version | sed 's/^v//')
        npm_version=$(npm --version)

        if [[ "${node_version}" == "${TARGET_NODE_VERSION}" ]]; then
            print_skip "Node.js v${node_version} & npm ${npm_version}"
            skip_install=true
        else
            print_status "Current Node.js version: ${node_version}, target: ${TARGET_NODE_VERSION}"
        fi
    fi

    if [[ "${skip_install}" == false ]]; then
        local nodesource_list="/etc/apt/sources.list.d/nodesource.list"

        if [[ ! -f "${nodesource_list}" ]]; then
            if [[ "${DRY_RUN}" == true ]]; then
                print_dry_run "Add NodeSource repository and install Node.js (LTS)"
            else
                print_status "Adding NodeSource repository for Node.js LTS..."
                local tmp_installer
                tmp_installer="$(mktemp)"
                curl -fsSL -o "${tmp_installer}" https://deb.nodesource.com/setup_lts.x
                sudo -E bash "${tmp_installer}"
                rm -f "${tmp_installer}"
                print_success "NodeSource repository added"
            fi
        else
            print_skip "NodeSource repository"
        fi

        apt_install nodejs

        if command_exists npm; then
            local npm_version
            npm_version=$(npm --version)
            print_success "npm ${npm_version} installed"
        fi

        if [[ "${DRY_RUN}" == true ]]; then
            print_dry_run "npm install -g n"
            print_dry_run "n ${TARGET_NODE_VERSION}"
        else
            if ! command_exists n; then
                print_status "Installing 'n' Node version manager..."
                sudo npm install -g n
                print_success "'n' installed"
            else
                print_skip "'n' Node version manager"
            fi

            print_status "Installing Node.js ${TARGET_NODE_VERSION} using 'n'..."
            sudo n "${TARGET_NODE_VERSION}"
            print_success "Node.js ${TARGET_NODE_VERSION} installed"

            export PATH="/usr/local/bin:${PATH}"

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
    local tmp_installer
    tmp_installer="$(mktemp)"
    curl -fsSL -o "${tmp_installer}" https://bun.sh/install
    bash "${tmp_installer}"
    rm -f "${tmp_installer}"
    print_success "Bun installed"

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

    export PATH="${HOME}/.bun/bin:${PATH}"

    if command_exists bun; then
        local bun_version
        bun_version=$(bun --version)
        print_success "Bun ${bun_version} installed successfully"
    else
        print_warning "Bun installed but not found in PATH (may need to restart shell)"
    fi
}

install_jdk() {
    print_section "Java Development Kit (JDK)"

    if command_exists java && command_exists javac; then
        local java_version
        java_version=$(java -version 2>&1 | head -n 1 | awk -F '"' '{print $2}')
        print_skip "JDK (Java ${java_version})"
        return 0
    fi

    apt_install default-jdk

    if command_exists java && command_exists javac; then
        local java_version
        java_version=$(java -version 2>&1 | head -n 1 | awk -F '"' '{print $2}')
        print_success "JDK installed (Java ${java_version})"
    else
        print_warning "JDK installation completed but java/javac not found in PATH"
    fi
}

install_claude_code() {
    print_section "Claude Code CLI"

    local claude_path="${HOME}/.local/bin/claude"

    if command_exists claude || [[ -x "${claude_path}" ]]; then
        local claude_version
        if command_exists claude; then
            claude_version=$(claude --version 2>/dev/null || echo "unknown")
        else
            claude_version=$("${claude_path}" --version 2>/dev/null || echo "unknown")
        fi
        print_skip "Claude Code CLI (${claude_version})"
        return 0
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "Install Claude Code CLI via native installer (curl -fsSL https://claude.ai/install.sh | bash)"
        print_dry_run "Add ~/.local/bin to PATH in .bashrc"
        return 0
    fi

    if command_exists npm && npm list -g @anthropic-ai/claude-code &>/dev/null; then
        print_warning "Found an npm-installed Claude Code; removing it in favour of the native install"
        sudo npm uninstall -g @anthropic-ai/claude-code || true
    fi

    print_status "Installing Claude Code CLI (native installer)..."
    local tmp_installer
    tmp_installer="$(mktemp)"
    curl -fsSL -o "${tmp_installer}" https://claude.ai/install.sh
    bash "${tmp_installer}"
    rm -f "${tmp_installer}"
    print_success "Claude Code CLI installed"

    local path_entry="export PATH=\"\${HOME}/.local/bin:\${PATH}\""
    local bashrc="${HOME}/.bashrc"

    if ! grep -qF '.local/bin' "${bashrc}" 2>/dev/null; then
        print_status "Adding ~/.local/bin to PATH in .bashrc..."
        echo "" >> "${bashrc}"
        echo "# Local binaries (Claude Code)" >> "${bashrc}"
        echo "${path_entry}" >> "${bashrc}"
        print_success "Added ~/.local/bin to PATH"
    else
        print_skip "~/.local/bin PATH entry"
    fi

    export PATH="${HOME}/.local/bin:${PATH}"

    if command_exists claude; then
        local claude_version
        claude_version=$(claude --version 2>/dev/null || echo "unknown")
        print_success "Claude Code CLI ${claude_version} installed successfully"
    else
        print_warning "Claude Code installed but not found in PATH (may need to restart shell)"
    fi
}

install_1password() {
    print_section "1Password"

    if package_installed 1password; then
        print_skip "1Password"
        return 0
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "Install 1Password (add GPG key, repo, debsig, and install package)"
        return 0
    fi

    add_signed_repo_by_name "1Password"

    # 1Password-specific: debsig verification
    local debsig_policy_dir="/etc/debsig/policies/AC2D62742012EA22"
    local debsig_keyring_dir="/usr/share/debsig/keyrings/AC2D62742012EA22"

    if [[ ! -f "${debsig_policy_dir}/1password.pol" ]]; then
        print_status "Setting up debsig verification..."
        sudo mkdir -p "${debsig_policy_dir}"
        curl -sS https://downloads.1password.com/linux/debian/debsig/1password.pol | \
            sudo tee "${debsig_policy_dir}/1password.pol" > /dev/null
        sudo mkdir -p "${debsig_keyring_dir}"
        curl -sS https://downloads.1password.com/linux/keys/1password.asc | \
            sudo gpg --dearmor --yes --output "${debsig_keyring_dir}/debsig.gpg"
        print_success "Debsig verification configured"
    else
        print_skip "1Password debsig verification"
    fi

    apt_update_if_needed
    apt_install 1password
}

install_docker() {
    print_section "Docker Engine"

    if command_exists docker; then
        local docker_version
        docker_version=$(docker --version | awk '{print $3}' | sed 's/,//')
        print_skip "Docker Engine (version ${docker_version})"
        return 0
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "Install Docker Engine (add GPG key, repo, and install packages)"
        return 0
    fi

    add_signed_repo_by_name "Docker"
    apt_update_if_needed
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

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

    echo ""
    print_success "Docker installation complete!"
    print_status "Docker version: $(docker --version 2>/dev/null || echo 'N/A')"
    print_status "Docker Compose version: $(docker compose version 2>/dev/null || echo 'N/A')"
}

install_twingate() {
    print_section "Twingate VPN Client"

    if command_exists twingate || package_installed twingate; then
        print_skip "Twingate"
        return 0
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "Install Twingate (add GPG key, repo, and install package)"
        return 0
    fi

    add_signed_repo_by_name "Twingate"
    apt_update_if_needed
    apt_install twingate

    echo ""
    print_success "Twingate installed successfully!"
    print_warning "Configure Twingate by running: sudo twingate setup"
    print_status "Network name: ${TWINGATE_NETWORK}"
    echo ""
}

install_postgresql() {
    print_section "PostgreSQL"

    if command_exists psql; then
        local pg_version
        pg_version=$(psql --version | awk '{print $3}')
        print_skip "PostgreSQL (version ${pg_version})"
        return 0
    fi

    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run "Install PostgreSQL (add GPG key, repo, and install package)"
        return 0
    fi

    add_signed_repo_by_name "PostgreSQL"
    apt_update_if_needed
    apt_install postgresql postgresql-contrib

    # Start and enable PostgreSQL service
    if systemctl is-active --quiet postgresql; then
        print_skip "PostgreSQL service (already running)"
    else
        print_status "Starting PostgreSQL service..."
        sudo systemctl start postgresql
        sudo systemctl enable postgresql
        print_success "PostgreSQL service started and enabled"
    fi
}

# =============================================================================
# Data-Driven Installers
# =============================================================================

# Installs all SIMPLE_SIGNED_REPO_APPS entries from the SIGNED_REPO_APPS config.
install_signed_repo_apps() {
    for label in "${SIMPLE_SIGNED_REPO_APPS[@]}"; do
        # Look up entry in SIGNED_REPO_APPS
        local entry=""
        local e
        for e in "${SIGNED_REPO_APPS[@]}"; do
            if [[ "${e%%|*}" == "${label}" ]]; then
                entry="${e}"
                break
            fi
        done
        if [[ -z "${entry}" ]]; then
            print_error "No SIGNED_REPO_APPS entry for: ${label}"
            continue
        fi

        local _label gpg_url keyring sources_file repo_line packages
        IFS='|' read -r _label gpg_url keyring sources_file repo_line packages <<< "${entry}"

        print_section "${label}"

        # Check if first package is already installed
        local first_pkg="${packages%% *}"
        if package_installed "${first_pkg}"; then
            print_skip "${label}"
            continue
        fi

        # Spotify: migrate old insecure keyring from trusted.gpg.d
        if [[ "${label}" == "Spotify" ]] && [[ "${DRY_RUN}" != true ]]; then
            local old_keyring="/etc/apt/trusted.gpg.d/spotify.gpg"
            if [[ -f "${old_keyring}" ]]; then
                print_status "Migrating Spotify keyring to secure location..."
                sudo rm -f "${old_keyring}"
            fi
        fi

        add_signed_repo "${label}" "${gpg_url}" "${keyring}" "${sources_file}" "${repo_line}"
        apt_update_if_needed
        # Intentionally unquoted to allow word splitting on multi-package entries
        apt_install ${packages}
    done
}

# Installs all SIMPLE_APT_APPS entries from default repos.
install_simple_apt_apps() {
    print_section "Additional Packages"

    for entry in "${SIMPLE_APT_APPS[@]}"; do
        local cmd_name pkg_name display_name
        IFS='|' read -r cmd_name pkg_name display_name <<< "${entry}"

        if command_exists "${cmd_name}" || package_installed "${pkg_name}"; then
            print_skip "${display_name}"
            continue
        fi

        apt_install "${pkg_name}"
    done
}

# Installs all FLATPAK_APPS entries.
install_flatpak_apps() {
    print_section "Flatpak Apps"

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

# =============================================================================
# Desktop Settings
# =============================================================================

install_desktop_settings() {
    print_section "Desktop Settings (Ubuntu/Wayland)"

    if ! command_exists gsettings; then
        print_warning "gsettings not available, skipping desktop configuration"
        return 0
    fi

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

    # Set dark mode
    local current_color_scheme
    current_color_scheme=$(gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null || echo "")
    if [[ "${current_color_scheme}" != "'prefer-dark'" ]]; then
        print_status "Setting appearance to dark mode..."
        gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
        gsettings set org.gnome.desktop.interface gtk-theme 'Yaru-dark'
        gsettings set org.gnome.desktop.interface icon-theme 'Yaru-dark'
        gsettings set org.gnome.desktop.wm.preferences theme 'Yaru-dark'
        print_success "Dark mode enabled (Yaru-dark theme)"
        changes_made=$((changes_made + 1))
    else
        print_skip "Dark mode (already enabled)"
    fi

    # Configure Ubuntu Dock
    if gsettings list-schemas | grep -q "org.gnome.shell.extensions.dash-to-dock"; then
        local dock_schema="org.gnome.shell.extensions.dash-to-dock"

        local dock_fixed
        dock_fixed=$(gsettings get ${dock_schema} dock-fixed 2>/dev/null || echo "true")
        if [[ "${dock_fixed}" != "false" ]]; then
            print_status "Enabling dock auto-hide..."
            gsettings set ${dock_schema} dock-fixed false
            gsettings set ${dock_schema} autohide true
            gsettings set ${dock_schema} intellihide true
            gsettings set ${dock_schema} intellihide-mode 'ALL_WINDOWS'
            gsettings set ${dock_schema} autohide-in-fullscreen false
            print_success "Dock auto-hide enabled (intellihide mode)"
            changes_made=$((changes_made + 1))
        else
            print_skip "Dock auto-hide (already enabled)"
        fi

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
    else
        print_warning "Ubuntu Dock (dash-to-dock) not found, skipping dock settings"
    fi

    # Desktop icon position
    if gsettings list-schemas | grep -q "org.gnome.shell.extensions.ding"; then
        local start_corner
        start_corner=$(gsettings get org.gnome.shell.extensions.ding start-corner 2>/dev/null || echo "'top-left'")
        if [[ "${start_corner}" != "'top-right'" ]]; then
            print_status "Setting desktop icons to start from top-right..."
            gsettings set org.gnome.shell.extensions.ding start-corner 'top-right'
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

# =============================================================================
# Setup Helpers
# =============================================================================

setup_sudo_keepalive() {
    if [[ "${DRY_RUN}" == true ]]; then
        return 0
    fi

    if ! sudo -v; then
        print_error "Failed to obtain sudo privileges"
        exit 1
    fi

    while true; do
        sudo -n true
        sleep 60
        kill -0 "$$" || exit
    done 2>/dev/null &
    SUDO_KEEPALIVE_PID=$!
}

# =============================================================================
# Main Execution
# =============================================================================

show_help() {
    cat <<'HELPEOF'
System Setup Script
Configures a fresh Ubuntu/Pop!_OS installation with common development tools

Usage: ./system-setup.sh [OPTIONS]
  --force-system76          Force System76 driver installation (auto-detected by default)
  --skip-system76           Skip System76 driver installation even if detected
  --skip-system76-nvidia    Skip NVIDIA driver installation
  --skip-flatpak            Skip Flatpak and GNOME Circle apps
  --skip-reboot-pause       Skip the reboot pause after Flatpak setup
  --dry-run                 Show what would be installed without making changes
  --help                    Show this help message
HELPEOF
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
    echo ""

    # Sudo setup
    setup_sudo_keepalive

    # Ensure curl is available
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

    # --- System Updates ---
    print_section "System Updates"
    apt_update
    apt_upgrade

    # --- Hardware Drivers ---
    install_system76_drivers

    # --- Flatpak Infrastructure ---
    setup_flatpak

    # --- Web Browsers ---
    install_brave

    # --- Version Control ---
    install_git
    install_git_lfs
    install_gitkraken

    # --- Languages & Runtimes ---
    install_nodejs
    install_bun
    install_jdk

    # --- Package Managers & CLI Tools ---
    install_npm_packages
    install_claude_code

    # --- Security & Passwords ---
    install_1password

    # --- Containers & Infrastructure ---
    install_docker
    install_twingate

    # --- Databases ---
    install_postgresql

    # --- Signed-Repo Apps (Chrome, GitHub CLI, GitHub Desktop, Spotify, pgAdmin, ngrok) ---
    install_signed_repo_apps

    # --- Simple APT Packages (Chromium, FFmpeg, GIMP, Go) ---
    install_simple_apt_apps

    # --- Flatpak Apps ---
    install_flatpak_apps

    # --- Desktop Customization ---
    install_desktop_settings

    # --- Cleanup ---
    print_section "System Cleanup"
    if [[ "${DRY_RUN}" != true ]]; then
        print_status "Running apt auto cleanup..."
        sudo apt autoremove -y 2>&1 | tee -a "${LOG_FILE}"
        sudo apt autoclean -y 2>&1 | tee -a "${LOG_FILE}"
        print_success "Cleanup completed"
    else
        print_dry_run "apt autoremove and autoclean"
    fi

    # --- Summary ---
    print_section "Setup Complete"
    print_success "System setup finished successfully!"
    print_status "Log file saved to: ${LOG_FILE}"
    echo ""
    print_warning "Recommended: Restart your computer to ensure all changes take effect"
    echo ""
}

main "$@"

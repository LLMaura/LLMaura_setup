#!/bin/bash

# LLMaura runs open source LLM models in house by automating the installation
# of Ollama and Open WebUI on specific Debian and Ubuntu versions.
#
# This version supports:
# - Debian 12 (Bookworm)
# - Ubuntu 24 (Noble Numbat, including point releases)
#
# It automatically detects the operating system and version and uses the
# appropriate package manager and commands.
#
# It attempts a standard pip installation of Open WebUI and falls back to
# building from source if a compatible pre-built package is not found.
#
# It configures Open WebUI as a systemd service running as the 'ollama' user,
# sets the working and data directory for Open WebUI to /opt/openwebui,
# configures ollama.service to store models in /opt/models,
# and configures iptables for port forwarding from 80 to 8080.
#
# Maintained by: info@manceps.com
# ---------------------------------------------------------------------------

# Exit immediately if a command exits with a non-zero status
# Treat unset variables as an error when substituting
# Enable -x to allow  printing commands before execution
set -euo pipefail

# --- Function Definitions ---

# Function to output messages with timestamp
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message"
}

# Function to check if a command exists
command_exists() {
    command -v "$@" > /dev/null 2>&1
}

# Function to check for essential commands needed before main installations
check_essential_commands() {
    log "INFO" "Checking for essential commands..."
    # Core system commands expected to be present early.
    # Package-specific commands needed later are checked after installation.
    local missing_commands=()
    local commands=(sed systemctl sudo chown chmod mkdir cat grep df rm id dpkg)

    for cmd in "${commands[@]}"; do
        if ! command_exists "$cmd"; then
            missing_commands+=("$cmd")
        fi
    done

    if [ ${#missing_commands[@]} -gt 0 ]; then
        log "ERROR" "Missing essential commands: ${missing_commands[*]}." >&2
        log "ERROR" "Please ensure these commands are installed and in the PATH." >&2
        exit 1
    fi
    log "INFO" "All essential commands found."
}

# Function to install all required APT packages
install_required_packages_apt() {
    log "INFO" "Checking and installing required APT packages..."

    local required_packages=(
        git
        curl
        python3
        python3-pip
        python3-full
        python3-venv
        libopenblas-dev
        build-essential
        python3-dev
        nodejs
        npm
        iptables-persistent
        # Add debconf explicitly as debconf-set-selections is used early for iptables-persistent
        # Although typically a base package, explicitly including it ensures debconf-set-selections works
        debconf
        # Ensure netfilter-persistent is installed, as it's the service unit
        netfilter-persistent
    )

    local packages_to_install=()

    # Check which packages are not already installed
    for pkg in "${required_packages[@]}"; do
        if ! dpkg -s "$pkg" >/dev/null 2>&1; then
            packages_to_install+=("$pkg")
        else
            log "INFO" "Package '$pkg' is already installed. Skipping."
        fi
    done

    if [ ${#packages_to_install[@]} -gt 0 ]; then
        log "INFO" "Packages to install: ${packages_to_install[*]}"
        # Run apt update before installing
        if ! apt update; then
            log "WARNING" "apt update failed before package installation. Package lists might be outdated." >&2
        fi

        # Install all missing packages in one go
        log "INFO" "Running apt install for required packages..."
        # Use DEBIAN_FRONTEND=noninteractive to prevent prompts during installation
        # Use --no-install-recommends to minimize installed packages
        if ! DEBIAN_FRONTEND=noninteractive apt install -y --no-install-recommends "${packages_to_install[@]}"; then
            log "ERROR" "Failed to install required APT packages." >&2
            exit 1
        fi
        log "INFO" "Required APT packages installed successfully."
    else
        log "INFO" "All required APT packages are already installed."
    fi
}

install_ollama() {
    log "INFO" "Starting Ollama installation and configuration..."

    # Check if Ollama is already installed and running
    OLLAMA_INSTALLED=false
    # 'command_exists' and 'systemctl' are guaranteed to exist here
    if command_exists ollama; then
        log "INFO" "Ollama command found."
        if systemctl is-active --quiet ollama; then
            log "INFO" "Ollama service appears to be already installed and running. Skipping installation."
            OLLAMA_INSTALLED=true
        else
            log "WARNING" "Ollama command found, but service is not running. Skipping installation but will attempt to start/configure." >&2
            OLLAMA_INSTALLED=true
        fi
    else
        log "INFO" "Ollama not found. Proceeding with installation."
    fi

    # Install Ollama if not already installed
    if [ "$OLLAMA_INSTALLED" = false ]; then
        log "INFO" "Installing Ollama server... This downloads and runs a script from ollama.com."
        log "INFO" "Note: Piping a script from the internet to sh as root has security implications."
        # The official Ollama installation script handles dependencies and service setup
        # 'curl' is guaranteed to exist here due to install_required_packages_apt
        if ! curl -fsSL https://ollama.com/install.sh | sh; then
            log "ERROR" "Failed to install Ollama. Open WebUI will not function without an LLM backend." >&2
            exit 1
        fi
        log "INFO" "Ollama installed successfully."
        echo "" # Add a newline for readability
    fi

    # Ensure Ollama user and group exist after potential installation
    # 'id' is guaranteed to exist here
    if ! id -u "$OPENWEBUI_USER" >/dev/null 2>&1; then
        log "ERROR" "Ollama user '${OPENWEBUI_USER}' not found after installation attempt." >&2
        log "ERROR" "The official Ollama install script should create this user." >&2
        exit 1
    fi
    if ! id -g "$OPENWEBUI_GROUP" >/dev/null 2>&2; then # Use 2>&2 for group check output
        log "ERROR" "Ollama group '${OPENWEBUI_GROUP}' not found after installation attempt." >&2
        log "ERROR" "The official Ollama install script should create this group." >&2
        exit 1
    fi
    log "INFO" "Confirmed Ollama user (${OPENWEBUI_USER}) and group (${OPENWEBUI_GROUP}) exist."

    # Configure Ollama service to use /opt/models and ensure it's running
    log "INFO" "Configuring Ollama systemd service (${OLLAMA_SERVICE_FILE}) to use ${OLLAMA_MODELS_DIR}..."
    # Check if the service file exists (Ollama installer creates it)
    if [ -f "$OLLAMA_SERVICE_FILE" ]; then
        # Create the models directory if it doesn't exist and set permissions for the ollama user
        # 'mkdir', 'chown', 'chmod' are guaranteed to exist here
        mkdir -p "$OLLAMA_MODELS_DIR"
        chown "$OPENWEBUI_USER":"$OPENWEBUI_GROUP" "$OLLAMA_MODELS_DIR"
        chmod 750 "$OLLAMA_MODELS_DIR" # ollama user rwx, ollama group rx, others no permissions
        log "INFO" "Created/Ensured ${OLLAMA_MODELS_DIR} exists and set permissions for ${OPENWEBUI_USER}."

        # Add or update the Environment variable in the Service section
        # Use sed to delete any existing line starting with Environment="OLLAMA_MODELS=.*" in the Service section
        # and then append the new one after the [Service] line.
        # Ensure we only modify the [Service] section by targeting lines between [Service] and the next section header.
        # 'grep' and 'sed' are guaranteed to exist here
        if grep -q "^\[Service\]" "$OLLAMA_SERVICE_FILE"; then
            # Delete existing OLLAMA_MODELS env var lines within the [Service] section
            sed -i -e "/^\[Service\]/,/^\[.*\]/ { /^Environment=\"OLLAMA_MODELS=/d; }" "$OLLAMA_SERVICE_FILE"
            # Append the new Environment variable right after the [Service] line
            sed -i "/^\[Service\]/a Environment=\"OLLAMA_MODELS=${OLLAMA_MODELS_DIR}\"" "$OLLAMA_SERVICE_FILE"
            log "INFO" "Added/Updated Environment=\"OLLAMA_MODELS=${OLLAMA_MODELS_DIR}\" in ${OLLAMA_SERVICE_FILE}"

            # Reload daemon and restart Ollama for changes to take effect
            # 'systemctl' is guaranteed to exist here
            log "INFO" "Reloading systemd daemon and restarting ollama service..."
            systemctl daemon-reload || log "WARNING" "systemctl daemon-reload failed. Service changes may not take effect." >&2
            systemctl enable ollama || log "WARNING" "Failed to enable ollama service. It may not start on boot." >&2 # Enable if not already
            # Use || true so set -e doesn't exit if restart fails (status will be checked later)
            systemctl restart ollama || log "WARNING" "Failed to restart ollama service. Check its status manually." >&2
        else
            log "WARNING" "Could not find [Service] section in ${OLLAMA_SERVICE_FILE}. Cannot configure OLLAMA_MODELS." >&2
        fi
    else
        log "WARNING" "Ollama service file not found at ${OLLAMA_SERVICE_FILE}. Cannot configure OLLAMA_MODELS." >&2
    fi
}

wait_for_ollama() {
    # Wait for Ollama to be fully ready (up to 90 seconds - increased wait)
    log "INFO" "Waiting for Ollama to start and become ready (up to 90 seconds)..."
    local ollama_ready=false
    for i in {1..90}; do # Increased wait time
        # Use the default Ollama API endpoint
        # 'curl' is guaranteed to exist here
        if curl -s http://localhost:11434 >/dev/null; then
            log "INFO" "Ollama is ready!"
            ollama_ready=true
            break
        fi
        echo -n "." # Progress indicator
        sleep 1
    done
    echo "" # Newline after progress indicator

    if ! $ollama_ready; then
        log "ERROR" "Ollama failed to start after 90 seconds." >&2
        log "ERROR" "Check 'systemctl status ollama' and 'journalctl -u ollama --no-pager -n 50' for details." >&2
        # 'journalctl' is generally available, checked by check_essential_commands
        journalctl -u ollama --no-pager -n 50 # Output recent logs
        # Exiting makes sense as Open WebUI won't work without Ollama.
        exit 1
    fi
}

download_ollama_models() {
    local models=("$@") # Get models array passed as arguments

    if [ ${#models[@]} -gt 0 ]; then
        log "INFO" "Downloading specified Ollama models to ${OLLAMA_MODELS_DIR} (this may take a while)..."
        # Use the ollama user to pull models, as it owns the models directory
        # Pass model names as positional arguments ($@) to the inner bash script
        # The '_' is a placeholder for $0 inside the inner script.
        # Temporarily disable errexit for the model pull loop
        set +e
        # 'sudo' is guaranteed to exist here
        sudo -u "$OPENWEBUI_USER" bash -c '
        # Inside this bash script, the models are available as positional arguments ($1, $2, ...)
        # We iterate over them using "$@"
        for model in "$@"; do
            echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Pulling ${model}..."
            MODEL_PULLED=false
            for attempt in {1..5}; do
                # Use the ollama command installed by the ollama script and check its exit status
                # ollama command should be in PATH for the ollama user after installation
                if ollama pull "${model}"; then
                    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Successfully pulled ${model}."
                    MODEL_PULLED=true
                    break
                else
                    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [WARNING] Attempt ${attempt} failed to pull ${model}, retrying in 15 seconds..." >&2
                    sleep 15
                fi
            done
            if [[ "$MODEL_PULLED" == "false" ]]; then
                echo "[$(date +"%Y-%m-%d %H:%M:%S")] [WARNING] Failed to pull model ${model} after 5 attempts." >&2
            fi
        done
        echo "[$(date +"%Y-%m-%d %H:%M:%S")] [INFO] Model downloading complete."
        ' _ "${models[@]}" # Pass array elements as positional arguments
        # Re-enable errexit
        set -e
        log "INFO" "Completed Ollama model download process."
    else
        log "INFO" "No Ollama models specified in the OLLAMA_MODELS array. Skipping model download."
    fi
    echo "" # Add a newline for better readability
}

configure_iptables() {
    log "INFO" "Setting up port forwarding from 80 to 8080 using iptables..."
    # Clear previous rules for port 80 if they exist to avoid conflicts
    # Use 2>/dev/null || true to make deletion attempts non-fatal
    # Delete potential previous rule for 80 -> 8000 (a common alternative Open WebUI port)
    # 'iptables' is guaranteed to exist here
    iptables -t nat -D PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8000 2>/dev/null || true
    # Delete potential previous rule for 80 -> 8080
    iptables -t nat -D PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080 2>/dev/null || true
    log "INFO" "Removed existing iptables PREROUTING rules for port 80."

    # Add the new rule
    # Ensure the rule is appended (-A) to avoid conflicts with other potential PREROUTING rules
    log "INFO" "Adding iptables PREROUTING rule to redirect TCP port 80 to 8080..."
    if ! iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080; then
        log "WARNING" "Failed to add iptables PREROUTING rule. Port 80 forwarding may not work." >&2
    else
        log "INFO" "iptables PREROUTING rule added successfully."
    fi

    # Save iptables rules using the netfilter-persistent service (standard on modern Debian/Ubuntu)
    log "INFO" "Saving iptables rules using netfilter-persistent service..."
    # On systemd systems, restarting the service triggers a save to /etc/iptables/rules.v4 and rules.v6
    # 'systemctl' and 'netfilter-persistent' command are guaranteed to exist here
    # We also need to ensure the service is enabled to run on boot
    systemctl enable netfilter-persistent || log "WARNING" "Failed to enable netfilter-persistent service. Rules may not persist on boot." >&2

    if systemctl restart netfilter-persistent; then
         log "INFO" "iptables rules saved successfully via netfilter-persistent service restart."
    # Add a fallback using the netfilter-persistent command directly
    elif netfilter-persistent save; then
        log "INFO" "iptables rules saved successfully using netfilter-persistent save command."
    else
        # Fallback to older init system command (less likely needed on target distros)
        # Check for invoke-rc.d as a last resort for saving rules
        if command_exists invoke-rc.d; then
             log "WARNING" "Failed to restart netfilter-persistent service. Attempting to save using invoke-rc.d netfilter-persistent save..." >&2
             if invoke-rc.d netfilter-persistent save; then
                 log "INFO" "iptables rules saved successfully using invoke-rc.d netfilter-persistent save."
             else
                 log "WARNING" "Failed to save iptables rules using invoke-rc.d. Rules may not persist after reboot." >&2
             fi
        else
            log "WARNING" "Could not find a standard way to save iptables rules using netfilter-persistent or invoke-rc.d." >&2
            log "WARNING" "Please ensure the netfilter-persistent service is functional. Rules may not persist after reboot." >&2
        fi
    fi
    echo "" # Add a newline for better readability
}

install_webui_pip() {
    log "INFO" "Attempting to install Open WebUI using pip as user ${OPENWEBUI_USER}..."

    # Ensure the temporary directory for pip cache exists and is writable by the ollama user
    # 'mkdir', 'chown', 'chmod' are guaranteed to exist here
    mkdir -p "$PIP_TEMP_DIR"
    chown "$OPENWEBUI_USER":"$OPENWEBUI_GROUP" "$PIP_TEMP_DIR"
    chmod 750 "$PIP_TEMP_DIR" # Ensure ollama user can write
    log "INFO" "Ensured pip temporary cache directory ${PIP_TEMP_DIR} exists and has correct permissions."

    log "INFO" "Setting PIP_CACHE_DIR and TMPDIR to $PIP_TEMP_DIR for pip installation."
    log "INFO" "Please ensure the filesystem containing '$PIP_TEMP_DIR' has sufficient free space (at least several GB)."

    # Execute the pip install command and capture output and status
    # Using pipefail with set -euxo already ensures pipeline status is checked.
    # Temporarily disable set -e to handle pip install failure gracefully.
    set +e
    # Use 'env' with sudo to pass environment variables specifically for this command
    log "INFO" "Running pip install..."
    # pip is guaranteed to exist here (python3-pip installed by apt)
    PIP_INSTALL_OUTPUT=$(sudo -u "$OPENWEBUI_USER" env PIP_CACHE_DIR="$PIP_TEMP_DIR" TMPDIR="$PIP_TEMP_DIR" "$INSTALL_DIR/venv/bin/pip" install open-webui 2>&1)
    PIP_EXIT_STATUS=$?
    set -e # Re-enable set -e

    if [ "$PIP_EXIT_STATUS" -eq 0 ]; then
        log "INFO" "Open WebUI installed successfully via pip."
        return 0 # Indicate success
    else
        log "WARNING" "Pip installation failed (exit status $PIP_EXIT_STATUS)." >&2
        log "WARNING" "Pip output:\n$PIP_INSTALL_OUTPUT" >&2 # Print the pip error output
        # Return non-zero to indicate failure
        return 1
    fi
}

install_webui_source_fallback() {
    log "INFO" "Attempting to build Open WebUI from source as a fallback..."

    # Define a temporary directory base for source cloning and building.
    local SOURCE_BUILD_TMP_BASE="/var/tmp/openwebui_build_tmp" # Use a separate tmp base for source build
    local SOURCE_DIR="" # Initialize SOURCE_DIR variable
    local TEMP_DIR_SET_BY_SCRIPT=false
    local ORIG_TMPDIR="$TMPDIR" # Store original TMPDIR if set

    # Ensure the base directory exists before mktemp tries to use it
    # 'mkdir' is guaranteed to exist here
    mkdir -p "$SOURCE_BUILD_TMP_BASE" || { log "ERROR" "Failed to create source build temporary base directory $SOURCE_BUILD_TMP_BASE."; exit 1; }

    # Set TMPDIR to a location for the source build if not already set by the user
    # Use -p with mktemp to specify the parent directory explicitly within the base.
    # 'mktemp' is guaranteed to exist here
    if [ -z "$ORIG_TMPDIR" ]; then
        # If TMPDIR is not set by the user, use mktemp to create a unique directory
        # within the base directory, and set TMPDIR to that unique directory.
        SOURCE_DIR=$(mktemp -d -p "$SOURCE_BUILD_TMP_BASE" tmp.XXXXXX)
        export TMPDIR="$SOURCE_DIR" # Set TMPDIR for the current script and child processes
        TEMP_DIR_SET_BY_SCRIPT=true
        log "INFO" "TMPDIR environment variable was not set for the source build. Setting it to $TMPDIR."
    else
        # If TMPDIR was already set by the user, use mktemp to create a unique directory
        # within the location specified by the user's TMPDIR.
        SOURCE_DIR=$(mktemp -d "$ORIG_TMPDIR/tmp.XXXXXX") # mktemp will use the existing TMPDIR value
        log "INFO" "TMPDIR environment variable is already set to $ORIG_TMPDIR. Using a unique subdirectory $SOURCE_DIR within this location for the source build."
        # $SOURCE_DIR is the unique directory created by mktemp.
        # $TMPDIR remains the user-set value ($ORIG_TMPDIR).
    fi

    log "INFO" "Please ensure the filesystem containing '$SOURCE_DIR' has sufficient free space (at least 10-20 GB is recommended for build dependencies)."

    # Clean up temp dir on script exit or interruption
    # Trap needs to remove the unique SOURCE_DIR and restore TMPDIR if the script set it
    trap '
        local trap_exit_status=$? # Capture the exit status of the command that caused the trap
        log "INFO" "Trap triggered. Cleaning up temporary directory '"$SOURCE_DIR"'."
        # 'rm' is guaranteed to exist here
        rm -rf "$SOURCE_DIR" || log "WARNING" "Failed to remove temporary directory '"$SOURCE_DIR"'." >&2

        # Restore original TMPDIR only if the script set it
        if [ "$TEMP_DIR_SET_BY_SCRIPT" = true ]; then
            # We set TMPDIR to the unique directory, so just unset it
            unset TMPDIR
            log "INFO" "Unsetting TMPDIR set by the script."
            # Optionally clean the base dir if empty, but probably not necessary
            # rmdir "$SOURCE_BUILD_TMP_BASE" 2>/dev/null || true
        elif [ -n "$ORIG_TMPDIR" ]; then
            export TMPDIR="$ORIG_TMPDIR"
            log "INFO" "Restoring TMPDIR to '$ORIG_TMPDIR'."
        else
             log "INFO" "TMPDIR was originally unset, ensuring it remains unset."
             unset TMPDIR # Just in case, although it should already be unset
        fi

        # Exit with the original exit status
        exit $trap_exit_status
    ' EXIT SIGINT SIGTERM

    log "INFO" "Cloning Open WebUI repository into temporary directory: $SOURCE_DIR"
    # Use the created SOURCE_DIR for cloning
    # 'git' is guaranteed to exist here due to install_required_packages_apt
    if ! git clone https://github.com/open-webui/open-webui.git "$SOURCE_DIR"; then
         log "ERROR" "Failed to clone Open WebUI repository." >&2
         # The trap will handle cleanup and TMPDIR restoration, then exit.
         exit 1
    fi

    # Change ownership of the source directory to the ollama user for building
    log "INFO" "Setting permissions on source directory ${SOURCE_DIR} for user ${OPENWEBUI_USER}."
    # 'chown' is guaranteed to exist here
    chown -R "$OPENWEBUI_USER":"$OPENWEBUI_GROUP" "$SOURCE_DIR"

    log "INFO" "Building and installing Open WebUI from source using pip install ...."
    log "INFO" "This step can take a significant amount of time depending on system resources."
    # Run pip install from the source directory within the venv, as the ollama user
    # This needs to be done in the source directory context
    # Use --no-cache-dir to avoid issues with stale cache
    # Temporarily disable set -e for the build process.
    set +e
    # Pass the calculated SOURCE_DIR to the bash -c command
    # Ensure TMPDIR is passed to sudo if it was set by the script, otherwise sudo inherits.
    BUILD_OUTPUT=$(sudo -u "$OPENWEBUI_USER" bash -c "cd \"$SOURCE_DIR\" && \"$INSTALL_DIR/venv/bin/pip\" install . --no-cache-dir 2>&1")
    BUILD_EXIT_STATUS=$?
    set -e # Re-enable set -e

    if [ "$BUILD_EXIT_STATUS" -eq 0 ]; then
        log "INFO" "Open WebUI built and installed from source successfully."
        # Unset the trap after successful source build so cleanup doesn't run on normal exit
        trap - EXIT SIGINT SIGTERM
        # Need to explicitly run cleanup now for success case
        log "INFO" "Cleaning up temporary directory '$SOURCE_DIR'."
        # 'rm' is guaranteed to exist here
        rm -rf "$SOURCE_DIR" || log "WARNING" "Failed to remove temporary directory '$SOURCE_DIR'." >&2
        # Restore original TMPDIR if the script set it
        if [ "$TEMP_DIR_SET_BY_SCRIPT" = true ]; then
            unset TMPDIR
            log "INFO" "Unsetting TMPDIR set by the script."
        elif [ -n "$ORIG_TMPDIR" ]; then
             export TMPDIR="$ORIG_TMPDIR"
             log "INFO" "Restoring TMPDIR to '$ORIG_TMPDIR'."
        fi
        return 0 # Indicate success
    else
        log "ERROR" "Failed to build and install Open WebUI from source (exit status $BUILD_EXIT_STATUS)." >&2
        log "ERROR" "Build output:\n$BUILD_OUTPUT" >&2

        # Check if the error is due to lack of space during build
        # 'grep' and 'df' are guaranteed to exist here
        if echo "$BUILD_OUTPUT" | grep -q "ENOSPC: no space left on device"; then
             log "CRITICAL ERROR" "The source build failed due to 'No space left on device' (ENOSPC)." >&2
             log "CRITICAL ERROR" "This means the temporary directory used during the build ran out of disk space." >&2
             log "CRITICAL ERROR" "The build process, especially frontend dependencies, requires significant temporary space (at least 10-20 GB recommended)." >&2
             log "CRITICAL ERROR" "The script used '$SOURCE_DIR' for cloning and building." >&2
             log "CRITICAL ERROR" "Please free up disk space on the filesystem containing '$SOURCE_DIR'." >&2
             log "CRITICAL ERROR" "You can check disk space using 'df -h $(dirname "$SOURCE_DIR")'." >&2
             log "CRITICAL ERROR" "Alternatively, you can manually set the TMPDIR environment variable to a location on a filesystem with more space before running this script, like:" >&2
             log "CRITICAL ERROR" "  export TMPDIR=/path/to/larger/disk && sudo ./your_script.sh" >&2
        # Check if the error is due to onnxruntime compatibility/availability
        elif echo "$BUILD_OUTPUT" | grep -qE "(Could not find a version that satisfies the requirement onnxruntime==|No matching distribution found for onnxruntime==)"; then
            log "ERROR" "The source build failed because a required dependency, 'onnxruntime', specifically version 1.20.1, could not be found on PyPI that is compatible with your Python environment." >&2
            log "ERROR" "This often happens on newer distributions or less common architectures where pre-built packages ('wheels') for this specific version of onnxruntime are not yet available on PyPI." >&2
            log "ERROR" "Building onnxruntime from source is complex and requires many dependencies not handled by this script." >&2
            log "ERROR" "Recommendations:" >&2
            log "ERROR" "  - Verify your internet connection to pypi.org." >&2
            log "ERROR" "  - Check the official Open WebUI GitHub page or documentation for known build issues with onnxruntime or alternative installation methods (e.g., Docker)." >&2
            log "ERROR" "  - The version of Python in your virtual environment is $("$INSTALL_DIR/venv/bin/python3" --version 2>/dev/null || echo 'unknown'). Compatibility depends on PyPI having wheels for this exact version and your OS/architecture." >&2
            log "ERROR" "Unfortunately, the script cannot automatically resolve this onnxruntime compatibility issue." >&2
        else
             # Existing generic build failure message
             log "ERROR" "Please ensure all required build prerequisites (including build tools, Python development headers, Node.js, and npm) are installed and review the build output above for details." >&2
        fi

        # The trap will handle cleanup and TMPDIR restoration, then exit.
        return 1 # Indicate failure
    fi
}


# --- End Function Definitions ---


# Define installation directory and service name for Open WebUI
INSTALL_DIR="/opt/openwebui"
SERVICE_NAME="openwebui"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
# Define the user and group for Open WebUI (using the ollama user/group)
OPENWEBUI_USER="ollama"
OPENWEBUI_GROUP="ollama"

# Define directory for Ollama models
OLLAMA_MODELS_DIR="/opt/models"
OLLAMA_SERVICE_FILE="/etc/systemd/system/ollama.service"

# Define Ollama models to download
OLLAMA_MODELS=("tinyllama" "phi" "mistral" "gemma:2b" "mistral:7b-instruct-v0.2-q4_K_M")

# Define the temporary pip cache directory used for initial pip install
PIP_TEMP_DIR="/var/tmp/openwebui_pip_cache"

log "INFO" "Starting LLMaura: Ollama and Open WebUI installation..."

# --- Main Installation Flow ---

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    log "ERROR" "This script must be run as root to perform system-level installations and configurations." >&2
    exit 1
fi

# --- Distribution and Version Detection ---
# This needs to happen early to determine the package manager

DISTRO=""
VERSION_ID=""
PACKAGE_MANAGER="" # Will only be 'apt' for supported versions

# 'cat' is guaranteed to exist on these systems
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO=$ID
    VERSION_ID=$VERSION_ID # Capture version ID
# 'lsb_release' requires the command exists, check if it's present as a fallback
# This check might fail if lsb_release is not installed, but /etc/os-release is standard
elif command_exists lsb_release; then
    DISTRO=$(lsb_release -si | tr '[:upper:]' '[:lower:]') # Ensure lowercase
    VERSION_ID=$(lsb_release -sr) # Capture version ID
else
    log "ERROR" "Could not detect operating system distribution." >&2
    exit 1
fi

log "INFO" "Detected distribution: $DISTRO $VERSION_ID"

# --- Early Exit for Unsupported Distributions/Versions ---
case "$DISTRO" in
    debian)
        if [ "$VERSION_ID" = "12" ]; then
            PACKAGE_MANAGER="apt"
            # Prerequisite lists are now consolidated in install_required_packages_apt
            # Pre-configure iptables-persistent to automatically save rules
            log "INFO" "Pre-configuring iptables-persistent..."
            # 'debconf-set-selections' is guaranteed to exist here after install_required_packages_apt (installs debconf)
            debconf-set-selections <<< "iptables-persistent iptables-persistent/autosave_v4 boolean true"
            debconf-set-selections <<< "iptables-persistent iptables-persistent/autosave_v6 boolean true"
        else
            log "ERROR" "Detected unsupported Debian version: $VERSION_ID." >&2
            log "ERROR" "This script currently only supports Debian 12 (Bookworm) and Ubuntu 24 (including point releases)." >&2
            log "ERROR" "Consider using the official Docker installation method for broader compatibility." >&2
            exit 1
        fi
        ;;
    ubuntu)
        # Use starts_with for 24.04 LTS which might have point releases like 24.04.1
        if [[ "$VERSION_ID" == "24."* ]]; then
            PACKAGE_MANAGER="apt"
            # Prerequisite lists are now consolidated in install_required_packages_apt
             # Pre-configure iptables-persistent to automatically save rules
            log "INFO" "Pre-configuring iptables-persistent..."
            # 'debconf-set-selections' is guaranteed to exist here after install_required_packages_apt (installs debconf)
            debconf-set-selections <<< "iptables-persistent iptables-persistent/autosave_v4 boolean true"
            debconf-set-selections <<< "iptables-persistent iptables-v6 boolean true"
        else
            log "ERROR" "Detected unsupported Ubuntu version: $VERSION_ID." >&2
            log "ERROR" "This script currently only supports Debian 12 (Bookworm) and Ubuntu 24.04 LTS (including point releases)." >&2
            log "ERROR" "Consider using the official Docker installation method for broader compatibility." >&2
            exit 1
        fi
        ;;
    *) # Catch all other distros and versions (Fedora, Arch, CentOS, RHEL, etc.)
        log "ERROR" "Detected unsupported distribution: $DISTRO." >&2
        log "ERROR" "This script currently only supports Debian 12 (Bookworm) and Ubuntu 24 (including point releases)." >&2
        log "ERROR" "Consider using the official Docker installation method for broader compatibility." >&2
        exit 1
        ;;
esac

# Since we exit early for unsupported package managers, this check simplifies
if [ "$PACKAGE_MANAGER" != "apt" ]; then
     log "ERROR" "Internal Error: Package manager not set to 'apt' for a supposedly supported distribution." >&2
     exit 1
fi

# --- Check essential commands ---
# These are base commands expected on supported systems before main installs
check_essential_commands

# --- Install all required APT packages ---
# This needs to happen after package manager detection and essential command check
# This ensures 'git', 'curl', python, build tools, iptables-persistent, debconf, netfilter-persistent are installed
install_required_packages_apt

# Check Python version is sufficient (Open WebUI generally requires >= 3.9)
# python3 is guaranteed to be installed by install_required_packages_apt
# command_exists python3 is used here to ensure it's in the PATH and executable
if command_exists python3; then
    PYTHON_MAJOR=$(python3 -c 'import sys; print(sys.version_info[0])')
    PYTHON_MINOR=$(python3 -c 'import sys; print(sys.version_info[1])')
    if [ "$PYTHON_MAJOR" -lt 3 ] || ([ "$PYTHON_MAJOR" -eq 3 ] && [ "$PYTHON_MINOR" -lt 9 ]); then
        log "ERROR" "Python 3.9 or later is required to install Open WebUI." >&2
        log "ERROR" "Detected system Python version: $PYTHON_MAJOR.$PYTHON_MINOR" >&2
        log "ERROR" "Please install a more recent Python version or use a distribution that provides one." >&2
        exit 1
    fi
    log "INFO" "System Python version $PYTHON_MAJOR.$PYTHON_MINOR detected, which is likely sufficient for Open WebUI."
else
     # This else block should ideally not be reached if install_required_packages_apt succeeded
     log "ERROR" "python3 command not found even after attempting installation." >&2
     exit 1
fi


# 1. Install Ollama
# 'curl' is guaranteed to exist here due to install_required_packages_apt
install_ollama

# 2. Wait for Ollama to be ready
# 'curl' is guaranteed to exist here due to install_required_packages_apt
wait_for_ollama

# 3. Download Ollama models (if Ollama is ready)
download_ollama_models "${OLLAMA_MODELS[@]}"

# 4. Configure iptables for port forwarding
# 'iptables', 'systemctl', 'invoke-rc.d' (if needed), 'debconf-set-selections', 'netfilter-persistent' command/service are guaranteed to exist here
configure_iptables

# 5. Create Open WebUI directories and set permissions
log "INFO" "Creating installation directory ${INSTALL_DIR} for Open WebUI and setting permissions for ${OPENWEBUI_USER}..."
# 'mkdir' is guaranteed to exist here
mkdir -p "$INSTALL_DIR" || { log "ERROR" "Failed to create installation directory ${INSTALL_DIR}."; exit 1; }
# 'chown' and 'chmod' are guaranteed to exist here
chown -R "$OPENWEBUI_USER":"$OPENWEBUI_GROUP" "$INSTALL_DIR" || log "WARNING" "Failed to set ownership on ${INSTALL_DIR}." >&2
chmod 750 "$INSTALL_DIR" || log "WARNING" "Failed to set permissions on ${INSTALL_DIR}." >&2 # Owner (ollama) rwx, Group (ollama) rx, Others no permissions
log "INFO" "Created/Ensured ${INSTALL_DIR} exists and set permissions for ${OPENWEBUI_USER}."

log "INFO" "Creating data directory ${INSTALL_DIR}/data for Open WebUI and setting permissions for ${OPENWEBUI_USER}..."
mkdir -p "$INSTALL_DIR/data" || { log "ERROR" "Failed to create data directory ${INSTALL_DIR}/data."; exit 1; }
chown -R "$OPENWEBUI_USER":"$OPENWEBUI_GROUP" "$INSTALL_DIR/data" || log "WARNING" "Failed to set ownership on ${INSTALL_DIR}/data." >&2
chmod 700 "$INSTALL_DIR/data" || log "WARNING" "Failed to set permissions on ${INSTALL_DIR}/data." >&2 # Only owner (ollama) rwx, Group and Others no permissions
log "INFO" "Created/Ensured ${INSTALL_DIR}/data exists and set permissions for ${OPENWEBUI_USER}."

# 6. Create virtual environment
log "INFO" "Creating Python virtual environment in ${INSTALL_DIR}/venv as user ${OPENWEBUI_USER} for Open WebUI..."
# python3-venv is guaranteed to be installed by install_required_packages_apt
# 'dpkg' is guaranteed to exist here
if ! dpkg -s python3-venv >/dev/null 2>&1; then
    # This check should ideally pass if install_required_packages_apt succeeded
    log "ERROR" "python3-venv package required but not found after installation attempt. Exiting." >&2
    exit 1
fi

# Run venv creation as the ollama user
# If the venv already exists and is not empty, this command will fail due to set -e
# 'sudo' is guaranteed to exist here
if sudo -u "$OPENWEBUI_USER" python3 -m venv "$INSTALL_DIR/venv"; then
    log "INFO" "Virtual environment created successfully."
else
    # If venv creation failed, it likely already exists or there's another issue
    # Given the script assumes a fresh install or idempotent overwrite,
    # a failure here is considered critical unless we add venv upgrade logic.
    log "ERROR" "Failed to create Python virtual environment as user ${OPENWEBUI_USER}." >&2
    log "ERROR" "Ensure your Python 3 installation includes the 'venv' module and that the directory ${INSTALL_DIR}/venv is empty if it exists." >&2
    exit 1
fi


# 7. Install Open WebUI (Pip or Source)
# 'git' is guaranteed to exist here due to install_required_packages_apt for the source fallback
if ! install_webui_pip; then
    # Pip install failed, attempt source build fallback
    if ! install_webui_source_fallback; then
        log "CRITICAL ERROR" "Open WebUI installation failed via both pip and source build." >&2
        log "CRITICAL ERROR" "Please review the detailed error messages above to troubleshoot." >&2
        exit 1
    fi
fi
echo "" # Add a newline for better readability


# 8. Create and configure Open WebUI systemd service
log "INFO" "Creating systemd service file ${SERVICE_FILE} for Open WebUI..."
# 'cat' is guaranteed to exist here
cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Open WebUI Service
After=network.target ollama.service # Ensure Open WebUI starts after Ollama

[Service]
Type=simple
User=${OPENWEBUI_USER}
Group=${OPENWEBUI_GROUP}
WorkingDirectory=${INSTALL_DIR}
# Set environment variables to direct data and cache to the installation directory
Environment="DATA_DIR=${INSTALL_DIR}/data" "HF_HOME=${INSTALL_DIR}/data/cache" "TRANSFORMERS_CACHE=${INSTALL_DIR}/data/cache" "SENTENCE_TRANSFORMERS_HOME=${INSTALL_DIR}/data/cache"
ExecStart=${INSTALL_DIR}/venv/bin/open-webui serve
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
log "INFO" "Created Open WebUI service file ${SERVICE_FILE}."

# Reload systemd daemon to recognize the new service
log "INFO" "Reloading systemd daemon..."
# 'systemctl' is guaranteed to exist here
systemctl daemon-reload || log "WARNING" "systemctl daemon-reload failed." >&2

# Enable the Open WebUI service to start on boot
log "INFO" "Enabling Open WebUI service to start on boot..."
systemctl enable "$SERVICE_NAME" || log "WARNING" "Failed to enable Open WebUI service. It may not start on boot." >&2

# Start the Open WebUI service
log "INFO" "Starting Open WebUI service..."
# Use || true so set -e doesn't exit immediately if service fails to start
systemctl start "$SERVICE_NAME" || log "WARNING" "Failed to start Open WebUI service. Check its status manually." >&2

# --- Cleanup temporary pip cache ---
# Ensure this is the very last step before the script would naturally exit or exit on error
# The temporary pip cache directory defined at the start
log "INFO" "Cleaning up temporary pip cache directory: $PIP_TEMP_DIR"
# Use rm -rf and handle potential errors gracefully
# 'rm' is guaranteed to exist here
if rm -rf "$PIP_TEMP_DIR"; then
    log "INFO" "Temporary pip cache directory removed successfully."
else
    log "WARNING" "Failed to remove temporary pip cache directory $PIP_TEMP_DIR. You may need to remove it manually." >&2
fi
# --- End Cleanup ---


# 9. Final Status Check and Completion Message
log "INFO" "Checking Open WebUI service status..."
# Use || log "WARNING"... >&2 for error messages
# 'systemctl' is guaranteed to exist here
systemctl status "$SERVICE_NAME" --no-pager || log "WARNING" "Could not get Open WebUI service status or service is not active." >&2


log "INFO" "---------------------------------------------------------------------------"
log "INFO" "LLMaura, Ollama and Open WebUI installation and configuration complete."
log "INFO" "---------------------------------------------------------------------------"
log "INFO" "Ollama should be running and serving models from ${OLLAMA_MODELS_DIR}."
log "INFO" "Open WebUI should now be running as user ${OPENWEBUI_USER} and accessible on port 8080 (or externally on port 80 due to forwarding)."
log "INFO" "Port forwarding from 80 to 8080 has been configured and saved (persistence depends on netfilter-persistent service)."
log "INFO" "Open WebUI's working directory and data directory are set to ${INSTALL_DIR} and owned by ${OPENWEBUI_USER}."
log "INFO" "Cache directories for Hugging Face models used by Open WebUI are directed to ${INSTALL_DIR}/data/cache."
log "INFO" ""
log "INFO" "To access Open WebUI:"
log "INFO" "1. Open the URL http://[HOST_IP] or http://localhost in your web browser."
echo "2. Complete the initial administrator user setup in Open WebUI." # Using echo for numbered list format
echo "3. Open WebUI should automatically detect the local Ollama instance." # Using echo for numbered list format
echo "4. Use the Open WebUI interface to interact with your models for RAG." # Using echo for numbered list format
log "INFO" ""
log "INFO" "To manage the Open WebUI service:"
log "INFO" "  Stop: sudo systemctl stop $SERVICE_NAME"
log "INFO" "  Start: sudo systemctl start $SERVICE_NAME"
log "INFO" "  Restart: sudo systemctl restart $SERVICE_NAME"
# Use --no-pager for journalctl in instructions as well
log "INFO" "  Logs: journalctl -u $SERVICE_NAME --no-pager --follow"
log "INFO" "---------------------------------------------------------------------------"


exit 0 # Explicitly exit with success

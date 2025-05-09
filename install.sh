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
set -e

# Function to check if a command exists (Used in the main script scope)
command_exists() {
    command -v "$@" > /dev/null 2>&1
}

# Define installation directory and service name for Open WebUI
INSTALL_DIR="/opt/openwebui"
SERVICE_NAME="openwebui"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
# Define the user and group for Open WebUI (using the ollama user/group)
# Note: These variables are used for clarity in the Open WebUI steps,
# but the actual user/group 'ollama' is hardcoded where permissions are set.
# This prevents conflicts with the Ollama installation which creates the 'ollama' user.
OPENWEBUI_USER="ollama"
OPENWEBUI_GROUP="ollama"

# Define directory for Ollama models
OLLAMA_MODELS_DIR="/opt/models"
OLLAMA_SERVICE_FILE="/etc/systemd/system/ollama.service"

# Define Ollama models to download
OLLAMA_MODELS=("tinyllama" "phi" "mistral" "gemma:2b" "mistral:7b-instruct-v0.2-q4_K_M")

# Define the temporary pip cache directory used for initial pip install
PIP_TEMP_DIR="/var/tmp/openwebui_pip_cache"

echo "Starting LLMaura: Ollama and Open WebUI installation..."

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root to perform system-level installations and configurations."
    exit 1
fi

# --- Distribution and Version Detection ---

DISTRO=""
VERSION_ID=""
PACKAGE_MANAGER="" # Will only be 'apt' for supported versions

if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO=$ID
    VERSION_ID=$VERSION_ID # Capture version ID
elif type lsb_release >/dev/null 2>&1; then
    DISTRO=$(lsb_release -si | tr '[:upper:]' '[:lower:]') # Ensure lowercase
    VERSION_ID=$(lsb_release -sr) # Capture version ID
else
    echo "Error: Could not detect operating system distribution."
    exit 1
fi

echo "Detected distribution: $DISTRO $VERSION_ID"

# --- Early Exit for Unsupported Distributions/Versions ---
case "$DISTRO" in
    debian)
        if [ "$VERSION_ID" = "12" ]; then
            PACKAGE_MANAGER="apt"
            PYTHON_PREREQUISITES=(python3 python3-pip python3-full python3-venv libopenblas-dev)
            BUILD_PREREQUISITES=(build-essential python3-dev nodejs npm)
            IPTABLES_PREREQUISITES=(iptables-persistent)
            # Pre-configure iptables-persistent to automatically save rules
            echo "Pre-configuring iptables-persistent..."
            echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
            echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
        else
            echo ""
            echo "Error: Detected unsupported Debian version: $VERSION_ID."
            echo "This script currently only supports Debian 12 (Bookworm) and Ubuntu 24 (including point releases)."
            echo "Consider using the official Docker installation method for broader compatibility."
            exit 1
        fi
        ;;
    ubuntu)
        # Use starts_with for 24.04 LTS which might have point releases like 24.04.1
        if [[ "$VERSION_ID" == "24."* ]]; then
            PACKAGE_MANAGER="apt"
            PYTHON_PREREQUISITES=(python3 python3-pip python3-full python3-venv libopenblas-dev)
            BUILD_PREREQUISITES=(build-essential python3-dev nodejs npm)
            IPTABLES_PREREQUISITES=(iptables-persistent)
             # Pre-configure iptables-persistent to automatically save rules
            echo "Pre-configuring iptables-persistent..."
            echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
            echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
        else
            echo ""
            echo "Error: Detected unsupported Ubuntu version: $VERSION_ID."
            echo "This script currently only supports Debian 12 (Bookworm) and Ubuntu 24.04 LTS (including point releases)."
            echo "Consider using the official Docker installation method for broader compatibility."
            exit 1
        fi
        ;;
    *) # Catch all other distros and versions (Fedora, Arch, CentOS, RHEL, etc.)
        echo ""
        echo "Error: Detected unsupported distribution: $DISTRO."
        echo "This script currently only supports Debian 12 (Bookworm) and Ubuntu 24 (including point releases)."
        echo "Consider using the official Docker installation method for broader compatibility."
        exit 1
        ;;
esac

# Since we exit early for unsupported package managers, this check simplifies
if [ "$PACKAGE_MANAGER" != "apt" ]; then
     echo "Internal Error: Package manager not set to 'apt' for a supposedly supported distribution."
     exit 1
fi


# Check Python version is sufficient (Open WebUI generally requires >= 3.9)
if command_exists python3; then
    PYTHON_MAJOR=$(python3 -c 'import sys; print(sys.version_info[0])')
    PYTHON_MINOR=$(python3 -c 'import sys; print(sys.version_info[1])')
    if [ "$PYTHON_MAJOR" -lt 3 ] || ([ "$PYTHON_MAJOR" -eq 3 ] && [ "$PYTHON_MINOR" -lt 9 ]); then
        echo "Error: Python 3.9 or later is required to install Open WebUI."
        echo "Detected system Python version: $PYTHON_MAJOR.$PYTHON_MINOR"
        echo "Please install a more recent Python version or use a distribution that provides one."
        exit 1
    fi
    echo "System Python version $PYTHON_MAJOR.$PYTHON_MINOR detected, which is likely sufficient for Open WebUI."
else
     echo "Error: python3 command not found. Python prerequisites are not installed correctly."
     exit 1
fi


# --- Common Installation and Configuration Steps ---

# --- Ollama Installation and Configuration ---

# Check if Ollama is already installed and running
OLLAMA_INSTALLED=false
if command_exists ollama; then
    echo "Ollama command found."
    if systemctl is-active --quiet ollama; then
        echo "Ollama service appears to be already installed and running. Skipping installation."
        OLLAMA_INSTALLED=true
    else
        echo "Ollama command found, but service is not running. Skipping installation but will attempt to start/configure."
        OLLAMA_INSTALLED=true
    fi
else
    echo "Ollama not found. Proceeding with installation."
fi

# Install Ollama if not already installed
if [ "$OLLAMA_INSTALLED" = false ]; then
    echo "Installing Ollama server..."
    # The official Ollama installation script handles dependencies and service setup
    if ! curl -fsSL https://ollama.com/install.sh | sh; then
        echo "Error: Failed to install Ollama. Open WebUI will not function without an LLM backend."
        exit 1
    fi
    echo "Ollama installed successfully."
    echo ""
fi

# Ensure Ollama user and group exist after potential installation
if ! id -u "$OPENWEBUI_USER" >/dev/null 2>&1; then
    echo "Error: Ollama user '${OPENWEBUI_USER}' not found after installation attempt."
    echo "The official Ollama install script should create this user."
    exit 1
fi
if ! id -g "$OPENWEBUI_GROUP" >/dev/null 2>&2; then # Use 2>&2 for group check output
    echo "Error: Ollama group '${OPENWEBUI_GROUP}' not found after installation attempt."
    echo "The official Ollama install script should create this group."
    exit 1
fi
echo "Confirmed Ollama user (${OPENWEBUI_USER}) and group (${OPENWEBUI_GROUP}) exist."

# Configure Ollama service to use /opt/models and ensure it's running
echo "Configuring Ollama systemd service (${OLLAMA_SERVICE_FILE}) to use ${OLLAMA_MODELS_DIR}..."
# Check if the service file exists (Ollama installer creates it)
if [ -f "$OLLAMA_SERVICE_FILE" ]; then
    # Create the models directory if it doesn't exist and set permissions for the ollama user
    mkdir -p "$OLLAMA_MODELS_DIR"
    chown "$OPENWEBUI_USER":"$OPENWEBUI_GROUP" "$OLLAMA_MODELS_DIR"
    chmod 750 "$OLLAMA_MODELS_DIR" # ollama user rwx, ollama group rx, others no permissions

    # Add or update the Environment variable in the Service section
    # Use sed to delete any existing line starting with Environment="OLLAMA_MODELS=.*" in the Service section
    # and then append the new one after the [Service] line.
    # Use non-greedy match .*? and multiline flag m for better handling of service files
    # Ensure we only modify the [Service] section
    if grep -q "^\[Service\]" "$OLLAMA_SERVICE_FILE"; then
        sed -i -e "/^\[Service\]/,/^\[.*\]/ { /^Environment=\"OLLAMA_MODELS=/d; }" "$OLLAMA_SERVICE_FILE"
        sed -i "/^\[Service\]/a Environment=\"OLLAMA_MODELS=${OLLAMA_MODELS_DIR}\"" "$OLLAMA_SERVICE_FILE"
        echo "Added/Updated Environment=\"OLLAMA_MODELS=${OLLAMA_MODELS_DIR}\" in ${OLLAMA_SERVICE_FILE}"

        # Reload daemon and restart Ollama for changes to take effect
        echo "Reloading systemd daemon and restarting ollama service..."
        systemctl daemon-reload || echo "Warning: systemctl daemon-reload failed. Service changes may not take effect."
        systemctl enable ollama || echo "Warning: Failed to enable ollama service. It may not start on boot." # Enable if not already
        systemctl restart ollama || echo "Warning: Failed to restart ollama service. Check its status manually." # Restart for env var to take effect
    else
        echo "Warning: Could not find [Service] section in ${OLLAMA_SERVICE_FILE}. Cannot configure OLLAMA_MODELS."
    fi
else
    echo "Warning: Ollama service file not found at ${OLLAMA_SERVICE_FILE}. Cannot configure OLLAMA_MODELS."
fi

# Wait for Ollama to be fully ready (up to 90 seconds - increased wait)
echo "Waiting for Ollama to start and become ready..."
OLLAMA_READY=false
for i in {1..90}; do # Increased wait time
    # Use the default Ollama API endpoint
    if curl -s http://localhost:11434 >/dev/null; then
        echo "Ollama is ready!"
        OLLAMA_READY=true
        break
    fi
    echo "Waiting for Ollama, attempt $i..."
    sleep 1
done

if ! $OLLAMA_READY; then
    echo "Error: Ollama failed to start after 90 seconds. Check 'systemctl status ollama'."
    journalctl -u ollama --no-pager -n 50
    # Exiting makes sense as Open WebUI won't work without Ollama.
    exit 1
fi

# Download models with retries (only if Ollama is ready)
if $OLLAMA_READY && [ ${#OLLAMA_MODELS[@]} -gt 0 ]; then
    echo "Downloading specified Ollama models to ${OLLAMA_MODELS_DIR} (this may take a while)..."
    # Use the ollama user to pull models, as it owns the models directory
    # Pass model names as positional arguments ($@) to the inner bash script
    # The '_' is a placeholder for $0 inside the inner script.
    sudo -u "$OPENWEBUI_USER" bash -c '
    # Inside this bash script, the models are available as positional arguments ($1, $2, ...)
    # We iterate over them using "$@"
    for model in "$@"; do
        echo "Pulling ${model}..."
        MODEL_PULLED=false
        for attempt in {1..5}; do
            # Use the ollama command installed by the ollama script and check its exit status
            if ollama pull "${model}"; then
                echo "Successfully pulled ${model}."
                MODEL_PULLED=true
                break
            else
                echo "Attempt ${attempt} failed to pull ${model}, retrying in 15 seconds..."
                sleep 15
            fi
        done
        if [[ "$MODEL_PULLED" == "false" ]]; then # \$ needed because it is in single quotes
            echo "Warning: Failed to pull model ${model} after 5 attempts."
        fi
    done
    echo "Model downloading complete."
    ' _ "${OLLAMA_MODELS[@]}" # Pass array elements as positional arguments
else
    if [ ${#OLLAMA_MODELS[@]} -eq 0 ]; then
        echo "No Ollama models specified in the OLLAMA_MODELS array. Skipping model download."
    else
        echo "Skipping model download because Ollama is not ready."
    fi
fi
echo ""

# --- Open WebUI Installation and Configuration ---

echo "Starting Open WebUI installation and configuration..."

# Install prerequisites for Open WebUI
echo "Installing Open WebUI common, Python, build, and iptables prerequisites using $PACKAGE_MANAGER..."
case "$PACKAGE_MANAGER" in
    apt)
        apt update || echo "Warning: apt update failed. Proceeding with installation."
        apt install -y "${COMMON_PREREQUISITES[@]}" "${PYTHON_PREREQUISITES[@]}" "${BUILD_PREREQUISITES[@]}" "${IPTABLES_PREREQUISITES[@]}"
        ;;
    *)
        # This case should not be reached due to the early exit and the check above
        echo "Internal Error: Package manager '$PACKAGE_MANAGER' not handled in installation steps."
        exit 1
        ;;
esac


# ADD PORT FORWARDING FROM 80 TO 8080 (Open WebUI default port)
echo "Setting up port forwarding from 80 to 8080 using iptables..."
# Clear previous rules for port 80 if they exist to avoid conflicts
# Use 2>/dev/null || true to make deletion attempts non-fatal
iptables -t nat -D PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8000 2>/dev/null || true # Remove potential previous rule
iptables -t nat -D PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080 2>/dev/null || true # Remove potential previous rule for 8080

# Add the new rule
# Ensure the rule is appended to avoid conflicts with other potential PREROUTING rules
iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080 || echo "Warning: Failed to add iptables PREROUTING rule."

# Save iptables rules
echo "Saving iptables rules..."
case "$DISTRO" in
    debian|ubuntu)
        # iptables-persistent service automatically saves rules when the service is running/restarted
        # We already pre-configured it and installed the package.
        # A manual save might be redundant but ensures the current state is captured.
        if command_exists invoke-rc.d; then
            invoke-rc.d iptables-persistent save || echo "Warning: Failed to save iptables rules using invoke-rc.d."
        elif command_exists systemctl; then
             systemctl restart iptables-persistent || echo "Warning: Failed to restart iptables-persistent service to save rules."
        else
            echo "Warning: Could not find a standard way to save iptables rules using iptables-persistent."
            echo "Please check 'iptables-persistent' service status manually."
        fi
        ;;
    *)
        # This case should not be reached due to the early exit
        echo "Internal Warning: iptables save mechanism not handled for distribution '$DISTRO'."
        echo "iptables rules may not persist after reboot. Please save rules manually."
        ;;
esac
echo "" # Add a newline for better readability


# Create the installation directory for Open WebUI and set permissions for the ollama user
echo "Creating installation directory ${INSTALL_DIR} for Open WebUI and setting permissions for ${OPENWEBUI_USER}..."
mkdir -p "$INSTALL_DIR"
chown -R "$OPENWEBUI_USER":"$OPENWEBUI_GROUP" "$INSTALL_DIR"
chmod 750 "$INSTALL_DIR" # Owner (ollama) rwx, Group (ollama) rx, Others no permissions

# Create a virtual environment as the ollama user for Open WebUI
echo "Creating Python virtual environment in ${INSTALL_DIR}/venv as user ${OPENWEBUI_USER} for Open WebUI..."
# Use the python3 from the system path that was already checked
# Check for python3-venv explicitly for Debian/Ubuntu (our now only supported distros)
if ! dpkg -s python3-venv >/dev/null 2>&1; then
    echo "Error: python3-venv package is required but not installed. Install it using 'sudo apt install -y python3-venv'."
    exit 1
fi
if sudo -u "$OPENWEBUI_USER" python3 -m venv "$INSTALL_DIR/venv"; then
    echo "Virtual environment created successfully."
else
    echo "Error: Failed to create Python virtual environment as user ${OPENWEBUI_USER}. Ensure your Python 3 installation includes the 'venv' module (provided by python3-venv)."
    exit 1
fi

# --- Open WebUI Installation: Attempt Pip Install, Fallback to Source ---

echo "Attempting to install Open WebUI using pip as user ${OPENWEBUI_USER}..."

# Ensure the temporary directory for pip cache exists and is writable by the ollama user
mkdir -p "$PIP_TEMP_DIR"
chown "$OPENWEBUI_USER":"$OPENWEBUI_GROUP" "$PIP_TEMP_DIR"
chmod 750 "$PIP_TEMP_DIR" # Ensure ollama user can write

echo "Setting PIP_CACHE_DIR and TMPDIR to $PIP_TEMP_DIR for pip installation."
echo "Please ensure the filesystem containing '$PIP_TEMP_DIR' has sufficient free space (at least several GB)."


# Execute the pip install command and capture output and status
# Using pipefail to capture output and the correct exit status even if grep fails
set +e # Temporarily disable exit on error to handle pip failure gracefully
# Use 'env' with sudo to pass environment variables specifically for this command
PIP_INSTALL_OUTPUT=$(sudo -u "$OPENWEBUI_USER" env PIP_CACHE_DIR="$PIP_TEMP_DIR" TMPDIR="$PIP_TEMP_DIR" "$INSTALL_DIR/venv/bin/pip" install open-webui 2>&1)
PIP_EXIT_STATUS=$?
set -e # Re-enable exit on error

if [ "$PIP_EXIT_STATUS" -eq 0 ]; then
    echo "Open WebUI installed successfully via pip."
else
    echo "Pip installation failed (exit status $PIP_EXIT_STATUS)."
    echo "$PIP_INSTALL_OUTPUT" # Print the pip error output

    # Check if the failure is due to lack of space during download/install
    if echo "$PIP_INSTALL_OUTPUT" | grep -q "OSError: .*No space left on device"; then
        echo ""
        echo "Critical Error: Pip installation failed due to 'No space left on device' (OSError 28)."
        echo "This happened while downloading or installing packages (like torch), indicating the filesystem used by pip for temporary files or caching has run out of space."
        echo "The script attempted to use '$PIP_TEMP_DIR' as the temporary directory."
        echo "Please free up significant disk space on the filesystem containing '$PIP_TEMP_DIR'."
        echo "You can try cleaning pip's cache manually: 'sudo -u $OPENWEBUI_USER $INSTALL_DIR/venv/bin/pip cache purge'"
        echo "You can check disk space using 'df -h $PIP_TEMP_DIR'."
        echo "Alternatively, you can manually set the PIP_CACHE_DIR and TMPDIR environment variables to a location on a filesystem with more space before running this script, like:"
        echo "  export PIP_CACHE_DIR=/path/to/larger/disk/pip_cache TMPDIR=/path/to/larger/disk/tmp && sudo ./your_script.sh"
        echo "After freeing space or setting temporary directories, you can re-run the script."
        exit 1 # Exit after reporting the critical error

    # Check if the failure is due to "No matching distribution found" for open-webui specifically
    elif echo "$PIP_INSTALL_OUTPUT" | grep -qE "(Could not find a version that satisfies the requirement open-webui|No matching distribution found for open-webui)"; then
        echo "Reason: Could not find a compatible pre-built package for open-webui on PyPI."
        echo "Attempting to build Open WebUI from source as a fallback..."

        # --- Source Build Logic ---

        # Define a temporary directory base for source cloning and building.
        SOURCE_BUILD_TMP_BASE="/var/tmp/openwebui_build_tmp" # Use a separate tmp base for source build

        # Ensure the base directory exists before mktemp tries to use it
        mkdir -p "$SOURCE_BUILD_TMP_BASE" || { echo "Error: Failed to create source build temporary base directory $SOURCE_BUILD_TMP_BASE."; exit 1; }

        # Store original TMPDIR if set before potentially setting it for the build
        ORIG_TMPDIR="$TMPDIR"
        TEMP_DIR_SET_BY_SCRIPT=false
        SOURCE_DIR="" # Initialize SOURCE_DIR variable

        # Set TMPDIR to a location for the source build if not already set by the user
        # Use -p with mktemp to specify the parent directory explicitly
        if [ -z "$TMPDIR" ]; then
            # If TMPDIR is not set by the user, use mktemp to create a unique directory
            # within the base directory we just ensured exists, and set TMPDIR to that.
            SOURCE_DIR=$(mktemp -d -p "$SOURCE_BUILD_TMP_BASE" tmp.XXXXXX)
            export TMPDIR="$SOURCE_DIR" # Set TMPDIR to the newly created unique directory
            TEMP_DIR_SET_BY_SCRIPT=true
            echo "TMPDIR environment variable was not set for the source build. Setting it to $TMPDIR."
        else
             # If TMPDIR was already set by the user, use mktemp to create a directory
             # within the location specified by the user's TMPDIR.
             SOURCE_DIR=$(mktemp -d tmp.XXXXXX) # mktemp will use the existing TMPDIR
             echo "TMPDIR environment variable is already set to $TMPDIR. Using this location for the source build."
             # $SOURCE_DIR is the unique directory created by mktemp.
             # $TMPDIR remains the user-set value.
        fi

        echo "Please ensure the filesystem containing '$TMPDIR' (or the filesystem containing '$SOURCE_DIR') has sufficient free space (at least 10-20 GB is recommended for build dependencies)."

        # Clean up temp dir on script exit or interruption
        # The trap needs to remove the unique SOURCE_DIR and restore TMPDIR if the script set it
        trap '
            echo "Cleaning up temporary directory '$SOURCE_DIR'."
            rm -rf "$SOURCE_DIR" || echo "Warning: Failed to remove temporary directory '$SOURCE_DIR'."
            # Restore original TMPDIR only if the script set it
            if [ "$TEMP_DIR_SET_BY_SCRIPT" = true ]; then
                # We set TMPDIR to the unique directory, so just unset it
                unset TMPDIR
                echo "Unsetting TMPDIR."
                # Optionally clean the base dir if empty, but probably not necessary
                # rmdir "$SOURCE_BUILD_TMP_BASE" 2>/dev/null || true
            elif [ -n "$ORIG_TMPDIR" ]; then
                export TMPDIR="$ORIG_TMPDIR"
                echo "Restoring TMPDIR to '$ORIG_TMPDIR'."
            else
                 echo "TMPDIR was originally unset, ensuring it remains unset."
                 unset TMPDIR
            fi
            # Exit cleanly after trap runs, unless the exit was due to a signal
            # Check if exit was due to a signal (e.g., Ctrl+C, SIGTERM)
            if [ -n "$_EXIT_SIGNAL" ]; then
                echo "Exiting due to signal $_EXIT_SIGNAL."
                trap - $_EXIT_SIGNAL # Remove the trap to avoid infinite loop
                kill -$_EXIT_SIGNAL $$ # Re-send the signal to the current process
            fi
            exit # Ensure script exits after trap runs
        ' EXIT

        echo "Cloning Open WebUI repository into temporary directory: $SOURCE_DIR"
        # Use the created SOURCE_DIR for cloning
        if ! git clone https://github.com/open-webui/open-webui.git "$SOURCE_DIR"; then
             echo "Error: Failed to clone Open WebUI repository."
             # The trap will handle cleanup and TMPDIR restoration
             _EXIT_SIGNAL=1 # Set a flag for the trap
             exit 1
        fi

        # Change ownership of the source directory to the ollama user for building
        chown -R "$OPENWEBUI_USER":"$OPENWEBUI_GROUP" "$SOURCE_DIR"

        echo "Building and installing Open WebUI from source using pip install ...."
        # Run pip install from the source directory within the venv, as the ollama user
        # This needs to be done in the source directory context
        # Use --no-cache-dir to avoid issues with stale cache
        set +e # Temporarily disable exit on error for source build
        # Pass the calculated SOURCE_DIR to the bash -c command
        # Ensure TMPDIR is passed to sudo if it was set by the script
        if [ "$TEMP_DIR_SET_BY_SCRIPT" = true ]; then
             BUILD_OUTPUT=$(sudo -u "$OPENWEBUI_USER" env TMPDIR="$TMPDIR" bash -c "cd \"$SOURCE_DIR\" && \"$INSTALL_DIR/venv/bin/pip\" install . --no-cache-dir 2>&1")
        else
             # If TMPDIR was set by the user, sudo will inherit it
             BUILD_OUTPUT=$(sudo -u "$OPENWEBUI_USER" bash -c "cd \"$SOURCE_DIR\" && \"$INSTALL_DIR/venv/bin/pip\" install . --no-cache-dir 2>&1")
        fi
        BUILD_EXIT_STATUS=$?
        set -e # Re-enable exit on error

        if [ "$BUILD_EXIT_STATUS" -eq 0 ]; then
             echo "Open WebUI built and installed from source successfully."
             # Unset the trap after successful source build so cleanup doesn't run on normal exit
             trap - EXIT
             # Need to explicitly run cleanup now for success case
             echo "Cleaning up temporary directory '$SOURCE_DIR'."
             rm -rf "$SOURCE_DIR" || echo "Warning: Failed to remove temporary directory '$SOURCE_DIR'."
             # Restore original TMPDIR if the script set it
             if [ "$TEMP_DIR_SET_BY_SCRIPT" = true ]; then
                 unset TMPDIR
                 echo "Unsetting TMPDIR."
             fi
        else
             echo "Error: Failed to build and install Open WebUI from source (exit status $BUILD_EXIT_STATUS)."
             echo "$BUILD_OUTPUT" # Print the build error output

             # Check if the error is due to lack of space during build
             if echo "$BUILD_OUTPUT" | grep -q "ENOSPC: no space left on device"; then
                 echo ""
                 echo "Critical Error: The source build failed due to 'No space left on device' (ENOSPC)."
                 echo "This means the temporary directory used during the build ($(dirname "$SOURCE_DIR")) ran out of disk space."
                 echo "The build process, especially frontend dependencies, requires significant temporary space (at least 10-20 GB recommended)."
                 # Determine which temporary directory was used for the build based on how TMPDIR was set
                 BUILD_TEMP_DIR_USED="$TMPDIR"
                 if [ "$TEMP_DIR_SET_BY_SCRIPT" != true ] && [ -z "$ORIG_TMPDIR" ]; then
                     # If TMPDIR wasn't set by script or user, mktemp used a default location,
                     # likely /tmp or /var/tmp depending on system config.
                     # We can't know the exact location reliably, so warn based on SOURCE_DIR
                     BUILD_TEMP_DIR_USED="$(dirname "$SOURCE_DIR")"
                 fi
                 echo "The script used '$BUILD_TEMP_DIR_USED' as the temporary directory during the build."
                 echo "Please free up disk space on the filesystem containing '$BUILD_TEMP_DIR_USED'."
                 echo "You can check disk space using 'df -h $BUILD_TEMP_DIR_USED'."
                 echo "Alternatively, you can manually set the TMPDIR environment variable to a location on a filesystem with more space before running this script, like:"
                 echo "  export TMPDIR=/path/to/larger/disk && sudo ./your_script.sh"
                 echo "After freeing space or setting TMPDIR, you can re-run the script."
             # Check if the error is due to onnxruntime compatibility/availability
             elif echo "$BUILD_OUTPUT" | grep -qE "(Could not find a version that satisfies the requirement onnxruntime==|No matching distribution found for onnxruntime==)"; then
                 echo ""
                 echo "Error: The source build failed because a required dependency, 'onnxruntime', specifically version 1.20.1, could not be found on PyPI that is compatible with your Python environment."
                 echo "This often happens on newer distributions or less common architectures where pre-built packages ('wheels') for this specific version of onnxruntime are not yet available on PyPI."
                 echo "Building onnxruntime from source is complex and requires many dependencies not handled by this script."
                 echo "Recommendations:"
                 echo "  - Verify your internet connection to pypi.org."
                 echo "  - Check the official Open WebUI GitHub page or documentation for known build issues with onnxruntime or alternative installation methods (e.g., Docker)."
                 echo "  - The version of Python in your virtual environment is $("$INSTALL_DIR/venv/bin/python3" --version 2>/dev/null || echo 'unknown'). Compatibility depends on PyPI having wheels for this exact version and your OS/architecture."
                 echo "Unfortunately, the script cannot automatically resolve this onnxruntime compatibility issue."

             else
                 # Existing generic build failure message
                 echo "Please ensure all required build prerequisites (including build tools, Python development headers, Node.js, and npm) are installed and review the build output above for details."
             fi

             # The trap will handle cleanup and TMPDIR restoration
             _EXIT_SIGNAL=1 # Set a flag for the trap
             exit 1
        fi


        # --- End Source Build Logic ---

    else
        # If the failure is for another reason (not the above known errors)
        echo "Error: Pip installation failed for an unexpected reason."
        echo "Please review the output above for details."
        exit 1
    fi
fi


# Create the data directory within the install directory for Open WebUI and set permissions for the ollama user
echo "Creating data directory ${INSTALL_DIR}/data for Open WebUI and setting permissions for ${OPENWEBUI_USER}..."
mkdir -p "$INSTALL_DIR/data"
chown -R "$OPENWEBUI_USER":"$OPENWEBUI_GROUP" "$INSTALL_DIR/data"
chmod 700 "$INSTALL_DIR/data" # Only owner (ollama) rwx, Group and Others no permissions

# Create the systemd service file for Open WebUI
echo "Creating systemd service file ${SERVICE_FILE} for Open WebUI..."
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

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd daemon to recognize the new service
echo "Reloading systemd daemon..."
systemctl daemon-reload

# Enable the Open WebUI service to start on boot
echo "Enabling Open WebUI service to start on boot..."
systemctl enable "$SERVICE_NAME" || echo "Warning: Failed to enable Open WebUI service. It may not start on boot."

# Start the Open WebUI service
echo "Starting Open WebUI service..."
systemctl start "$SERVICE_NAME" || echo "Warning: Failed to start Open WebUI service. Check its status manually."

# Check the Open WebUI service status
echo "Checking Open WebUI service status..."
systemctl status "$SERVICE_NAME" --no-pager || echo "Warning: Could not get Open WebUI service status."

echo "LLMaura, Ollama and Open WebUI installation and configuration complete."
echo "Ollama should be running and serving models from ${OLLAMA_MODELS_DIR}."
echo "Open WebUI should now be running as user ${OPENWEBUI_USER} and accessible on port 8080 (or externally on port 80 due to forwarding)."
echo "Port forwarding from 80 to 8080 has been configured and saved (persistence depends on distribution setup)."
echo "Open WebUI's working directory and data directory are set to ${INSTALL_DIR} and owned by ${OPENWEBUI_USER}."
echo "Cache directories for Hugging Face models used by Open WebUI are directed to ${INSTALL_DIR}/data/cache."
echo ""
echo "To access Open WebUI:"
echo "1. Open the URL http://[HOST_IP] or http://localhost in your web browser."
echo "2. Complete the initial administrator user setup in Open WebUI."
echo "3. Open WebUI should automatically detect the local Ollama instance."
echo "4. Use the Open WebUI interface to interact with your models and upload documents for RAG."
echo ""
echo "To manage the Open WebUI service:"
echo "  Stop: sudo systemctl stop $SERVICE_NAME"
echo "  Start: sudo systemctl start $SERVICE_NAME"
echo "  Restart: sudo systemctl restart $SERVICE_NAME"
# Use --no-pager for journalctl in instructions as well
echo "  Logs: journalctl -u $SERVICE_NAME --no-pager --follow"

# --- Cleanup temporary pip cache ---
# Ensure this is the very last step before the script would naturally exit
# The temporary pip cache directory defined at the start
echo "Cleaning up temporary pip cache directory: $PIP_TEMP_DIR"
# Use rm -rf and handle potential errors gracefully
if rm -rf "$PIP_TEMP_DIR"; then
    echo "Temporary pip cache directory removed successfully."
else
    echo "Warning: Failed to remove temporary pip cache directory $PIP_TEMP_DIR. You may need to remove it manually."
fi
# --- End Cleanup ---

# Script will exit automatically here due to set -e unless there's an unhandled error
# The trap will handle cleanup on exit signal or explicit exit calls within error blocks.
# For a normal successful run that doesn't trigger a trap exit, we run cleanup manually.

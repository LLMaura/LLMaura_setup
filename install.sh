#!/bin/bash

# LLMaura runs open source LLM models in house by automating the installation
# of Ollama and Open WebUI on Debian 12.
#
# It configures Open WebUI as a systemd service running as the 'ollama' user,
# sets the working and data directory for Open WebUI to /opt/openwebui,
# configures ollama.service to store models in /opt/models,
# and configures iptables for port forwarding from 80 to 8080.
#
# Maintained by: info@manceps.com

# Exit immediately if a command exits with a non-zero status
set -e

# Function to check if a command exists
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

echo "Starting LLMaura: Ollama and Open WebUI installation..."

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root to perform system-level installations and configurations."
   exit 1
fi

# --- Ollama Installation and Configuration ---

# Check if Ollama is already installed and running
OLLAMA_INSTALLED=false
if command_exists ollama && systemctl is-active --quiet ollama; then
    echo "Ollama appears to be already installed and running. Skipping installation."
    OLLAMA_INSTALLED=true
elif command_exists ollama; then
     echo "Ollama command found, but service is not running. Skipping installation but will attempt to start/configure."
     OLLAMA_INSTALLED=true
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
if ! id -g "$OPENWEBUI_GROUP" >/dev/null 2>&1; then
     echo "Error: Ollama group '${OPENWEBUI_GROUP}' not found after installation attempt."
     echo "The official Ollama install script should create this group."
     exit 1
fi
echo "Confirmed Ollama user (${OPENWEBUI_USER}) and group (${OPENWEBUI_GROUP}) exist."


# Configure Ollama service to use /opt/models and ensure it's running
echo "Configuring Ollama systemd service (${OLLAMA_SERVICE_FILE}) to use ${OLLAMA_MODELS_DIR}..."
# Check if the service file exists
if [ -f "$OLLAMA_SERVICE_FILE" ]; then
    # Create the models directory if it doesn't exist and set permissions for the ollama user
    mkdir -p "$OLLAMA_MODELS_DIR"
    chown "$OPENWEBUI_USER":"$OPENWEBUI_GROUP" "$OLLAMA_MODELS_DIR"
    chmod 750 "$OLLAMA_MODELS_DIR" # ollama user rwx, ollama group rx, others no permissions

    # Add or update the Environment variable in the Service section
    # Use sed to delete any existing line starting with Environment="OLLAMA_MODELS=.*" in the Service section
    # and then append the new one after the [Service] line.
    sed -i -e "/^\[Service\]/,/^\[/ { /^Environment=\"OLLAMA_MODELS=/d; }" "$OLLAMA_SERVICE_FILE"
    sed -i "/^\[Service\]/a Environment=\"OLLAMA_MODELS=${OLLAMA_MODELS_DIR}\"" "$OLLAMA_SERVICE_FILE"
    echo "Added/Updated Environment=\"OLLAMA_MODELS=${OLLAMA_MODELS_DIR}\" in ${OLLAMA_SERVICE_FILE}"

    # Reload daemon and restart Ollama for changes to take effect
    echo "Reloading systemd daemon and restarting ollama service..."
    systemctl daemon-reload || true # Reload if unit files changed, ignore error if none changed
    systemctl enable ollama || echo "Warning: Failed to enable ollama service. It may not start on boot." # Enable if not already
    systemctl restart ollama || echo "Warning: Failed to restart ollama service. Check its status manually." # Restart for env var to take effect
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
            # Use the ollama command installed by the ollama script
            if ollama pull "${model}"; then
                echo "Successfully pulled ${model}."
                MODEL_PULLED=true
                break
            else
                echo "Attempt ${attempt} failed to pull ${model}, retrying in 15 seconds..."
                sleep 15
            fi
        done
        if [[ "\$MODEL_PULLED" == "false" ]]; then # \$ needed because it is in single quotes
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

# Pre-configure iptables-persistent to automatically save rules
echo "Pre-configuring iptables-persistent..."
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections


# Update package list and install prerequisites for Open WebUI
echo "Installing Open WebUI prerequisites (if not already present)..."
apt update # Run update again just in case new packages were added or dependencies changed
apt install -y python3 python3-pip python3-full python3-venv libopenblas-dev iptables-persistent curl git

# ADD PORT FORWARDING FROM 80 TO 8080 (Open WebUI default port)
echo "Setting up port forwarding from 80 to 8080..."
# Clear previous rules for port 80 if they exist to avoid conflicts
# Use 2>/dev/null || true to make deletion attempts non-fatal
iptables -t nat -D PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8000 2>/dev/null || true # Remove potential previous rule
iptables -t nat -D PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080 2>/dev/null || true # Remove potential previous rule for 8080

# Add the new rule
# Ensure the rule is appended to avoid conflicts with other potential PREROUTING rules
iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080

# Save iptables rules
echo "Saving iptables rules using iptables-save..."
if command_exists iptables-save; then
    # Determine the correct location for rules based on systemd-networkd or legacy networking
    if [ -d /etc/iptables ]; then
        iptables-save > /etc/iptables/rules.v4
        echo "Saved IPv4 iptables rules to /etc/iptables/rules.v4"
    elif [ -d /etc/sysconfig ]; then
        iptables-save > /etc/sysconfig/iptables
        echo "Saved IPv4 iptables rules to /etc/sysconfig/iptables"
    else
        echo "Warning: Could not find a standard location like /etc/iptables to save iptables rules."
        echo "Attempting to use iptables-save directly (persistence may depend on iptables-persistent service status)."
        iptables-save # Attempt save without redirection
    fi

    if command_exists ip6tables-save; then
        if [ -d /etc/iptables ]; then
            ip6tables-save > /etc/iptables/rules.v6
            echo "Saved IPv6 iptables rules to /etc/iptables/rules.v6"
        elif [ -d /etc/sysconfig ]; then
             ip6tables-save > /etc/sysconfig/ip6tables
             echo "Saved IPv6 iptables rules to /etc/sysconfig/ip6tables"
        else
             echo "Warning: Could not find a standard location like /etc/iptables to save ip6tables rules."
             echo "Attempting to use ip6tables-save directly (persistence may depend on iptables-persistent service status)."
             ip6tables-save # Attempt save without redirection
        fi
    else
        echo "ip6tables-save command not found. Skipping IPv6 rules saving."
    fi
else
    echo "Warning: iptables-save command not found. iptables rules may not persist after reboot."
    echo "Ensure 'iptables-persistent' is installed and configured correctly."
fi
echo "" # Add a newline for better readability


# Create the installation directory for Open WebUI and set permissions for the ollama user
echo "Creating installation directory ${INSTALL_DIR} for Open WebUI and setting permissions for ${OPENWEBUI_USER}..."
mkdir -p "$INSTALL_DIR"
chown -R "$OPENWEBUI_USER":"$OPENWEBUI_GROUP" "$INSTALL_DIR"
chmod 750 "$INSTALL_DIR" # Owner (ollama) rwx, Group (ollama) rx, Others no permissions

# Create a virtual environment as the ollama user for Open WebUI
echo "Creating Python virtual environment in ${INSTALL_DIR}/venv as user ${OPENWEBUI_USER} for Open WebUI..."
sudo -u "$OPENWEBUI_USER" python3 -m venv "$INSTALL_DIR/venv"

# Install Open WebUI using pip within the virtual environment as the ollama user
echo "Installing Open WebUI using pip as user ${OPENWEBUI_USER}..."
sudo -u "$OPENWEBUI_USER" "$INSTALL_DIR/venv/bin/pip" install open-webui

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
systemctl enable "$SERVICE_NAME"

# Start the Open WebUI service
echo "Starting Open WebUI service..."
systemctl start "$SERVICE_NAME"

# Check the Open WebUI service status
echo "Checking Open WebUI service status..."
systemctl status "$SERVICE_NAME" --no-pager

echo "Ollama and Open WebUI installation and configuration complete."
echo "Ollama should be running and serving models from ${OLLAMA_MODELS_DIR}."
echo "Open WebUI should now be running as user ${OPENWEBUI_USER} and accessible on port 8080 (or externally on port 80 due to forwarding)."
echo "Port forwarding from 80 to 8080 has been configured and saved."
echo "Open WebUI's working directory and data directory are set to ${INSTALL_DIR} and owned by ${OPENWEBUI_USER}."
echo "Cache directories for Hugging Face models used by Open WebUI are directed to ${INSTALL_DIR}/data/cache."
echo ""
echo "1. Open the URL http://[HOST_IP] in your web browser."
echo "2. Complete the initial administrator user setup in Open WebUI."
echo "3. Open WebUI should automatically detect the local Ollama instance."
echo "4. Use the Open WebUI interface to interact with your models and upload documents for RAG."
echo ""
echo "To manage the Open WebUI service:"
echo "  Stop: sudo systemctl stop $SERVICE_NAME"
echo "  Start: sudo systemctl start $SERVICE_NAME"
echo "  Restart: sudo systemctl restart $SERVICE_NAME"
echo "  Status: sudo systemctl status $SERVICE_NAME"
echo "  Logs: journalctl -u $SERVICE_NAME --follow"

#!/bin/bash

# LLMaura runs open source LLM models in house by automating the installation
# of Ollama and Open WebUI on Debian 12.
# It configures Open WebUI as a systemd service running as a less privileged user,
# sets the working and data directory for Open WebUI to /opt/openwebui,
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
# Define the less privileged user and group for Open WebUI
APP_USER="openwebui"
APP_GROUP="openwebui"

# Define Ollama models to download
OLLAMA_MODELS=("tinyllama" "phi" "mistral" "gemma:2b" "mistral:7b-instruct-v0.2-q4_K_M")

echo "Starting LLMaura :Ollama and Open WebUI installation..."

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root to perform system-level installations and configurations."
   exit 1
fi

# Create the less privileged user and group for Open WebUI if they don't exist
echo "Creating system user and group ${APP_USER} for Open WebUI..."
if ! id -u "$APP_USER" >/dev/null 2>&1; then
    groupadd --system "$APP_GROUP" || echo "Group ${APP_GROUP} already exists, skipping."
    useradd --system --no-create-home --shell /usr/sbin/nologin -g "$APP_GROUP" "$APP_USER"
    echo "System user ${APP_USER} created."
else
    echo "System user ${APP_USER} already exists, skipping user/group creation."
fi

# Install Ollama
echo "Installing Ollama server..."
# The official Ollama installation script handles dependencies and service setup
if ! curl -fsSL https://ollama.com/install.sh | sh; then
    echo "Error: Failed to install Ollama. Open WebUI will not function without an LLM backend."
    exit 1
fi
echo "Ollama installed successfully."
echo ""

# Configure Ollama service (ensure it runs and is configured)
echo "Ensuring Ollama systemd service is configured and started..."
# The default install script usually puts it at /etc/systemd/system/ollama.service
# We will just ensure it's enabled and started
systemctl daemon-reload || true # Reload if unit files changed, ignore error if none changed
systemctl enable ollama || echo "Warning: Failed to enable ollama service. It may not start on boot." # Enable if not already
systemctl start ollama || echo "Warning: Failed to start ollama service. Check its status manually." # Start if not running

# Wait for Ollama to be fully ready (up to 60 seconds)
echo "Waiting for Ollama to start..."
OLLAMA_READY=false
for i in {1..60}; do # Increased wait time for potentially slower systems
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
    echo "Error: Ollama failed to start after 60 seconds. Check 'systemctl status ollama'."
    journalctl -u ollama --no-pager -n 50
    exit 1
fi

# Download models with retries
if [ ${#OLLAMA_MODELS[@]} -gt 0 ]; then
    echo "Downloading specified Ollama models (this may take a while)..."
    for model in "${OLLAMA_MODELS[@]}"; do
        echo "Pulling ${model}..."
        MODEL_PULLED=false
        for attempt in {1..5}; do # Increased retry attempts
            # Use the ollama command installed by the ollama script
            if ollama pull "${model}"; then
                echo "Successfully pulled ${model}."
                MODEL_PULLED=true
                break
            else
                echo "Attempt ${attempt} failed to pull ${model}, retrying in 10 seconds..." # Increased retry delay
                sleep 10
                # Consider restarting ollama service on failure, but could interrupt other pulls
                # systemctl restart ollama || true
                # sleep 5
            fi
        done
        if ! $MODEL_PULLED; then
            echo "Warning: Failed to pull model ${model} after 5 attempts."
            # Do not exit, try to install Open WebUI anyway with available models
        fi
    done
    echo "Model downloading complete."
else
    echo "No Ollama models specified in the OLLAMA_MODELS array. Skipping model download."
fi
echo ""

# Pre-configure iptables-persistent to automatically save rules
echo "Pre-configuring iptables-persistent..."
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections


# Update package list and install prerequisites for Open WebUI (ensure they are installed even if apt update was run earlier)
echo "Installing Open WebUI prerequisites (if not already present)..."
apt update # Run update again just in case new packages were added or dependencies changed
apt install -y python3 python3-pip python3-full python3-venv libopenblas-dev iptables-persistent curl git


# ADD PORT FORWARDING FROM 80 TO 8080 (Open WebUI default port)
echo "Setting up port forwarding from 80 to 8080..."
# Clear previous rules for port 80 if they exist to avoid conflicts
# Use 2>/dev/null || true to make deletion attempts non-fatal
# Note: Deleting rules needs them to exist. If they don't, the command will fail without || true.
iptables -t nat -D PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8000 2>/dev/null || true # Remove potential previous rule
iptables -t nat -D PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080 2>/dev/null || true # Remove potential previous rule for 8080

# Add the new rule
# Ensure the rule is appended to avoid conflicts with other potential PREROUTING rules
iptables -t nat -A PREROUTING -p tcp --dport 80 -j REDIRECT --to-port 8080

# Save iptables rules
# With iptables-persistent installed and pre-configured, saving should work to standard locations
echo "Saving iptables rules using iptables-save..."
if command_exists iptables-save; then
    # Determine the correct location for rules based on systemd-networkd or legacy networking
    # iptables-persistent typically uses /etc/iptables
    if [ -d /etc/iptables ]; then
        iptables-save > /etc/iptables/rules.v4
        echo "Saved IPv4 iptables rules to /etc/iptables/rules.v4"
    elif [ -d /etc/sysconfig ]; then
        # Fallback for older or different configurations, though /etc/iptables is standard on modern Debian
        iptables-save > /etc/sysconfig/iptables
        echo "Saved IPv4 iptables rules to /etc/sysconfig/iptables"
    else
        echo "Warning: Could not find a standard location like /etc/iptables to save iptables rules."
        echo "Attempting to use iptables-save directly (persistence may depend on iptables-persistent service status)."
        iptables-save # Attempt save without redirection if location not found
    fi

    # Also handle IPv6 if ip6tables-save command exists
    if command_exists ip6tables-save; then
        if [ -d /etc/iptables ]; then
            ip6tables-save > /etc/iptables/rules.v6
            echo "Saved IPv6 iptables rules to /etc/iptables/rules.v6"
        elif [ -d /etc/sysconfig ]; then
             # Fallback for IPv6
             ip6tables-save > /etc/sysconfig/ip6tables
             echo "Saved IPv6 iptables rules to /etc/sysconfig/ip6tables"
        else
             echo "Warning: Could not find a standard location like /etc/iptables to save ip6tables rules."
             echo "Attempting to use ip6tables-save directly (persistence may depend on iptables-persistent service status)."
             ip6tables-save # Attempt save without redirection if location not found
        fi
    else
        echo "ip6tables-save command not found. Skipping IPv6 rules saving."
    fi
else
    echo "Warning: iptables-save command not found. iptables rules may not persist after reboot."
    echo "Ensure 'iptables-persistent' is installed and configured correctly."
fi
echo "" # Add a newline for better readability


# Create the installation directory for Open WebUI and set permissions for the new user
echo "Creating installation directory ${INSTALL_DIR} for Open WebUI and setting permissions for ${APP_USER}..."
mkdir -p "$INSTALL_DIR"
chown -R "$APP_USER":"$APP_GROUP" "$INSTALL_DIR"
chmod 750 "$INSTALL_DIR" # Owner (openwebui) rwx, Group (openwebui) rx, Others no permissions

# Create a virtual environment as the less privileged user for Open WebUI
# This helps isolate Open WebUI and its dependencies
echo "Creating Python virtual environment in ${INSTALL_DIR}/venv as user ${APP_USER} for Open WebUI..."
sudo -u "$APP_USER" python3 -m venv "$INSTALL_DIR/venv"

# Install Open WebUI using pip within the virtual environment as the less privileged user
echo "Installing Open WebUI using pip as user ${APP_USER}..."
sudo -u "$APP_USER" "$INSTALL_DIR/venv/bin/pip" install open-webui

# Create the data directory within the install directory for Open WebUI and set permissions for the new user
# This is where Open WebUI will store its data, including potentially sensitive information
echo "Creating data directory ${INSTALL_DIR}/data for Open WebUI and setting permissions for ${APP_USER}..."
mkdir -p "$INSTALL_DIR/data"
chown -R "$APP_USER":"$APP_GROUP" "$INSTALL_DIR/data"
chmod 700 "$INSTALL_DIR/data" # Only owner (openwebui) rwx, Group and Others no permissions

# Create the systemd service file for Open WebUI
echo "Creating systemd service file ${SERVICE_FILE} for Open WebUI..."
cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Open WebUI Service
After=network.target ollama.service # Ensure Open WebUI starts after Ollama

[Service]
Type=simple
User=${APP_USER}
Group=${APP_GROUP}
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
echo "Ollama should be running and serving models."
echo "Open WebUI should now be running as user ${APP_USER} and accessible on port 8080 (or esternall on port 80 due to forwarding)."
echo "Port forwarding from 80 to 8080 has been configured and saved."
echo "Open WebUI's working directory and data directory are set to ${INSTALL_DIR} and owned by ${APP_USER}."
echo "Cache directories for Hugging Face models used by Open WebUI are directed to ${INSTALL_DIR}/data/cache."
echo ""
echo "1. Open the URL http://[HOST_IP] in your web browser."
echo "2. Complete the initial administrator user setup in Open WebUI."
echo "3. Open WebUI should automatically detect the local Ollama instance."
echo "4. Use the Open WebUI interface to interact with your models and upload documents for RAG."
echo ""
echo "To manage the Open WebUI service:"
echo "  Stop: sudo systemctl stop $OPENWEBUI_SERVICE_NAME"
echo "  Start: sudo systemctl start $OPENWEBUI_SERVICE_NAME"
echo "  Restart: sudo systemctl restart $OPENWEBUI_SERVICE_NAME"
echo "  Status: sudo systemctl status $OPENWEBUI_SERVICE_NAME"
echo "  Logs: journalctl -u $OPENWEBUI_SERVICE_NAME --follow"

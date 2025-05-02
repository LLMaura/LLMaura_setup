# LLMaura- Host your LLM in-house.
![LLMaura](open-webui.png)

LLMaura automates the installation of Ollama and Open WebUI.

This script provides an automated way to install Ollama and Open WebUI on a Debian 12 system. It sets up Open WebUI to run as a less privileged system user via systemd, configures directories and permissions appropriately, pulls specified Ollama models, and sets up iptables port forwarding from port 80 to 8080 for easy access.

**Disclaimer:** Running web services requires careful security consideration. This script configures Open WebUI to run as a less privileged user, which is better than running as root, but further security measures (like a proper firewall beyond the port forwarding configured here) are recommended for production environments.

## Features

* Installs Ollama server using the official installation script.
* Pulls a predefined list of Large Language Models (LLMs) using Ollama.
* Installs Open WebUI and its dependencies using `pip` within a Python virtual environment.
* Configures Open WebUI as a systemd service (`openwebui.service`) ensuring it starts on boot and restarts automatically on failure.
* Configures iptables to forward incoming traffic on port 80 to Open WebUI's default port 8080 and saves the rules to persist across reboots.

## Prerequisites

* A server or virtual machine running **Debian 12**.
* **Root access** or a user with `sudo` privileges to run the installation script.
* **Internet connectivity** to download packages, Ollama, Open WebUI, and LLM models.
* **Sufficient disk space** for the chosen Ollama models and Open WebUI data. LLM models can be large (several gigabytes each).
* **Sufficient RAM and CPU** (and prefereably a compatible GPU) for Ollama to load and run the LLMs.

## Installation

1. Install git and clone this repo:
    ```bash
    sudo apt update
    sudo apt install -y git
    git clone https://github.com/alkari/LLMaura.git
    cd LLMaura
    ```` 

2.  Make the script executable:
    ```bash
    chmod +x install.sh
    ```

3.  Run the script with root privileges:
    ```bash
    sudo ./install.sh
    ```

4.  The script will proceed with the installation steps, including updating packages, installing prerequisites, installing Ollama, pulling models, setting up Open WebUI, configuring permissions, and setting up the systemd service and iptables rules. This process may take some time depending on your internet speed and system performance, especially during the model download phase.

5.  Monitor the script's output for any errors.

## Configurable Parameters

You can modify variables at the **beginning of the script** before running it to customize the installation:

* `OLLAMA_MODELS`: A bash array containing the names of the Ollama models to download during installation.
    * Example Default: `("tinyllama" "phi" "mistral" "gemma:2b" "mistral:7b-instruct-v0.2-q4_K_M")`
    * You can add or remove models from this list. Ensure the model names are valid as listed on the Ollama website (`ollama.com/models`).

## Post-Installation and Basic GUI Setup

1.  Once the script completes successfully, Open WebUI should be running as a background service.
2.  You can access the Open WebUI graphical interface via your web browser by navigating to the IP address of your Debian 12 server.
3.  The first time you access Open WebUI, you will be prompted to create an initial administrator user account. Follow the on-screen instructions.
4.  After logging in, you should see the Open WebUI chat interface. The models you specified in the `OLLAMA_MODELS` array during installation should be available in the model selection dropdown.

## Managing Ollama Models

You can add or remove models from Ollama at any time after the installation is complete. It's important to perform these actions as the user that the `ollama` service runs as (typically the `ollama` system user created by the official script) to ensure correct file permissions for the models.

* **To add a model:**
    ```bash
    sudo -u ollama ollama pull <model_name>
    ```
    Replace `<model_name>` with the name of the model you want to download (e.g., `llama2`).

* **To remove a model:**
    ```bash
    sudo -u ollama ollama rm <model_name>
    ```
    Replace `<model_name>` with the name of the model you want to remove.

* **To list installed models:**
    ```bash
    sudo -u ollama ollama list
    ```

The Open WebUI interface should automatically detect newly added or removed models after a short time.

## Maintenance

* **Updating Open WebUI:**
    1.  Stop the Open WebUI service:
        ```bash
        sudo systemctl stop openwebui
        ```
    2.  Update Open WebUI using pip, running as the `openwebui` user within its virtual environment:
        ```bash
        sudo -u openwebui /opt/openwebui/venv/bin/pip install --upgrade open-webui
        ```
    3.  Start the Open WebUI service:
        ```bash
        sudo systemctl start openwebui
        ```

* **Updating Ollama:**
    The recommended way to update Ollama installed via the `curl | sh` script is to re-run the installation script. It is designed to update an existing installation.
    ```bash
    curl -fsSL [https://ollama.com/install.sh](https://ollama.com/install.sh) | sh
    ```
    After updating Ollama, restart both services:
    ```bash
    sudo systemctl restart ollama openwebui
    ```

* **Updating System Packages:**
    Keep your Debian system up-to-date regularly:
    ```bash
    sudo apt update && sudo apt upgrade -y
    ```

## Troubleshooting

* **Script fails during execution:**
    * Read the error messages carefully. They usually indicate what went wrong (e.g., package not found, permission denied, failed download).
    * Ensure you are running the script as root (`sudo`).
    * Check your internet connection.
    * Verify that Debian 12 is installed correctly.

* **Cannot access Open WebUI GUI:**
    * Check if the `openwebui` service is running: `sudo systemctl status openwebui`. If not, check its logs (`journalctl -u openwebui --no-pager`) and try starting it (`sudo systemctl start openwebui`).
    * Check if the `ollama` service is running: `sudo systemctl status ollama`. Open WebUI depends on Ollama. If it's not running, check its logs (`journalctl -u ollama --no-pager`) and try starting it (`sudo systemctl start ollama`).
    * Verify the iptables port forwarding rule is active: `sudo iptables -t nat -L PREROUTING`. You should see a rule redirecting TCP traffic on port 80 to 8080.
    * Check if Open WebUI is listening on port 8080: `sudo ss -tulnp | grep 8080`. You should see a process listening on `0.0.0.0:8080` or `127.0.0.1:8080` (if only listening on localhost, the port forwarding won't work from external IPs).
    * Check your system's firewall (if you have one configured, e.g., UFW) to ensure ports 80 and/or 8080 are allowed.

* **`500: Ollama: 500, message='Internal Server Error'` in Open WebUI:**
    This error comes from Ollama itself.
    * Check the status and logs of the `ollama` service (see point 1 in GUI access troubleshooting).
    * Verify the models are installed and accessible to Ollama: `sudo -u ollama ollama list`.
    * Test the Ollama API directly from the server: `curl -X POST http://localhost:11434/api/generate -d '{ "model": "tinyllama", "prompt": "hello" }'`. If this fails or returns a 500, the issue is with your Ollama installation or model.
    * Check system resources (CPU, RAM, GPU) using `htop` or `nvidia-smi`. Ollama might be failing due to resource exhaustion when trying to load or run a model.

* **Permission denied errors in logs:**
    * Ensure the `openwebui` service is running as the `openwebui` user (`sudo systemctl status openwebui` should show `User=openwebui`).
    * Verify ownership and permissions of `/opt/openwebui` and `/opt/openwebui/data`: `ls -l /opt/`. The owner should be `openwebui`. Permissions should allow the owner to write (e.g., 750 or 700).

## Uninstallation

To remove Ollama and Open WebUI installed by this script:

1.  Stop the services:
    ```bash
    sudo systemctl stop openwebui ollama
    ```

2.  Disable the services:
    ```bash
    sudo systemctl disable openwebui ollama
    ```

3.  Reload systemd:
    ```bash
    sudo systemctl daemon-reload
    ```

4.  Uninstall Ollama using its official uninstall command:
    ```bash
    sudo ollama uninstall
    ```
    Follow any prompts. This should remove the Ollama binary and its service file.

5.  Remove the Open WebUI installation directory:
    ```bash
    sudo rm -rf /opt/openwebui
    ```
    (Adjust `/opt/openwebui` if you changed the `INSTALL_DIR`).

6.  Remove the Open WebUI service file:
    ```bash
    sudo rm /etc/systemd/system/openwebui.service
    ```

7.  (Optional) Remove the iptables port forwarding rule. This is best done manually to avoid accidentally removing other rules.
    * List the NAT PREROUTING rules with line numbers:
        ```bash
        sudo iptables -t nat -L PREROUTING --line-numbers
        ```
    * Identify the line number corresponding to the rule redirecting port 80 to 8080.
    * Delete the specific rule by its line number:
        ```bash
        sudo iptables -t nat -D PREROUTING <line_number>
        ```
        Replace `<line_number>` with the actual number.
    * Save the updated iptables rules:
        ```bash
        sudo iptables-save > /etc/iptables/rules.v4
        ```
        (You might also need to do this for IPv6 using `ip6tables-save > /etc/iptables/rules.v6` if an IPv6 rule was created).

8.  (Optional) Remove the `openwebui` user and group:
    ```bash
    sudo userdel openwebui
    sudo groupdel openwebui
    ```

9.  (Optional) Remove the installed prerequisite packages:
    ```bash
    sudo apt purge python3-pip python3-full python3-venv libopenblas-dev iptables-persistent curl git
    ```
    (Note: `iptables-persistent` removal will likely ask if you want to save rules again).

10. Clean up unused packages and the apt cache:
    ```bash
    sudo apt autoremove
    sudo apt clean
    ```

## Security Considerations

* **Running as Root:** The installation script *must* be run as root to perform system-level tasks. However, Open WebUI itself is configured to run as a less privileged user (`openwebui`), which is a significant security improvement over running it as root.
* **Port Forwarding:** The script sets up port forwarding from 80 to 8080 using iptables. This is *not* a comprehensive firewall. You should configure a proper firewall (like UFW) to control access to other ports and services on your server.
* **Data Directory:** The `/opt/openwebui/data` directory is set to be owned and writable only by the `openwebui` user (`chmod 700`). This protects potentially sensitive data stored by Open WebUI.

## License

This script is provided under the [MIT License](https://opensource.org/licenses/MIT).

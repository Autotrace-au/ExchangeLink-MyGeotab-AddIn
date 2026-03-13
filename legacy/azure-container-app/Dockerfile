# Production MyGeotab to Exchange Calendar Sync Container
FROM mcr.microsoft.com/powershell:7.4-ubuntu-22.04

# Install system dependencies
RUN apt-get update && apt-get install -y \
    curl \
    jq \
    python3 \
    python3-pip \
    ca-certificates \
    gnupg \
    lsb-release \
    && rm -rf /var/lib/apt/lists/*

# Install Azure CLI
RUN curl -sLS https://packages.microsoft.com/keys/microsoft.asc | \
    gpg --dearmor | \
    tee /etc/apt/trusted.gpg.d/microsoft.gpg > /dev/null && \
    echo "deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ $(lsb_release -cs) main" | \
    tee /etc/apt/sources.list.d/azure-cli.list && \
    apt-get update && \
    apt-get install -y azure-cli && \
    rm -rf /var/lib/apt/lists/*

# Install PowerShell modules for Exchange Online and Azure
RUN pwsh -Command " \
    Install-Module -Name ExchangeOnlineManagement -Force -AllowClobber -Scope AllUsers; \
    Install-Module -Name Az.Accounts -Force -AllowClobber -Scope AllUsers; \
    Install-Module -Name Az.KeyVault -Force -AllowClobber -Scope AllUsers"

# Install Python dependencies
RUN python3 -m pip install --no-cache-dir mygeotab azure-keyvault-secrets azure-identity

# Create app directory
WORKDIR /app

# Copy PowerShell scripts
COPY exchange-processor.ps1 .
COPY start-server.ps1 .
COPY mygeotab-exchange-sync.ps1 .
COPY update-device-properties.ps1 .
COPY update_device_properties.py .

# Make scripts executable
RUN chmod +x *.ps1 && chmod +x update_device_properties.py

# Expose port
EXPOSE 8080

# Start the PowerShell HTTP server
CMD ["pwsh", "./start-server.ps1"]
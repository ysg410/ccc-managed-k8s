#!/usr/bin/env bash
# Runs once via cloud-init on the jumpbox. Log: /var/log/aks-ccc-bootstrap.log
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
# shellcheck source=/dev/null
source /opt/aks-ccc/env.sh

apt-get update
apt-get install -y ca-certificates curl gnupg lsb-release git jq unzip dnsutils

# Azure CLI
curl -sL https://aka.ms/InstallAzureCLIDeb | bash

# Terraform (HashiCorp apt repository)
curl -fsSL https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
  > /etc/apt/sources.list.d/hashicorp.list
apt-get update
apt-get install -y terraform

# kubectl and kubelogin
az aks install-cli --install-location /usr/local/bin/kubectl --kubelogin-install-location /usr/local/bin/kubelogin

# PR branch and generated inputs
sudo -u azureuser git clone --branch "$EXAMPLE_REPO_BRANCH" "$EXAMPLE_REPO_URL" /home/azureuser/aks-avm
install -o azureuser -g azureuser -m 0600 /opt/aks-ccc/terraform.tfvars.json "$EXAMPLE_DIR/terraform.tfvars.json"
echo 'source /opt/aks-ccc/env.sh' >> /home/azureuser/.bashrc

touch /opt/aks-ccc/READY

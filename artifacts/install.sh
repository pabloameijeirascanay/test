#!/bin/bash
exec >aks.log
exec 2>&1

sudo apt-get update

# Export variables
export KUBECTL_VERSION="1.24/stable"
export TEMPLATE_BASE_URL=""

# Creating login message of the day (motd)
tput setaf 1;echo "-----------------------------------------------------------------------------------------------------------------------------"
echo ""
tput setaf 6;echo "Welcome to the Azure Firewall TLS inspection scenario!"
echo ""
tput setaf 6;echo "* To check the configuration deployment log, use the 'cat jumpstart_logs/installKubeadm.log' command."
echo ""
tput setaf 6;echo "* To work with the AKS cluster, use the 'kubectl <command>'. For example: kubectl get nodes"
echo ""
tput setaf 1;echo "-----------------------------------------------------------------------------------------------------------------------------"

# Installing Azure CLI & Azure Arc extensions
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash

echo "Log in to Azure"
sudo -u $ADMIN_USER_NAME az login --service-principal --username $SPN_CLIENT_ID --password $SPN_CLIENT_SECRET --tenant $TENANT_ID
export SUBSCRIPTION_ID=$(sudo -u $ADMIN_USER_NAME az account show --query id --output tsv)
az -v
echo ""

# Installing kubectl
sudo snap install kubectl --channel=$KUBECTL_VERSION --classic

# Installing Helm 3
sudo snap install helm --classic

# Intalling envsubst, it substitutes the values of environment variables.
curl -L https://github.com/a8m/envsubst/releases/download/v1.2.0/envsubst-`uname -s`-`uname -m` -o envsubst
chmod +x envsubst
sudo mv envsubst /usr/local/bin

# Get access credentials for a managed Kubernetes cluster
az aks get-credentials --name $AKS_NAME --resource-group $AKS_RESOURCE_GROUP_NAME

# Install Nginx Ingress Controller
echo ""
echo "######################################################################################"
echo "Install Nginx Ingress Controller..." 

sudo helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
sudo helm repo update
sudo helm install nginx-ingress ingress-nginx/ingress-nginx \
--set controller.replicaCount=2 \
--namespace ingress-nginx --create-namespace \
--set controller.nodeSelector."kubernetes\.io/os"=linux \
--set defaultBackend.nodeSelector."kubernetes\.io/os"=linux \
--set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-internal"="true" \
--set controller.service.externalTrafficPolicy=Local \
--set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz

# Install ExternalDNS
echo ""
echo "######################################################################################"
echo "Install ExternalDNS..." 

export PRINCIPAL_ID=$(az aks show --resource-group $DNS_PRIVATE_ZONE_RESOURCE_GROUP_NAME --name $AKS_NAME --query "identityProfile.kubeletidentity.objectId" --output tsv)
export DNS_ID=$(az network private-dns zone show --name $DNS_PRIVATE_ZONE_NAME --resource-group $DNS_PRIVATE_ZONE_RESOURCE_GROUP_NAME --query "id" --output tsv)
sudo -u $ADMIN_USER_NAME az role assignment create --role "Private DNS Zone Contributor" --assignee $PRINCIPAL_ID --scope $DNS_ID

cat <<-EOF > ./azure.json
{
  "tenantId": "$TENANT_ID",
  "subscriptionId": "$SUBSCRIPTION_ID",
  "resourceGroup": "$DNS_PRIVATE_ZONE_RESOURCE_GROUP_NAME",
  "useManagedIdentityExtension": true
}
EOF

sudo -u $ADMIN_USER_NAME kubectl create ns externaldns
sudo -u $ADMIN_USER_NAME kubectl create secret generic azure-config-file --namespace externaldns --from-file azure.json
envsubst < ${TEMPLATE_BASE_URL}artifacts/external-dns.yaml | kubectl apply -f -

echo ""
echo "######################################################################################"
echo "Use the Azure Key Vault Provider for Secrets Store CSI Driver..."

az aks enable-addons --addons azure-keyvault-secrets-provider --name $AKS_NAME --resource-group $RESOURCE_GROUP

export CLIENT_ID=$(az aks show --name $AKS_NAME --resource-group $RESOURCE_GROUP --query addonProfiles.azureKeyvaultSecretsProvider.identity.clientId -o tsv)

# set policy to access certs in your key vault
az keyvault set-policy -n $AKS_NAME --secret-permissions get --spn $CLIENT_ID

# Deploy a SecretProviderClass
envsubst < ${TEMPLATE_BASE_URL}artifacts/secret-provider-class.yaml | kubectl apply -f -

echo ""
echo "######################################################################################"
echo "Create the application..."

envsubst < ${TEMPLATE_BASE_URL}artifacts/app.yaml | kubectl apply -f -

echo ""
echo "######################################################################################"
echo "Create the ingress..."

envsubst < ${TEMPLATE_BASE_URL}artifacts/ingress.yaml | kubectl apply -f -
#!/bin/bash
sudo apt-get update

# Export variables
export KUBECTL_VERSION="1.24/stable"

# Installing Azure CLI & Azure Arc extensions
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
az -v
echo ""
echo "Log in to Azure"
echo ""
sudo -u $ADMIN_USER_NAME az login --service-principal --username $SPN_CLIENT_ID --password $SPN_CLIENT_SECRET --tenant $TENANT_ID
export SUBSCRIPTION_ID=$(sudo -u $ADMIN_USER_NAME az account show --query id --output tsv)

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

echo ""
echo "######################################################################################"
echo "## Disabling public access in Azure Key Vault...                                    ##" 
echo "######################################################################################"
echo ""

az keyvault update --name $AKV_NAME --public-network-access Disabled

# restart the networking service
sudo systemctl restart systemd-networkd
sleep 10

# Install Nginx Ingress Controller
echo ""
echo "######################################################################################"
echo "## Install Nginx Ingress Controller...                                              ##" 
echo "######################################################################################"
echo ""

sudo helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
sudo helm repo update
sudo helm install nginx-ingress ingress-nginx/ingress-nginx \
--set controller.replicaCount=2 \
--namespace ingress-nginx --create-namespace \
--set controller.nodeSelector."kubernetes\.io/os"=linux \
--set defaultBackend.nodeSelector."kubernetes\.io/os"=linux \
--set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-internal"="true" \
--set controller.service.externalTrafficPolicy=Local \
--set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz \
--set controller.service.loadBalancerIP=10.0.2.73 \
--kubeconfig /home/${ADMIN_USER_NAME}/.kube/config

# Install ExternalDNS
echo ""
echo "######################################################################################"
echo "## Install ExternalDNS...                                                           ##" 
echo "######################################################################################"
echo ""
export CLIENT_ID=$(az aks show --resource-group $AKS_RESOURCE_GROUP_NAME --name $AKS_NAME --query "identityProfile.kubeletidentity.clientId" --output tsv)
export PRINCIPAL_ID=$(az aks show --resource-group $AKS_RESOURCE_GROUP_NAME --name $AKS_NAME --query "identityProfile.kubeletidentity.objectId" --output tsv)
export DNS_ID=$(az network private-dns zone show --name $DNS_PRIVATE_ZONE_NAME --resource-group $DNS_PRIVATE_ZONE_RESOURCE_GROUP_NAME --query "id" --output tsv)
sudo -u $ADMIN_USER_NAME az role assignment create --role "Private DNS Zone Contributor" --assignee-object-id $PRINCIPAL_ID --assignee-principal-type ServicePrincipal --scope $DNS_ID

cat <<-EOF > ./azure.json
{
  "tenantId": "$TENANT_ID",
  "subscriptionId": "$SUBSCRIPTION_ID",
  "resourceGroup": "$DNS_PRIVATE_ZONE_RESOURCE_GROUP_NAME",
  "useManagedIdentityExtension": true,
  "userAssignedIdentityID": "$CLIENT_ID"
}
EOF

sudo -u $ADMIN_USER_NAME kubectl create ns externaldns
sudo -u $ADMIN_USER_NAME kubectl create secret generic azure-config-file --namespace externaldns --from-file azure.json
envsubst < external-dns.yaml | kubectl apply -f -

echo ""
echo "######################################################################################"
echo "## Configure workload identity...                                                   ##" 
echo "######################################################################################"
echo ""

# Install the aks-preview extension
az extension add --name aks-preview

# Register the 'EnableWorkloadIdentityPreview' feature
az feature register --namespace "Microsoft.ContainerService" --name "EnableWorkloadIdentityPreview"

# Don't continue until ingress controller EXTERNAL-IP exists
until [[ $FEATURE == "Registered" ]]; do
  FEATURE=$(az feature show --namespace "Microsoft.ContainerService" --name "EnableWorkloadIdentityPreview" --query properties.state -o tsv)
  echo "Waiting for EnableWorkloadIdentityPreview feature registration, hold tight...(5s sleeping loop)"
  sleep 5
done

# Enable OIDC and Workload Identity
az aks update -g $AKS_RESOURCE_GROUP_NAME -n $AKS_NAME --enable-oidc-issuer --enable-workload-identity

# create a managed identity
export CLIENT_ID="$(az identity create --name workload-identity --resource-group $AKS_RESOURCE_GROUP_NAME --query 'clientId' -o tsv)"

# Get the AKS cluster OIDC issuer URL
export AKS_OIDC_ISSUER="$(az aks show --resource-group $AKS_RESOURCE_GROUP_NAME --name $AKS_NAME --query "oidcIssuerProfile.issuerUrl" -o tsv)"

# Create the service account
export serviceAccountName="workload-identity-sa"
export serviceAccountNamespace="default" # can be changed to namespace of your workload, in this case is default
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    azure.workload.identity/client-id: ${CLIENT_ID}
  labels:
    azure.workload.identity/use: "true"
  name: ${serviceAccountName}
  namespace: ${serviceAccountNamespace}
EOF

# Create the federated identity credential between the Managed Identity, the service account issuer, and the subject
az identity federated-credential create --name aksfederatedidentity --identity-name workload-identity --resource-group $AKS_RESOURCE_GROUP_NAME --issuer ${AKS_OIDC_ISSUER} --subject system:serviceaccount:${serviceAccountNamespace}:${serviceAccountName}

echo ""
echo "######################################################################################"
echo "## Use the Azure Key Vault Provider for Secrets Store CSI Driver...                 ##" 
echo "######################################################################################"
echo ""

# set policy to access certs in your key vault
export PRINCIPAL_ID=$(az identity show -g $AKS_RESOURCE_GROUP_NAME --name workload-identity --query 'principalId' -o tsv)
az keyvault set-policy -n $AKV_NAME --secret-permissions get --object-id $PRINCIPAL_ID

# Deploy a SecretProviderClass
envsubst < secret-provider-class.yaml | kubectl apply -f -

echo ""
echo "######################################################################################"
echo "## Create the application...                                                        ##" 
echo "######################################################################################"
echo ""
envsubst < app.yaml | kubectl apply -f -

echo ""
echo "######################################################################################"
echo "## Create the ingress...                                                            ##" 
echo "######################################################################################"
echo ""

# Don't continue until ingress controller EXTERNAL-IP exists
until [[ $EXTERNAL_IP =~ (10)(\.([2]([0-5][0-5]|[01234][6-9])|[1][0-9][0-9]|[1-9][0-9]|[0-9])){3} ]]; do
  EXTERNAL_IP=$(kubectl get svc nginx-ingress-ingress-nginx-controller -n ingress-nginx -o jsonpath="{.status.loadBalancer.ingress[0].ip}")
  echo "Waiting for nginx ingress controller EXTERNAL-IP, hold tight...(5s sleeping loop)"
  sleep 5
done

# Create the ingress
envsubst < ingress.yaml | kubectl apply -f -

echo ""
echo "######################################################################################"
echo "## Restarting Application Gateway...                                                ##" 
echo "######################################################################################"
echo ""

# Stop the Azure Application Gateway
az network application-gateway stop -n $APPGW_NAME -g $APPGW_RESOURCE_GROUP_NAME

# Start the Azure Application Gateway
az network application-gateway start -n $APPGW_NAME -g $APPGW_RESOURCE_GROUP_NAME
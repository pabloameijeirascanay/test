exec >download.log
exec 2>&1

sudo apt-get update

sudo sed -i "s/PasswordAuthentication no/PasswordAuthentication yes/" /etc/ssh/sshd_config
sudo adduser staginguser --gecos "First Last,RoomNumber,WorkPhone,HomePhone" --disabled-password
sudo echo "staginguser:Passw0rd" | sudo chpasswd

# Injecting environment variables from Azure deployment
echo '#!/bin/bash' >> vars.sh
echo $ADMIN_USER_NAME:$1 | awk '{print substr($1,2); }' >> vars.sh
echo $SPN_CLIENT_ID:$2 | awk '{print substr($1,2); }' >> vars.sh
echo $SPN_CLIENT_SECRET:$3 | awk '{print substr($1,2); }' >> vars.sh
echo $TENANT_ID:$4 | awk '{print substr($1,2); }' >> vars.sh
echo $AKS_RESOURCE_GROUP_NAME:$5 | awk '{print substr($1,2); }' >> vars.sh
echo $LOCATION:$6 | awk '{print substr($1,2); }' >> vars.sh
echo $DNS_PRIVATE_ZONE_NAME:$7 | awk '{print substr($1,2); }' >> vars.sh
echo $AKS_NAME:$8 | awk '{print substr($1,2); }' >> vars.sh
echo $AKV_NAME:$9 | awk '{print substr($1,2); }' >> vars.sh
echo $CERT_NAME:${10} | awk '{print substr($1,2); }' >> vars.sh
echo $DNS_PRIVATE_ZONE_RESOURCE_GROUP_NAME:${11} | awk '{print substr($1,2); }' >> vars.sh
echo $TEMPLATE_BASE_URL:${11} | awk '{print substr($1,2); }' >> vars.sh
echo $AKV_RESOURCE_GROUP_NAME:${11} | awk '{print substr($1,2); }' >> vars.sh 

sed -i '2s/^/export ADMIN_USER_NAME=/' vars.sh
sed -i '3s/^/export SPN_CLIENT_ID=/' vars.sh
sed -i '4s/^/export SPN_CLIENT_SECRET=/' vars.sh
sed -i '5s/^/export TENANT_ID=/' vars.sh
sed -i '6s/^/export AKS_RESOURCE_GROUP_NAME=/' vars.sh
sed -i '7s/^/export LOCATION=/' vars.sh
sed -i '8s/^/export DNS_PRIVATE_ZONE_NAME=/' vars.sh
sed -i '9s/^/export AKS_NAME=/' vars.sh
sed -i '10s/^/export AKV_NAME=/' vars.sh
sed -i '11s/^/export CERT_NAME=/' vars.sh
sed -i '12s/^/export DNS_PRIVATE_ZONE_RESOURCE_GROUP_NAME=/' vars.sh
sed -i '13s/^/export TEMPLATE_BASE_URL=/' vars.sh
sed -i '13s/^/export AKV_RESOURCE_GROUP_NAME=/' vars.sh

chmod +x vars.sh 
. ./vars.sh

# Creating login message of the day (motd)
sudo curl -o /home/$ADMIN_USER_NAME/install.sh ${TEMPLATE_BASE_URL}artifacts/install.sh

sudo chmod +x install.sh

# Syncing this script log to 'home/user/' directory for ease of troubleshooting
sudo -u $ADMIN_USER_NAME mkdir -p /home/${ADMIN_USER_NAME}/
while sleep 1; do sudo -s rsync -a /var/lib/waagent/custom-script/download/0/download.log /home/${ADMIN_USER_NAME}/download.log; done &
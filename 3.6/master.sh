#!/bin/bash

echo "master.sh called."

RHNUSERNAME=$1
RHNPASSWORD=$2
RHNPOOLID=$3

# subscribe
subscription-manager register --username=$RHNUSERNAME --password=$RHNPASSWORD
subscription-manager attach --pool=$RHNPOOLID

# install zip & unzip package
yum install -y zip unzip

echo "master.sh finished."
exit 0

subscription-manager repos --disable="*"
subscription-manager repos \
    --enable="rhel-7-server-rpms" \
    --enable="rhel-7-server-extras-rpms" \
    --enable="rhel-7-server-ose-3.6-rpms" \
    --enable="rhel-7-fast-datapath-rpms"

yum -y update --exclude=WALinuxAgent
yum -y install zip unzip
yum -y install wget git net-tools bind-utils iptables-services bridge-utils bash-completion kexec-tools sos psacct httpd-tools
yum -y install atomic-openshift-utils
yum -y install atomic-openshift-excluder atomic-openshift-docker-excluder
atomic-openshift-excluder unexclude

yum -y install docker

#mkdir -p /etc/origin/master
#htpasswd -cb /etc/origin/master/htpasswd.dist ${USERNAME} ${PASSWORD}

sed -i -e "s#^OPTIONS='--selinux-enabled'#OPTIONS='--selinux-enabled --insecure-registry 172.30.0.0/16'#" /etc/sysconfig/docker
                                                                                         
cat <<EOF > /etc/sysconfig/docker-storage-setup
DEVS=/dev/sdc
VG=docker-vg
EOF

docker-storage-setup  
systemctl enable docker-cleanup
systemctl enable docker

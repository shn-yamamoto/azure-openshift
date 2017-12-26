#!/bin/bash
echo "jumpbox.sh called."

USERNAME=$1
HOSTNAME=$2 #fqdn of masters (web console address)
NODECOUNT=$3
ROUTEREXTIP=$4 #ip address of infranodes (must to be public ip address if access from internet needed)
MASTERCOUNT=$5
INFRACOUNT=$6
RHNUSERNAME=$7
RHNPASSWORD=$8
RHNPOOLID=$9

NFS=`hostname -f`

touch /var/tmp/mylog
echo "$USERNAME"  >> /var/tmp/mylog
echo "$HOSTNAME"  >> /var/tmp/mylog
echo "$NODECOUNT"  >> /var/tmp/mylog
echo "$ROUTEREXTIP"  >> /var/tmp/mylog
echo "$MASTERCOUNT"  >> /var/tmp/mylog
echo "$INFRACOUNT"  >> /var/tmp/mylog
echo "$RHNUSERNAME"  >> /var/tmp/mylog
echo "$RHNPASSWORD"  >> /var/tmp/mylog
echo "$RHNPOOLID"  >> /var/tmp/mylog


echo "$RHNUSERNAME" > /home/${USERNAME}/rhn-username
echo "$RHNPASSWORD" > /home/${USERNAME}/rhn-password
echo "$RHNPOOLID" > /home/${USERNAME}/rhn-poolid

# ############################################################################
# Create host preparation scripts 
# ############################################################################
cat <<EOF > /home/${USERNAME}/pre-install.sh
#!/bin/sh -v
WORKDIR=\`dirname \$0\`

_RHNUSERNAME=\`cat \$WORKDIR/rhn-username\`
_RHNPASSWORD=\`cat \$WORKDIR/rhn-password\`
_RHNPOOLID=\`cat \$WORKDIR/rhn-poolid\`

# subscribe
#subscription-manager register --username=\$_RHNUSERNAME --password=\$_RHNPASSWORD
#subscription-manager attach --pool=\$_RHNPOOLID
subscription-manager repos --disable="*"
subscription-manager repos \
    --enable="rhel-7-server-rpms" \
    --enable="rhel-7-server-extras-rpms" \
    --enable="rhel-7-server-ose-3.6-rpms" \
    --enable="rhel-7-fast-datapath-rpms"

# install packages
yum -y update --exclude=WALinuxAgent
yum -y install wget git net-tools bind-utils iptables-services bridge-utils bash-completion kexec-tools sos psacct
yum -y update --exclude=WALinuxAgent
yum -y install atomic-openshift-utils

yum -y install docker
sed -i '/OPTIONS=.*/c\OPTIONS="--selinux-enabled --insecure-registry 172.30.0.0/16"' /etc/sysconfig/docker

yum -y install zip unzip

# docker setup
cat <<EOS > /etc/sysconfig/docker-storage-setup
DEVS=/dev/sdc
VG=docker-vg
EOS

docker-storage-setup
systemctl enable docker-cleanup
systemctl enable docker
EOF

subscription-manager register --username=$RHNUSERNAME --password=$RHNPASSWORD
subscription-manager attach --pool=$RHNPOOLID
yum install -y zip unzip


chmod 755 /home/${USERNAME}/pre-install.sh
/home/${USERNAME}/pre-install.sh


# ############################################################################
# Create Playbook for install packages in nodes.
# ############################################################################
(cd /home/${USERNAME}; zip pre-install.zip pre-install.sh rhn-*)
cat <<EOF > /home/${USERNAME}/pre-install.yaml
---
- hosts: nodes
  tasks:
    - name: change ifcfg-eth0 NM_CONTROLLED=yes
      lineinfile:
        dest: /etc/sysconfig/network-scripts/ifcfg-eth0
        state: present
        regexp: '^NM_CONTROLLED'
        line: NM_CONTROLLED=yes

    - name: Restart NetworkManager
      service:
        name: NetworkManager
        state: restarted

    - name: copy and unzip files
      unarchive:
        src: pre-install.zip
        dest: /tmp

    - name: prepare packages
      shell:  /tmp/pre-install.sh
EOF

# ############################################################################
# Create Inventory file for install OpenShift
# ############################################################################
cat <<EOF > /etc/ansible/hosts
[OSEv3:children]
masters
nodes
nfs

[OSEv3:vars]
debug_level=2
ansible_ssh_user=${USERNAME}
ansible_become=yes

openshift_disable_check=memory_availability,disk_availability,docker_storage

deployment_type=openshift-enterprise
openshift_master_identity_providers=[{'name': 'htpasswd_auth', 'login': 'true', 'challenge': 'true', 'kind': 'HTPasswdPasswordIdentityProvider', 'filename': '/etc/origin/master/htpasswd'}]

openshift_master_cluster_method=native
openshift_master_cluster_hostname=${HOSTNAME}
openshift_master_cluster_public_hostname=${HOSTNAME}
openshift_master_default_subdomain=${ROUTEREXTIP}.xip.io

os_sdn_network_plugin_name=redhat/openshift-ovs-multitenant


# metrics
openshift_hosted_metrics_deploy=true
openshift_hosted_metrics_storage_kind=nfs
#openshift_hosted_metrics_storage_host=master
openshift_hosted_metrics_storage_access_modes=['ReadWriteOnce']
openshift_hosted_metrics_storage_nfs_directory=/var/exports/pvs
openshift_hosted_metrics_storage_nfs_options='*(rw,root_squash)'
openshift_hosted_metrics_storage_volume_name=metrics
openshift_hosted_metrics_storage_volume_size=10Gi
openshift_metrics_cassandra_storage_type=pv

# logging
openshift_hosted_logging_deploy=true
openshift_hosted_logging_storage_kind=nfs
openshift_hosted_logging_storage_access_modes=['ReadWriteOnce']
#openshift_hosted_logging_storage_host=master
openshift_hosted_logging_storage_nfs_directory=/var/exports/pvs
openshift_hosted_logging_storage_nfs_options='*(rw,root_squash)'
openshift_hosted_logging_storage_volume_name=logging
openshift_hosted_logging_storage_volume_size=10Gi


# Service Broker API
openshift_enable_service_catalog=true

openshift_hosted_etcd_storage_kind=nfs
openshift_hosted_etcd_storage_nfs_options="*(rw,root_squash,sync,no_wdelay)"
openshift_hosted_etcd_storage_nfs_directory=/var/exports/pvs
openshift_hosted_etcd_storage_volume_name=etcd-vol2
openshift_hosted_etcd_storage_access_modes=["ReadWriteOnce"]
openshift_hosted_etcd_storage_volume_size=1G
openshift_hosted_etcd_storage_labels={'storage': 'etcd'}
openshift_template_service_broker_namespaces=['openshift','myproject']

[masters]
master[1:${MASTERCOUNT}] openshift_public_hostname=${HOSTNAME}

[etcd]
master[1:${MASTERCOUNT}]

[nodes]
master[1:${MASTERCOUNT}]
node[01:${NODECOUNT}] openshift_node_labels="{'region': 'primary', 'zone': 'default'}"
infranode[1:${INFRACOUNT}] openshift_node_labels="{'region': 'infra', 'zone': 'default'}"

[nfs]
master1
EOF

cat <<EOF > /home/${USERNAME}/openshift-install.sh
export ANSIBLE_HOST_KEY_CHECKING=False
ansible-playbook pre-install.yaml
ansible-playbook /usr/share/ansible/openshift-ansible/playbooks/byo/config.yml
for i in $(seq -s " " 1 ${MASTERCOUNT}); do ssh -q -t -o StrictHostKeyChecking=no master\$i sudo htpasswd -cb /etc/origin/master/htpasswd joe redhat; done;
EOF

chmod 755 /home/${USERNAME}/openshift-install.sh


# ############################################################################
# Prepare persistent volume
# ############################################################################
yum -y install nfs-utils

mkdir -p /var/export/pvs/pv{1..10}
chown -R nfsnobody:nfsnobody /var/export/pvs
chmod -R 700 /var/export/pvs

for volume in pv{1..10} ; do
  echo Creating export for volume $volume;
  echo "/var/export/pvs/${volume} *(rw,sync,root_squash)" >> /etc/exports;
done;
echo "/var/export/pvs *(rw,sync,root_squash)" >> /etc/exports;

systemctl enable rpcbind nfs-server
systemctl start rpcbind nfs-server nfs-lock nfs-idmap
systemctl stop firewalld
systemctl disable firewalld

setsebool -P virt_use_nfs=true;


cat <<EOF > /home/${USERNAME}/post-install.sh
#!/bin/sh -v
volsize=5Gi

for volume in pv{1..10} ; do
  cat << EOS > \$volume.yaml
{
"apiVersion": "v1",
"kind": "PersistentVolume",
"metadata": {
  "name": "\$volume"
},
"spec": 
  {"capacity":
    {
      "storage": "\$volsize"
    },
    "accessModes": [ "ReadWriteOnce" ],
    "nfs": {
      "path": "/var/export/pvs/\$volume",
      "server": "$NFS"
    },
    "persistentVolumeReclaimPolicy": "Recycle"
  }
}
EOS
  echo "Created def file for \$volume";
done;
for f in pv*.yaml; do
  oc create -f \$f;
done
EOF
chmod 755 /home/${USERNAME}/post-install.sh


cat <<EOF > /home/${USERNAME}/post-install.yaml
---
# ansible-playbook post-install.yaml -l master1
- hosts: masters
  tasks:
    - name: copy post-install.sh
      copy:
        src: post-install.sh
        dest: /tmp
        mode: 0755

    - name: execute post-install.sh
      shell: post-install.sh
      args:
        chdir: /tmp
EOF

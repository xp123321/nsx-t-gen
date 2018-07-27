#!/bin/bash

export ROOT_DIR=`pwd`

export TASKS_DIR=$(dirname $BASH_SOURCE)
export PIPELINE_DIR=$(cd $TASKS_DIR/../../ && pwd)
export FUNCTIONS_DIR=$(cd $PIPELINE_DIR/functions && pwd)
export PYTHON_LIB_DIR=$(cd $PIPELINE_DIR/python && pwd)
export SCRIPT_DIR=$(dirname $0)

source $FUNCTIONS_DIR/check_null_variables.sh
source $FUNCTIONS_DIR/delete_vm_using_govc.sh

# First wipe out all non-nsx vms deployed on the management plane or compute clusters
echo "Need to delete the non-NSX Vms that are running in the computer cluster or Management cluster, before proceeding wtih clean of NSX Mgmt Plane!!"
echo "Deleting the non NSX related vms"
destroy_vms_not_matching_nsx

export ESXI_HOSTS_FILE="$ROOT_DIR/esxi_hosts"

cp $FUNCTIONS_DIR/uninstall-nsx-vibs.yml $ROOT_DIR/
if [ "$NSX_T_VERSION" == "2.2" ]; then
  cp $FUNCTIONS_DIR/uninstall-nsx-t-v2.2-vibs.sh $ROOT_DIR/uninstall-nsx-t-vibs.sh
else # [ "$NSX_T_VERSION" == "2.1" ]; then
  cp $FUNCTIONS_DIR/uninstall-nsx-t-v2.1-vibs.sh $ROOT_DIR/uninstall-nsx-t-vibs.sh
fi

cat > $ROOT_DIR/ansible.cfg << EOF
[defaults]
host_key_checking = false
EOF

echo ""

# Make sure the NSX Mgr is up
set +e
timeout 15 bash -c "(echo > /dev/tcp/${NSX_T_MANAGER_IP}/22) >/dev/null 2>&1"
status=$?
set -e

if [ "$status" == "0" ]; then
  # Start wiping the NSX Configurations from NSX Mgr,
  # cleaning up the routers, switches, transport nodes and fabric nodes
  # Additionally create the esxi hosts file so we can do vib cleanup (in case things are sticking around)
  python $PYTHON_LIB_DIR/nsx_t_wipe.py $ESXI_HOSTS_FILE
  STATUS=$?

  if [ "$STATUS" != "0" ]; then
    echo "Problem in running cleanup of NSX components!!"
    echo "The deletion of the NSX VMs  up as well as removal of vibs from Esxi hosts needs to be done manually!!"
    exit $STATUS
  fi
  echo "The resources used within NSX Management plane have been cleaned up!!"
  echo ""
else
  echo "NSX Manager VM not responding!!"
  echo "Cannot delete any related resources within the NSX Management plane"
  echo ""
fi

echo "Going to delete the NSX vms in 30 seconds!!!!"
echo ""
echo "Cancel the task if you want to manually check and then delete the VMs"
echo "If cancelled, the deletion of the NSX VMs as well as removal of vibs from Esxi hosts needs to be done manually!!"
echo ""

echo "Manual NSX-T v${NSX_T_VERSION} Vib removal command on each Esxi Host:"
echo "-----------------------------------------"
cat $ROOT_DIR/uninstall-nsx-t-vibs.sh
echo "-----------------------------------------"
echo ""
if [ -e $ESXI_HOSTS_FILE ]; then
  echo "Related Esxi hosts:"
  cat $ESXI_HOSTS_FILE | grep ansible |  awk '{print $1}' | sed -e 's/://g'
  echo ""
fi

sleep 30

echo "Proceeding with NSX-T Management Plane VM deletion!"
echo ""
delete_vm_using_govc "edge"
delete_vm_using_govc "ctrl"
delete_vm_using_govc "mgr"
echo "Finished NSX-T Management Plane VM deletion!"
echo ""

STATUS=0
if [ -e "$ESXI_HOSTS_FILE" ]; then
  sleep 5
  echo "Now removing the NSX-T related vibs from the Esxi Hosts"
  ansible-playbook -i $ESXI_HOSTS_FILE $ROOT_DIR/uninstall-nsx-vibs.yml
  STATUS=$?

  echo "NSX-T Vibs removed from the Esxi hosts"
  echo ""

  # esxi_hosts file looks like:
  # esxi_hosts:
  #   hosts:
  #     sc2-host-corp.local.io: { ansible_ssh_host: sc2-host-corp.local.io, ansible_ssh_user: root, ansible_ssh_pass: asdfn3! }

  echo "Related Esxi Hosts:"
  echo "--------------------------------------"
  cat $ESXI_HOSTS_FILE | grep ansible |  awk '{print $1}' | sed -e 's/://g'
  echo "--------------------------------------"
fi

echo ""
echo "WARNING!! The Esxi hosts should be rebooted for nsx-t vib removal to be effective!"
echo "Please reboot all the listed Esxi Hosts in a rolling fashion to pick the changes!!"
echo ""
echo "NSX-T ${NSX_T_VERSION} Uninstall Completed!!"

exit $STATUS

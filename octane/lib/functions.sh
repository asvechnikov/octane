#!/bin/bash

NODE_ID=0
FUEL_CACHE="/tmp/octane/deployment"

clone_env() {
# Clone settings of the environment specified by ID in the first argument using
# helper Python script `clone-env'
    local env_name
    [ -z $1 ] && die "Cannot clone environment with empty ID, exiting"
    env_name=$(fuel env --env $1 \
        | awk -F\| '$2~/(new|operational)/ {print $3}' \
        | sed -re "s%^[ ]+(.*)[ ]+$%\1%")
    [ -n "$env_name" ] || die "No environment found with ID $1, exiting"
    [ -d "./$env_name" ] && rm -r "./$env_name"
    echo $(./clone-env --upgrade "$env_name")
}

get_ips_from_cics() {
# Return a list of addresses assigned to the bridge identified by its name in
# the first argument on nodes in the original environment.
    [ -z "$1" ] && die "No environment ID and bridge name, exiting"
    [ -z "$2" ] && die "No bridge name, exiting"
    echo $(fuel nodes --env $1 \
        | grep controller \
        | cut -d\| -f5  \
        | xargs -I{} ssh root@{} ip addr\
        | awk '/'$2':/ {getline; getline; print $2}' \
        | sed -re 's%([^/]+)/[0-9]{2}%\1%' | sort)
}

get_vip_from_cics() {
# Return VIP of the given type (management or external) assgined to the original
# environment.
    local br_name
    [ -z "$1" ] && die "No environment ID and bridge name provided, exiting"
    [ -z "$2" ] && die "No bridge name provided, exiting"
    br_name=$(echo $2 \
        | awk '/br-ex/ {print "hapr-p"} \
        /br-mgmt/ {print "hapr-m"}')
    [ -n "$1" ] && echo $(fuel nodes --env-id $1 \
            | grep controller \
            | cut -d\| -f5  \
            | xargs -I{} ssh root@{} ip netns exec haproxy ip addr\
            | awk '/'$br_name':/ {getline; getline; print $2}' \
            | sed -re 's%([^/]+)/[0-9]{2}%\1%')
}

get_deployment_info() {
    local cmd
# Download deployment config from Fuel master for environment ENV to subdir in
# current directory.
    [ -z "$1" ] && die "No environment ID provided, exiting"
    [ -d "$FUEL_CACHE" ] || mkdir -p "$FUEL_CACHE"
    [ -d "${FUEL_CACHE}/deployment_$1" ] && rm -r ${FUEL_CACHE}/deployment_$1
    cmd=${2:-default}
    fuel --env $1 deployment --$cmd --dir ${FUEL_CACHE}
}

get_ips_from_deploy_info() {
# Returns a list of addresses that Fuel wants to assign to nodes in the 6.0
# deployment. These addresses must be replaced with addresses from the original
# environment.
    local filename
    local primary_cic
    [ -z "$1" ] && die "No environment ID and bridge name provided, exiting"
    [ -z "$2" ] && die "No bridge name provided, exiting"
    primary_cic=$(basename ${FUEL_CACHE}/deployment_$1/primary-controller_*.yaml)
    filename=${3:-$primary_cic}
    echo $(python ./extract-cic-ips ${FUEL_CACHE}/deployment_$1/$filename $2)
}

get_vip_from_deploy_info() {
# Returns a VIP of given type that Fuel wants to assign to the 6.0 environment
# and that we want to replace with original VIP.
    local br_name
    local filename
    local primary_cic
    [ -z "$1" ] && die "No environment ID and bridge name provided, exiting"
    br_name=$(echo ${2:-br-mgmt} \
        | awk '/br-ex/ {print "public_vip:"} \
        /br-mgmt/ {print "management_vip:"}')
    [ -z "$br_name" ] && die "No bridge name provided, exiting"
    primary_cic=$(basename ${FUEL_CACHE}/deployment_$1/primary-controller_*.yaml)
    filename=${3:-$primary_cic}
    [ -z "$filename" ] && filename=$(ls ${FUEL_CACHE}/deployment_$1 | head -1)
    [ -n "$br_name" ] && echo $(grep $br_name ${FUEL_CACHE}/deployment_$1/$filename \
        | awk '{print $2}')
}

get_primary_ip() {
    local filename
    local primary_id
    [ -z "$1" ] && die "No environment ID and bridge name provided, exiting"
    [ -z "$2" ] && die "No bridge name provided, exiting"
    filename=$(basename ${FUEL_CACHE}/deployment_$1/primary-controller_*.yaml)
    echo $(python ./extract-primary-ip "${FUEL_CACHE}/deployment_$1/$filename" $2)
}

upload_deployment_info() {
# Upload deployment configration with modifications to Fuel master for
# environment ENV.
    [ -z "$1" ] && die "No environment ID provided, exiting"
    [ -d "$FUEL_CACHE" ] &&
    fuel --env $1 deployment --upload --dir $FUEL_CACHE
}

replace_ip_addresses() {
# Replace IP addresses assigned to new env's controllers and VIPs with addresses
# of the original environment in deployment config dump.
    local dirname
    local orig_ip
    local seed_ip
    local tmpfile
    [ -z "$1" ] && die "No orig, seed env IDs, bridge name and IP addresses provided, exiting"
    [ -z "$2" ] && die "No seed env ID, bridge name and IP addresses provided, exiting"
    [ -z "$3" ] && die "No bridge name and IP addresses provided, exiting"
    dirname="${FUEL_CACHE}/deployment_$2"
    tmpfile="/tmp/env-$1-cic-$3-ips"
    shift 3
    for orig_ip in $(cat "$tmpfile")
        do
            if [ -n "$*" ]
                then
                    seed_ip=$1
                    sed -i 's%'$seed_ip'$%'$orig_ip'%' $dirname/*.yaml
                    sed -i 's%- '$seed_ip'/%- '$orig_ip'/%' $dirname/*.yaml
                    shift
                fi
        done
}

replace_vip_address() {
    local orig_vip
    local seed_vip
    local dirname
    local br_name
    dirname="${FUEL_CACHE}/deployment_$2"
    br_name=$3
    orig_vip=$(get_vip_from_cics $1 $br_name)
    [ -z "$orig_vip" ] && die "Cannot find VIP on $br_name in 5.1 env, exiting"
    seed_vip=$(get_vip_from_deploy_info $2 $br_name $4)
    [ -z "$seed_vip" ] && die "Cannot find VIP for $br_name in 6.0 env, exiting"
    sed -i 's%'$seed_vip'$%'$orig_vip'%' $dirname/*.yaml
}

replace_seed_ips() {
    local br_name
    local discard_ips
    local primary_ip
    [ -z "$1" ] && die "No orig and seed env IDs provided, exiting"
    [ -z "$2" ] && die "No seed env ID provided, exiting"
    for br_name in br-ex br-mgmt
        do
            get_ips_from_cics $1 $br_name > "/tmp/env-$1-cic-$br_name-ips"
            discard_ips=$(get_ips_from_deploy_info $2 $br_name)
            replace_ip_addresses $1 $2 $br_name $discard_ips
            replace_vip_address $1 $2 $br_name
        done
}

backup_deployment_info() {
    [ -z "$1" ] && die "No env ID provided, exiting"
    [ -d "${FUEL_CACHE}/deployment_$1" ] && {
        [ -d "${FUEL_CACHE}/deployment_$1.orig" ] || mkdir "${FUEL_CACHE}/deployment_$1.orig"
        cp -R ${FUEL_CACHE}/deployment_$1/*.yaml ${FUEL_CACHE}/deployment_$1.orig/
    }
}

remove_patch_transformations() {
# Remove add-patch actions for br-ex, br-mgmt bridges. Required to isolate new
# controllers from original environment while physically connected to the same
# L2 segment.
    [ -z "$1" ] && die "No env ID provided, exiting"
    python ../helpers/transformations.py ${FUEL_CACHE}/deployment_$1 remove_patch_ports
}

disable_ping_checker() {
    [ -z "$1" ] && die "No env ID provided, exiting"
    [ -d "${FUEL_CACHE}/deployment_$1" ] || die "Deployment info directory not found, exiting"
    ls ${FUEL_CACHE}/deployment_$1/** | xargs -I@ sh -c "echo 'run_ping_checker: \"false\"' >> @"
}

prepare_seed_deployment_info() {
    [ -z "$1" ] && "No orig and seed env ID provided, exiting"
    [ -z "$2" ] && "No seed env ID provided, exiting"
    get_deployment_info $2
    backup_deployment_info $2
    replace_seed_ips $1 $2
    disable_ping_checker $2
    remove_patch_transformations $2
    remove_predefined_networks $2
    upload_deployment_info $2
}

prepare_seed_deployment_info_nailgun() {
    [ -z "$1" ] && "No orig and seed env ID provided, exiting"
    [ -z "$2" ] && "No seed env ID provided, exiting"
    get_deployment_info $2
    for br_name in br-ex br-mgmt
        do
            update_ips_nailgun_db $1 $2 $br_name
            update_vip_nailgun_db $1 $2 $br_name
        done
    get_deployment_info $2
    backup_deployment_info $2
    disable_ping_checker $2
    remove_patch_transformations $2
    remove_predefined_networks $2
    upload_deployment_info $2
}

remove_predefined_networks() {
    [ -z "$1" ] && die "No env ID provided, exiting"
    python ../helpers/transformations.py ${FUEL_CACHE}/deployment_$1 remove_predefined_nets
}

prepare_cic_disk_fixture() {
    local node_id
    [ -z "$1" ] && die "No env ID provided, exiting"
    node_id=$(fuel node --env $1 | awk '/'${2:-controller}'/{print($1)}' | head -1)
    fuel node --node $node_id --disk --download --dir $FUEL_CACHE
    [ -f "${FUEL_CACHE}/node_$node_id/disks.yaml" ] &&
    cp ${FUEL_CACHE}/node_$node_id/disks.yaml ./disks.fixture.yaml
}

prepare_cic_network_fixture() {
    local node_id
    [ -z "$1" ] && die "No env ID provided, exiting"
    node_id=$(fuel node --env $1 | awk '/'${2:-controller}'/{print($1)}' | head -1)
    fuel node --node $node_id --network --download --dir $FUEL_CACHE
    [ -f "${FUEL_CACHE}/node_$node_id/interfaces.yaml" ] &&
    cp ${FUEL_CACHE}/node_$node_id/interfaces.yaml ./interfaces.fixture.yaml
}

list_nodes() {
    local roles_re
    [ -z "$1" ] && die "No env ID provided, exiting"
    roles_re=${2:-controller}
    echo "$(fuel node --env $1 \
        | awk -F\| '($7 ~ /'$roles_re'/ || $8 ~ /'$roles_re'/) && $2 ~ /'$3'/ {
                gsub(" ","",$1); print "node-" $1
            }')"
}

create_ovs_bridges() {
    local nodes
    local node
    local br_name
    [ -z "$1" ] && die "No env ID provided, exiting"
    nodes=$(list_nodes $1 '(controller)')
    for node in $nodes
        do
            ssh root@$node apt-get -y install openvswitch-switch
            [ $? -ne 0 ] && die "Cannot install openvswitch, exiting"
            for br_name in br-ex br-mgmt
                do
                    ssh root@$node ovs-vsctl add-br $br_name
                    ssh root@$node ip link set dev $br_name mtu 1450
                done
        done
}

tunnel_from_to() {
# Configure GRE tunnels between 2 nodes. Nodes are specified by their hostnames
# (e.g. node-2). Every tunnel must have unique key to avoid conflicting
# configurations.
    local src_node
    local dst_node
    local br_name
    local remote_ip
    local gre_port
    local key
    [ -z "$1" ] && die "No tunnel paramters provided, exiting"
    src_node=$1
    [ -z "$2" ] && die "No tunnel remote parameters provided, exiting"
    dst_node=$2
    [ -z "$3" ] && die "No bridge name provided, exiting"
    br_name=$3
    key=${4:-0}
    remote_ip=$(host $dst_node | grep -Eo '([0-9\.]+)$')
    [ -z "$remote_ip" ] && die "Tunnel remote host $dst_node not found, exiting"
    gre_port=$br_name--gre-$dst_node
    ssh root@$src_node ovs-vsctl add-port $br_name $gre_port -- \
        set Interface $gre_port type=gre options:remote_ip=$remote_ip \
        options:key=$key
}

create_tunnels() {
# Create tunnels between nodes in the new environment to ensure isolation from
# management and public network of original environment and retain connectivity
# in the 6.0 environment.
    local br_name
    local primary
    local nodes
    local node
    [ -z "$1" ] && die "No env ID provided, exiting"
    br_name=$2
    roles_re=${3:-'controller'}
    nodes=$(list_nodes $1 "$roles_re")
    primary=$(echo $nodes | cut -d ' ' -f1)
    for node in $nodes
        do
            [ "$node" == "$primary" ] || {
                tunnel_from_to $primary $node $br_name $KEY
                tunnel_from_to $node $primary $br_name $KEY
                KEY=$(expr $KEY + 1)
            }
        done
}

get_nailgun_db_pass() {
# Parse nailgun configuration to get DB password for 'nailgun' database. Return
# the password.
    echo $(dockerctl shell nailgun cat /etc/nailgun/settings.yaml \
        | awk 'BEGIN {out=""}
               /DATABASE/ {out=$0;next}
               /passwd:/ {if(out!=""){out="";print $2}}' \
        | tr -d '"')
}

postgres_cmd="psql -At postgresql://nailgun:$(get_nailgun_db_pass)@localhost/nailgun"

copy_generated_settings() {
# Update configuration of 6.0 environment in Nailgun DB to preserve generated
# parameters values from the original environmen.
    local db_pass
    local generated
    db_pass=$(get_nailgun_db_pass)
    [ -z "$1" ] && die "No 5.1 env ID provided, exiting"
    [ -z "$2" ] && die "No 6.0 env ID provided, exiting"
    generated=$(echo "select generated from attributes where cluster_id = $2;
select generated from attributes where cluster_id = $1;" \
        | psql -t postgresql://nailgun:$db_pass@localhost/nailgun \
        | grep -v ^$ \
        | python ../helpers/join-jsons.py);
    [ -z "$generated" ] && die "No generated attributes found for env $1"
    echo "update attributes set generated = '$generated' where cluster_id = $2" \
        | psql -t postgresql://nailgun:$db_pass@localhost/nailgun
}

env_action() {
# Start deployment or provisioning of all nodes in the environment, depending on
# second argument. First argument is an ID of env.
    local node_ids
    local mode
    [ -z "$1" ] && die "No 6.0 env ID provided, exiting"
    node_ids=$(fuel node --env $1 \
        | awk 'BEGIN {f = ""}
        /(controller|compute|ceph)/ {
            if (f == "") {f = $1}
            else {printf f","; f = $1}
        }
        END {printf f}')
    fuel node --env $1 --$2 --node $node_ids
    [ $? -ne 0 ] && die "Cannot start $2 for env $1, exiting" 2
}

check_deployment_status() {
# Verify operational status of environment.
    local status
    [ -z "$1" ] && die "No env ID provided, exiting"
    status=$(fuel env --env $1 \
        | awk -F"|" '/^'$1'/{print $2}' \
        | tr -d ' ')
    [ "$status" == 'new' ] || die "Environment is not operational, exiting"
}

discover_nodes_to_cics() {
    local node_ids
    [ -z "$1" ] && die "No env ID provided, exiting"
    node_ids=$(fuel node | awk -F\| '$2~/discover/{print($1)}' \
        | tr -d ' ' | sed ':a;N;$!ba;s/\n/,/g')
    fuel node set --env $1 --node $node_ids --role controller
}

check_vip_down() {
    local vip
    [ -z "$1" ] && die "No env ID and bridge name provided, exiting"
    [ -z "$2" ] && die "No bridge name provided, exiting"
    vip=$(get_vip_from_cics $1 $2)
    [ -n "$vip" ] && die "VIP is not down, exiting" 3
}

vips_down() {
    local nodes
    local node
    [ -z "$1" ] && die "No env ID and bridge name provided, exiting"
    nodes=$(list_nodes $1 'controller')
    for node in $nodes
        do
            echo vip__management vip__public vip__management_old vip__public_old \
                | xargs -I{} -d ' ' \
                ssh root@$node crm resource stop {}
        done
}

delete_tunnel() {
# Delete tunnel between src_node and dst_node.
    local src_node
    local dst_node
    local br_name
    local gre_port
    [ -z "$1" ] && die "No tunnel parameters provided, exiting"
    src_node=$1
    [ -z "$2" ] && die "Bridge name not specified"
    br_name=$2
    for gre_port in $(list_ports $src_node $br_name | grep $br_name--gre)
        do
            echo $gre_port \
                | xargs -I{} ssh root@$src_node ovs-vsctl del-port $br_name {}
            [ $? -ne 0 ] && die "Cannot delete GRE port, exiting"
        done
}

remove_tunnels() {
# Delete tunnels from 6.0 CICs to replace 5.1 controllers.
    local br_name
    local nodes
    local node
    [ -z "$1" ] && die "No env ID provided, exiting"
    br_name=$2
    nodes=$(list_nodes $1 'controller')
    for node in $nodes
        do
            delete_tunnel $node $br_name
        done
}

list_ports() {
# On the host identified by first argument, list ports in bridge, identified by
# second argument.
    [ -z "$1" ] && die "No hostname and bridge name provided, exiting"
    [ -z "$2" ] && die "No bridge name provided, exiting"
    echo -n "$(ssh root@$1 ovs-vsctl list-ports $2)"
}

create_patch_ports() {
# Create patch interface to connect logical interface to Public or Management
# network to the physical interface to that network.
    local br_name
    local ph_name
    local nodes
    local node
    local node_id
    local filename
    [ -d ${FUEL_CACHE}/deployment_$1.orig ] || die "Deployment information not found for env $1, exiting"
    [ -z "$1" ] && die "No env ID provided, exiting"
    br_name=$2
    nodes=$(list_nodes $1 'controller')
    for node in $nodes
        do
            node_id=$(echo $node | awk -F"-" '{print $2}')
            filename=$(ls ${FUEL_CACHE}/deployment_$1.orig/*_$node_id.yaml | head -1)
            ./create-patch-ports $filename $br_name \
                | xargs -I {} ssh root@$node {}
        done
}

delete_patch_ports() {
    local br_name
    local ph_name
    local node_ids
    local node_id
    local node
    [ -z "$1" ] && die "No env ID and bridge name provided, exiting"
    [ -z "$2" ] && die "No bridge name provided, exiting"
    br_name=$2
    for node in $(list_nodes $1 controller)
        do
            ph_name=$(list_ports $node $br_name \
                | tr -d '"' \
                | sed -nre 's/'$br_name'--(.*)/\1/p')

            ssh root@${node} ovs-vsctl del-port $br_name ${br_name}--${ph_name}
            ssh root@${node} ovs-vsctl del-port $ph_name ${ph_name}--${br_name}
        done
}

apply_disk_settings() {
    local disk_file
    [ -z "$1" ] && die "No node ID provided, exiting"
    [ -f "disks.fixture.yaml" ] || die "No disks fixture provided, exiting"
    disk_file="${FUEL_CACHE}/node_$1/disks.yaml"
    fuel node --node $1 --disk --download --dir $FUEL_CACHE
    ./copy-node-settings disks $disk_file ./disks.fixture.yaml by_name \
        > /tmp/disks_$1.yaml
    mv /tmp/disks_$1.yaml $disk_file
    fuel node --node $1 --disk --upload --dir $FUEL_CACHE
}

apply_network_settings() {
    local iface_file
    [ -z "$1" ] && die "No node ID provided, exiting"
    [ -f "interfaces.fixture.yaml" ] || die "No interfaces fixture provided, exiting"
    iface_file="${FUEL_CACHE}/node_$1/interfaces.yaml"
    fuel node --node $1 --network --download --dir $FUEL_CACHE
    ./copy-node-settings interfaces $iface_file \
        ./interfaces.fixture.yaml > /tmp/interfaces_$1.yaml
    mv /tmp/interfaces_$1.yaml $iface_file
    fuel node --node $1 --network --upload --dir $FUEL_CACHE
}

get_node_settings() {
    [ -z "$1" ] && die "No node ID provided, exiting"
    [ -d "$FUEL_NODE" ] || mkdir -p "$FUEL_CACHE"
    fuel node --node $1 --network --download --dir $FUEL_CACHE
    fuel node --node $1 --disk --download --dir $FUEL_CACHE
}

prepare_fixtures_from_node() {
    [ -z "$1" ] && die "No node ID provided, exiting"
    get_node_settings $1
    mv ${FUEL_CACHE}/node_$1/disks.yaml ./disks.fixture.yaml
    mv ${FUEL_CACHE}/node_$1/interfaces.yaml ./interfaces.fixture.yaml
    rmdir ${FUEL_CACHE}/node_$1
}

upload_node_settings() {
    [ -z "$1" ] && die "No node ID provided, exiting"
    [ -d "${FUEL_CACHE}/node_$1" ] || die "Local node settings not found, exiting"
    fuel node --node $1 --network --upload --dir $FUEL_CACHE
    fuel node --node $1 --disk --upload --dir $FUEL_CACHE
}

get_bootable_mac() {
    local port1
    local port2
    local port3
    [ -z "$1" ] && die "No node ID provided, exiting"
    port1=$(ssh "root@node-$1" "ovs-vsctl list-ifaces br-fw-admin")
    port2=$(ssh "root@node-$1" "ovs-vsctl list interface $port1" |
            awk -F\" '/^options/ { print $2; }')
    port3=$(ssh "root@node-$1" "ovs-vsctl list-ifaces \$(ovs-vsctl port-to-br $port2)" | grep -v $port2)
    ssh "root@node-$1" "ip link show $port3" | awk '/link\/ether/{print $2}'
}

assign_node_to_env(){
    local orig_id
    local roles
    local host
    local node_mac
    local id
    local node_values
    local node_online
    [ -z "$1" ] && die "No node ID provided, exiting"
    [ -z "$2" ] && die "No seed env ID provided, exiting"
    roles=$(fuel node --node $1 \
        | awk -F\| '/^'$1'/ {gsub(" ", "", $7);print $7}')
    orig_id=$(get_env_by_node $1)
    host=$(get_host_ip_by_node_id $1)
    if [ "$orig_id" != "None" ]
        then
            node_values=$(echo "SELECT uuid, name
                                FROM nodes WHERE id = $1;" | \
                          $postgres_cmd | \
                          sed -e "s/^/'/g" -e "s/$/'/g" -e "s/|/', '/g"
                          )
            node_mac=$(get_bootable_mac "$1")
            prepare_fixtures_from_node "$1"
            fuel node --node $1 --env $orig_id --delete-from-db
            dockerctl shell cobbler cobbler system remove --name node-$1
            echo "INSERT INTO nodes (id, uuid, name, mac, status, meta,
                                     timestamp, online, pending_addition,
                                     pending_deletion)
                  VALUES ($1, $node_values, '$node_mac', 'discover',
                          '{\"disks\": [], \"interfaces\": []}', now(), false,
                          false, false);" | $postgres_cmd
            ssh root@node-$1 shutdown -r now
            while :
                do
                    node_online=$(get_node_online $1)
                    [ "$node_online" == "True" ] && {
                        echo "Node $id came back online."
                        break
                    }
                    sleep 30
                done
        fi
    fuel node --node $1 --env $2 set --role ${roles:-compute,ceph-osd}
    apply_network_settings $1
    apply_disk_settings $1
    ./keep-ceph-partition ${FUEL_CACHE}/node_$1/disks.yaml > /tmp/disks-ceph-partition.yaml
    mv /tmp/disks-ceph-partition.yaml ${FUEL_CACHE}/node_$1/disks.yaml
    upload_node_settings $1
}

nodes_disks_equal() {
    set -e
    [ -z "$2" ] && die "IDs of 2 nodes required but not provided, exiting"
    [ -f "${FUEL_CACHE}/node_$1/disks.yaml" ]
    [ -f "${FUEL_CACHE}/node_$2/disks.yaml" ]
    python -c "import yaml; import sys;
disks1 = yaml.load(open('"$FUEL_CACHE"/node_$1/disks.yaml'));
disks2 = yaml.load(open('"$FUEL_CACHE"/node_$2/disks.yaml'));
for disk in disks1:
    if disk['extra'] in [d['extra'] for d in disks2]:
        continue;
    else:
        sys.exit(1)"
    return $?
}

set_osd_noout() {
    [ -z "$1" ] && die "No 6.0 env ID provided, exiting"
    ssh root@$(list_nodes $1 'controller' | head -1) ceph osd set noout
}

unset_osd_noout() {
    [ -z "$1" ] && die "No 6.0 env ID provided, exiting"
    ssh root@$(list_nodes $1 'controller' | head -1) ceph osd unset noout
}

check_ceph_cluster() {
    [ -z "$1" ] && die "No node ID provided, exiting"
    [ -z "$(ssh root@node-$1 ceph health | grep HEALTH_OK)" ] && \
        die "Ceph cluster is unhealthy, exiting"
}

patch_osd_node() {
    [ -z "$1" ] && die "No node ID provided, exiting"
    cd ../patches/pman/
    ./update_node.sh node-$1
    cd $OLDPWD
}

prepare_osd_node_upgrade() {
    [ -z "$1" ] && die "No node ID provided, exiting"
    check_ceph_cluster "$@"
    patch_osd_node "$@"
}

prepare_compute_upgrade() {
    [ -z "$1" ] && die "No 6.0 env ID provided, exiting"
    [ -z "$2" ] && die "No node ID provided, exiting"
    cic=$(list_nodes $1 controller | head -1)
    scp ./host_evacuation.sh root@$cic:/var/tmp/
    ssh root@$cic "/var/tmp/host_evacuation.sh node-$2"
}

cleanup_compute_upgrade() {
    [ -z "$1" ] && die "No 6.0 env ID provided, exiting"
    [ -z "$2" ] && die "No node ID provided, exiting"
    cic=$(list_nodes $1 controller | head -1)
    ssh root@$cic "source openrc; nova service-enable node-$2 nova-compute"
}

upgrade_node() {
    local roles
    local role
    local id
    local filename
    local discard_ips
    [ -z "$1" ] && die "No 6.0 env and node ID provided, exiting"
    [ -z "$2" ] && die "No node ID provided, exiting"
    roles=$(fuel node --node $2 \
        | awk -F\| '/^'$2'/ {gsub(" ", "", $7);print $7}' \
        | sed -re 's%,% %')
    for role in $roles
        do
            case $role in 
                compute)
                    prepare_compute_upgrade "$@"
                    ;;
                ceph-osd)
                    prepare_osd_node_upgrade $2
                    set_osd_noout $1
                    ;;
                *)
                    echo "Role $role unsupported, skipping"
                    ;;
             esac
         done
    assign_node_to_env $2 $1
    fuel node --env $1 --node $2 --provision
    wait_for_node $2 "provisioned"
    get_deployment_info $1 download
    rmdir ${FUEL_CACHE}/deployment_$1.download
    mv ${FUEL_CACHE}/deployment_$1 ${FUEL_CACHE}/deployment_$1.download
    get_deployment_info $1
    mv ${FUEL_CACHE}/deployment_$1.download/* ${FUEL_CACHE}/deployment_$1/
    for br_name in br-ex br-mgmt
        do
            get_ips_from_cics $1 $br_name > "/tmp/env-$1-cic-$br_name-ips"
            filename=$(echo $roles | cut -d ' ' -f 1)_$2.yaml
            discard_ips=$(get_ips_from_deploy_info $1 $br_name $filename)
            replace_ip_addresses $1 $1 $br_name $discard_ips
            replace_vip_address $1 $1 $br_name $filename
        done
    remove_predefined_networks $1
    upload_deployment_info $1
    fuel node --env $1 --node $2 --deploy
    wait_for_node $2 "ready"
    for role in $roles
        do
            case $role in
                compute)
                    cleanup_compute_upgrade "$@"
                    ;;
                ceph-osd)
                    unset_osd_noout $1
                    ;;
            esac
        done
}

wait_for_node() {
    local counter
    local status
    [ -z "$1" ] && die "No node ID provided, exiting"
    [ -z "$2" ] && die "No expected status provided, exiting"
    counter=0
    while :
        do
            [ $counter -gt 30 ] && die "Wait for node-$1 $2 timed out, exiting"
            status=$(fuel node --node $1 \
                | awk -F\| '/^'$1'/ {gsub(" ", "", $2);print $2}')
            [ "$status" == "$2" ] && break
            counter=$(expr $counter + 1)
            sleep 300
        done
}

import_bootstrap_osd() {
    local node
    [ -z "$1" ] && die "No env ID provided, exiting"
    node=$(list_nodes $1 controller | head -1)
    ssh root@$node ceph auth import -i /root/ceph.bootstrap-osd.keyring
    ssh root@$node ceph auth caps client.bootstrap-osd mon 'allow profile bootstrap-osd'
}

check_env_nodes() {
    local node
    [ -z "$1" ] && die "No env ID provided, exiting"
    for node in  $(list_nodes $1 "(controller|compute|ceph-osd)")
        do
            ping -c1 $node || die "Node $node inaccessible, exiting"
        done
}

provision_node() {
    local env_id
    [ -z "$1" ] && die "No node ID provided, exiting"
    env_id=$(get_env_by_node $1)
    [ -f "./interfaces.fixture.yaml" ] && apply_network_settings $1
    [ -f "./disks.fixture.yaml" ] && apply_disk_settings $1
    fuel node --env $env_id --node $1 --provision
}


get_node_group_id() {
    [ -z "$1" ] && die "No env ID provided, exiting"
    echo "select id from nodegroups where cluster_id = $1" \
        | $postgres_cmd
}

get_nailgun_net_id() {
    local vip_type
    local net_id
    local group_id
    [ -z "$1" ] && die "No group ID provided, exiting"
    [ -z "$2" ] && die "No bridge name provided, exiting"
    group_id=$(get_node_group_id $1) 
    vip_type=$(echo $2 | sed -e 's/br-ex/public/;s/br-mgmt/management/')
    net_id=$(echo "select id from network_groups where group_id = ${group_id} and
        name = '$vip_type';" | $postgres_cmd)
    echo $net_id
}

update_vip_nailgun_db() {
# Replace Virtual IP addresses assgined to 6.0 Seed environment in Nailgun DB
# with addresses from 5.1 environment
    local vip
    local seed_net_id
    local orig_net_id
    [ -z "$1" ] && die "No 5.1 and 6.0 env IDs provided, exiting"
    [ -z "$2" ] && die "No 6.0 env ID provided, exiting"
    [ -z "$3" ] && die "No bridge provided, exiting"
    orig_net_id=$(get_nailgun_net_id $1 $3)

    seed_net_id=$(get_nailgun_net_id $2 $3)
    vip=$(echo "select ip_addr from ip_addrs where network = $orig_net_id and
        node is null;" | $postgres_cmd)
    echo "update ip_addrs set ip_addr = '$vip' where network = $seed_net_id and
        node is null;" | $postgres_cmd
}

update_ips_nailgun_db() {
    local orig_net_id
    local seed_net_id
    local tmpfile
    local node
    [ -z "$1" ] && die "No 5.1 and 6.0 env IDs provided, exiting"
    [ -z "$2" ] && die "No 6.0 env ID provided, exiting"
    [ -z "$3" ] && die "No bridge provided, exiting"
    orig_net_id=$(get_nailgun_net_id $1 $3)
    seed_net_id=$(get_nailgun_net_id $2 $3)
    tmpfile="/tmp/env-$1-cics-$3-ips"
    list_nodes $1 controller | sed -re "s,node-(.*),\1," | sort > $tmpfile
    for node in $(list_nodes $2 controller | sed -re "s,node-(.*),\1," | sort)
        do
            orig_node=$(sed -i -e '1 w /dev/stdout' -e '1d' "$tmpfile")
            echo "DROP TABLE IF EXISTS ip_$$;
		SELECT ip_addr INTO ip_$$ FROM ip_addrs WHERE node = $orig_node AND network = $orig_net_id;
                DELETE FROM ip_addrs WHERE node = $node AND network = $seed_net_id;
                INSERT INTO ip_addrs VALUES(DEFAULT, $seed_net_id, $node, (SELECT ip_addr FROM ip_$$));
            " | $postgres_cmd
        done
}

upgrade_db() {
    [ -z "$1" ] && die "No 5.1 and 6.0 env IDs provided, exiting"
    [ -z "$2" ] && die "No 6.0 env ID provided, exiting"
    ./delete_fuel_resources.sh $2
    sleep 7
    ./manage_services.sh stop $2
    ./manage_services.sh disable $1
    ./upgrade-db.sh "$@"
}

init_seed() {
    local filename
    [ -z "$1" ] && die "No 6.0 env IDs provided, exiting"
    fuel node set --env $1 --node $2 --role controller
    ENV=$1 && shift
    filename="/tmp/env-$ENV-cics.hosts"
    [ -f "$filename" ] && die "Seed env $ENV already initialized, exiting"
    while [ -n "$*" ]
        do
            echo "$1" >> $filename
            shift
        done
}

install_primary_cic() {
    local hosts
    local node_id
    [ -z "$1" ] && die "No 5.1 and 6.0 env IDs provided, exiting"
    [ -z "$2" ] && die "No 6.0 env ID provided, exiting"
    hosts="/tmp/env-$2-cics.hosts"
    [ -f "$hosts" ] || die "Seed env $2 not initialized and $hosts file not found, exiting"
    node_id=$(head -1 "$hosts")
    [ -z "$node_id" ] && die "No primary CIC ID in $hosts file, exiting"
    provision_node $node_id
    wait_for_node $node_id "provisioned"
    prepare_seed_deployment_info $1 $2
    create_ovs_bridges $2
    fuel node --env $2 --node $node_id --deploy
    wait_for_node $node_id "ready"
}

install_cics() {
    local hosts
    local node_id
    [ -z "$1" ] && die "No 5.1 and 6.0 env IDs provided, exiting"
    [ -z "$2" ] && die "No 6.0 env ID provided, exiting"
    hosts=$(sed '1d' "/tmp/env-$2-cics.hosts")
    [ -z "$hosts" ] && exit 0
    ./manage_services.sh start $2
    for node_id in $hosts
        do
            fuel node set --env $2 --node $node_id --role controller
            provision_node $node_id
        done
    for i in $(seq 30)
        do
            if [ "$(fuel node --env $2 \
                | awk -F\| '$8 ~ /controller/ && $2 ~ /provisioned/ {print $0}' \
                | wc -l)" == "$(sed '1d' /tmp/env-$2-cics.hosts | wc -l)" ]
                then
                    break
                fi
            sleep 300
       done
    prepare_seed_deployment_info $1 $2
    create_ovs_bridges $2
    for  br_name in br-ex br-mgmt
        do
            create_tunnels $2 $br_name 'controller'
        done
    fuel node --env $2 --node $(sed '1d' "/tmp/env-$2-cics.hosts" \
        | awk 'BEGIN {f = ""}
        {
            if (f == "") {f = $1}
            else {printf f","; f = $1}
        }
        END {printf f}') --deploy
    for i in $(seq 30)
        do
            if [ "$(fuel node --env $2 \
                | awk -F\| '$7 ~ /controller/ && $2 ~ /ready/ {print $0}' \
                | wc -l)" == "$(cat /tmp/env-$2-cics.hosts | wc -l)" ]
                then
                    break
                fi
            sleep 300
       done
}

upgrade_ceph() {
    [ -z "$1" ] && die "No 5.1 and 6.0 env IDs provided, exiting"
    [ -z "$2" ] && die "No 6.0 env ID provided, exiting"
    ./migrate-ceph-mon.sh $1 $2
    import_bootstrap_osd $2
}

update_admin_tenant_id() {
    local cic_node
    local tenant_id
    [ -z "$1" ] && die "No 6.0 env ID provided, exiting"
    cic_node=$(list_nodes $1 controller | head -1)
    tenant_id=$(ssh root@$cic_node ". openrc; keystone tenant-get services" \
        | awk -F\| '$2 ~ /id/{print $3}' | tr -d \ )
    list_nodes $1 controller | xargs -I{} ssh root@{} \
        "sed -re 's/^(nova_admin_tenant_id )=.*/\1 = $tenant_id/' -i /etc/neutron/neutron.conf;
        restart neutron-server"
}

cleanup_nova_services() {
    [ -z "$1" ] && die "No 6.0 env ID provided, exiting"
    local cic=$(list_nodes $1 controller | head -1)
    ssh root@${cic} '. /root/openrc;
    nova service-list | grep nova \
    | grep -Ev "('$(list_nodes $1 "(controller|compute|ceph-osd)" \
    | sed ':a;N;$!ba;s/\n/|/g')')"' | awk -F \| '{print($2)}' | tr -d ' ' \
    | xargs -I{} ssh root@${cic} ". /root/openrc; nova service-delete {}"
}

cleanup_neutron_services() {
    [ -z "$1" ] && die "No 6.0 env ID provided, exiting"
    local cic=$(list_nodes $1 controller | head -1)
    ssh root@${cic} '. /root/openrc;
    neutron agent-list | grep neutron \
    | grep -Ev "('$(list_nodes $1 "(controller|compute|ceph-osd)" \
    | sed ':a;N;$!ba;s/\n/|/g')')"' | awk -F \| '{print($2)}' | tr -d ' ' \
    | xargs -I{} ssh root@${cic} ". /root/openrc; neutron agent-delete {}"
}

install_seed() {
    local orig_env
    local seed_env
    local args
    [ -z "$1" ] && die "No 5.1 env ID provided, exiting"
    [ -z "$2" ] && die "No node IDs for 6.0 controllers provided, exiting"
    orig_env=$1 && shift
    seed_env=$(clone_env $orig_env)
    args="$orig_env $seed_env"
    copy_generated_settings $args
    init_seed $seed_env "$@"
    prepare_cic_disk_fixture $orig_env
    prepare_cic_network_fixture $orig_env
    install_primary_cic $args
    upgrade_db $args
    install_cics $args
    upgrade_ceph $args
    update_admin_tenant_id $seed_env
}

delete_fuel_resources() {
    [ -z "$1" ] && die "No env ID provided, exiting"
    local node=$(list_nodes $1 controller | head -1)
    scp $HELPER_PATH/delete_fuel_resources.py \
        root@$(get_host_ip_by_node_id ${node#node-})
    ssh root@$(get_host_ip_by_node_id ${node#node-}) \
        "python delete_fuel_resources.py \$(cat openrc | grep OS_USER \\
        | tr \"='\" ' ' | awk '{print \$3}') \$(cat openrc | grep OS_PASS \\
        | tr\"='\" ' ' | awk '{print \$3}') \$(cat openrc | grep OS_TENANT \\
        | tr \"='\" ' ' | awk '{print \$3}') \$(. openrc; \\
            keystone endpoint-list | egrep ':5000' | awk '{print \$6}')"
}

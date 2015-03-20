#!/bin/sh -e
extract_vars() {
        sed -re '/^\+.*%.*/ s/.*%([^%]+)%.*/\L\1/;tx;d;:x' $1
}

convert_vars_to_regex() {
        tr "\n" " "| sed -re 's,^,^(,;s,.$,),;s, ,|,g'
}

generate_template_regex() {
        egrep "`extract_vars $1 | convert_vars_to_regex`" | awk -F= '{key = gensub(" ", "", "g", $1); printf("s|%%%s%%|%s|g;", toupper(key), $2)}'
}

upgrade_compute_service() {
	local regex
	local nova_regex
	regex=$(ssh root@$1 "find /etc/neutron -type f -exec cat {} \;" | generate_template_regex $PATCH)
	nova_regex=$(ssh root@$1 "cat /etc/nova/nova.conf" | generate_template_regex $NOVA_PATCH)
	sed -r "$regex" ${PATCH}  | ssh root@$1 "tee /tmp/patch-neutron-config_$1.patch"
	ssh root@$1 "apt-get update; apt-get install -o Dpkg::Options::='--force-confnew' --yes nova-compute"
	ssh root@$1 "cd /etc/neutron && patch -p0 < /tmp/patch-neutron-config_$1.patch"
	cat ${NOVA_PATCH} | sed -r "${nova_regex}" | ssh root@$1 "cat > /etc/nova/nova.conf"
} 

add_apt_sources() {
	local source
	source="http://$(grep fuel /etc/hosts | cut -d \  -f1):8080/2014.2-6.0/ubuntu/x86_64"
	printf "\ndeb $source precise main\n" | ssh root@$1 "cat >> /etc/apt/sources.list"
}


[ -f "./functions" ] && . ./functions

[ -z "$1" ] && die "No node ID provided, exiting"
PATCH=${2-"../patches/neutron-upgrade.patch"}
NOVA_PATCH=${3-"../patches/nova.conf"}

if [ ! -f "$PATCH" -o ! -f "$NOVA_PATCH" ]; then
    echo "Usage $0 NODE_ID [NEUTRON_PATCH_PATH] [NOVA_PATCH_PATH]" >> /dev/stderr
    exit 1
fi

add_apt_sources $1
upgrade_compute_service $1

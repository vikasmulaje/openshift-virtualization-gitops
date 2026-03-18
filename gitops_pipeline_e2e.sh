#!/bin/bash
set -euo pipefail

#############################################################################
# End-to-End Spoke Cluster Deployment Automation
#
# Assumes a FRESH OpenShift hub cluster and no existing spoke VMs.
#
# Default flow (no flags):
#   1. Hub GitOps bootstrap (ArgoCD, ACM, operators)
#   2. Create VM infrastructure from saved XMLs (identical to gitops repo BMH config)
#   3. Wait for spoke cluster provisioning via ACM + Assisted Installer
#   4. Day-2: Bootstrap ArgoCD on spoke clusters
#   5. Day-2: Operator compliance + ArgoCD resource tuning
#   6. (Optional) Post-deployment pytest validation (--test flag)
#
# Usage:
#   ./gitops_pipeline_e2e.sh                         # Full end-to-end: both clusters
#   ./gitops_pipeline_e2e.sh --clusters etl4         # Full end-to-end: etl4 only
#   ./gitops_pipeline_e2e.sh --clusters both         # Full end-to-end: etl4 + etl6
#   ./gitops_pipeline_e2e.sh --cleanup               # Destroy existing VMs first
#   ./gitops_pipeline_e2e.sh --phase hub             # Run only hub bootstrap
#   ./gitops_pipeline_e2e.sh --phase infra           # Run only VM infra creation
#   ./gitops_pipeline_e2e.sh --phase spoke           # Run only spoke provisioning wait
#   ./gitops_pipeline_e2e.sh --phase day2            # Run only day-2 operations
#   ./gitops_pipeline_e2e.sh --day2-only             # Extract kubeconfigs + all day-2 steps
#   ./gitops_pipeline_e2e.sh --clusters etl4 --day2-only  # Day-2 for etl4 only
#
#   Run directly on the hypervisor (no SSH):
#   ./gitops_pipeline_e2e.sh --local                   # Auto-run locally on hypervisor
#   ./gitops_pipeline_e2e.sh --local --clusters etl4   # Local, etl4 only
#
#   Run post-deployment tests (generates HTML report):
#   ./gitops_pipeline_e2e.sh --clusters etl4 --test    # Deploy + test
#   ./gitops_pipeline_e2e.sh --phase spoke --test      # Spoke wait + test
#   ./gitops_pipeline_e2e.sh --local --cleanup --test  # Full clean run + test
#
# Smart resume: re-run the same command after a failure and the script
# automatically detects what's already done and skips to what's missing.
#
# Prerequisites:
#   - SSH access to hypervisor (when running from laptop), OR
#   - Run directly on the hypervisor with --local flag
#   - Fresh hub cluster with KUBECONFIG available
#   - Pull secret JSON file on hypervisor
#############################################################################

# ========================= CONFIGURATION ==================================

export VIRSH_DEFAULT_CONNECT_URI="qemu:///system"

HYPERVISOR="cert-rhosp-01.lab.eng.rdu2.redhat.com"
HYPERVISOR_USER="root"
GITOPS_BRANCH="${GITOPS_BRANCH:-openshift-4.21}"
# Network profile is initialized after argument parsing (see init_network_profile)
SUSHY_PORT="8000"
SUSHY_IMAGE="quay.io/ocp-edge-qe/sushy-tools:latest"

HUB_KUBECONFIG="/home/kni/clusterconfigs/auth/kubeconfig"
GITOPS_REPO="https://github.com/vikasmulaje/openshift-virtualization-gitops.git"
# GITOPS_REPO_SSH="git@github.com:vikasmulaje/openshift-virtualization-gitops.git"
GITOPS_DIR="/home/kni/openshift-virtualization-gitops"
PULL_SECRET_FILE="/home/kni/pull-secret.json"
SSH_KEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCuvmmrAPF/axpjIrcJ6pdZ7Ale6XBOCUNanM0fTNOoY7emN/39PwZ7c4LQPvWI0MifjE0UgzuLSPwNGEeH/j8PM2Vy/Bp/h2r09rZ3ti8oaBgcV+UBafOd/85H6O/NMMSiGAubM9JUw0+z5q9yuESTZAPwGcp2gsgC1Ray5YZSIUcH7sSeZk0o6IOsZ8f08L4eiGwkTRZpZ20PRXKxATibxLz7cdzfm01G0ShizchaagOrbLaPXVN9s33L+kM+R4QfoWvhsUIroa3xzUp91n0QbNGj/hBO0OlXiPpitFQFx7F0AZi/ZuJiaYbTpiGlM0SwWPg1IT0a+E44q9gsRHKFuf5Ehpzm/sNb5+eAo0bSGivcwELEh1kzuWOsxPNMGS07I/r+vZ0PNu4fXB7oVH2Ox9hCIfNEsmH8BOK3fLsxp1Eg6QyTf1rKkFnw2iq4ZG/fyxwgPvdLbP24TRH5+fbqSp7EC9tZGKY2E8rRCufB82nbqR5bCChchRL8dmNipkc= root@cert-rhosp-01.lab.eng.rdu2.redhat.com"

VM_VCPUS=4    # default, overridden below by scope
VM_DISK_GB=120

BMC_USERNAME="admin"
BMC_PASSWORD="password"

# Docker Hub auth to avoid rate limiting (base64-encoded user:token)
DOCKER_IO_AUTH="dmlrYXNtdWxhamU6ZGNrcl9wYXRfczJ2Q0dqbjVGeXczcHlvcEtUTHFlb2Y1MV9Z"

# Cluster deployment scope: "both" (etl4+etl6) or "etl4" (etl4 only)
CLUSTER_SCOPE="both"

# Execution mode: "remote" (SSH from laptop) or "local" (directly on hypervisor)
# Auto-detected if hostname matches, or override with --local flag
RUN_LOCAL=false


# Cluster node configs are initialized after argument parsing (see init_network_profile)


# ========================= NETWORK PROFILE ================================

init_network_profile() {
  # Branch-based network profile: each OCP version uses a different
  # libvirt network and subnet. Add new entries for new hub clusters.
  case "${GITOPS_BRANCH}" in
    openshift-4.21)
      LIBVIRT_NETWORK="${LIBVIRT_NETWORK:-ocp3m0w-ic4s21}"
      NETWORK_SUBNET="192.168.139"
      OCP_VERSION_IMAGE="${OCP_VERSION_IMAGE:-img4.21.2-x86-64-appsub}"
      ;;
    main|openshift-4.20)
      LIBVIRT_NETWORK="${LIBVIRT_NETWORK:-ocp3m0w-ic4s20}"
      NETWORK_SUBNET="192.168.127"
      OCP_VERSION_IMAGE="${OCP_VERSION_IMAGE:-img4.20.14-x86-64-appsub}"
      ;;
    *)
      log_error "Unknown GITOPS_BRANCH=${GITOPS_BRANCH}. Add a network profile to init_network_profile()."
      exit 1
      ;;
  esac

  GATEWAY="${NETWORK_SUBNET}.1"
  DNS_SERVER="${NETWORK_SUBNET}.1"
  SUBNET_PREFIX="24"

  # ---- etl4 cluster configuration ----
  declare -gA ETL4_NODES
  ETL4_NODES["master-0"]="UUID=10fcb067-2230-44db-b4d5-987298a23227|MAC=52:54:00:aa:04:00|IP=${NETWORK_SUBNET}.160"
  ETL4_NODES["master-1"]="UUID=024bcb2a-9550-43b5-a6d1-025f84e3bede|MAC=52:54:00:aa:04:01|IP=${NETWORK_SUBNET}.161"
  ETL4_NODES["master-2"]="UUID=0b78f27a-de93-4ae2-90ae-ea347e757823|MAC=52:54:00:aa:04:02|IP=${NETWORK_SUBNET}.162"
  ETL4_API_VIP="${NETWORK_SUBNET}.165"
  ETL4_INGRESS_VIP="${NETWORK_SUBNET}.166"
  ETL4_POD_CIDR="10.136.0.0/14"
  ETL4_SVC_CIDR="172.32.0.0/16"
  ETL4_BASE_DOMAIN="etl4.qe.lab.redhat.com"

  # ---- etl6 cluster configuration ----
  declare -gA ETL6_NODES
  ETL6_NODES["master-0"]="UUID=d7708481-e48d-4216-8a48-f20e22a84752|MAC=52:54:00:aa:06:00|IP=${NETWORK_SUBNET}.170"
  ETL6_NODES["master-1"]="UUID=0e36b24d-a59a-4268-8540-4410cddd88d6|MAC=52:54:00:aa:06:01|IP=${NETWORK_SUBNET}.171"
  ETL6_NODES["master-2"]="UUID=271e0e77-b2ec-45ae-9fe4-f37ba6cbbd40|MAC=52:54:00:aa:06:02|IP=${NETWORK_SUBNET}.172"
  ETL6_API_VIP="${NETWORK_SUBNET}.175"
  ETL6_INGRESS_VIP="${NETWORK_SUBNET}.176"
  ETL6_POD_CIDR="10.128.0.0/14"
  ETL6_SVC_CIDR="172.30.0.0/16"
  ETL6_BASE_DOMAIN="etl6.qe.lab.redhat.com"
}

# ========================= HELPERS ========================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${BLUE}[INFO]${NC}  $(date '+%H:%M:%S') $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC}    $(date '+%H:%M:%S') $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $(date '+%H:%M:%S') $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $*"; }

get_deploy_clusters() {
  case "$CLUSTER_SCOPE" in
    etl4) echo "etl4" ;;
    both) echo "etl4 etl6" ;;
    *)
      log_error "Invalid --clusters value: $CLUSTER_SCOPE (must be 'etl4' or 'both')"
      exit 1
      ;;
  esac
}

run_cmd() {
  if [ "$RUN_LOCAL" = true ]; then
    sudo env "PATH=$PATH" bash -c "$*"
  else
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 ${HYPERVISOR_USER}@${HYPERVISOR} "$@"
  fi
}

ssh_hyp() {
  run_cmd "$@"
}

hub_oc() {
  if [ "$RUN_LOCAL" = true ]; then
    sudo env "PATH=$PATH" KUBECONFIG=${HUB_KUBECONFIG} oc $*
  else
    ssh_hyp "export KUBECONFIG=${HUB_KUBECONFIG}; oc $*"
  fi
}

spoke_oc() {
  local cluster=$1; shift
  if [ "$RUN_LOCAL" = true ]; then
    sudo env "PATH=$PATH" KUBECONFIG=/tmp/${cluster}-kubeconfig oc $*
  else
    ssh_hyp "export KUBECONFIG=/tmp/${cluster}-kubeconfig; oc $*"
  fi
}

wait_for_condition() {
  local description="$1"
  local check_cmd="$2"
  local timeout="${3:-600}"
  local max_interval="${4:-15}"
  local elapsed=0
  local interval=3

  log_info "Waiting for: $description (timeout: ${timeout}s)"
  while ! eval "$check_cmd" >/dev/null 2>&1; do
    if [ $elapsed -ge $timeout ]; then
      log_error "Timeout waiting for: $description"
      return 1
    fi
    sleep $interval
    elapsed=$((elapsed + interval))
    # Progressive backoff: 3 -> 5 -> 10 -> 15 -> max_interval
    if [ $interval -lt $max_interval ]; then
      if [ $elapsed -gt 120 ]; then interval=$max_interval
      elif [ $elapsed -gt 30 ]; then interval=10
      elif [ $elapsed -gt 10 ]; then interval=5
      fi
    fi
  done
  log_ok "$description (${elapsed}s)"
}

parse_node_field() {
  local node_data="$1"
  local field="$2"
  echo "$node_data" | tr '|' '\n' | grep "^${field}=" | cut -d= -f2
}

# Portable base64 encode -- macOS lacks -w0
b64_encode() {
  if base64 --help 2>&1 | grep -q '\-w'; then
    base64 -w0
  else
    base64 | tr -d '\n'
  fi
}

preflight_checks() {
  log_info "=== Pre-flight checks ==="
  local FAIL=false

  for CMD in oc virsh python3 podman envsubst curl; do
    if ! command -v "$CMD" &>/dev/null; then
      log_error "Required command not found: $CMD"
      FAIL=true
    fi
  done

  if [ ! -f "${HUB_KUBECONFIG}" ]; then
    log_error "Hub kubeconfig not found: ${HUB_KUBECONFIG}"
    FAIL=true
  fi

  if [ ! -f "${PULL_SECRET_FILE}" ]; then
    log_error "Pull secret not found: ${PULL_SECRET_FILE}"
    FAIL=true
  fi

  if ! sudo env "PATH=$PATH" KUBECONFIG=${HUB_KUBECONFIG} oc get nodes --no-headers &>/dev/null; then
    log_error "Cannot reach hub cluster (KUBECONFIG=${HUB_KUBECONFIG})"
    FAIL=true
  else
    local NODE_COUNT
    NODE_COUNT=$(sudo env "PATH=$PATH" KUBECONFIG=${HUB_KUBECONFIG} oc get nodes --no-headers 2>/dev/null | grep -c Ready || echo 0)
    log_ok "Hub cluster reachable ($NODE_COUNT nodes Ready)"
  fi

  if ! sudo env "PATH=$PATH" virsh net-info "${LIBVIRT_NETWORK}" &>/dev/null; then
    log_error "Libvirt network not found: ${LIBVIRT_NETWORK}"
    FAIL=true
  else
    log_ok "Libvirt network ${LIBVIRT_NETWORK} exists"
  fi


  if [ "$FAIL" = true ]; then
    log_error "Pre-flight checks failed -- aborting"
    exit 1
  fi
  log_ok "All pre-flight checks passed"
}

patch_docker_pull_secret() {
  local oc_func="$1"

  if [ -z "$DOCKER_IO_AUTH" ]; then
    log_warn "DOCKER_IO_AUTH not set -- skipping Docker Hub pull secret patch"
    return 0
  fi

  log_info "Patching global pull secret with Docker Hub credentials"

  local KUBECONFIG_PATH
  if [ "$oc_func" = "hub_oc" ]; then
    KUBECONFIG_PATH="${HUB_KUBECONFIG}"
  else
    local cluster_name
    cluster_name=$(echo "$oc_func" | awk '{print $NF}')
    KUBECONFIG_PATH="/tmp/${cluster_name}-kubeconfig"
  fi

  ssh_hyp "
    export KUBECONFIG=${KUBECONFIG_PATH}
    oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > /tmp/_pullsecret_current.json
    python3 -c \"
import json
with open('/tmp/_pullsecret_current.json') as f:
    data = json.load(f)
data.setdefault('auths', {})['docker.io'] = {'auth': '${DOCKER_IO_AUTH}'}
with open('/tmp/_pullsecret_merged.json', 'w') as f:
    json.dump(data, f)
\"
    oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/tmp/_pullsecret_merged.json
    rm -f /tmp/_pullsecret_current.json /tmp/_pullsecret_merged.json
  "

  log_ok "Docker Hub credentials added to global pull secret"
}

# ========================= PHASE 1: INFRASTRUCTURE =======================

detect_qemu_machine_type() {
  # Auto-detect the latest Q35 machine type supported by this hypervisor
  local detected
  detected=$(ssh_hyp "virsh capabilities 2>/dev/null" |     grep -oP 'pc-q35-rhel[\d.]+' | sort -V | tail -1)
  if [ -z "$detected" ]; then
    detected="q35"
  fi
  echo "$detected"
}

phase1_generate_vm_xml() {
  local VM_NAME="$1"
  local UUID="$2"
  local MAC="$3"
  local DISK="$4"

  cat <<XMLEOF
<domain type='kvm'>
  <name>${VM_NAME}</name>
  <uuid>${UUID}</uuid>
  <metadata xmlns:ns0="http://libosinfo.org/xmlns/libvirt/domain/1.0" xmlns:sushy="http://openstack.org/xmlns/libvirt/sushy">
    <ns0:libosinfo>
      <ns0:os id="http://redhat.com/rhel/9.0"/>
    </ns0:libosinfo>
    <sushy:bios>
      <sushy:attributes>
        <sushy:attribute name="BootMode" value="Uefi"/>
        <sushy:attribute name="EmbeddedSata" value="Raid"/>
        <sushy:attribute name="L2Cache" value="10x256 KB"/>
        <sushy:attribute name="NicBoot1" value="NetworkBoot"/>
        <sushy:attribute name="NumCores" value="10"/>
        <sushy:attribute name="ProcTurboMode" value="Enabled"/>
        <sushy:attribute name="QuietBoot" value="true"/>
        <sushy:attribute name="SecureBootStatus" value="Enabled"/>
        <sushy:attribute name="SerialNumber" value="QPX12345"/>
        <sushy:attribute name="SysPassword" value=""/>
      </sushy:attributes>
    </sushy:bios>
  </metadata>
  <memory unit='KiB'>${VM_MEMORY_KB}</memory>
  <currentMemory unit='KiB'>${VM_MEMORY_KB}</currentMemory>
  <vcpu placement='static'>${VM_VCPUS}</vcpu>
  <os>
    <type arch='x86_64' machine='${QEMU_MACHINE_TYPE}'>hvm</type>
  </os>
  <features>
    <acpi/>
    <apic/>
  </features>
  <cpu mode='host-passthrough' check='none' migratable='on'/>
  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/>
    <timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
  </clock>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <pm>
    <suspend-to-mem enabled='no'/>
    <suspend-to-disk enabled='no'/>
  </pm>
  <devices>
    <emulator>/usr/libexec/qemu-kvm</emulator>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='${DISK}'/>
      <target dev='vda' bus='virtio'/>
      <boot order='1'/>
    </disk>
    <interface type='network'>
      <mac address='${MAC}'/>
      <source network='${LIBVIRT_NETWORK}'/>
      <model type='virtio'/>
    </interface>
    <serial type='pty'>
      <target type='isa-serial' port='0'>
        <model name='isa-serial'/>
      </target>
    </serial>
    <console type='pty'>
      <target type='serial' port='0'/>
    </console>
    <channel type='unix'>
      <target type='virtio' name='org.qemu.guest_agent.0'/>
    </channel>
    <watchdog model='i6300esb' action='reset'/>
    <memballoon model='virtio'/>
    <rng model='virtio'>
      <backend model='random'>/dev/urandom</backend>
    </rng>
  </devices>
</domain>
XMLEOF
}

cleanup_vms() {
  log_info "=== CLEANUP: Destroying existing spoke VMs ==="

  for CLUSTER in $(get_deploy_clusters); do
    declare -n NODES="${CLUSTER^^}_NODES"
    for NODE in "${!NODES[@]}"; do
      local VM_NAME="${CLUSTER}-${NODE}"
      local DISK="/var/lib/libvirt/images/${VM_NAME}.qcow2"

      ssh_hyp "
        if virsh dominfo ${VM_NAME} >/dev/null 2>&1; then
          echo 'Destroying VM ${VM_NAME}...'
          virsh destroy ${VM_NAME} 2>/dev/null || true
          virsh undefine ${VM_NAME} --nvram --remove-all-storage 2>/dev/null || true
        fi
        rm -f ${DISK}
      "
      log_ok "Cleaned up $VM_NAME"
    done
  done
}

phase1_create_vms() {
  log_info "=== Creating VM infrastructure from saved XMLs ==="

  QEMU_MACHINE_TYPE=$(detect_qemu_machine_type)
  log_info "VM spec: ${VM_VCPUS} vCPUs, ${VM_MEMORY_LABEL} RAM, ${VM_DISK_GB}GB disk, machine=${QEMU_MACHINE_TYPE}"

  for CLUSTER in $(get_deploy_clusters); do
    log_info "Creating VMs for cluster: $CLUSTER"

    declare -n NODES="${CLUSTER^^}_NODES"
    for NODE in "${!NODES[@]}"; do
      local NODE_DATA="${NODES[$NODE]}"
      local UUID=$(parse_node_field "$NODE_DATA" "UUID")
      local MAC=$(parse_node_field "$NODE_DATA" "MAC")
      local VM_NAME="${CLUSTER}-${NODE}"
      local DISK="/var/lib/libvirt/images/${VM_NAME}.qcow2"

      log_info "Creating VM: $VM_NAME (UUID=$UUID, MAC=$MAC)"

      ssh_hyp "qemu-img create -f qcow2 ${DISK} ${VM_DISK_GB}G"

      local VM_XML
      VM_XML=$(phase1_generate_vm_xml "$VM_NAME" "$UUID" "$MAC" "$DISK")
      echo "$VM_XML" | ssh_hyp "rm -f /tmp/${VM_NAME}.xml; cat > /tmp/${VM_NAME}.xml && virsh define /tmp/${VM_NAME}.xml"

      local ACTUAL_UUID
      ACTUAL_UUID=$(ssh_hyp "virsh domuuid ${VM_NAME}")
      if [ "$ACTUAL_UUID" != "$UUID" ]; then
        log_error "UUID mismatch for $VM_NAME: expected=$UUID actual=$ACTUAL_UUID"
        return 1
      fi

      log_ok "VM $VM_NAME created (UUID=$ACTUAL_UUID, MAC=$MAC, Disk=$DISK)"
    done
  done
}

phase1_setup_dns() {
  log_info "=== Setting up DNS entries for spoke clusters ==="

  # 1. Add/update /etc/hosts entries on hypervisor (replace stale IPs)
  log_info "Adding/updating /etc/hosts entries"
  for CLUSTER in $(get_deploy_clusters); do
    local API_VIP_VAR="${CLUSTER^^}_API_VIP"
    local BASE_DOMAIN_VAR="${CLUSTER^^}_BASE_DOMAIN"
    ssh_hyp "
      sed -i '/api.${!BASE_DOMAIN_VAR}/d' /etc/hosts
      echo '${!API_VIP_VAR} api.${!BASE_DOMAIN_VAR}' >> /etc/hosts
      echo 'Set /etc/hosts: ${!API_VIP_VAR} -> api.${!BASE_DOMAIN_VAR}'
    "
  done

  # 2. Check if libvirt network already has the DNS entries
  log_info "Checking if libvirt network needs DNS updates"
  local NET_XML
  NET_XML=$(ssh_hyp "virsh net-dumpxml ${LIBVIRT_NETWORK}")

  local DNS_NEEDS_UPDATE=false
  for CLUSTER in $(get_deploy_clusters); do
    local API_VIP_VAR="${CLUSTER^^}_API_VIP"
    local BASE_DOMAIN_VAR="${CLUSTER^^}_BASE_DOMAIN"
    if echo "$NET_XML" | grep -q "${!API_VIP_VAR}.*${!BASE_DOMAIN_VAR}\|${!BASE_DOMAIN_VAR}.*${!API_VIP_VAR}"; then
      log_ok "DNS entry for ${!BASE_DOMAIN_VAR} correct (${!API_VIP_VAR})"
    else
      DNS_NEEDS_UPDATE=true
      if echo "$NET_XML" | grep -q "${!BASE_DOMAIN_VAR}"; then
        log_warn "DNS entry for ${!BASE_DOMAIN_VAR} exists but IP is wrong -- update needed"
      else
        log_info "DNS entry for ${!BASE_DOMAIN_VAR} not found in network -- update needed"
      fi
    fi
  done

  if [ "$DNS_NEEDS_UPDATE" = false ]; then
    log_ok "Libvirt network DNS entries already configured -- no restart needed"
    return 0
  fi

  # 3. Dump current network XML and add missing DNS entries
  log_info "Updating libvirt network with spoke DNS entries"
  ssh_hyp "rm -f /tmp/net-backup-${LIBVIRT_NETWORK}.xml; virsh net-dumpxml ${LIBVIRT_NETWORK} > /tmp/net-backup-${LIBVIRT_NETWORK}.xml"
  ssh_hyp "rm -f /tmp/net-${LIBVIRT_NETWORK}.xml; virsh net-dumpxml ${LIBVIRT_NETWORK} > /tmp/net-${LIBVIRT_NETWORK}.xml"

  # Build the DNS host entries and dnsmasq options to inject
  local DNS_HOST_ENTRIES=""
  local DNSMASQ_OPTIONS=""
  for CLUSTER in $(get_deploy_clusters); do
    local API_VIP_VAR="${CLUSTER^^}_API_VIP"
    local INGRESS_VIP_VAR="${CLUSTER^^}_INGRESS_VIP"
    local BASE_DOMAIN_VAR="${CLUSTER^^}_BASE_DOMAIN"

    DNS_HOST_ENTRIES+="<host ip='${!API_VIP_VAR}'><hostname>api.${!BASE_DOMAIN_VAR}</hostname></host>\n"
    DNSMASQ_OPTIONS+="<dnsmasq:option value='address=/apps.${!BASE_DOMAIN_VAR}/${!INGRESS_VIP_VAR}'/>\n"
  done

  # Inject DNS host entries into the network XML using python3
  ssh_hyp "python3 << 'PYEOF'
import xml.etree.ElementTree as ET

tree = ET.parse('/tmp/net-${LIBVIRT_NETWORK}.xml')
root = tree.getroot()

# Add DNS host entries
dns = root.find('dns')
if dns is None:
    dns = ET.SubElement(root, 'dns')

clusters = {
$(for CLUSTER in $(get_deploy_clusters); do
    local API_VIP_VAR="${CLUSTER^^}_API_VIP"
    local INGRESS_VIP_VAR="${CLUSTER^^}_INGRESS_VIP"
    local BASE_DOMAIN_VAR="${CLUSTER^^}_BASE_DOMAIN"
    echo "    '${!BASE_DOMAIN_VAR}': {'api_vip': '${!API_VIP_VAR}', 'ingress_vip': '${!INGRESS_VIP_VAR}'},"
done)
}

for domain, vips in clusters.items():
    # Remove existing entry (may have stale IP) and re-add with correct IP
    for host in list(dns.findall('host')):
        for hn in host.findall('hostname'):
            if hn.text and domain in hn.text:
                dns.remove(host)
                print(f'Removed stale DNS host for {hn.text}')
                break
    host_el = ET.SubElement(dns, 'host', ip=vips['api_vip'])
    hn_el = ET.SubElement(host_el, 'hostname')
    hn_el.text = f'api.{domain}'
    print(f'Set DNS host: api.{domain} -> {vips[\"api_vip\"]}')

# Handle dnsmasq:options namespace
nsmap = 'http://libvirt.org/schemas/network/dnsmasq/1.0'
ns_prefix = '{' + nsmap + '}'

# Check if xmlns:dnsmasq is in the raw XML
with open('/tmp/net-${LIBVIRT_NETWORK}.xml', 'r') as f:
    raw_xml = f.read()

for domain, vips in clusters.items():
    option_str = f\"address=/apps.{domain}/{vips['ingress_vip']}\"
    if option_str not in raw_xml:
        print(f'Need dnsmasq option: {option_str}')

tree.write('/tmp/net-${LIBVIRT_NETWORK}.xml', xml_declaration=False)
PYEOF
"

  # Also inject dnsmasq options using sed (ElementTree struggles with custom namespaces)
  for CLUSTER in $(get_deploy_clusters); do
    local INGRESS_VIP_VAR="${CLUSTER^^}_INGRESS_VIP"
    local BASE_DOMAIN_VAR="${CLUSTER^^}_BASE_DOMAIN"
    local OPTION_VAL="address=/apps.${!BASE_DOMAIN_VAR}/${!INGRESS_VIP_VAR}"

    ssh_hyp "
      # Remove any existing apps wildcard for this domain (may have stale IP)
      sed -i '/apps.${!BASE_DOMAIN_VAR}/d' /tmp/net-${LIBVIRT_NETWORK}.xml
      if grep -q 'dnsmasq:options' /tmp/net-${LIBVIRT_NETWORK}.xml; then
        sed -i '/<\/dnsmasq:options>/i\\    <dnsmasq:option value=\"${OPTION_VAL}\"/>' /tmp/net-${LIBVIRT_NETWORK}.xml
      else
        sed -i '/<\/network>/i\\  <dnsmasq:options>\\n    <dnsmasq:option value=\"${OPTION_VAL}\"/>\\n  </dnsmasq:options>' /tmp/net-${LIBVIRT_NETWORK}.xml
      fi
      echo 'Set dnsmasq option: ${OPTION_VAL}'
    "
  done

  # 4. Apply the updated network XML (requires net-destroy/net-start)
  log_warn "Restarting libvirt network to apply DNS changes -- hub nodes will be temporarily unreachable"
  ssh_hyp "
    virsh net-define /tmp/net-${LIBVIRT_NETWORK}.xml
    virsh net-destroy ${LIBVIRT_NETWORK}
    sleep 2
    virsh net-start ${LIBVIRT_NETWORK}
  "
  log_info "Libvirt network restarted"

  log_info "Reattaching hub VM tap devices to bridge after network restart"
  ssh_hyp "
    for VM in \$(virsh list --name 2>/dev/null | grep -v '^$'); do
      TAP=\$(virsh domiflist \$VM 2>/dev/null | awk '/network/{print \$1}')
      if [ -n \"\$TAP\" ]; then
        ip link set \$TAP master ${LIBVIRT_NETWORK} 2>/dev/null || true
      fi
    done
  "
  sleep 5

  # 5. Wait for hub cluster to come back online
  log_info "Waiting for hub cluster to recover after network restart..."

  wait_for_condition "Hub API server reachable" \
    "hub_oc 'get nodes --no-headers' 2>/dev/null | grep -q Ready" \
    300 10

  wait_for_condition "All 3 hub nodes Ready" \
    "[ \$(hub_oc 'get nodes --no-headers' 2>/dev/null | grep -c Ready) -ge 3 ]" \
    300 10

  log_ok "Hub cluster recovered. All nodes reachable."

  log_info "Waiting for hub cluster operators to stabilize after network restart..."
  wait_for_condition "Hub cluster operators not degraded" \
    "[ \$(hub_oc 'get clusteroperators --no-headers' 2>/dev/null | grep -cE 'True.*False.*False') -ge 25 ]" \
    600 20
  log_ok "Hub cluster operators stable"

  log_ok "DNS setup complete"
}

phase1_setup_sushy() {
  log_info "Setting up sushy-emulator"

  # Ensure libvirt socket compatibility: sushy-tools expects virtqemud-sock.
  # Only create a symlink when monolithic libvirtd is in use; when modular
  # virtqemud is active, its socket is managed by systemd and a symlink would
  # conflict and break the service.
  ssh_hyp "
    if systemctl is-active virtqemud.socket &>/dev/null; then
      echo 'Modular virtqemud detected -- socket managed by systemd, no symlink needed'
      if [ -L /var/run/libvirt/virtqemud-sock ]; then
        rm -f /var/run/libvirt/virtqemud-sock
        systemctl restart virtqemud.socket
        echo 'Removed stale symlink and restarted virtqemud.socket'
      fi
    elif [ -S /var/run/libvirt/libvirt-sock ] && [ ! -e /var/run/libvirt/virtqemud-sock ]; then
      ln -sf /var/run/libvirt/libvirt-sock /var/run/libvirt/virtqemud-sock
      echo 'Monolithic libvirtd detected -- created virtqemud-sock symlink'
    fi
  "

  ssh_hyp "
    if podman ps --filter name=sushy-tools --format '{{.Names}}' | grep -q sushy-tools; then
      echo 'Sushy-emulator already running'
    else
      podman rm -f sushy-tools 2>/dev/null || true
      podman run -d --name sushy-tools \
        --security-opt label=disable \
        --net host \
        --privileged \
        -v /var/run/libvirt:/var/run/libvirt \
        ${SUSHY_IMAGE}
      echo 'Sushy-emulator started'
    fi
  "

  sleep 5
  local SUSHY_RUNNING=$(ssh_hyp "podman ps --filter name=sushy-tools --filter status=running --format '{{.Names}}' 2>/dev/null")
  local SUSHY_PORT_OPEN=$(ssh_hyp "ss -tlnp 2>/dev/null | grep -q ':${SUSHY_PORT}' && echo 'yes' || echo 'no'")
  if [ -n "$SUSHY_RUNNING" ] && [ "$SUSHY_PORT_OPEN" == "yes" ]; then
    log_ok "Sushy-emulator is running and listening on port ${SUSHY_PORT}"
  else
    log_error "Sushy-emulator not responding (container=$SUSHY_RUNNING, port=$SUSHY_PORT_OPEN)"
    return 1
  fi
}

phase1_verify_infra() {
  log_info "Verifying infrastructure"

  for CLUSTER in $(get_deploy_clusters); do
    declare -n NODES="${CLUSTER^^}_NODES"
    for NODE in "${!NODES[@]}"; do
      local NODE_DATA="${NODES[$NODE]}"
      local UUID=$(parse_node_field "$NODE_DATA" "UUID")
      local VM_NAME="${CLUSTER}-${NODE}"

      local VM_EXISTS=$(ssh_hyp "virsh dominfo ${VM_NAME} >/dev/null 2>&1 && echo 'yes' || echo 'no'")
      if [ "$VM_EXISTS" != "yes" ]; then
        log_error "VM $VM_NAME does not exist!"
        return 1
      fi

      log_ok "VM $VM_NAME verified (UUID=$UUID)" 
    done
  done
  log_ok "All VMs and Redfish endpoints verified"
}

# ========================= PHASE 2: HUB BOOTSTRAP ========================

phase2_hub_bootstrap() {
  log_info "=== PHASE 2: Hub Cluster GitOps Bootstrap ==="

  log_info "Cloning GitOps repository on hypervisor"
  ssh_hyp "
    git config --global --add safe.directory /home/kni/openshift-virtualization-gitops 2>/dev/null || true
    cd /home/kni
    if [ -d openshift-virtualization-gitops ] && [ ! -w openshift-virtualization-gitops/.git ]; then
      rm -rf openshift-virtualization-gitops
    fi
    if [ -d openshift-virtualization-gitops ]; then
      cd openshift-virtualization-gitops && git fetch --all && git checkout ${GITOPS_BRANCH} && git pull
    else
      git clone -b ${GITOPS_BRANCH} ${GITOPS_REPO}
      cd openshift-virtualization-gitops
    fi
  "

  log_info "Installing OpenShift GitOps Operator on hub"
  hub_oc "apply -f ${GITOPS_DIR}/.bootstrap/subscription.yaml"

  wait_for_condition "GitOps operator CSV Succeeded" \
    "hub_oc 'get csv -n openshift-operators -l operators.coreos.com/openshift-gitops-operator.openshift-operators --no-headers' 2>/dev/null | grep -q Succeeded" \
    300

  wait_for_condition "ArgoCD server deployment available" \
    "hub_oc 'wait --for=condition=available deployment/openshift-gitops-server -n openshift-gitops --timeout=10s'" \
    300
}

phase2_configure_argocd() {
  log_info "Configuring ArgoCD CR + CMP env vars (with envsubst)"

  log_info "Ensuring GitOps repo is up to date"
  ssh_hyp "
    git config --global --add safe.directory /home/kni/openshift-virtualization-gitops 2>/dev/null || true
    cd /home/kni
    if [ -d openshift-virtualization-gitops ] && [ ! -w openshift-virtualization-gitops/.git ]; then
      rm -rf openshift-virtualization-gitops
    fi
    if [ -d openshift-virtualization-gitops ]; then
      cd openshift-virtualization-gitops && git fetch --all && git checkout ${GITOPS_BRANCH} && git pull
    else
      git clone -b ${GITOPS_BRANCH} ${GITOPS_REPO}
    fi
  "

  hub_oc "apply -f ${GITOPS_DIR}/.bootstrap/cluster-rolebinding.yaml"

  ssh_hyp "
    export KUBECONFIG=${HUB_KUBECONFIG}
    export gitops_repo='${GITOPS_REPO}'
    export gitops_branch='${GITOPS_BRANCH}'
    export cluster_name='hub'
    export cluster_base_domain=\$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' | sed 's/^apps\.//')
    export platform_base_domain=\${cluster_base_domain}
    envsubst < ${GITOPS_DIR}/.bootstrap/argocd.yaml | oc apply -f -
  "

  log_info "Restarting repo-server to pick up ConfigMap changes"
  hub_oc "rollout restart deployment openshift-gitops-repo-server -n openshift-gitops" 2>/dev/null || true

  wait_for_condition "ArgoCD server ready after CR apply" \
    "hub_oc 'wait --for=condition=available deployment/openshift-gitops-server -n openshift-gitops --timeout=10s'" \
    300

  wait_for_condition "ArgoCD repo-server rollout complete" \
    "hub_oc 'rollout status deployment/openshift-gitops-repo-server -n openshift-gitops --timeout=10s'" \
    300

  log_ok "ArgoCD configured with CMP plugin and environment variables"
}

phase2_cleanup_stale_apps() {
  log_info "Checking for stale apps with unresolved template variables"
  local STALE_APPS
  STALE_APPS=$(hub_oc 'get applications.argoproj.io -n openshift-gitops -o json' 2>/dev/null | \
    python3 -c "
import sys, json
data = json.load(sys.stdin)
for app in data.get('items', []):
    repo = app.get('spec', {}).get('source', {}).get('repoURL', '')
    if '\${' in repo or 'INFRA_GITOPS_REPO' in repo:
        print(app['metadata']['name'])
" 2>/dev/null || true)

  if [ -n "$STALE_APPS" ]; then
    log_warn "Found stale apps with unresolved template vars -- cleaning up"
    for APP in $STALE_APPS; do
      log_info "Deleting stale app: $APP"
      hub_oc "patch applications.argoproj.io $APP -n openshift-gitops -p '{\"metadata\":{\"finalizers\":null}}' --type=merge" 2>/dev/null || true
      hub_oc "delete applications.argoproj.io $APP -n openshift-gitops --ignore-not-found" 2>/dev/null || true
    done
    hub_oc "patch applications.argoproj.io root-applications -n openshift-gitops -p '{\"metadata\":{\"finalizers\":null}}' --type=merge" 2>/dev/null || true
    hub_oc "delete applications.argoproj.io root-applications -n openshift-gitops --ignore-not-found" 2>/dev/null || true
    sleep 5
    log_ok "Stale apps cleaned up"
  else
    log_ok "No stale apps found"
  fi
}

phase2_patch_hub_docker_auth() {
  patch_docker_pull_secret hub_oc
}

phase2_create_secrets() {
  log_info "Creating spoke cluster secrets on hub"

  for CLUSTER in $(get_deploy_clusters); do
    log_info "Creating secrets for $CLUSTER"

    hub_oc "create namespace ${CLUSTER}" 2>/dev/null || true

    hub_oc "create secret generic pullsecret-${CLUSTER} \
      --from-file=.dockerconfigjson=${PULL_SECRET_FILE} \
      --type=kubernetes.io/dockerconfigjson \
      -n ${CLUSTER}" 2>/dev/null || log_warn "Pull secret for $CLUSTER already exists"

    hub_oc "label secret pullsecret-${CLUSTER} -n ${CLUSTER} \
      agent-install.openshift.io/watch=true \
      cluster.open-cluster-management.io/backup=true --overwrite"

    hub_oc "create secret generic bmc-credentials \
      --from-literal=username=${BMC_USERNAME} \
      --from-literal=password=${BMC_PASSWORD} \
      -n ${CLUSTER}" 2>/dev/null || log_warn "BMC secret for $CLUSTER already exists"

    hub_oc "label secret bmc-credentials -n ${CLUSTER} \
      environment.metal3.io=baremetal --overwrite"

    log_ok "Secrets created for $CLUSTER"
  done
}

phase2_apply_root_app() {
  log_info "Applying root application on hub"

  ssh_hyp "
    export KUBECONFIG=${HUB_KUBECONFIG}
    export gitops_repo='${GITOPS_REPO}'
    export gitops_branch='${GITOPS_BRANCH}'
    export cluster_name='hub'
    envsubst < ${GITOPS_DIR}/.bootstrap/root-application.yaml | oc apply -f -
  "
  log_ok "Root application applied on hub"
}

phase2_wait_acm() {
  log_info "Waiting for ACM to be operational"

  log_info "Waiting for ArgoCD to begin syncing hub applications..."
  wait_for_condition "Hub root app synced" \
    "hub_oc 'get applications.argoproj.io root-applications -n openshift-gitops -o jsonpath={.status.sync.status}' 2>/dev/null | grep -qE 'Synced|OutOfSync'" \
    300 15

  wait_for_condition "ACM operator subscription created" \
    "hub_oc 'get subscription.operators.coreos.com advanced-cluster-management -n open-cluster-management --no-headers' 2>/dev/null | grep -q ." \
    600 20

  wait_for_condition "MultiClusterHub Running" \
    "hub_oc 'get multiclusterhub -A --no-headers' | grep -q Running" \
    2400 30

  wait_for_condition "AgentServiceConfig reconciled" \
    "hub_oc 'get agentserviceconfig agent --no-headers'" \
    900 15

  wait_for_condition "Provisioning CR with watchAllNamespaces" \
    "hub_oc 'get provisioning provisioning-configuration -o jsonpath={.spec.watchAllNamespaces}' | grep -q true" \
    600 15

  log_ok "ACM is fully operational"
}


# ========================= PHASE 2b: HUB POST-DEPLOY FIXES ================

phase2_install_minio_operator() {
  log_info "Installing MinIO Operator via Helm (required by aap-configuration & acm-observability)"

  local HAS_CRD
  HAS_CRD=$(hub_oc "get crd tenants.minio.min.io --no-headers" 2>/dev/null || echo "")
  if [ -n "$HAS_CRD" ]; then
    log_ok "MinIO Tenant CRD already exists -- skipping"
    return 0
  fi

  ssh_hyp "
    export KUBECONFIG=${HUB_KUBECONFIG}

    helm repo add minio-operator https://operator.min.io 2>/dev/null || true
    helm repo update 2>/dev/null

    if helm status minio-operator -n minio-operator &>/dev/null; then
      echo 'MinIO operator Helm release already exists'
    else
      helm install minio-operator minio-operator/operator \
        --namespace minio-operator \
        --create-namespace \
        --set operator.replicaCount=1
    fi

    oc adm policy add-scc-to-user nonroot-v2 -z minio-operator -n minio-operator 2>/dev/null || true
  "

  wait_for_condition "MinIO Tenant CRD available" \
    "hub_oc 'get crd tenants.minio.min.io --no-headers'" \
    120 10

  wait_for_condition "MinIO operator pod running" \
    "hub_oc 'get pods -n minio-operator --no-headers 2>/dev/null' | grep -q Running" \
    120 10

  log_ok "MinIO Operator installed and running"
}

phase2_patch_forklift_crd() {
  log_info "Patching ForkliftController CRD schema (olm_managed field for ArgoCD sync)"

  local HAS_FIELD
  HAS_FIELD=$(hub_oc "get crd forkliftcontrollers.forklift.konveyor.io -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.olm_managed}'" 2>/dev/null || echo "")

  if [ -n "$HAS_FIELD" ] && [ "$HAS_FIELD" != "''" ]; then
    log_ok "ForkliftController CRD already has olm_managed field -- skipping"
    return 0
  fi

  local HAS_CRD
  HAS_CRD=$(hub_oc "get crd forkliftcontrollers.forklift.konveyor.io --no-headers" 2>/dev/null || echo "")
  if [ -z "$HAS_CRD" ]; then
    log_warn "ForkliftController CRD not found -- MTV operator may not be installed yet, skipping"
    return 0
  fi

  hub_oc "patch crd forkliftcontrollers.forklift.konveyor.io --type=json -p='[{"op":"add","path":"/spec/versions/0/schema/openAPIV3Schema/properties/spec/properties/olm_managed","value":{"type":"boolean","description":"Whether the operator is managed by OLM"}}]'"

  log_ok "ForkliftController CRD patched"
}

phase2_approve_hub_installplans() {
  log_info "Approving pending InstallPlans on hub cluster"

  local PENDING
  PENDING=$(hub_oc "get installplan -A -o json" 2>/dev/null | \
    python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('items', []):
    if not item.get('spec', {}).get('approved', False):
        ns = item['metadata']['namespace']
        name = item['metadata']['name']
        print(f'{ns}/{name}')
" 2>/dev/null || true)

  if [ -z "$PENDING" ]; then
    log_ok "No pending InstallPlans on hub"
    return 0
  fi

  for PLAN in $PENDING; do
    local NS=$(echo $PLAN | cut -d/ -f1)
    local NAME=$(echo $PLAN | cut -d/ -f2)
    log_info "Approving InstallPlan $NAME in namespace $NS on hub"
    hub_oc "patch installplan $NAME -n $NS --type merge -p '{"spec":{"approved":true}}'"
  done

  log_ok "Hub InstallPlans approved"
}

phase2_scale_down_external_dns() {
  log_info "Checking external-dns connectivity"

  local EXT_DNS_EXISTS
  EXT_DNS_EXISTS=$(hub_oc "get deployment external-dns -n external-dns --no-headers" 2>/dev/null || echo "")
  if [ -z "$EXT_DNS_EXISTS" ]; then
    log_info "external-dns deployment not found -- skipping"
    return 0
  fi

  local CRASH_LOOP
  CRASH_LOOP=$(hub_oc "get pods -n external-dns --no-headers" 2>/dev/null | grep -c "CrashLoopBackOff" || echo "0")

  if [ "$CRASH_LOOP" -gt 0 ] 2>/dev/null; then
    log_warn "external-dns pods in CrashLoopBackOff -- scaling to 0 (DNS server likely unreachable in libvirt env)"
    hub_oc "scale deployment external-dns -n external-dns --replicas=0"
    log_ok "external-dns scaled down"
  else
    log_ok "external-dns pods are healthy"
  fi
}

phase2_hub_post_deploy_fixes() {
  log_info "=== Hub Post-Deployment Fixes ==="
  phase2_approve_hub_installplans
  phase2_install_minio_operator
  phase2_patch_forklift_crd
  phase2_scale_down_external_dns
}

phase4_create_spoke_prereq_namespaces() {
  log_info "Creating prerequisite namespaces on spoke clusters"

  for CLUSTER in $(get_deploy_clusters); do
    spoke_oc $CLUSTER "create namespace openshift-power-monitoring" 2>/dev/null || true
    log_ok "openshift-power-monitoring namespace ensured on $CLUSTER"
  done
}

# ========================= PHASE 3: SPOKE PROVISIONING ====================

phase3_wait_spoke_provisioning() {
  log_info "=== PHASE 3: Spoke Cluster Provisioning ==="

  for CLUSTER in $(get_deploy_clusters); do
    log_info "Waiting for $CLUSTER ArgoCD application to sync"
    wait_for_condition "$CLUSTER ArgoCD app synced" \
      "hub_oc 'get applications.argoproj.io ${CLUSTER} -n openshift-gitops -o jsonpath={.status.sync.status}' | grep -q Synced" \
      600 15
  done

  for CLUSTER in $(get_deploy_clusters); do
    log_info "Waiting for $CLUSTER BMH registration"
    wait_for_condition "$CLUSTER BMH registration" \
      "[ \$(hub_oc 'get bmh -n ${CLUSTER} --no-headers' 2>/dev/null | wc -l) -ge 3 ]" \
      300 15
  done

  for CLUSTER in $(get_deploy_clusters); do
    log_info "Waiting for $CLUSTER cluster deployment to be provisioned"
    local TIMEOUT=3600
    local ELAPSED=0
    local CHECK_INTERVAL=30
    local PREV_PCT=""

    while [ $ELAPSED -lt $TIMEOUT ]; do
      local INSTALLED=$(hub_oc "get clusterdeployment ${CLUSTER} -n ${CLUSTER} -o jsonpath={.status.installedTimestamp}" 2>/dev/null)
      if [ -n "$INSTALLED" ]; then
        log_ok "$CLUSTER ClusterDeployment provisioned (${ELAPSED}s)"
        break
      fi

      local PCT=$(hub_oc "get agentclusterinstall ${CLUSTER} -n ${CLUSTER} -o jsonpath={.status.progress.totalPercentage}" 2>/dev/null || echo "0")
      local STATE=$(hub_oc "get agentclusterinstall ${CLUSTER} -n ${CLUSTER} -o jsonpath={.status.debugInfo.state}" 2>/dev/null || echo "unknown")
      local STATE_INFO=$(hub_oc "get agentclusterinstall ${CLUSTER} -n ${CLUSTER} -o jsonpath={.status.debugInfo.stateInfo}" 2>/dev/null || echo "")
      local HOSTS_DONE=$(hub_oc "get agent -n ${CLUSTER} --no-headers" 2>/dev/null | grep -c "Done" || echo "0")
      local HOSTS_TOTAL=$(hub_oc "get agent -n ${CLUSTER} --no-headers" 2>/dev/null | wc -l | tr -d " " || echo "0")

      if [ "$PCT" != "$PREV_PCT" ] || [ $((ELAPSED % 120)) -eq 0 ]; then
        log_info "$CLUSTER [${ELAPSED}s] ${PCT}% | state: ${STATE} | hosts: ${HOSTS_DONE}/${HOSTS_TOTAL} done | ${STATE_INFO}"
        PREV_PCT="$PCT"
      fi

      if echo "$STATE" | grep -qi "adding-hosts\|installed"; then
        log_ok "$CLUSTER cluster installation complete -- ${PCT}% (${ELAPSED}s)"
        break
      fi

      if echo "$STATE" | grep -qi "error\|failed"; then
        log_error "$CLUSTER installation failed: $STATE - $STATE_INFO"
        return 1
      fi

      sleep $CHECK_INTERVAL
      ELAPSED=$((ELAPSED + CHECK_INTERVAL))
      if [ $ELAPSED -gt 300 ] && [ $CHECK_INTERVAL -lt 60 ]; then CHECK_INTERVAL=60; fi
    done

    if [ $ELAPSED -ge $TIMEOUT ]; then
      log_error "Timeout waiting for $CLUSTER ClusterDeployment (${TIMEOUT}s)"
      return 1
    fi
  done
}

phase3_extract_kubeconfigs() {
  log_info "Extracting spoke kubeconfigs"

  for CLUSTER in $(get_deploy_clusters); do
    hub_oc "get secret ${CLUSTER}-admin-kubeconfig -n ${CLUSTER} -o jsonpath={.data.kubeconfig}" | base64 -d > /tmp/${CLUSTER}-kubeconfig
    log_ok "Kubeconfig for $CLUSTER saved to /tmp/${CLUSTER}-kubeconfig"
  done
}

phase3_verify_spokes() {
  log_info "Verifying spoke clusters"

  for CLUSTER in $(get_deploy_clusters); do
    log_info "Checking $CLUSTER nodes"
    spoke_oc $CLUSTER "get nodes"
    spoke_oc $CLUSTER "get clusterversion"
  done

  log_info "Checking managed clusters on hub"
  hub_oc "get managedclusters"
}

# ========================= PHASE 4: DAY-2 SPOKE BOOTSTRAP ================

phase4_spoke_gitops_bootstrap() {
  log_info "=== PHASE 4: Day-2 Spoke GitOps Bootstrap ==="

  for CLUSTER in $(get_deploy_clusters); do
    log_info "Bootstrapping ArgoCD on $CLUSTER"

    log_info "Installing GitOps operator on $CLUSTER"
    spoke_oc $CLUSTER "apply -f ${GITOPS_DIR}/.bootstrap/subscription.yaml"

    wait_for_condition "GitOps operator on $CLUSTER" \
      "spoke_oc $CLUSTER 'get csv -n openshift-operators -l operators.coreos.com/openshift-gitops-operator.openshift-operators --no-headers' 2>/dev/null | grep -q Succeeded" \
      600

    wait_for_condition "ArgoCD server on $CLUSTER" \
      "spoke_oc $CLUSTER 'wait --for=condition=available deployment/openshift-gitops-server -n openshift-gitops --timeout=10s'" \
      600

    log_info "Applying cluster role bindings on $CLUSTER"
    spoke_oc $CLUSTER "apply -f ${GITOPS_DIR}/.bootstrap/cluster-rolebinding.yaml"

    log_info "Applying ArgoCD custom resource on $CLUSTER (with envsubst)"
    local SPOKE_BASE_DOMAIN_VAR="${CLUSTER^^}_BASE_DOMAIN"
    ssh_hyp "
      export KUBECONFIG=/tmp/${CLUSTER}-kubeconfig
      export gitops_repo='${GITOPS_REPO}'
      export gitops_branch='${GITOPS_BRANCH}'
      export cluster_name='${CLUSTER}'
      export cluster_base_domain='${!SPOKE_BASE_DOMAIN_VAR}'
      export platform_base_domain='${!SPOKE_BASE_DOMAIN_VAR}'
      envsubst < ${GITOPS_DIR}/.bootstrap/argocd.yaml | oc apply -f -
    "

    wait_for_condition "ArgoCD ready on $CLUSTER" \
      "spoke_oc $CLUSTER 'wait --for=condition=available deployment/openshift-gitops-server -n openshift-gitops --timeout=10s'" \
      600


    log_info "Patching Docker Hub credentials on $CLUSTER"
    patch_docker_pull_secret "spoke_oc $CLUSTER"
    log_info "Applying root application on $CLUSTER"
    ssh_hyp "
      export KUBECONFIG=/tmp/${CLUSTER}-kubeconfig
      export gitops_repo='${GITOPS_REPO}'
      export gitops_branch='${GITOPS_BRANCH}'
      export cluster_name='${CLUSTER}'
      envsubst < ${GITOPS_DIR}/.bootstrap/root-application.yaml | oc apply -f -
    "

    log_info "Waiting for ArgoCD apps to begin syncing on $CLUSTER"
    wait_for_condition "$CLUSTER root app visible" \
      "spoke_oc $CLUSTER 'get applications.argoproj.io root-applications -n openshift-gitops --no-headers' 2>/dev/null | grep -q ." \
      300 15

    log_ok "ArgoCD bootstrapped on $CLUSTER"
  done
}

# ========================= PHASE 5: DAY-2 OPERATOR COMPLIANCE ============

phase5_cleanup_failed_pods() {
  log_info "Cleaning up Failed/Evicted pods on spoke clusters"

  for CLUSTER in $(get_deploy_clusters); do
    local FAILED_COUNT
    FAILED_COUNT=$(spoke_oc $CLUSTER "get pods -A --field-selector=status.phase=Failed --no-headers 2>/dev/null | wc -l" || echo "0")
    FAILED_COUNT=$(echo "$FAILED_COUNT" | tr -d '[:space:]')
    if [ "$FAILED_COUNT" -gt 0 ] 2>/dev/null; then
      log_info "Deleting $FAILED_COUNT failed/evicted pods on $CLUSTER"
      spoke_oc $CLUSTER "delete pods -A --field-selector=status.phase=Failed --ignore-not-found" 2>/dev/null || true
    else
      log_ok "No failed pods on $CLUSTER"
    fi
  done
}

phase5_approve_installplans() {
  log_info "=== PHASE 5: Day-2 Operator Compliance ==="

  local MAX_ROUNDS=3
  local ROUND_DELAY=120

  for ROUND in $(seq 1 $MAX_ROUNDS); do
    log_info "InstallPlan approval round $ROUND/$MAX_ROUNDS"
    local ANY_APPROVED=false

    for CLUSTER in $(get_deploy_clusters); do
      local PENDING
      PENDING=$(spoke_oc $CLUSTER "get installplan -A -o json 2>/dev/null" | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
for item in data.get('items', []):
    if not item.get('spec', {}).get('approved', False):
        print(f\"{item['metadata']['namespace']}/{item['metadata']['name']}\")
" 2>/dev/null || true)

      if [ -n "$PENDING" ]; then
        log_warn "Pending InstallPlans on $CLUSTER:"
        echo "$PENDING"
        for PLAN in $PENDING; do
          local NS=$(echo $PLAN | cut -d/ -f1)
          local NAME=$(echo $PLAN | cut -d/ -f2)
          log_info "Approving InstallPlan $NAME in namespace $NS on $CLUSTER"
          spoke_oc $CLUSTER "patch installplan $NAME -n $NS --type merge -p '{\"spec\":{\"approved\":true}}'"
          ANY_APPROVED=true
        done
      else
        log_ok "No pending InstallPlans on $CLUSTER (round $ROUND)"
      fi
    done

    if [ "$ANY_APPROVED" = false ] && [ "$ROUND" -gt 1 ]; then
      log_ok "No new InstallPlans found -- skipping remaining rounds"
      break
    fi

    if [ "$ROUND" -lt "$MAX_ROUNDS" ]; then
      log_info "Waiting for new InstallPlans to appear (checking every 15s, max ${ROUND_DELAY}s)..."
      local WAITED=0
      while [ $WAITED -lt $ROUND_DELAY ]; do
        sleep 15
        WAITED=$((WAITED + 15))
        local HAS_PENDING=false
        for CLUSTER in $(get_deploy_clusters); do
          if spoke_oc $CLUSTER "get installplan -A -o jsonpath='{range .items[?(@.spec.approved==false)]}{.metadata.name}{end}'" 2>/dev/null | grep -q .; then
            HAS_PENDING=true
            break
          fi
        done
        if [ "$HAS_PENDING" = true ]; then
          log_info "New pending InstallPlans detected after ${WAITED}s -- proceeding to next round"
          break
        fi
      done
    fi
  done

  log_ok "InstallPlan approval complete"
}

phase5_tune_argocd_resources() {
  log_info "Tuning ArgoCD resources on spoke clusters (compact cluster optimization)"

  for CLUSTER in $(get_deploy_clusters); do
    log_info "Reducing ArgoCD resource requests on $CLUSTER"

    spoke_oc $CLUSTER "scale deployment openshift-gitops-operator-controller-manager \
      -n openshift-operators --replicas=0" 2>/dev/null || true

    spoke_oc $CLUSTER "patch statefulset openshift-gitops-application-controller \
      -n openshift-gitops --type json -p '[
        {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/resources/requests/cpu\",\"value\":\"10m\"},
        {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/resources/requests/memory\",\"value\":\"128Mi\"},
        {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/resources/limits/cpu\",\"value\":\"1\"},
        {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/resources/limits/memory\",\"value\":\"2Gi\"}
      ]'" 2>/dev/null || true

    for DEPLOY in openshift-gitops-redis openshift-gitops-server openshift-gitops-repo-server; do
      spoke_oc $CLUSTER "patch deployment $DEPLOY \
        -n openshift-gitops --type json -p '[
          {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/resources/requests/cpu\",\"value\":\"10m\"},
          {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/resources/requests/memory\",\"value\":\"64Mi\"}
        ]'" 2>/dev/null || true
    done

    for DEPLOY in openshift-gitops-dex-server openshift-gitops-applicationset-controller gitops-plugin cluster; do
      spoke_oc $CLUSTER "scale deployment $DEPLOY -n openshift-gitops --replicas=0" 2>/dev/null || true
    done

    log_ok "ArgoCD resources tuned on $CLUSTER"
  done
}

phase5_verify_spoke_apps() {
  log_info "Verifying spoke ArgoCD applications"

  for CLUSTER in $(get_deploy_clusters); do
    log_info "$CLUSTER ArgoCD applications:"
    spoke_oc $CLUSTER "get applications.argoproj.io -n openshift-gitops -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status" 2>/dev/null || \
      log_warn "Could not fetch ArgoCD apps on $CLUSTER (ArgoCD may still be stabilizing)"
  done
}

# ========================= STATE DETECTION (smart resume) ==================

check_hub_gitops_ready() {
  hub_oc "get deployment openshift-gitops-server -n openshift-gitops -o jsonpath={.status.availableReplicas}" 2>/dev/null | grep -q "[1-9]"
}

check_hub_docker_auth() {
  hub_oc "get secret pull-secret -n openshift-config -o jsonpath={.data.\.dockerconfigjson}" 2>/dev/null | base64 -d 2>/dev/null | grep -q "docker.io"
}

check_hub_acm_ready() {
  hub_oc "get multiclusterhub -A --no-headers" 2>/dev/null | grep -q Running && \
  hub_oc "get agentserviceconfig agent --no-headers" 2>/dev/null | grep -q . && \
  hub_oc "get provisioning provisioning-configuration -o jsonpath={.spec.watchAllNamespaces}" 2>/dev/null | grep -q true
}

check_hub_root_app() {
  hub_oc "get applications.argoproj.io root-applications -n openshift-gitops --no-headers" 2>/dev/null | grep -q .
}

check_hub_secrets() {
  local OK=true
  for CLUSTER in $(get_deploy_clusters); do
    hub_oc "get secret pullsecret-${CLUSTER} -n ${CLUSTER} --no-headers" 2>/dev/null | grep -q . || OK=false
    hub_oc "get secret bmc-credentials -n ${CLUSTER} --no-headers" 2>/dev/null | grep -q . || OK=false
  done
  [ "$OK" = true ]
}

check_vms_exist() {
  for CLUSTER in $(get_deploy_clusters); do
    declare -n NODES="${CLUSTER^^}_NODES"
    for NODE in "${!NODES[@]}"; do
      ssh_hyp "virsh dominfo ${CLUSTER}-${NODE}" &>/dev/null || return 1
    done
  done
}

check_sushy_running() {
  ssh_hyp "podman ps --filter name=sushy-tools --filter status=running --format '{{.Names}}'" 2>/dev/null | grep -q sushy-tools &&   ssh_hyp "ss -tlnp | grep -q ':${SUSHY_PORT}'" 2>/dev/null
}

check_spokes_installed() {
  for CLUSTER in $(get_deploy_clusters); do
    local STATE
    STATE=$(hub_oc "get agentclusterinstall ${CLUSTER} -n ${CLUSTER} -o jsonpath={.status.debugInfo.state}" 2>/dev/null || echo "")
    echo "$STATE" | grep -qi "adding-hosts\|installed" || return 1
  done
}

check_spoke_kubeconfigs() {
  for CLUSTER in $(get_deploy_clusters); do
    ssh_hyp "test -f /tmp/${CLUSTER}-kubeconfig" 2>/dev/null || return 1
    spoke_oc $CLUSTER "get nodes --no-headers" 2>/dev/null | grep -q Ready || return 1
  done
}

check_spoke_gitops_ready() {
  for CLUSTER in $(get_deploy_clusters); do
    spoke_oc $CLUSTER "get deployment openshift-gitops-server -n openshift-gitops -o jsonpath={.status.availableReplicas}" 2>/dev/null | grep -q "[1-9]" || return 1
  done
}

check_spoke_docker_auth() {
  for CLUSTER in $(get_deploy_clusters); do
    spoke_oc $CLUSTER "get secret pull-secret -n openshift-config -o jsonpath={.data.\.dockerconfigjson}" 2>/dev/null | base64 -d 2>/dev/null | grep -q "docker.io" || return 1
  done
}

check_spoke_root_apps() {
  for CLUSTER in $(get_deploy_clusters); do
    spoke_oc $CLUSTER "get applications.argoproj.io root-applications -n openshift-gitops --no-headers" 2>/dev/null | grep -q . || return 1
  done
}


check_minio_operator() {
  hub_oc "get crd tenants.minio.min.io --no-headers" 2>/dev/null | grep -q .
}

check_forklift_crd_patched() {
  local result
  result=$(hub_oc "get crd forkliftcontrollers.forklift.konveyor.io -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.olm_managed.type}'" 2>/dev/null || echo "")
  echo "$result" | grep -q "boolean"
}

check_spoke_prereq_namespaces() {
  for CLUSTER in $(get_deploy_clusters); do
    spoke_oc $CLUSTER "get namespace openshift-power-monitoring --no-headers" 2>/dev/null | grep -q . || return 1
  done
}

run_step() {
  local step_name="$1"
  local check_func="$2"
  local run_func="$3"

  if $check_func 2>/dev/null; then
    log_ok "SKIP: ${step_name} (already done)"
  else
    log_info "RUN:  ${step_name}"
    $run_func
  fi
}

# ========================= MAIN EXECUTION =================================

PHASE="all"
DO_CLEANUP=false
DAY2_ONLY=false
RUN_TESTS=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --phase)     PHASE="$2"; shift 2 ;;
    --clusters)  CLUSTER_SCOPE="$2"; shift 2 ;;
    --cleanup)   DO_CLEANUP=true; shift ;;
    --day2-only) DAY2_ONLY=true; shift ;;
    --host)      HYPERVISOR="$2"; shift 2 ;;
    --branch)    GITOPS_BRANCH="$2"; shift 2 ;;
    --network)   LIBVIRT_NETWORK="$2"; shift 2 ;;
    --local)     RUN_LOCAL=true; shift ;;
    --test)      RUN_TESTS=true; shift ;;
    --help|-h)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --host <FQDN>            Hypervisor hostname (default: ${HYPERVISOR})"
      echo "  --clusters <etl4|both>   Deploy etl4 only or both clusters (default: both)"
      echo "  --phase <PHASE>          Run a specific phase only:"
      echo "                             hub   - Hub GitOps bootstrap"
      echo "                             infra - VM infrastructure creation"
      echo "                             spoke - Spoke provisioning wait"
      echo "                             day2  - Day-2 operations"
      echo "                             all   - Full end-to-end (default)"
      echo "  --branch <BRANCH>        Git branch to use (default: openshift-4.21)"
      echo "                             Sets network profile automatically"
      echo "  --network <NAME>         Override libvirt network name"
      echo "  --cleanup                Destroy existing VMs before creating new ones"
      echo "  --day2-only              Extract kubeconfigs + all day-2 steps"
      echo "  --local                  Run directly on the hypervisor (no SSH)"
      echo "  --test                   Run pytest validation after deployment (HTML report)"
      echo "  --help                   Show this help message"
      exit 0
      ;;
    *) log_warn "Unknown option: $1"; shift ;;
  esac
done

# Auto-detect: if running on the hypervisor, switch to local mode
if [ "$RUN_LOCAL" = false ] && hostname -f 2>/dev/null | grep -q "${HYPERVISOR}"; then
  log_info "Detected running on hypervisor -- switching to local mode"
  RUN_LOCAL=true
fi

if [ "$RUN_LOCAL" = true ]; then
  RUN_MODE="local (on hypervisor)"
else
  RUN_MODE="remote (SSH from laptop)"
fi

# Initialize network profile based on --branch (or default)
init_network_profile

DEPLOY_LIST=$(get_deploy_clusters)

# etl4-only: 8 vCPUs + 48GB RAM; both clusters: 4 vCPUs + 24GB RAM (fit within 64 threads / 250GB)
if [ "$CLUSTER_SCOPE" = "etl4" ]; then
  VM_VCPUS=8
  VM_MEMORY_KB=50331648   # 48GB
  VM_MEMORY_LABEL="48GB"
else
  VM_VCPUS=4
  VM_MEMORY_KB=25165824   # 24GB
  VM_MEMORY_LABEL="24GB"
fi

echo ""
echo "=============================================="
echo "  Spoke Cluster Deployment Automation"
echo "=============================================="
echo "  Hypervisor: ${HYPERVISOR}"
echo "  Hub:        ${HUB_KUBECONFIG}"
echo "  GitOps:     ${GITOPS_REPO}"
echo "  Branch:     ${GITOPS_BRANCH}"
echo "  Network:    ${LIBVIRT_NETWORK} (${NETWORK_SUBNET}.0/24)"
echo "  Clusters:   ${DEPLOY_LIST}"
echo "  VM Spec:    ${VM_VCPUS} vCPUs, ${VM_MEMORY_LABEL} RAM"
echo "  Phase:      ${PHASE}"
echo "  Cleanup:    ${DO_CLEANUP}"
echo "  Mode:       ${RUN_MODE}"
echo "  Run Tests:  ${RUN_TESTS}"
echo "=============================================="
echo ""

preflight_checks

if [ "$DAY2_ONLY" = true ]; then
  run_step "Spoke kubeconfigs"       check_spoke_kubeconfigs    phase3_extract_kubeconfigs
  run_step "Spoke ArgoCD bootstrap"  check_spoke_root_apps          phase4_spoke_gitops_bootstrap
  run_step "Spoke prereq namespaces" check_spoke_prereq_namespaces  phase4_create_spoke_prereq_namespaces
  phase5_cleanup_failed_pods
  phase5_approve_installplans
  phase5_cleanup_failed_pods
  phase5_tune_argocd_resources
  phase5_verify_spoke_apps
  log_ok "=== Day-2 operations complete ==="
  exit 0
fi

case "$PHASE" in
  infra)
    if [ "$DO_CLEANUP" = true ]; then cleanup_vms; fi
    run_step "VM infrastructure"  check_vms_exist       phase1_create_vms
    phase1_setup_dns
    run_step "Sushy emulator"     check_sushy_running   phase1_setup_sushy
    phase1_verify_infra
    ;;
  hub)
    run_step "Hub GitOps bootstrap"   check_hub_gitops_ready   phase2_hub_bootstrap
    phase2_configure_argocd
    phase2_cleanup_stale_apps
    run_step "Hub Docker auth"        check_hub_docker_auth    phase2_patch_hub_docker_auth
    run_step "Hub spoke secrets"      check_hub_secrets        phase2_create_secrets
    run_step "Hub root application"   check_hub_root_app       phase2_apply_root_app
    run_step "ACM fully operational"  check_hub_acm_ready        phase2_wait_acm
    run_step "MinIO operator"         check_minio_operator       phase2_install_minio_operator
    run_step "ForkliftController CRD" check_forklift_crd_patched phase2_patch_forklift_crd
    phase2_approve_hub_installplans
    phase2_scale_down_external_dns
    ;;
  spoke)
    run_step "Spoke provisioning"  check_spokes_installed     phase3_wait_spoke_provisioning
    run_step "Spoke kubeconfigs"   check_spoke_kubeconfigs    phase3_extract_kubeconfigs
    phase3_verify_spokes
    ;;
  day2)
    run_step "Spoke kubeconfigs"       check_spoke_kubeconfigs        phase3_extract_kubeconfigs
    run_step "Spoke ArgoCD bootstrap"  check_spoke_root_apps          phase4_spoke_gitops_bootstrap
    run_step "Spoke prereq namespaces" check_spoke_prereq_namespaces  phase4_create_spoke_prereq_namespaces
    phase5_cleanup_failed_pods
    phase5_approve_installplans
    phase5_cleanup_failed_pods
    phase5_tune_argocd_resources
    phase5_verify_spoke_apps
    ;;
  all)
    if [ "$DO_CLEANUP" = true ]; then cleanup_vms; fi

    log_info "=== Smart resume: detecting current state ==="

    # 1. Hub GitOps + ACM
    run_step "Hub GitOps bootstrap"   check_hub_gitops_ready   phase2_hub_bootstrap
    phase2_configure_argocd
    phase2_cleanup_stale_apps
    run_step "Hub Docker auth"        check_hub_docker_auth    phase2_patch_hub_docker_auth
    run_step "Hub spoke secrets"      check_hub_secrets        phase2_create_secrets
    run_step "Hub root application"   check_hub_root_app       phase2_apply_root_app
    run_step "ACM fully operational"  check_hub_acm_ready      phase2_wait_acm

    # 1b. Hub post-deploy fixes (MinIO, CRD patches, InstallPlans)
    run_step "MinIO operator"         check_minio_operator       phase2_install_minio_operator
    run_step "ForkliftController CRD" check_forklift_crd_patched phase2_patch_forklift_crd
    phase2_approve_hub_installplans
    phase2_scale_down_external_dns

    # 2. VM infrastructure
    run_step "VM infrastructure"  check_vms_exist       phase1_create_vms
    phase1_setup_dns
    run_step "Sushy emulator"     check_sushy_running   phase1_setup_sushy
    phase1_verify_infra

    # 3. Spoke cluster provisioning
    run_step "Spoke provisioning"  check_spokes_installed     phase3_wait_spoke_provisioning
    run_step "Spoke kubeconfigs"   check_spoke_kubeconfigs    phase3_extract_kubeconfigs
    phase3_verify_spokes

    # 4. Day-2 spoke operations
    run_step "Spoke ArgoCD bootstrap"  check_spoke_root_apps          phase4_spoke_gitops_bootstrap
    run_step "Spoke prereq namespaces" check_spoke_prereq_namespaces  phase4_create_spoke_prereq_namespaces
    phase5_cleanup_failed_pods
    phase5_approve_installplans
    phase5_cleanup_failed_pods
    phase5_tune_argocd_resources
    phase5_verify_spoke_apps
    ;;
  *)
    echo "Usage: $0 [--clusters <etl4|both>] [--phase <infra|hub|spoke|day2|all>] [--cleanup] [--day2-only]"
    exit 1
    ;;
esac

# ========================= PHASE 6: POST-DEPLOYMENT TESTS ================

phase6_run_tests() {
  log_info "=== PHASE 6: Post-deployment validation tests ==="

  local SCRIPT_DIR
  SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  local TEST_FILE="${SCRIPT_DIR}/test_deployment.py"
  local REPORT_DIR="/tmp/deployment-reports"
  local REPORT_FILE="${REPORT_DIR}/gitops-e2e-test.html"

  if [ ! -f "$TEST_FILE" ]; then
    # Try the gitops dir on the hypervisor
    TEST_FILE="${GITOPS_DIR}/test_deployment.py"
  fi

  if [ ! -f "$TEST_FILE" ]; then
    log_error "test_deployment.py not found in ${SCRIPT_DIR} or ${GITOPS_DIR}"
    return 1
  fi

  log_info "Installing test dependencies"
  pip3 install --quiet pytest pytest-html 2>/dev/null ||     pip3 install --quiet --user pytest pytest-html 2>/dev/null ||     log_warn "pip3 install failed -- pytest may already be available"

  mkdir -p "${REPORT_DIR}"

  local CLUSTERS_CSV
  CLUSTERS_CSV=$(get_deploy_clusters | tr ' ' ',')

  log_info "Running tests: ${TEST_FILE}"
  log_info "Clusters: ${CLUSTERS_CSV}"
  log_info "Report:   ${REPORT_FILE}"

  set +eo pipefail
  HUB_KUBECONFIG="${HUB_KUBECONFIG}" \
  SPOKE_CLUSTERS="${CLUSTERS_CSV}" \
  SPOKE_KUBECONFIG_DIR="/tmp" \
  EXPECTED_OCP_VERSION="${OCP_VERSION_IMAGE%%.*}.${OCP_VERSION_IMAGE#*.}" \
  python3 -m pytest "${TEST_FILE}" \
    -v \
    --tb=short \
    --html="${REPORT_FILE}" \
    --self-contained-html \
    2>&1 | tee /tmp/pytest-output.log

  local TEST_RC=${PIPESTATUS[0]}
  set -eo pipefail

  if [ $TEST_RC -eq 0 ]; then
    log_ok "All tests passed"
  else
    log_warn "Some tests failed (exit code: $TEST_RC)"
  fi

  log_ok "HTML report: ${REPORT_FILE}"
  return 0
}

echo ""
log_ok "=== Deployment automation complete ==="
echo ""
echo "Summary of deployed clusters:"
for CLUSTER in $(get_deploy_clusters); do
  API_VIP_VAR="${CLUSTER^^}_API_VIP"
  INGRESS_VIP_VAR="${CLUSTER^^}_INGRESS_VIP"
  echo "  ${CLUSTER}: API=${!API_VIP_VAR}, Ingress=${!INGRESS_VIP_VAR}"
done
echo ""
echo "Kubeconfigs (on hypervisor):"
for CLUSTER in $(get_deploy_clusters); do
  echo "  /tmp/${CLUSTER}-kubeconfig"
done
echo ""

if [ "$RUN_TESTS" = true ]; then
  phase6_run_tests
fi

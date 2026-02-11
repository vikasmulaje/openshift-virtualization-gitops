# Spoke1 Cluster Deployment Guide

## What Was Created

I've created a complete spoke cluster configuration structure for `spoke1`:

### Files Created:
1. **Cluster Provisioning** (`clusters/hub/overlays/cluster-spoke1/`):
   - `namespace.yaml` - Namespace for the cluster
   - `kustomization.yaml` - Helm charts for cluster creation
   - `*-baremetal-host.yaml` - 3 bare metal host definitions (masters)
   - `*-nmstate-config.yaml` - Network configuration for each node
   - `*-fqdn.yaml` - DNS entries for each node
   - `readme.md` - Detailed setup instructions

2. **Day-2 Configuration** (`clusters/spoke1/`):
   - `kustomization.yaml` - Cluster-specific ArgoCD app config
   - `values.yaml` - ArgoCD applications for this cluster
   - `overlays/openshift-config/` - Cluster version and console configs

3. **Integration**:
   - Added to `clusters/hub/values.yaml` - Registered with hub ArgoCD
   - Added to `clusters/cluster-versions.yaml` - Version pinning config

## Next Steps to Deploy

### 1. Update Configuration Files

Before deploying, you **must** update these placeholders in the files:

**Bare Metal Hosts** (`*-baremetal-host.yaml`):
- Replace `CHANGE_ME_BMC_IP` with actual BMC IP addresses (3 different IPs)
- Replace `CHANGE_ME_BOOT_MAC` with actual boot MAC addresses (3 different MACs)
- Replace `${PLATFORM_BASE_DOMAIN}` with actual domain (e.g., `qe.lab.redhat.com`)

**NMState Configs** (`*-nmstate-config.yaml`):
- Replace `CHANGE_ME_STATIC_IP` with actual static IPs for each node
- Replace `CHANGE_ME_GATEWAY` with your network gateway
- Replace `CHANGE_ME_MAC_ADDRESS` with actual MAC addresses

**DNS Endpoints** (`*-fqdn.yaml`):
- Replace `CHANGE_ME_STATIC_IP` with actual static IPs
- Replace `${PLATFORM_BASE_DOMAIN}` with actual domain

**Kustomization** (`kustomization.yaml`):
- Verify `ingressVIP` and `apiVIP` are available and not conflicting
- Adjust `podCIDR` and `serviceCIDR` if needed

### 2. Create Required Secrets

On the hub cluster, create the secrets:

```bash
export KUBECONFIG=/home/kni/clusterconfigs/auth/kubeconfig

# Create namespace
oc new-project spoke1

# Create BMC credentials secret
oc create secret generic bmc-credentials -n spoke1 \
  --from-literal=username='<your-bmc-username>' \
  --from-literal=password='<your-bmc-password>'

# Create pull secret (reuse from hub)
oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | \
  base64 -d | oc create secret generic pullsecret-spoke1 \
  -n spoke1 --from-file=.dockerconfigjson=/dev/stdin \
  --type=kubernetes.io/dockerconfigjson
```

### 3. Deploy via ArgoCD (Recommended)

If you have ArgoCD set up on the hub cluster, the cluster will be automatically deployed when you:
1. Commit these changes to your GitOps repository
2. ArgoCD will detect the new application in `clusters/hub/values.yaml`
3. It will apply the helm charts and create the cluster

### 4. Deploy Manually (Alternative)

If you need to deploy manually:

```bash
export KUBECONFIG=/home/kni/clusterconfigs/auth/kubeconfig

# Install helm if not available
# Then apply with kustomize
cd /path/to/repo
oc kustomize --enable-helm clusters/hub/overlays/cluster-spoke1 | oc apply -f -
```

### 5. Monitor Cluster Creation

```bash
# Watch cluster deployment
oc get clusterdeployment -n spoke1
oc get agentclusterinstall -n spoke1
oc get agents -n spoke1

# Check cluster status in ACM
oc get managedclusters
```

## Current Status

✅ **Configuration files created** - All templates are in place
⏳ **Needs customization** - Update placeholders with actual infrastructure details
⏳ **Secrets required** - Create BMC credentials and pull secret
⏳ **Ready for deployment** - Once customized, can be deployed via ArgoCD or manually

## Notes

- The cluster is configured for **3 control plane nodes** (no workers, masters schedulable)
- Using OpenShift version **4.18.12**
- Network CIDRs: Pod `10.132.0.0/14`, Service `172.31.0.0/16`
- VIPs: API `192.168.123.201`, Ingress `192.168.123.200` (verify these are available)

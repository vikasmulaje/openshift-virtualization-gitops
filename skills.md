# OpenShift Virtualization GitOps - Operational Skills & Knowledge Transfer

> Last updated: 2026-03-18 (session with etl4 spoke cluster deployment)
> Audience: Human operators AND LLM assistants (Cursor, Copilot, ChatGPT, etc.)

---

## 0. LLM Quick-Start Context

If you are an LLM picking up this project mid-conversation, read this section first.

### What this project is

A GitOps-managed OpenShift Virtualization lab. A **hub cluster** runs ArgoCD + ACM (Advanced Cluster Management) and manages **spoke clusters** (compact 3-node VMs on a bare-metal hypervisor). ArgoCD on both hub and spoke reads manifests from GitHub. A Jenkins pipeline on GitLab runs the e2e deployment script.

### Two git remotes -- critical distinction

- **GitHub** (`origin`): `git@github.com:vikasmulaje/openshift-virtualization-gitops.git` -- Contains cluster manifests, operator policies, component YAMLs. **ArgoCD reads from here.** Push manifest/policy changes here.
- **GitLab** (`gitlab`): `git@gitlab.cee.redhat.com:certification-qe/openshift-virtualization-gitops.git` -- Contains everything from GitHub PLUS `gitops_pipeline_e2e.sh` and `test_deployment.py`. **Jenkins reads from here.** Push script/test changes here.

**RULE: Never push `gitops_pipeline_e2e.sh` or `test_deployment.py` to GitHub.**

### Branch mapping

| Local branch | Remote | Purpose |
|-------------|--------|---------|
| `main` | `origin/main` (GitHub) | Cluster manifests. ArgoCD source of truth. |
| `gitlab-push` | `gitlab/main` (GitLab) | E2e script + tests + manifests. Jenkins source. |

To edit manifests: `git checkout main`, edit, push to `origin main`.
To edit the e2e script or tests: `git checkout gitlab-push`, edit, push with `git push gitlab gitlab-push:main`.

### How to SSH into the hypervisor

```bash
ssh -o StrictHostKeyChecking=no root@cert-rhosp-01.lab.eng.rdu2.redhat.com
```

### How to run oc commands against clusters (from hypervisor)

```bash
# Hub cluster
export KUBECONFIG=/home/kni/clusterconfigs/auth/kubeconfig

# Spoke etl4
export KUBECONFIG=/tmp/etl4-kubeconfig
```

### Decision rules for LLMs

1. If a user asks to "check cluster status" -- SSH to the hypervisor, set KUBECONFIG, run `oc get nodes`, `oc get mcp`, `oc get applications.argoproj.io -n openshift-gitops`, `oc get pods -A | grep -Ev "Running|Completed|Succeeded"`.
2. If an ArgoCD app is **Degraded** -- check if an OperatorPolicy is NonCompliant (`oc get operatorpolicy -A`). If version mismatch, update the `spec.versions` list in the relevant `components/*/operator-policy.yaml` on GitHub.
3. If an ArgoCD app is **OutOfSync/Missing** -- check if the CRDs exist (`oc get crd <name>`). If not, the prerequisite operator isn't installed.
4. If pods are **Pending/Evicted** -- check node taints (`oc get nodes -o json | ... MemoryPressure`), check MCP rollout (`oc get mcp`), check `kubelet-config.yaml` eviction thresholds.
5. If making a fix on the live cluster -- ALSO update the gitops repo so ArgoCD doesn't revert it. Patch both the cluster AND the YAML.
6. If a pod is stuck **Terminating** and blocking an MCP rollout -- force delete it: `oc delete pod <name> -n <ns> --force --grace-period=0`.
7. When running long SSH commands, use `block_until_ms` appropriately (MCP rollouts take 5-10 min per node).

---

## 1. Project Overview

This repository manages OpenShift Virtualization lab clusters using a GitOps approach (ArgoCD + ACM policies). It provisions and configures:

- A **hub cluster** (`ocp3m0w-ic4s20`) running ACM, ArgoCD, and operator policies
- **Spoke clusters** (`etl4`, `etl6`, `spoke1`) provisioned as compact 3-node VMs via libvirt on a bare-metal hypervisor

### Repository Layout

```
openshift-virtualization-gitops/
├── .bootstrap/                  # GitOps operator Subscription + ClusterRoleBinding
├── clusters/
│   ├── hub/                     # Hub ArgoCD ApplicationSets and overlays
│   │   └── overlays/
│   │       └── cluster-etl4/    # Hub-side app that creates etl4 spoke via ACM
│   ├── etl4/                    # Spoke etl4 app-of-apps (kustomization.yaml, values.yaml)
│   │   └── overlays/            # Per-component overlays (metallb-configuration, nmstate-configuration, openshift-config)
│   ├── etl6/
│   └── spoke1/
├── components/                  # Reusable operator/config building blocks
│   ├── openshift-virtualization-operator/
│   │   └── operator-policy.yaml # ACM OperatorPolicy -- has spec.versions list
│   ├── openshift-virtualization-instance/
│   │   └── kubelet-config.yaml  # KubeletConfig -- eviction thresholds
│   ├── mtv-operator/
│   │   └── operator-policy.yaml
│   ├── node-health-check-operator/
│   │   ├── nhc-operator-policy.yaml
│   │   ├── far-operator-policy.yaml
│   │   └── snr-operator-policy.yaml
│   ├── metallb-operator/
│   ├── metallb-configuration/
│   ├── nmstate-instance/
│   ├── nmstate-configuration/
│   ├── cert-manager-operator/
│   ├── cert-manager-configuration/
│   ├── descheduler-operator/
│   ├── descheduler-configuration/
│   ├── external-dns-operator/
│   ├── external-dns-configuration/
│   ├── aap-operator/
│   ├── aap-configuration/
│   ├── acm-operator/
│   ├── acm-instance/
│   ├── acm-configuration/
│   ├── acm-observability/
│   ├── mtv-configuration/
│   └── ...
├── groups/                      # Cluster group definitions
├── gitops_pipeline_e2e.sh       # E2E script (GITLAB ONLY -- do not push to GitHub)
├── test_deployment.py           # Pytest validation (GITLAB ONLY)
└── skills.md                    # This file
```

---

## 2. Infrastructure

### Hypervisor

- **Host**: `cert-rhosp-01.lab.eng.rdu2.redhat.com`
- **Access**: `ssh root@cert-rhosp-01.lab.eng.rdu2.redhat.com`
- **Libvirt network**: `ocp3m0w-ic4s20` (DNS, DHCP, VM networking)
- **Sushy emulator**: Podman container for BMC emulation (virtual Redfish). Uses dynamically detected libvirt socket (`/var/run/libvirt/virtqemud-sock` or `/var/run/libvirt/libvirt-sock`).

### Kubeconfig Locations (on hypervisor)

| Cluster | Kubeconfig Path |
|---------|----------------|
| Hub | `/home/kni/clusterconfigs/auth/kubeconfig` |
| etl4 spoke | `/tmp/etl4-kubeconfig` |

To extract a spoke kubeconfig from hub:
```bash
export KUBECONFIG=/home/kni/clusterconfigs/auth/kubeconfig
oc get secret -n etl4 etl4-admin-kubeconfig -o jsonpath='{.data.kubeconfig}' | base64 -d > /tmp/etl4-kubeconfig
```

### Spoke VMs

- 3 compact nodes (control-plane + worker roles combined) per spoke
- **Memory**: 48GB per VM (`VM_MEMORY_KB=50331648` in e2e script)
- **QEMU machine type**: Auto-detected by `detect_qemu_machine_type()` via `virsh capabilities`
- **Watchdog model**: `i6300esb` (do NOT use `itco` -- unsupported on QEMU)

---

## 3. Current Cluster State (as of 2026-03-18)

### Hub Cluster (OCP 4.20.14)

- 3 nodes, all Ready, healthy
- 0 non-running pods
- ArgoCD apps: All Synced/Healthy. `root-applications` is OutOfSync which is normal (it's an app-of-apps parent).
- Managed clusters: `etl4` (Available), `etl6` (Unknown), `spoke1` (Unknown)

### Spoke etl4 (OCP 4.20.14)

- 3 nodes, all Ready, MemoryPressure=False
- MCP fully updated (3/3)

**ArgoCD app status:**

| App | Sync | Health | Root Cause if not Synced/Healthy |
|-----|------|--------|--------------------------------|
| descheduler-configuration | Synced | Healthy | -- |
| descheduler-operator | Synced | Healthy | -- |
| hyperconverged-instance | Synced | Healthy | -- |
| node-health-check-operator | Synced | Healthy | -- |
| node-health-check-configuration | Synced | Healthy | -- |
| openshift-virtualization | Synced | Healthy | -- |
| root-applications | OutOfSync | Healthy | Normal for app-of-apps |
| metallb-configuration | OutOfSync | Healthy | `metallb-operator` not installed on spoke. CRDs `metallbs.metallb.io`, `ipaddresspools.metallb.io` missing. |
| nmstate-configuration | OutOfSync | Healthy | `kubernetes-nmstate-operator` not installed on spoke. CRD `nodenetworkconfigurationpolicies.nmstate.io` missing. |
| openshift-config | OutOfSync | Missing | `openshift-cert-manager-operator` not installed on spoke. CRD `certificates.cert-manager.io` missing. |

**Pending action**: `kubevirt-hyperconverged-operator.v4.20.8` InstallPlan awaiting approval in `openshift-cnv` namespace.

---

## 4. Known Issues & Workarounds

### 4.1 metal3-image-customization CrashLoopBackOff (OCP 4.20.11+)

- **Red Hat bug**: Solution 7137547
- **Error**: `/bin/copy-metal: line 43: /coreos/coreos-aarch64.iso.sha256: Read-only file system`
- **Affected**: All OCP 4.20.11+ clusters with `provisioningNetwork: Disabled`
- **Impact**: Low -- pod not needed when `provisioningNetwork: Disabled`
- **Workaround**: Patch deployment with pre-init container that copies `/coreos` to emptyDir, then overlay writable emptyDir at `/coreos`. See section 6 for exact command.
- **Caveat**: Cluster Baremetal Operator (CBO) reverts the patch within minutes. The e2e script function `phase5_fix_metal3_image_customization()` re-applies it.
- **Permanent fix**: Upgrade OCP when z-stream fix ships.

### 4.2 MetalLB, NMState, cert-manager NOT Installed on Spoke

- **Root cause**: ACM OperatorPolicies for these operators exist in `open-cluster-management-policies` namespace (hub-scoped), but no PlacementBindings target spoke clusters like `etl4`.
- **Evidence**: `oc get subscription -A` on spoke returns empty. `oc get crd metallbs.metallb.io` returns NotFound.
- **Fix needed**: Create ACM PlacementRules/PlacementBindings in the gitops repo to propagate these operator installations to spoke clusters. This is a gitops repo change in `clusters/hub/` or `components/`.

### 4.3 KubeletConfig Eviction Threshold

- **File**: `components/openshift-virtualization-instance/kubelet-config.yaml`
- **Was**: `evictionSoft.memory.available: "50Gi"` (impossible threshold on 48GB VMs -> perpetual MemoryPressure)
- **Fixed to**: `"2Gi"` (committed to GitHub `origin/main`)
- **If you see MemoryPressure on nodes**: Check this file first. Also verify on cluster: `oc get kubeletconfig set-virt-values -o json | python3 -c "import sys,json; print(json.load(sys.stdin)['spec']['kubeletConfig']['evictionSoft'])"`

### 4.4 OperatorPolicy Version Drift

- **Pattern**: OLM upgrades an operator (e.g., `v4.20.7` -> `v4.20.8`). The ACM OperatorPolicy only lists old versions in `spec.versions`. Policy becomes `NonCompliant`. ArgoCD app shows `Degraded`.
- **Files that need version updates** (on GitHub `origin/main`):
  - `components/openshift-virtualization-operator/operator-policy.yaml` -- kubevirt versions
  - `components/mtv-operator/operator-policy.yaml` -- mtv-operator versions
  - `components/node-health-check-operator/nhc-operator-policy.yaml`
  - `components/node-health-check-operator/far-operator-policy.yaml`
  - `components/node-health-check-operator/snr-operator-policy.yaml`
- **How to fix**: Add the new version string to the `spec.versions` array. Push to GitHub. Optionally patch cluster directly for immediate effect.

### 4.5 ArgoCD Sync Timeout / Stale operationState

- **Symptom**: App stuck retrying with `application controller sync timeout` or `force cannot be used with --server-side`.
- **Cause**: `status.operationState` has stale `force: true` conflicting with `ServerSideApply=true`.
- **Fix**: Remove `status.operationState` and `operation` fields from the Application object. See section 6 for exact command.

### 4.6 external-dns CrashLoopBackOff

- **Cause**: No accessible DNS server in the lab.
- **Fix**: `oc scale deployment external-dns -n external-dns --replicas=0` (automated in e2e script `phase2_scale_down_external_dns`).

### 4.7 ova-server NFS Mount Failures

- **Cause**: `external-dns` scaled down -> NFS PV hostname unresolvable. Also `/ovas` export path doesn't exist on NFS server.
- **Fix** (automated in `phase2_fix_ova_server_nfs()`):
  1. Add DNS host entry to libvirt network via `virsh net-update`
  2. Create `/ovas` in `nfs-server` pod, add to `/etc/exports`
  3. Restart `ova-server` pod

---

## 5. E2E Pipeline Script (`gitops_pipeline_e2e.sh`)

### Running Modes

```bash
# Full end-to-end (typically from Jenkins)
./gitops_pipeline_e2e.sh --host cert-rhosp-01.lab.eng.rdu2.redhat.com \
  --network ocp3m0w-ic4s20 --clusters etl4

# Local mode on hypervisor
./gitops_pipeline_e2e.sh --local --host cert-rhosp-01.lab.eng.rdu2.redhat.com \
  --network ocp3m0w-ic4s20 --clusters etl4

# Day-2 fixes only (no infra/install)
./gitops_pipeline_e2e.sh --local --host cert-rhosp-01.lab.eng.rdu2.redhat.com \
  --network ocp3m0w-ic4s20 --clusters etl4 --day2-only

# Tests only
./gitops_pipeline_e2e.sh --local --host cert-rhosp-01.lab.eng.rdu2.redhat.com \
  --network ocp3m0w-ic4s20 --clusters etl4 --test
```

### Phases

| Phase | Key Functions | What It Does |
|-------|--------------|--------------|
| 1 | `phase1_generate_vm_xml`, `phase1_setup_sushy` | VM creation, sushy BMC emulator |
| 2 | `phase2_hub_bootstrap`, `phase2_configure_argocd`, `phase2_hub_post_deploy_fixes` | Hub ArgoCD, secrets, ACM, operator fixes |
| 3 | `phase3_wait_spoke_provisioning`, `phase3_extract_kubeconfigs` | Wait for spoke install, get kubeconfigs |
| 4 | `phase4_spoke_gitops_bootstrap`, `phase4_create_spoke_prereq_namespaces` | Spoke ArgoCD setup |
| 5 | `phase5_cleanup_failed_pods`, `phase5_approve_installplans`, `phase5_tune_argocd_resources`, `phase5_fix_metal3_image_customization`, `phase5_verify_spoke_apps` | Day-2 operations |
| 6 | `phase6_run_tests` | Pytest with HTML report |

### Smart Resume Pattern

```bash
run_step "Step name"  check_function  run_function
```
If `check_function` returns 0, step is skipped with "SKIP: already done". This makes the script idempotent and safe to re-run.

### Key Helper Functions

- `hub_oc "command"` -- runs `oc` against hub cluster
- `spoke_oc <cluster> "command"` -- runs `oc` against a spoke cluster
- `ssh_hyp "command"` -- runs command on hypervisor via SSH
- `wait_for_condition "desc" "check_cmd" timeout` -- polls until condition is true

---

## 6. Common Operations (Copy-Paste Commands)

### Quick cluster health check

```bash
ssh root@cert-rhosp-01.lab.eng.rdu2.redhat.com '
  echo "=== HUB ===" &&
  export KUBECONFIG=/home/kni/clusterconfigs/auth/kubeconfig &&
  oc get nodes && oc get applications.argoproj.io -n openshift-gitops &&
  echo "=== SPOKE etl4 ===" &&
  export KUBECONFIG=/tmp/etl4-kubeconfig &&
  oc get nodes && oc get mcp &&
  oc get applications.argoproj.io -n openshift-gitops &&
  oc get pods -A --no-headers | grep -Ev "Running|Completed|Succeeded"
'
```

### Approve a pending InstallPlan

```bash
oc patch installplan <NAME> -n <NAMESPACE> --type merge -p '{"spec":{"approved":true}}'
```

### Clear stuck ArgoCD operationState

```bash
oc get applications.argoproj.io <APP> -n openshift-gitops -o json | python3 -c "
import sys, json
app = json.load(sys.stdin)
app['status'].pop('operationState', None)
app.pop('operation', None)
json.dump(app, sys.stdout)
" | oc replace -f -
```

### Fix metal3-image-customization (apply writable /coreos overlay)

```bash
oc get deployment metal3-image-customization -n openshift-machine-api -o json | python3 -c "
import sys, json
dep = json.load(sys.stdin)
spec = dep['spec']['template']['spec']
img = None
for ic in spec.get('initContainers', []):
    if ic['name'] == 'machine-os-images':
        img = ic['image']
        mounts = ic.get('volumeMounts', [])
        if not any(m['mountPath'] == '/coreos' for m in mounts):
            mounts.append({'name': 'coreos-rw', 'mountPath': '/coreos'})
        if not any(m['mountPath'] == '/coreos.orig' for m in mounts):
            mounts.append({'name': 'coreos-orig', 'mountPath': '/coreos.orig'})
        ic['volumeMounts'] = mounts
        ic['command'] = ['/bin/sh', '-c', 'cp -a /coreos.orig/* /coreos/ 2>/dev/null; exec /bin/copy-metal --all /shared/html/images']
pre = {'name': 'copy-coreos-files', 'image': img,
       'command': ['/bin/sh', '-c', 'cp -a /coreos/* /coreos-orig/'],
       'volumeMounts': [{'name': 'coreos-orig', 'mountPath': '/coreos-orig'}],
       'resources': {'requests': {'cpu': '5m', 'memory': '50Mi'}},
       'securityContext': {'privileged': True, 'capabilities': {'drop': ['ALL']}}}
inits = spec.get('initContainers', [])
if not any(ic['name'] == 'copy-coreos-files' for ic in inits):
    inits.insert(0, pre)
spec['initContainers'] = inits
vols = spec.get('volumes', [])
if not any(v['name'] == 'coreos-rw' for v in vols):
    vols.extend([{'name': 'coreos-rw', 'emptyDir': {}}, {'name': 'coreos-orig', 'emptyDir': {}}])
spec['volumes'] = vols
json.dump(dep, sys.stdout)
" | oc replace -f -
# Then clean up crashing pods from the old RS:
oc delete pods -n openshift-machine-api -l k8s-app=metal3-image-customization --field-selector status.phase!=Running --force --grace-period=0
```

---

## 7. Remaining Work / Next Steps

1. **Install MetalLB, NMState, cert-manager on spoke** -- Create ACM PlacementBindings/PolicySets targeting `etl4`. Without this, 3 ArgoCD apps remain OutOfSync.
2. **Approve kubevirt v4.20.8 InstallPlan** on etl4 (`openshift-cnv` namespace), then update `components/openshift-virtualization-operator/operator-policy.yaml` on GitHub.
3. **etl6 and spoke1 clusters** -- both show `Unknown` on hub. Need provisioning or cleanup.
4. **metal3 permanent fix** -- wait for OCP z-stream with bug fix (Red Hat solution 7137547).
5. **descheduler-operator** -- pods run briefly then exit. Operator behavior, not a bug. `phase5_cleanup_failed_pods` handles periodic cleanup.

---

## 8. Troubleshooting Cheat Sheet

| Symptom | Likely Cause | Quick Fix |
|---------|-------------|-----------|
| ArgoCD app **Degraded** | OperatorPolicy NonCompliant (version mismatch) | Add new version to `spec.versions` in `components/*/operator-policy.yaml`, push to GitHub |
| ArgoCD app **OutOfSync/Missing** | CRDs don't exist (operator not installed) | Install the prerequisite operator on the target cluster |
| ArgoCD stuck **retrying sync** | Stale operationState | Clear operationState (see section 6) |
| Nodes **MemoryPressure** | KubeletConfig `evictionSoft.memory.available` too high | Check `kubelet-config.yaml`, must be `"2Gi"` not `"50Gi"` |
| Pods **Pending/Evicted** | Memory pressure or MCP rollout | Wait for MCP; check node taints with `oc describe node` |
| **metal3-image-customization** CrashLoop | OCP 4.20.11+ bug (read-only /coreos) | Apply writable overlay (section 6); CBO will revert, re-apply as needed |
| **ova-server** ContainerCreating | NFS hostname unresolvable or /ovas missing | Run `phase2_fix_ova_server_nfs` or fix DNS + NFS manually |
| **external-dns** CrashLoop | No DNS server in lab | Scale to 0: `oc scale deployment external-dns -n external-dns --replicas=0` |
| **InstallPlan** RequiresApproval | OLM upgrade needs manual approval | `oc patch installplan <name> -n <ns> --type merge -p '{"spec":{"approved":true}}'` |
| Pods stuck **Terminating** (blocking MCP) | PDB or finalizer | `oc delete pod <name> -n <ns> --force --grace-period=0` |
| **Subscription** empty on spoke | Operators deployed via ACM policies, not local subscriptions | Check OperatorPolicy on hub and PlacementBindings |

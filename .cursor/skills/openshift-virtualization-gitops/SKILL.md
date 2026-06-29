---
name: openshift-virtualization-gitops
description: >-
  Domain knowledge for the OpenShift Virtualization GitOps project. Covers
  architecture, repo structure, e2e automation script, Jenkins CI pipeline,
  branching strategy, ACM spoke provisioning, ArgoCD CMP patterns, and
  troubleshooting. Use when working on GitOps manifests, modifying the e2e
  script, debugging deployment failures, adding operators, creating new spoke
  clusters, or updating Jenkins pipeline configuration.
---

# OpenShift Virtualization GitOps

## Project Overview

A GitOps-driven deployment platform for OpenShift Virtualization using ArgoCD app-of-apps with ACM spoke provisioning. Deploys 25+ operators across hub + spoke clusters from a single Git repo.

**Key technologies:** ArgoCD, ACM (Advanced Cluster Management), Assisted Installer, CMP (Custom Management Plugin) with `envsubst`, Kustomize, Helm.

For the full project report, see [GITOPS-VIRTUALIZATION-COMPLETION-REPORT.md](../../../GITOPS-VIRTUALIZATION-COMPLETION-REPORT.md).

## Architecture

```
Hub Cluster (ArgoCD + ACM)
  ├── root-applications (Helm app-of-apps)
  │   ├── Wave 5:  ACM, Reflector, MTV operators
  │   ├── Wave 15: ACM Instance, MTV Config (ForkliftController)
  │   ├── Wave 20: cert-manager, MetalLB, NMState, AAP, spoke definitions
  │   ├── Wave 25: ACM Config, Observability, operator CRs, OVA server
  │   └── Wave 30: kube-ops-view, web-terminal
  │
  └── Spoke Clusters (etl4, etl6) — provisioned via ACM Assisted Installer
      └── Spoke ArgoCD (bootstrapped by ACM policy + e2e script)
          ├── Wave 5:  OCP-Virt, Descheduler, NodeHealthCheck operators
          ├── Wave 15: HyperConverged, KubeDescheduler, NHC CRs
          ├── Wave 20: cert-manager, MetalLB, NMState (shared)
          └── Wave 25: Operator instance configs
```

ArgoCD uses a CMP sidecar that runs `kustomize build | envsubst` — variables like `${CLUSTER_NAME}`, `${CLUSTER_BASE_DOMAIN}`, `${NETWORK_SUBNET}` are substituted at sync time from the `environment-variables` ConfigMap in `.bootstrap/argocd.yaml`.

## Repository Structure

```
.bootstrap/               Day-0 manifests applied by e2e script
  subscription.yaml       Install GitOps operator
  argocd.yaml             ArgoCD config + CMP sidecar + environment-variables ConfigMap
  root-application.yaml   App-of-apps entry point
  cluster-rolebinding.yaml

.helm-charts/              Reusable Helm charts
  argocd-app-of-app/       Generates Application CRs from values.yaml
  bm-cluster-agent-install/ ACM/Assisted Installer resources
  cluster-registration/    ManagedCluster + MTV Provider + ServiceAccounts

clusters/                  Per-cluster overrides
  hub/                     Hub: ACM, MTV, AAP, spoke definitions
    values.yaml            List of ArgoCD apps for hub (used by app-of-app chart)
    overlays/              Cluster-specific Kustomize overlays (BMH, NMState)
  etl4/                    ETL4 spoke overrides
  etl6/                    ETL6 spoke overrides

groups/                    Shared app definitions
  all/                     Apps for ALL clusters
  prod/                    Apps for SPOKE clusters only

components/                25+ reusable K8s manifest sets (operators + configs)

gitops_pipeline_e2e.sh     E2E automation script (~1750 lines, GitLab only)
test_deployment.py         pytest validation suite (GitLab only)
Jenkinsfile                Jenkins pipeline definition (GitLab only)
```

## Git Repositories and Hygiene

| Repo | URL | Contains |
|------|-----|----------|
| **GitLab** (internal) | `gitlab.cee.redhat.com/certification-qe/openshift-virtualization-gitops` | Everything: manifests + e2e script + Jenkinsfile + tests |
| **GitHub** (public) | `github.com/<your-fork>/openshift-virtualization-gitops` | Clean manifests only — NO scripts, NO credentials |
| **Upstream** | `github.com/redhat-developer/openshift-virtualization-gitops` | Original reference implementation |

**CRITICAL:** Never push `gitops_pipeline_e2e.sh`, `gitops_pipeline_multicluster-e2e.sh`, `Jenkinsfile`, or any credentials to GitHub. These files are in `.gitignore`.

## Branching Strategy

| Branch | OCP Version | Libvirt Network | Subnet Fallback |
|--------|------------|-----------------|-----------------|
| `main` | 4.20 (GA) | `ocp3m0w-ic4s20` | `192.168.135` |
| `openshift-4.21` | 4.21 (GA) | `ocp3m0w-ic4s21` | `192.168.135` |
| `openshift-4.22` | 4.22 (Nightly) | `ocp3m0w-ic4n22` | `192.168.134` |
| `disconnected` | 4.20 | Same as main | Image tags → SHA digests |

Branch selection auto-configures network, subnet, and ClusterImageSet via `init_network_profile()` in the e2e script.

## E2E Automation Script

**File:** `gitops_pipeline_e2e.sh` — 6-phase deployment pipeline.

### Phases

1. **Infrastructure** — Create KVM VMs, DNS in `/etc/hosts`, sushy-emulator (Redfish BMC)
2. **Hub Bootstrap** — GitOps operator → ArgoCD + CMP → root application → 25+ apps auto-sync
3. **Spoke Provisioning** — Monitor ACM Assisted Installer until 100%; nightly builds: fix `policy.json` on nodes
4. **Spoke Bootstrap** — ACM policy installs GitOps on spokes; script configures spoke ArgoCD
5. **Day-2 Operations** — Clean failed pods, approve InstallPlans, tune ArgoCD resources
6. **Validation Tests** — Run `test_deployment.py`, generate HTML report

### Common Usage

```bash
# Full e2e with tests
./gitops_pipeline_e2e.sh --local --branch main --clusters etl4 --test

# With VM cleanup
./gitops_pipeline_e2e.sh --local --branch openshift-4.22 --clusters etl4 --cleanup --test

# Day-2 only
./gitops_pipeline_e2e.sh --local --day2-only --clusters etl4

# Individual phases
./gitops_pipeline_e2e.sh --local --phase hub
./gitops_pipeline_e2e.sh --local --phase spoke
```

### Key Functions

- `init_network_profile()` — Sets network/subnet/image per branch
- `phase1_create_vms()` — VM creation + DNS + sushy
- `phase2_bootstrap_hub()` — Hub ArgoCD setup
- `phase3_wait_spoke()` — ACM provisioning monitor with nightly workarounds
- `phase4_bootstrap_spoke()` — Spoke ArgoCD configuration
- `phase5_day2_operations()` — Post-install cleanup + approval
- `phase6_run_tests()` — pytest execution (requires `--test` flag)
- `get_deploy_clusters()` — Returns cluster list based on `--clusters` param
- `ssh_hyp` — SSH wrapper for hypervisor commands
- `run_cmd` — Command wrapper using `sudo -E PATH="$PATH"` for Jenkins

## Jenkins CI Pipeline

**Jenkins:** `jenkins-csb-kniqe-ci.dno.corp.redhat.com`

### Job Hierarchy

```
CI/gitops-deploy (profile, every Wednesday, ~85 min)
  ├── #0 Infra/cleanup-all-terraform    → Wipe Terraform state
  ├── #1 Infra/factory-cluster-clone    → Deploy fresh HUB OCP cluster
  └── #2 spoke-gitops-deploy            → E2E script + tests + Slack
```

### spoke-gitops-deploy Parameters

| Parameter | Default | Purpose |
|-----------|---------|---------|
| `HOST` | (required) | Hypervisor hostname |
| `LIBVIRT_NETWORK` | `ocp3m0w-ic4s20` | Libvirt network from Hub |
| `GITOPS_BRANCH` | `main` | Git branch to deploy |
| `CLUSTERS` | `etl4` | Spokes: `etl4` or `both` |
| `CLEANUP` | `false` | Destroy existing VMs first |
| `TEST` | `true` | Run validation tests |
| `SLACK_CHANNEL` | `eco-ci-reporting` | Notification channel |

Post-actions: archive `gitops-e2e-test.html`, publish via `publishHTML`, Slack notification.

## Common Tasks

### Adding a New Operator to Spoke Clusters

1. Create `components/<operator-name>/` with Kustomize manifests (Subscription, OperatorGroup, CR)
2. Add entry in `groups/prod/` (or `groups/all/` if hub also needs it)
3. Set appropriate sync wave in annotations
4. Add to `clusters/<cluster>/values.yaml` app list
5. Commit to GitLab, push to GitHub (manifests only)

### Adding a New Spoke Cluster

1. Copy an existing overlay dir (e.g., `clusters/hub/overlays/cluster-etl4/`) to new name
2. Update BMH, NMStateConfig with correct MACs, hostnames, IPs (use `${NETWORK_SUBNET}` template)
3. Add cluster entry in `clusters/hub/values.yaml`
4. Create `clusters/<new-cluster>/` with values.yaml for spoke apps
5. Update `get_deploy_clusters()` in e2e script
6. Add DNS pattern in `phase1_setup_dns()`

### Adding a New OCP Version Branch

1. Create branch: `git checkout -b openshift-4.XX main`
2. Add case in `init_network_profile()` with correct network, subnet, image
3. Update `ClusterImageSet` if needed
4. Test: `./gitops_pipeline_e2e.sh --local --branch openshift-4.XX --clusters etl4`

### Enabling CMP (envsubst) for an Application

1. In `clusters/<cluster>/values.yaml`, add to the app entry:
   ```yaml
   extraSourceFields: |
     plugin: {}
   ```
2. Use `${VAR_NAME}` in the component's manifests
3. Ensure the variable exists in `environment-variables` ConfigMap (`.bootstrap/argocd.yaml`)
4. After changing ConfigMap: flush ArgoCD Redis cache and hard-refresh apps

## Known Gotchas and Troubleshooting

### ArgoCD shows stale/unexpanded manifests
Flush Redis and hard-refresh:
```bash
oc exec -n openshift-gitops argocd-redis-<pod> -- redis-cli FLUSHALL
oc annotate app <app-name> -n openshift-gitops argocd.argoproj.io/refresh=hard
```

### Nightly build nodes crash-loop (CRI-O signature errors)
The e2e script auto-handles this for `openshift-4.22` branch. Manual fix:
```bash
ssh core@<node> "sudo sed -i 's/\"reject\"/\"insecureAcceptAnything\"/g' /etc/containers/policy.json && sudo systemctl restart crio"
```

### Subnet mismatch after hypervisor rebuild
The e2e script auto-detects via `virsh net-dumpxml`. If manual: check `virsh net-dumpxml <network>` for the actual subnet and update `environment-variables` ConfigMap.

### DNS entries point to old VIPs after reprovisioning
The e2e script's `phase1_setup_dns()` auto-cleans stale entries. Manual: `sed -i` delete old entries from `/etc/hosts` before adding new ones.

### Jenkins agent permission errors
The `run_cmd()` wrapper uses `sudo -E PATH="$PATH"` to preserve env. If adding new commands that need root, wrap them with `run_cmd`.

### spoke-gitops-deploy test report missing
Ensure `--test` flag is passed and `test_deployment.py` exists in the repo. The report is generated at `/tmp/deployment-reports/gitops-e2e-test.html`.

## Validation Tests

**File:** `test_deployment.py` — 6 test classes, 30+ test cases.

```bash
HUB_KUBECONFIG=/path/to/hub/kubeconfig \
SPOKE_CLUSTERS=etl4 \
EXPECTED_OCP_VERSION=4.20 \
  pytest test_deployment.py -v --html=report.html --self-contained-html
```

| Test Class | Validates |
|-----------|-----------|
| `TestHubAppStatus` | ArgoCD apps synced and healthy |
| `TestHubClusterHealth` | ClusterVersion, node readiness |
| `TestHubOperatorStatus` | ClusterOperators, CSVs |
| `TestFleetClusterStatus` | ManagedClusters, AgentClusterInstall |
| `TestSpokeClusterHealth` | Spoke ClusterVersion, nodes |
| `TestSpokeOperatorStatus` | Spoke operators, CSVs |

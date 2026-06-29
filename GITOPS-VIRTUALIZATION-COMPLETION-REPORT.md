# OpenShift Virtualization GitOps -- Project Completion Report

**Author:** Vikas Mulaje
**Date:** June 2026
**Status:** Completed and in Production CI

---

## Table of Contents

- [1. Problem Statement](#1-problem-statement)
- [2. What Was Required](#2-what-was-required)
- [3. Solution Overview](#3-solution-overview)
- [4. Architecture](#4-architecture)
- [5. Repository Structure](#5-repository-structure)
- [6. Git Repositories](#6-git-repositories)
- [7. Branching Strategy](#7-branching-strategy)
- [8. What Gets Deployed (25+ Components)](#8-what-gets-deployed-25-components)
- [9. End-to-End Automation Script](#9-end-to-end-automation-script)
- [10. Jenkins CI Pipeline](#10-jenkins-ci-pipeline)
- [11. Post-Deployment Validation Tests](#11-post-deployment-validation-tests)
- [12. Key Technical Challenges Solved](#12-key-technical-challenges-solved)
- [13. Disconnected Cluster Support](#13-disconnected-cluster-support)
- [14. DevConf US 2026 Talk](#14-devconf-us-2026-talk)
- [15. Future Work](#15-future-work)

---

## 1. Problem Statement

Deploying OpenShift Virtualization at enterprise scale requires provisioning multi-cluster infrastructure (hub + spoke clusters), installing 25+ operators across them, and ensuring the entire stack is reproducible, auditable, and drift-free. Manually performing these steps is error-prone, time-consuming, and not scalable.

The upstream reference implementation ([redhat-developer/openshift-virtualization-gitops](https://github.com/redhat-developer/openshift-virtualization-gitops)) provides the GitOps manifests but lacked:

- **Automated end-to-end deployment** -- no single command could stand up the full stack
- **CI/CD integration** -- no Jenkins pipeline for continuous validation
- **Multi-version support** -- no mechanism to deploy different OCP versions (4.20, 4.21, 4.22) from the same codebase
- **Nightly build compatibility** -- nightly/pre-release OCP builds have unsigned container images that break node bootstrapping
- **Environment portability** -- hardcoded network subnets prevented deployment across different hypervisors
- **Post-deployment validation** -- no automated testing to verify deployment health
- **Disconnected cluster support** -- image tags prevented use in air-gapped environments

## 2. What Was Required

1. Fork the upstream GitOps repository and adapt it for our QE lab infrastructure
2. Create an end-to-end automation script that deploys the full stack from scratch
3. Integrate with Jenkins for CI pipeline execution
4. Support multiple OCP versions via Git branching
5. Handle nightly build quirks (unsigned images, MCO degradation)
6. Add post-deployment validation tests
7. Templatize environment-specific values (network subnets) for portability
8. Prepare image SHA digests for disconnected/air-gapped deployments
9. Maintain separation between internal (GitLab) and public (GitHub) repositories

## 3. Solution Overview

The solution is a **GitOps-driven, fully automated deployment platform** for OpenShift Virtualization built on:

- **ArgoCD** as the GitOps engine on both hub and spoke clusters
- **ACM (Advanced Cluster Management)** for spoke cluster provisioning via Assisted Installer
- **App-of-Apps pattern** with sync waves for ordered deployment of 25+ components
- **CMP (Custom Management Plugin)** for runtime environment variable substitution
- **Bash automation script** (`gitops_pipeline_e2e.sh`) orchestrating 6 phases
- **Jenkins pipeline** for CI execution with Slack notifications and HTML test reports
- **pytest-based validation suite** (`test_deployment.py`) for post-deployment health checks

### End-to-End Flow

```
Empty Hypervisor
    |
    v
[Phase 1] Create VMs + DNS + Sushy BMC emulator
    |
    v
[Phase 2] Bootstrap Hub: GitOps operator → ArgoCD + CMP → Root Application
    |                                                          |
    |                                         ArgoCD auto-syncs 25+ apps
    |                                         (ACM, MTV, MetalLB, NMState...)
    v
[Phase 3] ACM provisions spoke clusters via Assisted Installer
    |       (Nightly builds: auto-fix image signature policy on nodes)
    v
[Phase 4] Bootstrap Spoke ArgoCD via ACM policy + script configuration
    |
    v
[Phase 5] Spoke ArgoCD deploys day-2 operators
    |       (OpenShift Virtualization, Descheduler, NodeHealthCheck...)
    v
[Phase 6] Post-deployment validation tests → HTML report
    |
    v
Complete: Hub + 2 Spoke clusters with full virtualization stack
```

## 4. Architecture

### Hub-and-Spoke Topology

```
+-------------------------------------------------------------------------------------+
|                        Git Repository (Single Source of Truth)                        |
|   clusters/hub/     clusters/etl4/     clusters/etl6/     groups/    components/     |
+--------+------------------+------------------+--------------------------------------+
         |                  |                  |
         v                  v                  v
+-----------------+  +--------------+  +--------------+
|   HUB CLUSTER   |  |  ETL4 SPOKE  |  |  ETL6 SPOKE  |
|   (OCP 4.20+)   |  |  (OCP 4.20+) |  |  (OCP 4.20+) |
|                  |  |              |  |              |
|  ArgoCD (Hub)    |  | ArgoCD       |  | ArgoCD       |
|  ACM             |  | (Spoke)      |  | (Spoke)      |
|  MTV             |  |              |  |              |
|  AAP             |  | OCP-Virt     |  | OCP-Virt     |
|                  |  | MetalLB      |  | MetalLB      |
|  3 Masters       |  | 3 Masters    |  | 3 Masters    |
+-----------------+  +--------------+  +--------------+
```

### ArgoCD App-of-Apps with CMP

ArgoCD on each cluster uses a `root-applications` Application (Helm-generated app-of-apps) combined with a CMP sidecar that runs `kustomize build | envsubst` at sync time. This allows a single set of reusable components to target any cluster by substituting variables like `${CLUSTER_NAME}`, `${CLUSTER_BASE_DOMAIN}`, and `${NETWORK_SUBNET}`.

### Spoke Provisioning via ACM + Assisted Installer

Hub ArgoCD syncs `BareMetalHost`, `ClusterDeployment`, `InfraEnv`, and `NMStateConfig` resources. ACM's Assisted Installer generates a discovery ISO, boots VMs via Redfish (sushy-emulator), and installs OCP on the spoke nodes. Once complete, ACM's GitOps bootstrap policy installs ArgoCD on the spoke, and the script configures it with the spoke-specific root application.

## 5. Repository Structure

```
openshift-virtualization-gitops/
|
+-- .bootstrap/                    Day-0: Applied by script to seed ArgoCD
|   +-- subscription.yaml         Install GitOps operator
|   +-- argocd.yaml               Configure ArgoCD + CMP sidecar + env vars ConfigMap
|   +-- root-application.yaml     App-of-apps entry point
|   +-- cluster-rolebinding.yaml  RBAC for ArgoCD
|
+-- .helm-charts/                  Reusable Helm charts
|   +-- argocd-app-of-app/        Generates ArgoCD Application CRs from values.yaml
|   +-- bm-cluster-agent-install/ Renders ACM/Assisted Installer resources
|   +-- cluster-registration/     ManagedCluster + MTV Provider + ServiceAccounts
|
+-- clusters/                      What ArgoCD deploys WHERE
|   +-- hub/                      Hub-specific: ACM, MTV, AAP, spoke definitions
|   +-- etl4/                     ETL4 spoke-specific overrides
|   +-- etl6/                     ETL6 spoke-specific overrides
|
+-- groups/                        Shared app definitions
|   +-- all/                      Apps for ALL clusters (cert-manager, MetalLB, NMState)
|   +-- prod/                     Apps for SPOKE clusters only (OCP-Virt, Descheduler, NHC)
|
+-- components/                    25+ reusable K8s manifest sets
|   +-- acm-operator/             ACM Subscription + OperatorGroup
|   +-- openshift-virtualization-operator/  OCP-Virt OperatorPolicy
|   +-- metallb-operator/         MetalLB OperatorPolicy
|   +-- mtv-operator/             MTV OperatorPolicy
|   +-- ... (20+ more)
|
+-- gitops_pipeline_e2e.sh        End-to-end automation (6 phases)
+-- test_deployment.py            Post-deployment validation (pytest)
+-- Jenkinsfile                   CI pipeline definition
```

## 6. Git Repositories

| Repository | Purpose | Access |
|-----------|---------|--------|
| **GitLab** (Internal): `gitlab.cee.redhat.com/certification-qe/openshift-virtualization-gitops` | Primary development repo. Contains e2e script, Jenkinsfile, test suite, deployment docs. Jenkins CI pulls from here. | Internal Red Hat |
| **GitHub** (Public): `github.com/vikasmulaje/openshift-virtualization-gitops` | Clean public fork. Contains only GitOps manifests -- no credentials, no e2e scripts, no Jenkinsfile. | Public |
| **Upstream**: `github.com/redhat-developer/openshift-virtualization-gitops` | Original reference implementation by Red Hat Developer. Our work is based on this. | Public |

### Repository Hygiene Rules

- E2e scripts (`gitops_pipeline_e2e.sh`, `gitops_pipeline_multicluster-e2e.sh`) are in `.gitignore` -- they exist on GitLab only, never pushed to GitHub
- `Jenkinsfile` exists on GitLab only
- No credentials, pull secrets, or BMC passwords are committed to either repository
- All sensitive values are injected at runtime via environment variables

## 7. Branching Strategy

| Branch | OCP Version | Libvirt Network | Status |
|--------|------------|-----------------|--------|
| `main` | 4.20 (GA) | `ocp3m0w-ic4s20` | Production -- default |
| `openshift-4.21` | 4.21 (GA) | `ocp3m0w-ic4s21` | Production |
| `openshift-4.22` | 4.22 (Nightly) | `ocp3m0w-ic4n22` | Production (with nightly workarounds) |
| `disconnected` | 4.20 | Same as main | Image tags converted to SHA digests |

Each branch auto-configures the correct network, subnet, and ClusterImageSet when used with `--branch`:

```bash
./gitops_pipeline_e2e.sh --branch openshift-4.22 --clusters etl4
# Auto-selects: network=ocp3m0w-ic4n22, image=img4.22.0-0.nightly-..., subnet=192.168.134
```

## 8. What Gets Deployed (25+ Components)

### Hub Cluster (25+ ArgoCD Applications)

| Sync Wave | Components |
|-----------|-----------|
| Wave 5 | ACM Operator, Reflector Operator, MTV Operator |
| Wave 15 | ACM Instance (MultiClusterHub), MTV Configuration (ForkliftController) |
| Wave 20 | cert-manager, external-dns, MetalLB, NMState, AAP operators; GitOps bootstrap policy; Spoke cluster definitions (etl4, etl6) |
| Wave 25 | ACM Configuration (AgentServiceConfig), ACM Observability, all operator instance CRs, MetalLB/NMState/cert-manager configs, OVA server |
| Wave 30 | kube-ops-view, web-terminal-operator |

### Spoke Clusters (10+ ArgoCD Applications)

| Sync Wave | Components |
|-----------|-----------|
| Wave 5 | OpenShift Virtualization operator, Descheduler operator, Node Health Check operator (FAR, NHC, NM, SNR) |
| Wave 15 | HyperConverged CR, KubeDescheduler CR, NodeHealthCheck CR |
| Wave 20 | cert-manager, external-dns, MetalLB, NMState operators (shared) |
| Wave 25 | Operator instance configurations |

## 9. End-to-End Automation Script

**File:** `gitops_pipeline_e2e.sh` (~1750 lines)

### Features

- **Smart resume**: Re-run after failure and it auto-detects completed steps
- **Branch-aware**: `--branch` flag auto-configures network/image/subnet for known OCP versions
- **Multi-mode**: Runs remotely via SSH or locally on the hypervisor (`--local`)
- **Nightly build workarounds**: Auto-fixes unsigned image policy on nodes, applies MachineConfig, monitors MCO recovery
- **Subnet auto-detection**: Reads live libvirt network XML to detect correct subnet
- **Phase selection**: Run individual phases or full end-to-end
- **Post-deployment tests**: `--test` flag runs pytest validation suite

### Usage

```bash
# Full end-to-end deployment (etl4 only)
./gitops_pipeline_e2e.sh --local --branch main --clusters etl4 --test

# Full deployment with cleanup of existing VMs
./gitops_pipeline_e2e.sh --local --branch openshift-4.22 --clusters etl4 --cleanup --test

# Day-2 operations only
./gitops_pipeline_e2e.sh --local --day2-only --clusters etl4

# Individual phases
./gitops_pipeline_e2e.sh --local --phase hub     # Hub bootstrap only
./gitops_pipeline_e2e.sh --local --phase infra   # VM creation only
./gitops_pipeline_e2e.sh --local --phase spoke   # Spoke provisioning wait only
./gitops_pipeline_e2e.sh --local --phase day2    # Day-2 operations only
```

### Script Phases

| Phase | What It Does |
|-------|-------------|
| **Phase 1: Infrastructure** | Creates 3-6 KVM VMs (4-8 vCPUs, 24-32GB RAM, 120GB disk), configures DNS entries in `/etc/hosts`, starts sushy-emulator (Redfish BMC) |
| **Phase 2: Hub Bootstrap** | Installs GitOps operator, configures ArgoCD with CMP sidecar, patches Docker Hub auth (rate limiting), creates spoke cluster secrets (pull-secret, SSH key), applies root application |
| **Phase 3: Spoke Provisioning** | Monitors ACM/Assisted Installer progress until spoke clusters reach 100%, extracts spoke kubeconfigs. For nightly builds: fixes `/etc/containers/policy.json` on nodes, applies MachineConfig, monitors MCO reboots |
| **Phase 4: Spoke Bootstrap** | ACM policy installs GitOps operator on spokes. Script configures spoke ArgoCD with CMP + root application |
| **Phase 5: Day-2 Operations** | Cleans up failed pods, approves pending InstallPlans, tunes ArgoCD resource limits, verifies spoke app health |
| **Phase 6: Validation Tests** | Runs `test_deployment.py` via pytest, generates HTML report at `/tmp/deployment-reports/gitops-e2e-test.html` |

## 10. Jenkins CI Pipeline

**Jenkins URL:** `jenkins-csb-kniqe-ci.dno.corp.redhat.com`

The CI pipeline consists of two jobs: a **profile runner** (`CI/gitops-deploy`) that orchestrates the full flow, and a **downstream job** (`spoke-gitops-deploy`) that performs the GitOps deployment.

### 10.1 Profile Job: `CI/gitops-deploy`

| Property | Value |
|----------|-------|
| **Type** | WorkflowJob (Pipeline) |
| **Trigger** | Every Wednesday (nightly) |
| **Health** | 66% (1 of last 3 builds failed) |
| **Duration** | ~85 minutes end-to-end |

**Parameter:** `JOB_DATA` (YAML) -- defines the entire profile configuration:

```yaml
lock_label: cert-rhosp-01.lab.eng.rdu2.redhat.com
host: cert-rhosp-01.lab.eng.rdu2.redhat.com
version: 4.20
profile_name: gitops-deploy
trigger_day: Wednesday
```

**Environment variables set by the profile:**
- `VERSION`: 4.20
- `MAJOR_VERSION` / `OCP_MAJOR_VERSION`: 4
- `MINOR_VERSION` / `OCP_MINOR_VERSION`: 20
- `PULL_SPEC`: `quay.io/openshift-release-dev/ocp-release:4.20.26-x86_64`
- `PROFILE_NAME`: gitops-deploy

**Pipeline Stages (sequential):**

| Stage | Duration | What It Does |
|-------|----------|-------------|
| Declarative: Checkout SCM | ~17s | Checks out the pipeline repo |
| init | ~27s | Parses `JOB_DATA` YAML, sets up environment variables |
| run jobs | ~15s | Orchestrates downstream job triggers |
| #0 Cleanup Terraform | ~20s | Triggers `Infra/cleanup-all-terraform` -- wipes existing Terraform state/resources on the host |
| #1 Create HUB Cluster | ~24 min | Triggers `Infra/factory-cluster-clone` -- deploys a fresh OCP HUB cluster (stable-4.20) on the host |
| #2 GitOps E2E Pipeline | ~59 min | Triggers `spoke-gitops-deploy` -- the main GitOps spoke deployment and E2E validation |

### 10.2 Downstream Job: `spoke-gitops-deploy`

**File:** `Jenkinsfile` (GitLab only)

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `HOST` | String | (required) | Hypervisor/Agent to run on |
| `LIBVIRT_NETWORK` | String | `ocp3m0w-ic4s20` | Libvirt network name from Hub |
| `GITOPS_REPO` | String | GitLab URL | GitOps repository URL |
| `GITOPS_BRANCH` | String | `main` | Git branch (can change for testing) |
| `CLUSTERS` | Choice | `etl4` | Which spokes: `etl4` or `both` (etl4+etl6) |
| `CLEANUP` | Boolean | `false` | Destroy existing VMs before creating new ones |
| `TEST` | Boolean | `true` | Run post-deployment validation tests |
| `SLACK_CHANNEL` | String | `eco-ci-reporting` | Slack channel for results |

**Pipeline Stages:**

1. **Checkout SCM** -- Checks out pipeline repository
2. **Checkout GitOps Repo** -- Clones specified branch from `GITOPS_REPO`
3. **Execute GitOps Spoke Deployment** (~59 min) -- Runs `gitops_pipeline_e2e.sh` with configured flags
4. **Post Actions** -- Copies test report, archives HTML artifact, publishes via `publishHTML`, sends Slack notification

### 10.3 Complete CI Flow

```
CI/gitops-deploy (profile runner, triggered every Wednesday)
  |
  +-- #0 Infra/cleanup-all-terraform        → Clean host (Terraform state wipe)
  |
  +-- #1 Infra/factory-cluster-clone         → Deploy fresh HUB OCP 4.20 cluster
  |
  +-- #2 spoke-gitops-deploy                 → GitOps spoke deployment + E2E tests
        |
        +-- Checks out openshift-virtualization-gitops repo (GitLab)
        +-- Runs gitops_pipeline_e2e.sh (6 phases)
        +-- Deploys etl4 (or both etl4+etl6) spoke clusters
        +-- Runs pytest validation tests
        +-- Generates HTML test report
        +-- Posts results to #eco-ci-reporting (Slack)
```

### 10.4 Recent Build History

| Build | Result | Date | Duration |
|-------|--------|------|----------|
| #45 | SUCCESS | Jun 23, 2026 | ~85 min |
| #44 | SUCCESS | Jun 16, 2026 | ~85 min |

## 11. Post-Deployment Validation Tests

**File:** `test_deployment.py` (pytest-based)

### Test Suite Coverage (6 Test Classes, 30+ Test Cases)

| Test Class | What It Validates |
|-----------|------------------|
| `TestHubAppStatus` | Hub ArgoCD server running, critical apps synced and healthy, spoke apps synced |
| `TestHubClusterHealth` | Hub ClusterVersion available and matches expected version, all nodes Ready, minimum 3 nodes |
| `TestHubOperatorStatus` | All cluster operators available, none degraded, expected CSVs Succeeded |
| `TestFleetClusterStatus` | ManagedClusters accepted/joined/available, MultiClusterHub running, AgentClusterInstall complete, all agents Done |
| `TestSpokeClusterHealth` | Spoke ClusterVersion available and matches expected, all nodes Ready |
| `TestSpokeOperatorStatus` | Spoke cluster operators healthy, expected CSVs Succeeded |

### Execution

```bash
HUB_KUBECONFIG=/home/kni/clusterconfigs/auth/kubeconfig \
SPOKE_CLUSTERS=etl4 \
EXPECTED_OCP_VERSION=4.20 \
    pytest test_deployment.py -v --html=gitops-e2e-test.html --self-contained-html
```

## 12. Key Technical Challenges Solved

### 12.1 Network Subnet Portability

**Problem:** Cluster overlay files (BMH, NMStateConfig, kustomization.yaml) had hardcoded `192.168.135.x` IPs. Different hypervisors use different subnets, causing deployment failures.

**Solution:** Templatized all IPs to `${NETWORK_SUBNET}.x`, added `NETWORK_SUBNET` to the ArgoCD `environment-variables` ConfigMap, enabled CMP plugin for cluster overlays via `plugin: {}` in `values.yaml`, and added subnet auto-detection in the e2e script.

### 12.2 Nightly Build Image Signature Policy

**Problem:** OCP nightly builds use unsigned container images. Nodes reject them due to `/etc/containers/policy.json` requiring signatures, causing CRI-O to crash loop and Kubelet to fail to start.

**Solution:** The e2e script detects nightly builds, SSHs into spoke nodes during provisioning to patch `policy.json` to `insecureAcceptAnything`, then applies a `MachineConfig` (`99-master-nightly-container-policy`) post-install to make the fix persistent across MCO-triggered reboots.

### 12.3 ArgoCD CMP Cache Invalidation

**Problem:** After modifying the `environment-variables` ConfigMap or enabling `plugin: {}` for applications, ArgoCD continued serving stale (unexpanded) manifests from its Redis cache.

**Solution:** Flushed ArgoCD's Redis cache (`redis-cli FLUSHALL`) and hard-refreshed applications (`argocd.argoproj.io/refresh=hard` annotation).

### 12.4 Jenkins Agent Permissions

**Problem:** The Jenkins agent runs as a non-root user. Commands like `virsh`, `oc`, and writing to `/tmp` failed with permission errors.

**Solution:** Modified `run_cmd()` to use `sudo -E PATH="$PATH" bash -c "$*"` to preserve environment and PATH. Changed kubeconfig extraction to use `sudo tee` with `chmod 644`.

### 12.5 Stale DNS Entries

**Problem:** Reprovisioned clusters get new VIPs, but `/etc/hosts` on the hypervisor retained old entries, causing API connection timeouts.

**Solution:** Modified `phase1_setup_dns()` to actively `sed -i` delete existing entries before adding new ones with correct VIPs.

### 12.6 Dual Repository Management

**Problem:** Need to keep e2e scripts, Jenkinsfile, and credentials on GitLab (internal) while publishing clean GitOps manifests to GitHub (public).

**Solution:** Added `gitops_pipeline_e2e.sh` and `gitops_pipeline_multicluster-e2e.sh` to `.gitignore`. Established workflow: develop on GitLab, push only clean manifests to GitHub. Enforced via Cursor rule to prevent accidental pushes.

## 13. Disconnected Cluster Support

**Branch:** `disconnected`

Converted container image tags to SHA256 digests for air-gapped deployments:

| Image | Original Tag | SHA Digest |
|-------|-------------|-----------|
| `registry.redhat.io/rhacm2/multicluster-operators-subscription-rhel9` | `v2.11` | `sha256:...` |
| `quay.io/raffaelespazzoli/raffa-envsub` | `1.1` | `sha256:...` |

This ensures clusters without internet access can pull images from a mirrored registry using immutable digests.

## 14. DevConf US 2026 Talk

**Status:** Accepted
**Title:** GitOps at Scale: Building a Virtualization Migration Factory on OpenShift
**Conference:** DevConf.US 2026, September 24-25, Boston
**Track:** DevOps and Automation
**Format:** 35-minute talk (25 min + 10 min Q&A)

The talk covers the architecture, app-of-apps pattern, ACM spoke provisioning, CMP environment substitution, and includes a live demo of the end-to-end automation pipeline.

CFP proposal: `devconf-us-2026-cfp.md`

## 15. Future Work

| Item | Description | Priority |
|------|------------|----------|
| **Replace OperatorPolicy with OLM** | Current spoke operators use ACM `OperatorPolicy` CRDs which require ACM. Converting to standard OLM `Subscription` + `OperatorGroup` would make the repo usable without ACM dependency. | High |
| **Add VM Migration workflow** | Add vSphere Provider, NetworkMap, StorageMap, and sample Migration Plan to enable actual VM migration (not just infrastructure readiness). The hub already has MTV + spoke Providers configured. | High |
| **VDDK image integration** | Configure the VMware VDDK image in ForkliftController for vSphere disk migrations. | Medium |
| **MTV+ / Storage Offload** | Explore Hitachi Vantara's storage offload capability for 10x faster migrations. | Medium |
| **Multi-cluster e2e script** | `gitops_pipeline_multicluster-e2e.sh` for deploying across multiple hypervisors. | Low |

---

*This document summarizes the complete body of work performed on the OpenShift Virtualization GitOps project from initial setup through production CI integration.*

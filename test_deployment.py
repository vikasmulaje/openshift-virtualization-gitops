#!/usr/bin/env python3
"""
Post-deployment validation tests for spoke cluster provisioning.

Usage:
    # Run all tests (hub + spoke)
    HUB_KUBECONFIG=/home/kni/clusterconfigs/auth/kubeconfig \
    SPOKE_CLUSTERS=etl4 \
        pytest test_deployment.py -v

    # Run only hub tests
    pytest test_deployment.py -v -k hub

    # Run only ArgoCD sync tests
    pytest test_deployment.py -v -k argocd

    # Spoke kubeconfig path convention: /tmp/<cluster>-kubeconfig
    # Override with SPOKE_KUBECONFIG_DIR env var

Environment Variables:
    HUB_KUBECONFIG          Path to hub cluster kubeconfig
    SPOKE_CLUSTERS          Comma-separated spoke cluster names (default: etl4)
    SPOKE_KUBECONFIG_DIR    Directory containing <cluster>-kubeconfig files (default: /tmp)
    EXPECTED_OCP_VERSION    Expected OCP version prefix (default: 4.20)
"""

import json
import os
import subprocess
import pytest


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

HUB_KUBECONFIG = os.environ.get(
    "HUB_KUBECONFIG", "/home/kni/clusterconfigs/auth/kubeconfig"
)
SPOKE_CLUSTERS = [
    c.strip() for c in os.environ.get("SPOKE_CLUSTERS", "etl4").split(",") if c.strip()
]
SPOKE_KUBECONFIG_DIR = os.environ.get("SPOKE_KUBECONFIG_DIR", "/tmp")
EXPECTED_OCP_VERSION = os.environ.get("EXPECTED_OCP_VERSION", "4.20")

HUB_EXPECTED_OPERATORS = [
    "openshift-gitops-operator",
    "advanced-cluster-management",
]

SPOKE_EXPECTED_OPERATORS = [
    "openshift-gitops-operator",
]

HUB_CRITICAL_ARGOCD_APPS = [
    "root-applications",
    "acm-operator",
    "acm-instance",
]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def oc(args, kubeconfig=HUB_KUBECONFIG, timeout=30):
    """Run an oc command and return stdout."""
    cmd = f"oc --kubeconfig={kubeconfig} {args}"
    result = subprocess.run(
        cmd, shell=True, capture_output=True, text=True, timeout=timeout,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"oc failed (rc={result.returncode}): {cmd}\n"
            f"stderr: {result.stderr.strip()}"
        )
    return result.stdout.strip()


def oc_json(args, kubeconfig=HUB_KUBECONFIG, timeout=30):
    """Run an oc command with -o json and return parsed dict."""
    return json.loads(oc(f"{args} -o json", kubeconfig=kubeconfig, timeout=timeout))


def hub_oc(args, **kw):
    return oc(args, kubeconfig=HUB_KUBECONFIG, **kw)


def hub_oc_json(args, **kw):
    return oc_json(args, kubeconfig=HUB_KUBECONFIG, **kw)


def spoke_kubeconfig(cluster):
    return os.path.join(SPOKE_KUBECONFIG_DIR, f"{cluster}-kubeconfig")


def spoke_oc(cluster, args, **kw):
    return oc(args, kubeconfig=spoke_kubeconfig(cluster), **kw)


def spoke_oc_json(cluster, args, **kw):
    return oc_json(args, kubeconfig=spoke_kubeconfig(cluster), **kw)


def get_conditions_map(resource):
    """Extract conditions as {type: condition_dict} from a resource."""
    return {
        c["type"]: c for c in resource.get("status", {}).get("conditions", [])
    }


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(params=SPOKE_CLUSTERS)
def cluster(request):
    """Parameterized fixture yielding each spoke cluster name."""
    return request.param


# ===================================================================
# HUB CLUSTER HEALTH
# ===================================================================

class TestHubClusterVersion:

    def test_hub_version_available(self):
        cv = hub_oc_json("get clusterversion version")
        conds = get_conditions_map(cv)
        avail = conds.get("Available", {})
        assert avail.get("status") == "True", (
            f"ClusterVersion not available: {avail.get('message', '')}"
        )

    def test_hub_version_not_progressing(self):
        cv = hub_oc_json("get clusterversion version")
        conds = get_conditions_map(cv)
        prog = conds.get("Progressing", {})
        assert prog.get("status") == "False", (
            f"ClusterVersion still progressing: {prog.get('message', '')}"
        )

    def test_hub_version_matches_expected(self):
        cv = hub_oc_json("get clusterversion version")
        version = cv["status"]["desired"]["version"]
        assert version.startswith(EXPECTED_OCP_VERSION), (
            f"Hub version {version} does not match expected {EXPECTED_OCP_VERSION}"
        )


class TestHubNodes:

    def test_hub_all_nodes_ready(self):
        nodes = hub_oc_json("get nodes")
        not_ready = []
        for node in nodes["items"]:
            name = node["metadata"]["name"]
            conds = get_conditions_map(node)
            if conds.get("Ready", {}).get("status") != "True":
                not_ready.append(name)
        assert not not_ready, f"Hub nodes not Ready: {not_ready}"

    def test_hub_minimum_node_count(self):
        nodes = hub_oc_json("get nodes")
        count = len(nodes["items"])
        assert count >= 3, f"Expected >= 3 hub nodes, got {count}"


class TestHubOperators:

    def test_hub_no_degraded_operators(self):
        cos = hub_oc_json("get clusteroperators")
        degraded = []
        for co in cos["items"]:
            name = co["metadata"]["name"]
            conds = {
                c["type"]: c["status"]
                for c in co["status"].get("conditions", [])
            }
            if conds.get("Degraded") == "True":
                degraded.append(name)
        assert not degraded, f"Degraded operators: {degraded}"

    def test_hub_all_operators_available(self):
        cos = hub_oc_json("get clusteroperators")
        unavailable = []
        for co in cos["items"]:
            name = co["metadata"]["name"]
            conds = {
                c["type"]: c["status"]
                for c in co["status"].get("conditions", [])
            }
            if conds.get("Available") != "True":
                unavailable.append(name)
        assert not unavailable, f"Unavailable operators: {unavailable}"

    @pytest.mark.parametrize("operator", HUB_EXPECTED_OPERATORS)
    def test_hub_expected_csv_succeeded(self, operator):
        csvs = hub_oc_json("get csv -A")
        found = any(
            operator in item["metadata"]["name"]
            and item["status"].get("phase") == "Succeeded"
            for item in csvs["items"]
        )
        assert found, f"Operator CSV '{operator}' not found or not Succeeded"


# ===================================================================
# HUB ACM STATUS
# ===================================================================

class TestHubACM:

    def test_multiclusterhub_running(self):
        mch = hub_oc_json(
            "get multiclusterhub -n open-cluster-management multiclusterhub"
        )
        phase = mch["status"].get("phase", "")
        assert phase == "Running", f"MultiClusterHub phase: {phase}"

    def test_agentserviceconfig_exists(self):
        asc = hub_oc_json("get agentserviceconfig agent")
        assert asc["metadata"]["name"] == "agent"

    def test_provisioning_watches_all_namespaces(self):
        prov = hub_oc_json("get provisioning provisioning-configuration")
        assert prov["spec"].get("watchAllNamespaces") is True


# ===================================================================
# HUB ARGOCD
# ===================================================================

class TestHubArgoCD:

    def test_hub_argocd_server_running(self):
        deploy = hub_oc_json(
            "get deployment openshift-gitops-server -n openshift-gitops"
        )
        replicas = deploy["status"].get("availableReplicas", 0)
        assert replicas >= 1, "ArgoCD server has no available replicas"

    @pytest.mark.parametrize("app_name", HUB_CRITICAL_ARGOCD_APPS)
    def test_hub_critical_app_synced(self, app_name):
        app = hub_oc_json(
            f"get applications.argoproj.io {app_name} -n openshift-gitops"
        )
        sync = app["status"].get("sync", {}).get("status", "")
        assert sync == "Synced", f"App {app_name} sync={sync}"

    def test_hub_no_degraded_argocd_apps(self):
        apps = hub_oc_json("get applications.argoproj.io -n openshift-gitops")
        degraded = []
        for app in apps["items"]:
            name = app["metadata"]["name"]
            health = (
                app.get("status", {}).get("health", {}).get("status", "Unknown")
            )
            if health == "Degraded":
                degraded.append(f"{name} (health={health})")
        assert not degraded, f"Degraded ArgoCD apps:\n" + "\n".join(degraded)


# ===================================================================
# SPOKE CLUSTER HEALTH (parameterized per cluster)
# ===================================================================

class TestSpokeClusterVersion:

    def test_spoke_version_available(self, cluster):
        cv = spoke_oc_json(cluster, "get clusterversion version")
        conds = get_conditions_map(cv)
        avail = conds.get("Available", {})
        assert avail.get("status") == "True", (
            f"{cluster}: ClusterVersion not available"
        )

    def test_spoke_version_matches_expected(self, cluster):
        cv = spoke_oc_json(cluster, "get clusterversion version")
        version = cv["status"]["desired"]["version"]
        assert version.startswith(EXPECTED_OCP_VERSION), (
            f"{cluster}: version {version} does not match {EXPECTED_OCP_VERSION}"
        )


class TestSpokeNodes:

    def test_spoke_all_nodes_ready(self, cluster):
        nodes = spoke_oc_json(cluster, "get nodes")
        not_ready = []
        for node in nodes["items"]:
            name = node["metadata"]["name"]
            conds = get_conditions_map(node)
            if conds.get("Ready", {}).get("status") != "True":
                not_ready.append(name)
        assert not not_ready, f"{cluster}: nodes not Ready: {not_ready}"

    def test_spoke_minimum_node_count(self, cluster):
        nodes = spoke_oc_json(cluster, "get nodes")
        count = len(nodes["items"])
        assert count >= 3, f"{cluster}: expected >= 3 nodes, got {count}"


class TestSpokeOperators:

    def test_spoke_no_degraded_operators(self, cluster):
        cos = spoke_oc_json(cluster, "get clusteroperators")
        degraded = []
        for co in cos["items"]:
            name = co["metadata"]["name"]
            conds = {
                c["type"]: c["status"]
                for c in co["status"].get("conditions", [])
            }
            if conds.get("Degraded") == "True":
                degraded.append(name)
        assert not degraded, f"{cluster}: degraded operators: {degraded}"

    def test_spoke_all_operators_available(self, cluster):
        cos = spoke_oc_json(cluster, "get clusteroperators")
        unavailable = []
        for co in cos["items"]:
            name = co["metadata"]["name"]
            conds = {
                c["type"]: c["status"]
                for c in co["status"].get("conditions", [])
            }
            if conds.get("Available") != "True":
                unavailable.append(name)
        assert not unavailable, f"{cluster}: unavailable operators: {unavailable}"

    @pytest.mark.parametrize("operator", SPOKE_EXPECTED_OPERATORS)
    def test_spoke_expected_csv_succeeded(self, cluster, operator):
        csvs = spoke_oc_json(cluster, "get csv -A")
        found = any(
            operator in item["metadata"]["name"]
            and item["status"].get("phase") == "Succeeded"
            for item in csvs["items"]
        )
        assert found, f"{cluster}: operator '{operator}' not Succeeded"


# ===================================================================
# MANAGED CLUSTER STATUS (hub perspective)
# ===================================================================

class TestManagedCluster:

    def test_managed_cluster_accepted(self, cluster):
        mc = hub_oc_json(f"get managedcluster {cluster}")
        conds = get_conditions_map(mc)
        accepted = conds.get("HubAcceptedManagedCluster", {})
        assert accepted.get("status") == "True", f"{cluster}: not accepted by hub"

    def test_managed_cluster_joined(self, cluster):
        mc = hub_oc_json(f"get managedcluster {cluster}")
        conds = get_conditions_map(mc)
        joined = conds.get("ManagedClusterJoined", {})
        assert joined.get("status") == "True", (
            f"{cluster}: not joined - {joined.get('message', '')}"
        )

    def test_managed_cluster_available(self, cluster):
        mc = hub_oc_json(f"get managedcluster {cluster}")
        conds = get_conditions_map(mc)
        avail = conds.get("ManagedClusterConditionAvailable", {})
        assert avail.get("status") == "True", (
            f"{cluster}: not available - {avail.get('message', '')}"
        )

    def test_cluster_deployment_provisioned(self, cluster):
        cd = hub_oc_json(f"get clusterdeployment {cluster} -n {cluster}")
        installed = cd["status"].get("installedTimestamp")
        assert installed is not None, (
            f"{cluster}: ClusterDeployment not provisioned"
        )

    def test_agent_cluster_install_complete(self, cluster):
        aci = hub_oc_json(f"get agentclusterinstall {cluster} -n {cluster}")
        state = aci.get("status", {}).get("debugInfo", {}).get("state", "")
        pct = aci.get("status", {}).get("progress", {}).get("totalPercentage", 0)
        assert state in ("adding-hosts", "installed"), (
            f"{cluster}: state={state}, expected adding-hosts or installed"
        )
        assert pct == 100, f"{cluster}: progress {pct}%, expected 100%"

    def test_all_agents_done(self, cluster):
        agents = hub_oc_json(f"get agent -n {cluster}")
        not_done = []
        for agent in agents["items"]:
            name = agent["metadata"]["name"][:12]
            progress = agent.get("status", {}).get("progress", {})
            stage = progress.get("currentStage", "unknown")
            if stage != "Done":
                not_done.append(f"{name}: {stage}")
        assert not not_done, f"{cluster}: agents not done: {not_done}"


# ===================================================================
# SPOKE ARGOCD (day-2)
# ===================================================================

class TestSpokeArgoCD:

    def test_spoke_argocd_server_running(self, cluster):
        try:
            deploy = spoke_oc_json(
                cluster,
                "get deployment openshift-gitops-server -n openshift-gitops",
            )
        except RuntimeError:
            pytest.skip(f"{cluster}: ArgoCD not installed (day-2 not run)")
        replicas = deploy["status"].get("availableReplicas", 0)
        assert replicas >= 1, f"{cluster}: ArgoCD has no available replicas"

    def test_spoke_root_app_exists(self, cluster):
        try:
            app = spoke_oc_json(
                cluster,
                "get applications.argoproj.io root-applications -n openshift-gitops",
            )
        except RuntimeError:
            pytest.skip(f"{cluster}: root-applications not found (day-2 not run)")
        sync = app.get("status", {}).get("sync", {}).get("status", "Unknown")
        assert sync in ("Synced", "OutOfSync"), (
            f"{cluster}: root-applications sync={sync}"
        )

    def test_spoke_hub_argocd_app_synced(self, cluster):
        """Hub-side ArgoCD app for this spoke is synced and healthy."""
        app = hub_oc_json(
            f"get applications.argoproj.io {cluster} -n openshift-gitops"
        )
        sync = app["status"].get("sync", {}).get("status", "")
        health = app["status"].get("health", {}).get("status", "")
        assert sync == "Synced", f"{cluster}: hub-side app sync={sync}"
        assert health == "Healthy", f"{cluster}: hub-side app health={health}"

#!/usr/bin/env python3
"""
Post-deployment validation tests for spoke cluster provisioning.

Usage:
    HUB_KUBECONFIG=/home/kni/clusterconfigs/auth/kubeconfig \
    SPOKE_CLUSTERS=etl4 \
        pytest test_deployment.py -v --html=gitops-e2e-test.html --self-contained-html

Environment Variables:
    HUB_KUBECONFIG          Path to hub cluster kubeconfig
    SPOKE_CLUSTERS          Comma-separated spoke cluster names (default: etl4)
    SPOKE_KUBECONFIG_DIR    Directory for <cluster>-kubeconfig files (default: /tmp)
    EXPECTED_OCP_VERSION    Expected OCP version prefix (default: 4.20)
"""

import json
import os
import subprocess
import textwrap
import pytest


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

HUB_KUBECONFIG = os.environ.get(
    "HUB_KUBECONFIG", "/home/kni/clusterconfigs/auth/kubeconfig"
)
SPOKE_CLUSTERS = [
    c.strip()
    for c in os.environ.get("SPOKE_CLUSTERS", "etl4").split(",")
    if c.strip()
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
    "acm-configuration",
]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def oc(args, kubeconfig=HUB_KUBECONFIG, timeout=60):
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


def oc_json(args, kubeconfig=HUB_KUBECONFIG, timeout=60):
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


def format_table(headers, rows):
    """Return a simple ASCII table string for test output."""
    widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(str(cell)))
    sep = "  ".join("-" * w for w in widths)
    hdr = "  ".join(str(h).ljust(w) for h, w in zip(headers, widths))
    lines = [hdr, sep]
    for row in rows:
        lines.append("  ".join(str(c).ljust(w) for c, w in zip(row, widths)))
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(params=SPOKE_CLUSTERS)
def cluster(request):
    """Parameterized fixture yielding each spoke cluster name."""
    return request.param


# ===================================================================
# TEST 1: HUB ARGOCD APPLICATION STATUS
# ===================================================================

class TestHubAppStatus:
    """Verify all ArgoCD applications on the hub cluster."""

    def test_hub_argocd_server_running(self):
        deploy = hub_oc_json(
            "get deployment openshift-gitops-server -n openshift-gitops"
        )
        replicas = deploy["status"].get("availableReplicas", 0)
        desired = deploy["spec"].get("replicas", 1)
        print(f"\nHub ArgoCD server: {replicas}/{desired} replicas available")
        assert replicas >= 1, "ArgoCD server has no available replicas"

    @pytest.mark.parametrize("app_name", HUB_CRITICAL_ARGOCD_APPS)
    def test_hub_critical_app_synced(self, app_name):
        app = hub_oc_json(
            f"get applications.argoproj.io {app_name} -n openshift-gitops"
        )
        sync = app["status"].get("sync", {}).get("status", "")
        health = app["status"].get("health", {}).get("status", "")
        print(f"\n{app_name}: sync={sync}  health={health}")
        if app_name == "root-applications":
            assert sync in ("Synced", "OutOfSync"), f"{app_name}: sync={sync}"
        else:
            assert sync == "Synced", f"{app_name}: sync={sync}"
            assert health not in ("Degraded", "Unknown"), (
                f"{app_name}: health={health}"
            )

    def test_hub_all_apps_status_summary(self):
        """Print and validate all hub ArgoCD apps. No Degraded allowed."""
        apps = hub_oc_json("get applications.argoproj.io -n openshift-gitops")
        rows = []
        degraded = []
        for app in apps["items"]:
            name = app["metadata"]["name"]
            sync = app.get("status", {}).get("sync", {}).get("status", "Unknown")
            health = app.get("status", {}).get("health", {}).get("status", "Unknown")
            rows.append((name, sync, health))
            if health == "Degraded" and name != "root-applications":
                degraded.append(name)

        table = format_table(["APP", "SYNC", "HEALTH"], sorted(rows))
        print(f"\n--- Hub ArgoCD Applications ({len(rows)} apps) ---")
        print(table)

        assert not degraded, f"Degraded ArgoCD apps: {degraded}"

    def test_hub_spoke_apps_synced_and_healthy(self, cluster):
        """Hub-side ArgoCD app for each spoke is Synced + Healthy."""
        app = hub_oc_json(
            f"get applications.argoproj.io {cluster} -n openshift-gitops"
        )
        sync = app["status"].get("sync", {}).get("status", "")
        health = app["status"].get("health", {}).get("status", "")
        print(f"\nHub app '{cluster}': sync={sync}  health={health}")
        assert sync == "Synced", f"{cluster}: hub app sync={sync}"
        assert health == "Healthy", f"{cluster}: hub app health={health}"


# ===================================================================
# TEST 2: HUB CLUSTER HEALTH & OPERATOR STATUS
# ===================================================================

class TestHubClusterHealth:
    """Verify hub cluster version, nodes and operators."""

    def test_hub_version_available(self):
        cv = hub_oc_json("get clusterversion version")
        version = cv["status"]["desired"]["version"]
        conds = get_conditions_map(cv)
        avail = conds.get("Available", {})
        print(f"\nHub ClusterVersion: {version}  Available={avail.get('status', '?')}")
        assert avail.get("status") == "True", (
            f"ClusterVersion not available: {avail.get('message', '')}"
        )

    def test_hub_version_not_progressing(self):
        cv = hub_oc_json("get clusterversion version")
        version = cv["status"]["desired"]["version"]
        conds = get_conditions_map(cv)
        prog = conds.get("Progressing", {})
        print(f"\nHub ClusterVersion: {version}  Progressing={prog.get('status', '?')}")
        assert prog.get("status") == "False", (
            f"Still progressing: {prog.get('message', '')}"
        )

    def test_hub_version_matches_expected(self):
        cv = hub_oc_json("get clusterversion version")
        version = cv["status"]["desired"]["version"]
        print(f"\nHub cluster version: {version}")
        assert version.startswith(EXPECTED_OCP_VERSION), (
            f"Hub version {version} doesn't match expected {EXPECTED_OCP_VERSION}"
        )

    def test_hub_all_nodes_ready(self):
        nodes = hub_oc_json("get nodes")
        rows = []
        not_ready = []
        for node in nodes["items"]:
            name = node["metadata"]["name"]
            conds = get_conditions_map(node)
            status = "Ready" if conds.get("Ready", {}).get("status") == "True" else "NotReady"
            roles = ",".join(
                k.replace("node-role.kubernetes.io/", "")
                for k in node["metadata"].get("labels", {})
                if k.startswith("node-role.kubernetes.io/")
            )
            version = node["status"]["nodeInfo"]["kubeletVersion"]
            rows.append((name, status, roles, version))
            if status != "Ready":
                not_ready.append(name)

        print(f"\n--- Hub Nodes ({len(rows)}) ---")
        print(format_table(["NODE", "STATUS", "ROLES", "VERSION"], rows))
        assert not not_ready, f"Hub nodes not Ready: {not_ready}"

    def test_hub_minimum_node_count(self):
        nodes = hub_oc_json("get nodes")
        count = len(nodes["items"])
        names = [n["metadata"]["name"] for n in nodes["items"]]
        print(f"\nHub node count: {count}  nodes: {names}")
        assert count >= 3, f"Expected >= 3 hub nodes, got {count}"


class TestHubOperatorStatus:
    """Verify all hub cluster operators are healthy."""

    def test_hub_operator_status_summary(self):
        """Print full operator table. None should be Degraded."""
        cos = hub_oc_json("get clusteroperators")
        rows = []
        degraded = []
        for co in cos["items"]:
            name = co["metadata"]["name"]
            conds = {
                c["type"]: c["status"]
                for c in co["status"].get("conditions", [])
            }
            avail = conds.get("Available", "?")
            prog = conds.get("Progressing", "?")
            deg = conds.get("Degraded", "?")
            version = ""
            for v in co["status"].get("versions", []):
                if v.get("name") == "operator":
                    version = v.get("version", "")
                    break
            rows.append((name, avail, prog, deg, version))
            if deg == "True":
                degraded.append(name)

        print(f"\n--- Hub Cluster Operators ({len(rows)}) ---")
        print(format_table(
            ["OPERATOR", "AVAILABLE", "PROGRESSING", "DEGRADED", "VERSION"],
            sorted(rows),
        ))
        assert not degraded, f"Degraded operators: {degraded}"

    def test_hub_no_unavailable_operators(self):
        cos = hub_oc_json("get clusteroperators")
        total = len(cos["items"])
        unavailable = [
            co["metadata"]["name"]
            for co in cos["items"]
            if {c["type"]: c["status"] for c in co["status"].get("conditions", [])}.get(
                "Available"
            )
            != "True"
        ]
        print(f"\nHub operators: {total} total, {total - len(unavailable)} available, {len(unavailable)} unavailable")
        if unavailable:
            print(f"  Unavailable: {unavailable}")
        assert not unavailable, f"Unavailable operators: {unavailable}"

    @pytest.mark.parametrize("operator", HUB_EXPECTED_OPERATORS)
    def test_hub_expected_csv_succeeded(self, operator):
        csvs = hub_oc_json("get csv -A")
        matches = [
            (item["metadata"]["name"], item["status"].get("phase", ""))
            for item in csvs["items"]
            if operator in item["metadata"]["name"]
        ]
        assert matches, f"No CSV found matching '{operator}'"
        for name, phase in matches:
            print(f"  {name}: {phase}")
        assert all(
            phase == "Succeeded" for _, phase in matches
        ), f"CSV '{operator}' not all Succeeded: {matches}"


# ===================================================================
# TEST 3: FLEET / MANAGED CLUSTER STATUS (hub perspective)
# ===================================================================

class TestFleetClusterStatus:
    """Verify ACM fleet: managed clusters, deployment, agents."""

    def test_fleet_overview(self):
        """Print all managed clusters and their status."""
        mcs = hub_oc_json("get managedclusters")
        rows = []
        for mc in mcs["items"]:
            name = mc["metadata"]["name"]
            conds = get_conditions_map(mc)
            accepted = conds.get("HubAcceptedManagedCluster", {}).get("status", "?")
            joined = conds.get("ManagedClusterJoined", {}).get("status", "?")
            avail = conds.get("ManagedClusterConditionAvailable", {}).get("status", "?")
            url = mc.get("status", {}).get("clusterClaims", [])
            version = ""
            for claim in mc.get("status", {}).get("clusterClaims", []):
                if claim.get("name") == "version.openshift.io":
                    version = claim.get("value", "")
                    break
            rows.append((name, accepted, joined, avail, version))

        print(f"\n--- Fleet: Managed Clusters ({len(rows)}) ---")
        print(format_table(
            ["CLUSTER", "ACCEPTED", "JOINED", "AVAILABLE", "VERSION"], rows
        ))

    def test_multiclusterhub_running(self):
        mch = hub_oc_json(
            "get multiclusterhub -n open-cluster-management multiclusterhub"
        )
        phase = mch["status"].get("phase", "")
        version = mch["status"].get("currentVersion", "")
        print(f"\nMultiClusterHub: phase={phase} version={version}")
        assert phase == "Running", f"MultiClusterHub phase: {phase}"

    def test_agentserviceconfig_exists(self):
        asc = hub_oc_json("get agentserviceconfig agent")
        db_storage = asc.get("spec", {}).get("databaseStorage", {}).get("resources", {}).get("requests", {}).get("storage", "?")
        fs_storage = asc.get("spec", {}).get("filesystemStorage", {}).get("resources", {}).get("requests", {}).get("storage", "?")
        img_storage = asc.get("spec", {}).get("imageStorage", {}).get("resources", {}).get("requests", {}).get("storage", "?")
        print(f"\nAgentServiceConfig: db={db_storage}  fs={fs_storage}  img={img_storage}")

    def test_managed_cluster_accepted(self, cluster):
        mc = hub_oc_json(f"get managedcluster {cluster}")
        conds = get_conditions_map(mc)
        accepted = conds.get("HubAcceptedManagedCluster", {}).get("status", "?")
        print(f"\n{cluster}: HubAcceptedManagedCluster={accepted}")
        assert accepted == "True", (
            f"{cluster}: not accepted by hub"
        )

    def test_managed_cluster_joined(self, cluster):
        mc = hub_oc_json(f"get managedcluster {cluster}")
        conds = get_conditions_map(mc)
        joined = conds.get("ManagedClusterJoined", {})
        print(f"\n{cluster}: ManagedClusterJoined={joined.get('status', '?')}  msg={joined.get('message', '')[:80]}")
        assert joined.get("status") == "True", (
            f"{cluster}: not joined - {joined.get('message', '')}"
        )

    def test_managed_cluster_available(self, cluster):
        mc = hub_oc_json(f"get managedcluster {cluster}")
        conds = get_conditions_map(mc)
        avail = conds.get("ManagedClusterConditionAvailable", {})
        print(f"\n{cluster}: ManagedClusterAvailable={avail.get('status', '?')}  msg={avail.get('message', '')[:80]}")
        assert avail.get("status") == "True", (
            f"{cluster}: not available - {avail.get('message', '')}"
        )

    def test_cluster_deployment_provisioned(self, cluster):
        cd = hub_oc_json(f"get clusterdeployment {cluster} -n {cluster}")
        installed = cd["status"].get("installedTimestamp")
        assert installed is not None, f"{cluster}: not yet provisioned"
        print(f"\n{cluster}: provisioned at {installed}")

    def test_agent_cluster_install_complete(self, cluster):
        aci = hub_oc_json(f"get agentclusterinstall {cluster} -n {cluster}")
        state = aci.get("status", {}).get("debugInfo", {}).get("state", "")
        pct = aci.get("status", {}).get("progress", {}).get("totalPercentage", 0)
        print(f"\n{cluster}: state={state} progress={pct}%")
        assert state in ("adding-hosts", "installed"), (
            f"{cluster}: state={state}"
        )
        assert pct == 100, f"{cluster}: progress {pct}%"

    def test_all_agents_done(self, cluster):
        agents = hub_oc_json(f"get agent -n {cluster}")
        rows = []
        not_done = []
        for agent in agents["items"]:
            uid = agent["metadata"]["name"][:12]
            role = agent.get("status", {}).get("role", "?")
            stage = agent.get("status", {}).get("progress", {}).get(
                "currentStage", "unknown"
            )
            rows.append((uid, role, stage))
            if stage != "Done":
                not_done.append(f"{uid}: {stage}")

        print(f"\n--- {cluster} Agents ---")
        print(format_table(["AGENT", "ROLE", "STAGE"], rows))
        assert not not_done, f"{cluster}: agents not done: {not_done}"


# ===================================================================
# TEST 4: SPOKE (PROD) ARGOCD APP STATUS
# ===================================================================

class TestSpokeAppStatus:
    """Verify ArgoCD applications on the spoke/prod cluster."""

    def test_spoke_argocd_server_running(self, cluster):
        try:
            deploy = spoke_oc_json(
                cluster,
                "get deployment openshift-gitops-server -n openshift-gitops",
            )
        except RuntimeError:
            pytest.skip(f"{cluster}: ArgoCD not installed (day-2 not run)")
        replicas = deploy["status"].get("availableReplicas", 0)
        desired = deploy["spec"].get("replicas", 1)
        print(f"\n{cluster} ArgoCD server: {replicas}/{desired} replicas available")
        assert replicas >= 1, f"{cluster}: ArgoCD has no available replicas"

    def test_spoke_all_apps_status_summary(self, cluster):
        """Print and validate all spoke ArgoCD apps."""
        try:
            apps = spoke_oc_json(
                cluster, "get applications.argoproj.io -n openshift-gitops"
            )
        except RuntimeError:
            pytest.skip(f"{cluster}: ArgoCD not installed (day-2 not run)")

        rows = []
        degraded = []
        for app in apps["items"]:
            name = app["metadata"]["name"]
            sync = app.get("status", {}).get("sync", {}).get("status", "Unknown")
            health = app.get("status", {}).get("health", {}).get("status", "Unknown")
            rows.append((name, sync, health))
            if health == "Degraded" and name != "root-applications":
                degraded.append(name)

        print(f"\n--- {cluster} ArgoCD Applications ({len(rows)} apps) ---")
        print(format_table(["APP", "SYNC", "HEALTH"], sorted(rows)))
        assert not degraded, f"{cluster}: degraded apps: {degraded}"

    def test_spoke_root_app_synced(self, cluster):
        try:
            app = spoke_oc_json(
                cluster,
                "get applications.argoproj.io root-applications -n openshift-gitops",
            )
        except RuntimeError:
            pytest.skip(f"{cluster}: root-applications not found")
        sync = app.get("status", {}).get("sync", {}).get("status", "Unknown")
        health = app.get("status", {}).get("health", {}).get("status", "Unknown")
        print(f"\n{cluster} root-applications: sync={sync}  health={health}")
        assert sync in ("Synced", "OutOfSync"), (
            f"{cluster}: root-applications sync={sync}"
        )


# ===================================================================
# TEST 5: SPOKE (PROD) CLUSTER HEALTH & OPERATOR STATUS
# ===================================================================

class TestSpokeClusterHealth:
    """Verify spoke cluster version and nodes."""

    def test_spoke_version_available(self, cluster):
        cv = spoke_oc_json(cluster, "get clusterversion version")
        version = cv["status"]["desired"]["version"]
        conds = get_conditions_map(cv)
        avail = conds.get("Available", {})
        print(f"\n{cluster} ClusterVersion: {version}  Available={avail.get('status', '?')}")
        assert avail.get("status") == "True", (
            f"{cluster}: ClusterVersion not available"
        )

    def test_spoke_version_matches_expected(self, cluster):
        cv = spoke_oc_json(cluster, "get clusterversion version")
        version = cv["status"]["desired"]["version"]
        print(f"\n{cluster} cluster version: {version}")
        assert version.startswith(EXPECTED_OCP_VERSION), (
            f"{cluster}: version {version} doesn't match {EXPECTED_OCP_VERSION}"
        )

    def test_spoke_all_nodes_ready(self, cluster):
        nodes = spoke_oc_json(cluster, "get nodes")
        rows = []
        not_ready = []
        for node in nodes["items"]:
            name = node["metadata"]["name"]
            conds = get_conditions_map(node)
            status = "Ready" if conds.get("Ready", {}).get("status") == "True" else "NotReady"
            roles = ",".join(
                k.replace("node-role.kubernetes.io/", "")
                for k in node["metadata"].get("labels", {})
                if k.startswith("node-role.kubernetes.io/")
            )
            version = node["status"]["nodeInfo"]["kubeletVersion"]
            rows.append((name, status, roles, version))
            if status != "Ready":
                not_ready.append(name)

        print(f"\n--- {cluster} Nodes ({len(rows)}) ---")
        print(format_table(["NODE", "STATUS", "ROLES", "VERSION"], rows))
        assert not not_ready, f"{cluster}: nodes not Ready: {not_ready}"

    def test_spoke_minimum_node_count(self, cluster):
        nodes = spoke_oc_json(cluster, "get nodes")
        count = len(nodes["items"])
        names = [n["metadata"]["name"] for n in nodes["items"]]
        print(f"\n{cluster} node count: {count}  nodes: {names}")
        assert count >= 3, (
            f"{cluster}: expected >= 3 nodes, got {count}"
        )


class TestSpokeOperatorStatus:
    """Verify all spoke cluster operators are healthy."""

    def test_spoke_operator_status_summary(self, cluster):
        """Print full operator table. None should be Degraded."""
        cos = spoke_oc_json(cluster, "get clusteroperators")
        rows = []
        degraded = []
        for co in cos["items"]:
            name = co["metadata"]["name"]
            conds = {
                c["type"]: c["status"]
                for c in co["status"].get("conditions", [])
            }
            avail = conds.get("Available", "?")
            prog = conds.get("Progressing", "?")
            deg = conds.get("Degraded", "?")
            version = ""
            for v in co["status"].get("versions", []):
                if v.get("name") == "operator":
                    version = v.get("version", "")
                    break
            rows.append((name, avail, prog, deg, version))
            if deg == "True":
                degraded.append(name)

        print(f"\n--- {cluster} Cluster Operators ({len(rows)}) ---")
        print(format_table(
            ["OPERATOR", "AVAILABLE", "PROGRESSING", "DEGRADED", "VERSION"],
            sorted(rows),
        ))
        assert not degraded, f"{cluster}: degraded operators: {degraded}"

    def test_spoke_no_unavailable_operators(self, cluster):
        cos = spoke_oc_json(cluster, "get clusteroperators")
        total = len(cos["items"])
        unavailable = [
            co["metadata"]["name"]
            for co in cos["items"]
            if {c["type"]: c["status"] for c in co["status"].get("conditions", [])}.get(
                "Available"
            )
            != "True"
        ]
        print(f"\n{cluster} operators: {total} total, {total - len(unavailable)} available, {len(unavailable)} unavailable")
        if unavailable:
            print(f"  Unavailable: {unavailable}")
        assert not unavailable, f"{cluster}: unavailable operators: {unavailable}"

    @pytest.mark.parametrize("operator", SPOKE_EXPECTED_OPERATORS)
    def test_spoke_expected_csv_succeeded(self, cluster, operator):
        csvs = spoke_oc_json(cluster, "get csv -A")
        matches = [
            (item["metadata"]["name"], item["status"].get("phase", ""))
            for item in csvs["items"]
            if operator in item["metadata"]["name"]
        ]
        assert matches, f"{cluster}: no CSV matching '{operator}'"
        for name, phase in matches:
            print(f"  {name}: {phase}")
        assert all(
            phase == "Succeeded" for _, phase in matches
        ), f"{cluster}: CSV not Succeeded: {matches}"

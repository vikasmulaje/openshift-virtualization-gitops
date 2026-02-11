# Create cluster spoke1

## Prerequisites

Before deploying this cluster, you need to create the required secrets manually (they will not be present in the git repository):

### BMC credentials secret:

```yaml
kind: Secret
apiVersion: v1
metadata:
  name: bmc-credentials
  namespace: spoke1
stringData: 
  username: <your-bmc-username>
  password: <your-bmc-password>
```

### Pull secret:

```yaml
kind: Secret
apiVersion: v1
metadata:
  name: pullsecret-spoke1
  namespace: spoke1
stringData:
  '.dockerconfigjson': '<pull-secret-json>'
type: 'kubernetes.io/dockerconfigjson'
```

You can reuse the pull secret from the hub cluster:
```sh
oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > /tmp/pull-secret.json
oc create secret generic pullsecret-spoke1 -n spoke1 --from-file=.dockerconfigjson=/tmp/pull-secret.json --type=kubernetes.io/dockerconfigjson
```

## Configuration Required

Before applying, you must update the following files with your actual infrastructure details:

1. **Bare Metal Hosts** (`*-baremetal-host.yaml`):
   - Replace `CHANGE_ME_BMC_IP` with actual BMC IP addresses
   - Replace `CHANGE_ME_BOOT_MAC` with actual boot MAC addresses

2. **NMState Configs** (`*-nmstate-config.yaml`):
   - Replace `CHANGE_ME_STATIC_IP` with actual static IP addresses for each node
   - Replace `CHANGE_ME_GATEWAY` with your network gateway
   - Replace `CHANGE_ME_MAC_ADDRESS` with actual MAC addresses (should match boot MAC)

3. **DNS Endpoints** (`*-fqdn.yaml`):
   - Replace `CHANGE_ME_STATIC_IP` with actual static IP addresses (should match NMState configs)

4. **Network Configuration** (`kustomization.yaml`):
   - Verify `ingressVIP` and `apiVIP` are available and not conflicting
   - Adjust `podCIDR` and `serviceCIDR` if they conflict with existing networks

## Deployment

Once configured, create the namespace and secrets:

```sh
oc new-project spoke1
oc apply -f ./bmc-credentials-secret.yaml -n spoke1
oc apply -f ./pull-secret.yaml -n spoke1
```

Then apply the cluster configuration through ArgoCD or directly:

```sh
oc apply -k clusters/hub/overlays/cluster-spoke1
```

# Spoke1 Cluster - VM Details

## Virtual Machines Created

Three virtual machines have been created on `cert-rhosp-01.lab.eng.rdu2.redhat.com` using libvirt/virsh:

### VM Specifications
- **Count**: 3 control plane nodes (masters)
- **Resources per VM**: 8GB RAM, 4 vCPUs, 20GB disk
- **Network**: baremetal-0 (192.168.123.0/24)
- **Hypervisor**: QEMU/KVM with libvirt

### Node Details

| Node | MAC Address | Static IP | BMC/IPMI IP | Hostname |
|------|-------------|-----------|-------------|----------|
| spoke1-master-0 | 52:54:00:aa:01:00 | 192.168.123.210 | 192.168.123.220 | spoke1-master-0.spoke1.qe.lab.redhat.com |
| spoke1-master-1 | 52:54:00:aa:01:01 | 192.168.123.211 | 192.168.123.221 | spoke1-master-1.spoke1.qe.lab.redhat.com |
| spoke1-master-2 | 52:54:00:aa:01:02 | 192.168.123.212 | 192.168.123.222 | spoke1-master-2.spoke1.qe.lab.redhat.com |

### Network Configuration
- **Network**: baremetal-0
- **Network CIDR**: 192.168.123.0/24
- **Gateway**: 192.168.123.1
- **Platform Base Domain**: qe.lab.redhat.com
- **Cluster Base Domain**: spoke1.qe.lab.redhat.com

### IPMI/BMC Configuration
Each VM has IPMI/BMC simulation configured via QEMU's IPMI simulator:
- IPMI is accessible at the BMC IP addresses listed above
- Port: 623 (standard IPMI port)
- Credentials: Will be set via the `bmc-credentials` secret in the cluster

### Cluster Network Settings
- **Pod CIDR**: 10.132.0.0/14
- **Service CIDR**: 172.31.0.0/16
- **API VIP**: 192.168.123.201
- **Ingress VIP**: 192.168.123.200

## VM Management Commands

### View VM Status
```bash
virsh list --all | grep spoke1
```

### Start VMs
```bash
for vm in spoke1-master-0 spoke1-master-1 spoke1-master-2; do
  virsh start $vm
done
```

### Stop VMs
```bash
for vm in spoke1-master-0 spoke1-master-1 spoke1-master-2; do
  virsh destroy $vm
done
```

### View VM Details
```bash
virsh dominfo spoke1-master-0
virsh domiflist spoke1-master-0
```

### Access VM Console
```bash
virsh console spoke1-master-0
```

## Configuration Files Updated

All configuration files have been updated with the actual VM details:
- ✅ BareMetalHost definitions (MAC addresses, BMC IPs)
- ✅ NMStateConfig (static IPs, gateway, MAC addresses)
- ✅ DNSEndpoint (DNS entries with static IPs)

## Next Steps

1. **Create Secrets** on the hub cluster:
   ```bash
   export KUBECONFIG=/home/kni/clusterconfigs/auth/kubeconfig
   oc new-project spoke1
   
   # BMC credentials (use appropriate username/password)
   oc create secret generic bmc-credentials -n spoke1 \
     --from-literal=username='root' \
     --from-literal=password='redhat'
   
   # Pull secret (reuse from hub)
   oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | \
     base64 -d | oc create secret generic pullsecret-spoke1 \
     -n spoke1 --from-file=.dockerconfigjson=/dev/stdin \
     --type=kubernetes.io/dockerconfigjson
   ```

2. **Deploy Cluster Configuration**:
   - Via ArgoCD (if configured): Commit changes and ArgoCD will apply
   - Manually: Apply the kustomization with helm support

3. **Start VMs** when ready for cluster installation:
   ```bash
   for vm in spoke1-master-0 spoke1-master-1 spoke1-master-2; do
     virsh start $vm
   done
   ```

4. **Monitor Cluster Creation**:
   ```bash
   oc get clusterdeployment -n spoke1
   oc get agentclusterinstall -n spoke1
   oc get agents -n spoke1
   ```

## Notes

- VMs are currently **shut off** and will be started when cluster installation begins
- The VMs will boot from PXE/network when started (configured for agent-based installation)
- IPMI/BMC is simulated via QEMU - standard IPMI tools should work
- All network configuration is static (no DHCP) as configured in NMStateConfig

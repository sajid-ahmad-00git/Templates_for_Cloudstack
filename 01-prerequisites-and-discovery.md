# Prerequisites and discovery

This chapter identifies the infrastructure before making changes. Do not install image-building tools on the CloudStack Management Server or manually create libvirt VMs on CloudStack-managed KVM hosts.

The workflow in this repository builds a temporary VM from a Rocky Linux Minimal ISO **inside CloudStack**, configures it, powers it off, and creates a template from its root volume.

## 1. Required access

You need:

- A CloudStack root administrator or an account with permission to manage ISOs, networks, instances, volumes, templates, firewall rules, and SSH key pairs.
- CloudMonkey (`cmk`) configured on a trusted administration machine or Management Server.
- `jq` and `curl`.
- SSH access to each KVM host for read-only CPU checks. Host configuration changes require a change window.
- A dedicated build account or the CloudStack `admin` account.
- An approved administration CIDR for SSH tests.

Never put CloudMonkey API keys in this repository.

## 2. Supported environment

The worked build used:

```text
Apache CloudStack: 4.23.0.0
Zone: Advanced
Hypervisor: KVM
KVM cluster: three hosts
Primary storage: Ceph RBD, zone scope
Secondary storage: NFS
Network: isolated, Virtual Router services
Guest OS: Rocky Linux 9.8 x86_64 Minimal
```

Replace all UUIDs and names below with values from your environment.

## 3. Confirm CloudStack and system VMs

Run the read-only helper:

```bash
chmod +x scripts/collect-cloudstack-info.sh
./scripts/collect-cloudstack-info.sh
```

Or query individual objects:

```bash
cmk list capabilities | jq -r '.. | objects | .cloudstackversion? // empty'
```

```bash
cmk list zones listall=true | jq
cmk list clusters listall=true | jq
cmk list hosts listall=true hypervisor=KVM | jq
cmk list storagepools listall=true | jq
cmk list imagestores | jq
cmk list systemvms listall=true | jq
```

Required state before building:

| Component | Required condition |
|---|---|
| Zone | Enabled |
| KVM cluster | Enabled and Managed |
| KVM hosts | Up and Enabled |
| Primary storage | Up |
| Secondary Storage VM | Running |
| Console Proxy VM | Running |
| Secondary storage | Available |

## 4. Distinguish primary and secondary NFS

NFS secondary storage stores ISOs and templates. It does not prove that VM root or data volumes work on NFS primary storage.

Record primary storage separately:

```bash
cmk list storagepools listall=true | jq -r '
  .. | objects |
  select(.id? and .name? and .type?) |
  [.id, .name, .type, .scope, .state] | @tsv
'
```

If only RBD primary storage exists, build and validate on RBD. Mark NFS primary tests as pending rather than claiming NFS validation.

## 5. Select network offerings

For an isolated build network, use an enabled offering that provides at least:

- DHCP
- DNS
- User Data
- Source NAT
- Firewall
- Port Forwarding, if external SSH is needed

Inspect providers:

```bash
cmk list networkofferings listall=true | jq -r '
  .. | objects |
  select(.id? and .name? and .guestiptype? and .service?) |
  [
    .id,
    .name,
    .guestiptype,
    ([.service[]? | (.name // "unknown") + ":" + ([.provider[]?.name] | join(","))] | join(";"))
  ] | @tsv
'
```

The tested isolated offering delivered DHCP, DNS, User Data, Source NAT, firewall, port forwarding, and static NAT through `VirtualRouter`.

Do not reuse another tenant's network. Create a dedicated admin-owned build network.

For shared-network validation, provision a separate approved shared network. It must provide DHCP, DNS, and User Data through a supported provider. Creating a shared network usually requires a network-owned VLAN, gateway, netmask, and IP range; do not invent those values.

## 6. Confirm Rocky OS type

```bash
cmk list ostypes | jq -r '
  .. | objects |
  select(.id? and .description?) |
  select(.description | ascii_downcase | contains("rocky")) |
  [.id, .description, (.oscategoryname // "unknown")] | @tsv
'
```

Select the `Rocky Linux 9` OS type. Do not directly modify the CloudStack database to add an OS type.

## 7. Select compute and disk offerings

A builder VM needs approximately:

```text
2 vCPU
4 GiB RAM
20 GiB root disk
Shared primary storage
```

List compute offerings:

```bash
cmk list serviceofferings listall=true issystem=false | jq -r '
  .. | objects |
  select(.id? and .name? and .cpunumber? and .memory?) |
  [.id, .name, (.cpunumber | tostring), (.memory | tostring), (.storagetype // "unknown")] | @tsv
'
```

List disk offerings:

```bash
cmk list diskofferings listall=true | jq -r '
  .. | objects |
  select(.id? and .name?) |
  [.id, .name, ((.disksize // 0) | tostring), ((.iscustomized // false) | tostring), (.storagetype // "unknown")] | @tsv
'
```

Use a fixed 20 GiB disk offering or a custom offering explicitly set to 20 GiB.

## 8. KVM CPU compatibility gate

Rocky Linux 9 requires the x86-64-v2 CPU baseline. CloudStack may generate a libvirt domain with the generic `qemu64` model, which can hide required instructions even when the host CPU is new.

Check every KVM host:

```bash
hostnamectl --static
lscpu | grep -E 'Architecture|Vendor ID|Model name|Virtualization'

sudo grep -nE '^(guest\.)?cpu\.(mode|model)=' \
  /etc/cloudstack/agent/agent.properties || \
  echo 'No explicit CPU mode/model configured'

sudo virsh domcapabilities \
  | sed -n "/<mode name='host-model'/,/<\/mode>/p" \
  | head -n 15
```

Check required host features. Linux often reports SSE3 as `pni`:

```bash
for requirement in \
  cx16:cx16 lahf_lm:lahf_lm popcnt:popcnt sse3:pni \
  ssse3:ssse3 sse4_1:sse4_1 sse4_2:sse4_2
 do
  label=${requirement%%:*}
  flag=${requirement##*:}
  grep -qm1 -w "$flag" /proc/cpuinfo \
    && printf '%-10s PASS\n' "$label" \
    || printf '%-10s MISSING\n' "$label"
done
```

Also check Rocky 10's future x86-64-v3 baseline if the same cluster will host Rocky 10:

```bash
for flag in avx avx2 bmi1 bmi2 f16c fma movbe; do
  grep -qm1 -w "$flag" /proc/cpuinfo \
    && printf '%-10s PASS\n' "$flag" \
    || printf '%-10s MISSING\n' "$flag"
done
```

### If the VM uses `qemu64`

Inspect the failed VM XML on its KVM host:

```bash
sudo virsh dumpxml INSTANCE_NAME | sed -n '/<cpu /,/<\/cpu>/p'
```

A problematic configuration looks like:

```xml
<cpu mode='custom' match='exact' check='full'>
  <model fallback='forbid'>qemu64</model>
</cpu>
```

The tested correction was a consistent host setting on all eligible KVM hosts:

```properties
guest.cpu.mode=host-model
```

> [!CAUTION]
> This is a host-wide behavior change. It affects future starts of other VMs, and potentially migration compatibility. Verify all hosts are homogeneous, schedule a change window, back up the file, and restart one agent at a time. Do not edit CloudStack-managed domain XML manually.

On each host:

```bash
AGENT_FILE=/etc/cloudstack/agent/agent.properties
BACKUP_FILE=${AGENT_FILE}.bak.$(date -u +%Y%m%dT%H%M%SZ)
sudo cp -a "$AGENT_FILE" "$BACKUP_FILE"

if sudo grep -q '^guest\.cpu\.mode=' "$AGENT_FILE"; then
  echo 'STOP: an active guest.cpu.mode already exists'
  sudo grep -n '^guest\.cpu\.mode=' "$AGENT_FILE"
else
  printf '\nguest.cpu.mode=host-model\n' | sudo tee -a "$AGENT_FILE" >/dev/null
fi

sudo systemctl restart cloudstack-agent
systemctl is-active cloudstack-agent
```

Verify that the host returns to `Up` and `Enabled` in CloudStack before changing the next host.

`host-model` was selected over `host-passthrough` because the target requires migration and recovery across eligible hosts. If host CPUs differ, select a common named CPU model only after confirming it is usable everywhere.

References:

- [CloudStack KVM host requirements](https://docs.cloudstack.apache.org/en/latest/installguide/hypervisor/kvm.html)
- [CloudStack issue: Rocky 9 fails on Ubuntu KVM hosts](https://github.com/apache/cloudstack/issues/8757)
- [QEMU CPU model guidance](https://www.qemu.org/docs/master/system/qemu-cpu-models.html)

## 9. Pre-flight exit gate

Do not register the ISO or create the builder until:

- CloudStack version is confirmed.
- The zone, cluster, and all intended hosts are healthy.
- Primary and secondary storage roles are understood.
- A Rocky 9 guest OS type exists.
- A 2-vCPU/4-GiB offering and 20-GiB disk offering exist.
- A suitable isolated Virtual Router offering exists.
- The build account and administrative CIDR are recorded.
- Every eligible host can present a Rocky-compatible CPU model.

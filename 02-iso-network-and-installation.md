# ISO, network, and Rocky Linux installation

This chapter registers the Rocky Linux Minimal ISO, creates a dedicated isolated build network, deploys a 20 GiB legacy-BIOS VM, and installs Rocky with an expansion-friendly disk layout.

Commands use placeholders. Set them from your discovery results:

```bash
export ROOT_DOMAIN_ID='<ROOT_DOMAIN_UUID>'
export ZONE_ID='<ZONE_UUID>'
export ROCKY9_OS_TYPE_ID='<ROCKY_9_OS_TYPE_UUID>'
export SERVICE_OFFERING_ID='<2_CPU_4_GIB_OFFERING_UUID>'
export DISK_OFFERING_ID='<20_GIB_DISK_OFFERING_UUID>'
export ISOLATED_OFFERING_ID='<ISOLATED_VR_OFFERING_UUID>'
```

## 1. Discover the current Rocky 9 Minimal ISO

Use Rocky's official download service:

```bash
ROCKY9_BASE_URL='https://download.rockylinux.org/pub/rocky/9/isos/x86_64'

curl --fail --silent --show-error "$ROCKY9_BASE_URL/" \
  | grep -oE 'Rocky-9\.[0-9]+-x86_64-minimal\.iso' \
  | sort -Vu
```

Select the current release:

```bash
ROCKY9_ISO_NAME=$(
  curl --fail --silent --show-error "$ROCKY9_BASE_URL/" \
    | grep -oE 'Rocky-9\.[0-9]+-x86_64-minimal\.iso' \
    | sort -Vu \
    | tail -n 1
)
ROCKY9_ISO_URL="$ROCKY9_BASE_URL/$ROCKY9_ISO_NAME"
printf 'ISO=%s\nURL=%s\n' "$ROCKY9_ISO_NAME" "$ROCKY9_ISO_URL"
```

Confirm HTTP availability:

```bash
curl --head --location --max-time 30 "$ROCKY9_ISO_URL"
```

## 2. Verify checksum metadata

```bash
curl --fail --silent --show-error "$ROCKY9_ISO_URL.CHECKSUM"
```

Extract the SHA-256 value:

```bash
ROCKY9_SHA256=$(
  curl --fail --silent --show-error "$ROCKY9_ISO_URL.CHECKSUM" \
    | grep -oE '[a-fA-F0-9]{64}' \
    | head -n 1
)
printf 'SHA-256=%s\n' "$ROCKY9_SHA256"
```

The tested Rocky 9.8 metadata had an incorrect byte-count comment while the SHA-256 was correct. Use the cryptographic hash as the integrity value. CloudStack will validate the downloaded ISO against it.

## 3. Register the ISO privately

First check for an existing ISO:

```bash
cmk list isos name="$ROCKY9_ISO_NAME" zoneid="$ZONE_ID" isofilter=all listall=true | jq
```

If none exists, register it:

```bash
REGISTER_RESULT=$(
  cmk register iso \
    name="$ROCKY9_ISO_NAME" \
    displaytext="Rocky Linux 9 Minimal x86_64 - Template Build Source" \
    url="$ROCKY9_ISO_URL" \
    zoneid="$ZONE_ID" \
    ostypeid="$ROCKY9_OS_TYPE_ID" \
    account=admin \
    domainid="$ROOT_DOMAIN_ID" \
    arch=x86_64 \
    bootable=true \
    checksum="{SHA-256}${ROCKY9_SHA256}" \
    directdownload=false \
    ispublic=false \
    isfeatured=false \
    isextractable=false \
    isdynamicallyscalable=false \
    passwordenabled=false \
    2>&1
)
printf '%s\n' "$REGISTER_RESULT" | jq
```

Capture the ID:

```bash
ISO_ID=$(printf '%s\n' "$REGISTER_RESULT" | jq -r '.. | objects | .id? // empty' | head -n 1)
printf 'ISO_ID=%s\n' "$ISO_ID"
```

Monitor until ready:

```bash
cmk list isos id="$ISO_ID" zoneid="$ZONE_ID" isofilter=all listall=true | jq
```

Do not deploy until `isready=true` and the download detail reports `100%`/`DOWNLOADED`.

## 4. Create a dedicated isolated build network

Use a new admin-owned network. Do not use another tenant's network.

```bash
BUILD_NETWORK_NAME='rocky-template-build-net'
```

Check for duplicates:

```bash
cmk list networks name="$BUILD_NETWORK_NAME" listall=true | jq
```

Create it:

```bash
NETWORK_RESULT=$(
  cmk create network \
    name="$BUILD_NETWORK_NAME" \
    displaytext='Admin-owned isolated network for Rocky template preparation' \
    networkofferingid="$ISOLATED_OFFERING_ID" \
    zoneid="$ZONE_ID" \
    account=admin \
    domainid="$ROOT_DOMAIN_ID" \
    acltype=Account \
    displaynetwork=true \
    networkdomain='rocky-template.internal' \
    2>&1
)
printf '%s\n' "$NETWORK_RESULT" | jq
```

Capture the network ID:

```bash
BUILD_NETWORK_ID=$(printf '%s\n' "$NETWORK_RESULT" | jq -r '.. | objects | select(.name? == "rocky-template-build-net") | .id' | head -n 1)
printf 'BUILD_NETWORK_ID=%s\n' "$BUILD_NETWORK_ID"
```

> [!IMPORTANT]
> Do not pass `physicalnetworkid` for this isolated-network call. In the tested CloudStack environment it failed with: `Physical network ID can be specified for networks of guest IP type Shared or L2 only.` CloudStack assigned the correct Guest physical network automatically.

The network may remain `Allocated` until its first VM starts.

## 5. Configure default-deny egress

Check the network object and current egress rules:

```bash
cmk list networks id="$BUILD_NETWORK_ID" listall=true | jq
cmk list egressfirewallrules networkid="$BUILD_NETWORK_ID" listall=true | jq
```

If the network has default-deny egress, create only the required rules. Replace `GUEST_CIDR` with the actual isolated-network CIDR:

```bash
export GUEST_CIDR='<GUEST_CIDR>'
```

HTTPS:

```bash
cmk create egressfirewallrule networkid="$BUILD_NETWORK_ID" protocol=TCP cidrlist="$GUEST_CIDR" destcidrlist=0.0.0.0/0 startport=443 endport=443 type=user fordisplay=true
```

HTTP, if required by mirrors or redirects:

```bash
cmk create egressfirewallrule networkid="$BUILD_NETWORK_ID" protocol=TCP cidrlist="$GUEST_CIDR" destcidrlist=0.0.0.0/0 startport=80 endport=80 type=user fordisplay=true
```

NTP:

```bash
cmk create egressfirewallrule networkid="$BUILD_NETWORK_ID" protocol=UDP cidrlist="$GUEST_CIDR" destcidrlist=0.0.0.0/0 startport=123 endport=123 type=user fordisplay=true
```

ICMP, only if ping testing is required:

```bash
cmk create egressfirewallrule networkid="$BUILD_NETWORK_ID" protocol=ICMP cidrlist="$GUEST_CIDR" destcidrlist=0.0.0.0/0 icmptype=-1 icmpcode=-1 type=user fordisplay=true
```

Each call is asynchronous. Capture the job ID and wait for `jobstatus=1` before proceeding.

## 6. Deploy the builder VM

Wait until the ISO is ready and confirm the name is unused:

```bash
BUILDER_NAME='rocky9-template-builder-01'
cmk list virtualmachines listall=true | jq --arg name "$BUILDER_NAME" '[.. | objects | select(.name? == $name)] | unique_by(.id) | length'
```

Deploy:

```bash
DEPLOY_RESULT=$(
  cmk deploy virtualmachine \
    name="$BUILDER_NAME" \
    displayname='Rocky Linux 9 Template Builder' \
    serviceofferingid="$SERVICE_OFFERING_ID" \
    diskofferingid="$DISK_OFFERING_ID" \
    templateid="$ISO_ID" \
    zoneid="$ZONE_ID" \
    networkids="$BUILD_NETWORK_ID" \
    account=admin \
    domainid="$ROOT_DOMAIN_ID" \
    hypervisor=KVM \
    boottype=BIOS \
    bootmode=Legacy \
    keyboard=us \
    startvm=true \
    2>&1
)
printf '%s\n' "$DEPLOY_RESULT" | jq
```

> [!NOTE]
> The direct API call in the tested CloudStack 4.23 environment failed when `boottype=BIOS` was passed without a boot mode. Supplying both `boottype=BIOS` and `bootmode=Legacy` avoided the null boot-mode exception. `bootmode` is normally discussed with UEFI, but this API path still required it.

Verify:

- VM is Running.
- Hypervisor is KVM.
- Root volume is exactly 20 GiB.
- Storage is the expected Ceph RBD pool.
- Network is Implemented.
- Virtual Router is Running.

## 7. If the installer panics

If the console shows `Kernel panic - not syncing: Attempted to kill init`, inspect the domain CPU XML. The likely cause is `qemu64`; follow the CPU gate in [Prerequisites and discovery](01-prerequisites-and-discovery.md#8-kvm-cpu-compatibility-gate).

Do not switch to UEFI and do not edit the CloudStack-managed libvirt XML manually.

## 8. Rocky installer settings

Open the CloudStack console and select:

| Installer area | Setting |
|---|---|
| Keyboard | English (US) |
| Language | English (United States) |
| Time and Date | UTC; network time enabled |
| Installation source | Local media |
| Software selection | Minimal Install; no add-ons |
| Kdump | Disabled |
| Network | `ens3` on; IPv4 DHCP; autoconnect |
| Temporary hostname | `rocky9-template-builder.localdomain` |
| Root password | Strong, unique temporary build password |

Do not publish or reuse the temporary password.

### Disk layout

Select the one 20 GiB disk and choose **Custom** partitioning with **Standard Partition**, not LVM.

Create:

```text
1 MiB       biosboot     BIOS boot partition; no normal mount point
remainder   /            XFS standard partition
```

Do not create:

- `/boot/efi`
- LVM physical volumes or logical volumes
- A swap partition after root
- Separate `/home` or `/var` partitions

The root partition must remain the final partition so `growpart` can extend it later.

Confirm the 20 GiB disk is the bootloader target, accept the changes, and begin installation.

## 9. First boot

After installation, reboot. If the ISO menu reappears, choose **Boot from local drive**. Log in at the console as:

```text
Username: root
Password: temporary build password
```

Check:

```bash
test ! -d /sys/firmware/efi && echo 'BIOS: PASS' || echo 'BIOS: FAIL'
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
findmnt /
df -hT /
ip -br address
ip route
cat /etc/resolv.conf
```

Required:

- Legacy BIOS
- Approximately 20 GiB disk
- Standard XFS root partition
- DHCP address and default route
- No LVM

## 10. Detach the ISO

From CloudStack, detach the ISO after the installed OS boots:

```bash
cmk detach iso virtualmachineid='<BUILDER_VM_UUID>'
```

Wait for the asynchronous job to succeed and verify no ISO is attached. The builder must subsequently boot from its Ceph RBD root disk.

Continue with [Guest configuration](03-guest-configuration.md).

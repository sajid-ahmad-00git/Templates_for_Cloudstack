# Generalize, create, and test the template

Generalization removes machine-specific identity and all build credentials. Once cleanup begins, complete it in one console session and power off. Do not reboot the source VM.

## 1. Final update

```bash
dnf -y upgrade --refresh
```

If packages change, reboot and repeat the pre-cleanup checks before continuing. If the system is current, proceed.

## 2. Remove optional build-only packages

Remove an editor installed only for the build, but retain `wget`:

```bash
dnf -y remove nano || true
rpm -q wget
dnf clean all
rm -rf /var/cache/dnf/*
```

Do not run `dnf autoremove` because it may remove required dependencies.

Disable kdump if present:

```bash
systemctl disable --now kdump.service || true
```

A message showing that the `kdump.service` symlink was removed indicates success. A harmless `rc.local is not marked executable` message does not require a change.

## 3. Remove unused default user

This guide supports root as the default login account:

```bash
if id cloud-user >/dev/null 2>&1; then
  userdel -r cloud-user
fi
```

Never remove a user that your organization intentionally requires.

## 4. Remove test artifacts

```bash
rm -f /var/lib/cloud/root-password-from-userdata
rm -f /var/lib/cloud/diagnostic-userdata-completed
rm -f /var/log/cloudstack-native-password-preoverride.txt
```

## 5. Remove SSH keys and host identity

```bash
rm -rf /root/.ssh
rm -rf /home/*/.ssh
rm -f /etc/ssh/ssh_host_*
```

Verify no key remains:

```bash
find /root /home -type f -name authorized_keys -print
find /root /home -type f -name 'id_*' -print
```

Both commands should return no files.

New SSH host keys will be generated when a VM boots from the template.

## 6. Clean cloud-init and machine identity

Confirm supported cleanup options:

```bash
cloud-init clean --help
```

Then:

```bash
cloud-init clean --logs --seed --machine-id
```

Do not run `cloud-init status` after cleaning. Doing so is unnecessary and may create new state.

`/etc/machine-id` should now be empty or contain the systemd uninitialized marker:

```bash
cat /etc/machine-id
```

Do not run `systemd-machine-id-setup` in the source image.

## 7. Remove network leases and random state

```bash
rm -f /var/lib/NetworkManager/*.lease
rm -f /var/lib/NetworkManager/*.lease-*
rm -f /var/lib/dhclient/*
rm -f /var/lib/systemd/random-seed
```

Keep the persistent DHCP keyfile under `/etc/NetworkManager/system-connections/`.

## 8. Remove temporary files

```bash
rm -rf /tmp/*
rm -rf /var/tmp/*
```

## 9. Lock the build password

```bash
passwd --lock root
passwd --status root
```

The status should contain `LK`. CloudStack/cloud-init will set and unlock a unique password on deployment.

## 10. Clear logs and history

```bash
journalctl --rotate
journalctl --vacuum-time=1s
find /var/log -type f -exec truncate -s 0 {} \;
history -c
rm -f /root/.bash_history
unset HISTFILE
```

## 11. Trim and power off

```bash
fstrim -av
sync
poweroff
```

An unsupported-discard warning should be recorded but does not automatically block template creation.

> [!WARNING]
> Do not start the source VM again. Booting it regenerates cloud-init state, machine ID, leases, host keys, logs, and random state. If it is started, repeat the entire generalization procedure.

## 12. Identify the stopped source and root volume

Run on the CloudStack Management Server:

```bash
export SOURCE_VM_NAME='<GENERALIZED_VM_NAME>'
export ROOT_DOMAIN_ID='<ROOT_DOMAIN_UUID>'
```

```bash
VM_RESULT=$(cmk list virtualmachines name="$SOURCE_VM_NAME" account=admin domainid="$ROOT_DOMAIN_ID" listall=true)
printf '%s\n' "$VM_RESULT" | jq
```

Require one exact match and `state=Stopped`.

```bash
SOURCE_VM_ID=$(printf '%s\n' "$VM_RESULT" | jq -r --arg name "$SOURCE_VM_NAME" '.. | objects | select(.id? and .name? == $name) | .id' | sort -u | head -n 1)
```

Find the root volume:

```bash
VOLUME_RESULT=$(cmk list volumes virtualmachineid="$SOURCE_VM_ID" type=ROOT listall=true)
printf '%s\n' "$VOLUME_RESULT" | jq
SOURCE_VOLUME_ID=$(printf '%s\n' "$VOLUME_RESULT" | jq -r '.. | objects | select(.id? and .type? == "ROOT") | .id' | sort -u | head -n 1)
```

Require:

```text
VM: Stopped
Volume: Ready
Size: 20 GiB
Storage: intended primary pool
```

## 13. Create a private template

Set:

```bash
export ZONE_ID='<ZONE_UUID>'
export ROCKY9_OS_TYPE_ID='<ROCKY_9_OS_TYPE_UUID>'
export TEMPLATE_NAME='Rocky-9.x-x86_64-BIOS-KVM-20G-v1'
export TEMPLATE_DISPLAY='Rocky Linux 9 x86_64 - BIOS - KVM - 20 GiB - Cloud-init'
```

Use a higher revision when replacing a failed candidate. Never overwrite evidence from a failed validation run.

Check for duplicates:

```bash
cmk list templates templatefilter=all listall=true | jq --arg name "$TEMPLATE_NAME" '[.. | objects | select(.id? and .name? == $name)] | unique_by(.id) | length'
```

Create:

```bash
CREATE_RESULT=$(
  cmk create template \
    name="$TEMPLATE_NAME" \
    displaytext="$TEMPLATE_DISPLAY" \
    ostypeid="$ROCKY9_OS_TYPE_ID" \
    volumeid="$SOURCE_VOLUME_ID" \
    account=admin \
    domainid="$ROOT_DOMAIN_ID" \
    arch=x86_64 \
    passwordenabled=true \
    requireshvm=true \
    isdynamicallyscalable=false \
    ispublic=false \
    2>&1
)
printf '%s\n' "$CREATE_RESULT" | jq
```

Wait for the async job, locate the template by exact name, and require:

```text
ready=true
format=QCOW2
hypervisor=KVM
passwordEnabled=true
requiresHVM=true
sizeGiB=20
owner=admin
public=false
```

Keep the template private until the full validation matrix passes.

## 14. Native generated-password test

Deploy a new VM with:

- The candidate template
- The dedicated isolated test network
- An approved compute offering
- No User Data
- A selected SSH key for emergency diagnostics
- BIOS/Legacy

Record CloudStack's generated password securely.

Wait for cloud-init, then test password authentication from a normal SSH terminal rather than noVNC:

```bash
ssh -o PubkeyAuthentication=no \
  -o PreferredAuthentications=password \
  root@VM_ADDRESS
```

This prevents an installed key from hiding a password failure.

### Required guest checks

```bash
cloud-init status --long
cloud-id
passwd --status root
rpm -q wget
```

Require:

```text
DataSourceCloudStack
root password state PS
wget installed
```

If the password fails but key login works, inspect:

```bash
grep -n -B8 -A12 'Failed to fetch password' /var/log/cloud-init.log
```

A `FileNotFoundError` for `wget` means the image omitted the dependency. Do not work around that failure with a default password.

## 15. Password-reset test

With the native-password test VM:

1. Stop the VM through CloudStack.
2. Select **Reset Password**.
3. Record the new generated password.
4. Start the VM.
5. Wait for cloud-init.
6. Confirm the new password works and the old password fails.
7. Confirm key authentication still works.

The image configures:

```yaml
- [set_passwords, always]
```

so the password module checks CloudStack on later boots.

## 16. SSH public-key test

Deploy or reuse a VM created with an admin-owned test key pair. Test key-only access:

```bash
ssh -o PasswordAuthentication=no \
  -i ~/.ssh/rocky-template-validation \
  root@VM_ADDRESS
```

Inside the VM:

```bash
stat /root/.ssh/authorized_keys
ssh-keygen -lf /root/.ssh/authorized_keys
ls -lZ /root/.ssh/authorized_keys
```

Require correct ownership, restrictive permissions, SELinux context, and the expected fingerprint.

An empty `authorized_keys` file is expected if no key pair was selected; it is a failure if a key pair was selected.

## 17. Caller-selected User Data password

Generate a hash on a trusted workstation:

```bash
openssl passwd -6
```

Paste a populated copy of [the User Data example](../examples/user-data-set-root-password.sh) into CloudStack's User Data field. Do not base64-encode it manually in the UI.

The script runs once in cloud-init's final stage and overrides the initial root password. Do not assume CloudStack's separately displayed native password will remain valid for that deployment.

Verify:

```bash
cat /var/lib/cloud/root-password-from-userdata
passwd --status root
```

Then test both password-only and key-only SSH.

## 18. Identity tests

For at least two independently deployed VMs:

```bash
cat /etc/machine-id
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

The machine IDs and SSH host-key fingerprints must differ.

Confirm BIOS:

```bash
test ! -d /sys/firmware/efi && echo 'BIOS: PASS' || echo 'BIOS: FAIL'
```

## 19. Root-disk expansion

Test both paths supported by your CloudStack deployment.

### Larger root disk at deployment

Deploy with a root size greater than 20 GiB, for example 30 GiB. After boot:

```bash
cloud-init status --wait
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
df -hT /
```

The disk, final root partition, and XFS filesystem should all show the larger capacity.

### Resize an existing root volume

Record the original layout, resize through CloudStack, and reboot or stop/start as required by the storage operation. Recheck `lsblk` and `df`.

If automatic expansion fails, collect cloud-init logs before using this diagnostic fallback:

```bash
ROOT_SOURCE=$(findmnt -n -o SOURCE /)
ROOT_PARENT=$(lsblk -n -o PKNAME "$ROOT_SOURCE")
ROOT_PART=$(lsblk -n -o PARTN "$ROOT_SOURCE")
growpart "/dev/$ROOT_PARENT" "$ROOT_PART"
xfs_growfs /
```

Do not bake the fallback into every boot without understanding the failure.

## 20. Additional disk and persistence

Attach a test data disk. Identify it carefully:

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL,SERIAL
```

Only after positively identifying the new empty device:

```bash
mkfs.xfs /dev/vdb
mkdir -p /data
UUID=$(blkid -s UUID -o value /dev/vdb)
printf 'UUID=%s /data xfs defaults,nofail 0 2\n' "$UUID" >> /etc/fstab
mount -a
findmnt /data
```

Write a test file, reboot, stop/start, and verify it persists.

## 21. Host, network, and storage coverage

- Deploy on or migrate to every eligible KVM host.
- Validate CPU compatibility and boot after migration.
- Validate the dedicated isolated Virtual Router network.
- Validate a separate approved shared network with DHCP, DNS, and User Data.
- Validate Ceph RBD.
- Validate NFS primary storage only if an NFS primary pool exists.

Continue to the [validation matrix](05-validation-matrix.md) and do not publish until all mandatory rows pass.

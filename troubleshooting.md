# Troubleshooting

This chapter records problems encountered during the real CloudStack 4.23 / Rocky Linux 9.8 build and the verified resolution or safe diagnostic path.

## CloudMonkey returns blank filtered output

### Symptom

A command such as `list zones` appears to return no objects after `grep 'id ='`, even though the UI contains resources.

### Cause

Modern CloudMonkey output is JSON:

```json
{"id": "...", "name": "..."}
```

Old examples search for table-style text such as `id =` and therefore remove every line.

### Fix

Use `jq` against the JSON object:

```bash
cmk list zones listall=true | jq
```

Use the repository's `scripts/collect-cloudstack-info.sh` for formatted, read-only discovery.

## `jq: parse error` after a CloudMonkey command

### Symptom

```text
jq: parse error: Invalid numeric literal
```

### Cause

CloudMonkey returned a plain-text error, sometimes prefixed with an icon, rather than JSON.

### Fix

Capture stderr and inspect raw output before retrying:

```bash
RESULT=$(cmk COMMAND ... 2>&1)
RC=$?
printf '%s\n' "$RESULT"
printf 'exit=%s\n' "$RC"
```

Do not retry state-changing commands until you know whether the first request had a side effect. Query the object by exact name or ID first.

## Isolated network rejects `physicalnetworkid`

### Symptom

```text
Physical network ID can be specified for networks of guest IP type Shared or L2 only.
```

### Cause

The isolated-network API call does not accept explicit physical-network selection in this path.

### Fix

Remove only `physicalnetworkid` and retain the zone, offering, account, domain, and ACL type. CloudStack selects the Guest physical network. Verify the resulting network's `physicalnetworkid` afterward.

## ISO status query appears empty

### Symptom

The ISO registration response succeeds, but `list isos id=...` displays nothing.

### Cause

The default ISO filter may exclude the record.

### Fix

Use:

```bash
cmk list isos id="$ISO_ID" zoneid="$ZONE_ID" isofilter=all listall=true | jq
```

or `isofilter=self` for a caller-owned ISO.

## Rocky checksum byte count differs from HTTP Content-Length

### Symptom

The checksum metadata comment shows a different size from the server's HTTP Content-Length.

### Resolution

Validate the SHA-256 from both the global and file-specific checksum metadata. Register the ISO with:

```text
{SHA-256}<64-hex-character-value>
```

CloudStack verifies the downloaded content. Do not treat a human-readable size comment as a cryptographic integrity check.

## BIOS API deployment throws a null boot-mode error

### Symptom

```text
Cannot invoke ... BootMode.toString() because ... getBootMode() is null
```

### Cause

The direct API call supplied `boottype=BIOS` but no `bootmode` in an API path that dereferenced the latter.

### Fix

Supply both:

```text
boottype=BIOS
bootmode=Legacy
```

Inside the installed guest, verify BIOS independently:

```bash
test ! -d /sys/firmware/efi && echo PASS
```

## Rocky 9 panics before the installer appears

### Symptom

The console ends with:

```text
Kernel panic - not syncing: Attempted to kill init!
exitcode=0x00007f00
```

### Cause

The final panic is a consequence of userspace init exiting. In the tested environment, libvirt exposed:

```xml
<cpu mode='custom'>
  <model>qemu64</model>
</cpu>
```

Rocky Linux 9 requires x86-64-v2, which the generic guest model did not provide.

### Diagnosis

On the selected host:

```bash
sudo virsh dumpxml INSTANCE_NAME | sed -n '/<cpu /,/<\/cpu>/p'
sudo virsh domcapabilities | sed -n "/<mode name='host-model'/,/<\/mode>/p"
```

### Verified fix

After validating all cluster hosts, back up `agent.properties` and set consistently:

```properties
guest.cpu.mode=host-model
```

Restart one CloudStack agent at a time and verify each host returns to `Up`/`Enabled`. Then stop/start the VM through CloudStack and confirm the regenerated XML uses `host-model`.

Do not use `virsh edit` on a CloudStack-managed VM. Do not select UEFI as a workaround for a CPU-model failure.

Reference: [Apache CloudStack issue #8757](https://github.com/apache/cloudstack/issues/8757).

## Gateway and DNS work, but HTTPS times out

### Symptom

- Guest gateway responds.
- `getent hosts` resolves names.
- `curl` to TCP 443 times out.
- No egress firewall rules exist.

### Cause

The isolated network has default-deny egress.

### Fix

Add the minimum required egress rules for the build network: TCP 443, optionally TCP 80, UDP 123, and ICMP when required. Wait for each async job to succeed.

Do not open all TCP/UDP ports merely to make the build convenient.

## `curl` options produce `command not found`

### Symptom

```text
--head: command not found
--location: command not found
```

### Cause

Each option was entered on a separate line in noVNC without shell continuation characters.

### Fix

Enter one line:

```bash
curl -I -L --max-time 20 https://download.rockylinux.org/
```

## `nano: command not found`

### Cause

Rocky Minimal does not include Nano.

### Fix

Install it temporarily:

```bash
dnf -y install nano
```

Remove it before generalization:

```bash
dnf -y remove nano
```

Alternatively use a guarded script or an editor already installed.

## QEMU Guest Agent unit does not exist

### Symptom

```text
Unit qemu-guest-agent.service could not be found
```

### Cause

The package was not installed even though the service-enable command was attempted.

### Fix

```bash
dnf -y install qemu-guest-agent
systemctl daemon-reload
systemctl enable --now qemu-guest-agent
```

Confirm the channel:

```bash
test -e /dev/virtio-ports/org.qemu.guest_agent.0
```

## `acpid.service` does not exist

Rocky may expose `acpid.socket` after package installation. `acpid` is optional for this template. Do not block release solely because an `acpid.service` unit is absent when normal CloudStack shutdown works.

## `rc.local is not marked executable, skipping`

This informational message is expected when no legacy rc.local startup script is used. Do not make it executable solely to suppress the message.

## Password module replacement finds zero entries

### Symptom

A search for `set-passwords` returns no lines.

### Cause

Rocky's packaged module is named with an underscore:

```yaml
- set_passwords
```

### Fix

Inspect the main file:

```bash
grep -n password /etc/cloud/cloud.cfg
grep -n -A30 cloud_init_modules /etc/cloud/cloud.cfg
```

Change exactly one entry to:

```yaml
- [set_passwords, always]
```

Do not add a tiny replacement `cloud_init_modules` list in a drop-in; that can replace the complete distro module list.

## Backup comparison says the backup does not exist

The backup command was skipped or used another filename. Stop editing, create a backup, and verify it before continuing:

```bash
cp -a /etc/cloud/cloud.cfg /etc/cloud/cloud.cfg.original
ls -l /etc/cloud/cloud.cfg*
```

## `cloud-init schema --system` mentions shell User Data

### Symptom

The schema command reports that User Data has MIME type `text/x-shellscript` and is not evaluated by cloud-init's YAML schema.

### Meaning

This is informational. A shell script is not cloud-config YAML. Network config may still report valid. Check script execution through `cloud-init status`, `cloud-final`, and its marker file.

## Generated CloudStack password does not work

Separate the test into distinct layers.

### Rule out noVNC keyboard mapping

Generated passwords may contain characters mapped differently in a browser console. Test with password-only SSH:

```bash
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password root@VM_ADDRESS
```

### Use a selected SSH key for emergency diagnostics

The diagnostic VM should include an SSH key, but the password test must explicitly disable public-key authentication.

### Inspect the guest

```bash
cloud-init status --long
passwd --status root
grep -n -B8 -A12 'Failed to fetch password' /var/log/cloud-init.log
```

Do not publish password or shadow values.

### Verified root cause in the worked build

The log showed:

```text
FileNotFoundError: [Errno 2] No such file or directory: b'wget'
```

`DataSourceCloudStack` attempted to execute `wget` against the Virtual Router password service. Install and retain:

```bash
dnf -y install wget
```

Then stop the VM, use CloudStack **Reset Password**, start it, and test the new password. This test succeeded in the worked environment.

### Password-server diagnosis without displaying the password

```bash
umask 077
curl -sS --max-time 5 http://DEFAULT_GATEWAY:8080/ -o /root/password-response
python3 - <<'PY'
from pathlib import Path
data = Path('/root/password-response').read_bytes().strip()
print('RESPONSE_BYTES=' + str(len(data)))
if not data:
    print('RESPONSE_CLASS=EMPTY')
elif data == b'bad_request':
    print('RESPONSE_CLASS=BAD_REQUEST')
elif data == b'saved_password':
    print('RESPONSE_CLASS=SAVED_PASSWORD')
else:
    print('RESPONSE_CLASS=NONEMPTY_PASSWORD_LIKE')
PY
rm -f /root/password-response
```

Never run `cat` on the response.

## Cloud-init reports password fetch failure although port 8080 works later

Check the traceback rather than assuming a timing issue. In the worked build, NetworkManager-wait-online was enabled and cloud-init was ordered after it; the actual failure was missing `wget`.

Useful commands:

```bash
systemctl is-enabled NetworkManager-wait-online.service
systemctl is-active NetworkManager-wait-online.service
systemctl cat cloud-init.service
systemd-analyze critical-chain cloud-init.service
```

Reference: [cloud-init early-network issue #4050](https://github.com/canonical/cloud-init/issues/4050).

## `authorized_keys` exists but is zero bytes

This is normal when no CloudStack SSH key pair was selected. If a key was selected, verify:

- VM `keypair`/`keypairs` property
- `/latest/meta-data/public-keys`
- `DataSourceCloudStack` logs
- `/root/.ssh` ownership and permissions
- SELinux context

```bash
stat /root/.ssh/authorized_keys
restorecon -RFv /root/.ssh
ssh-keygen -lf /root/.ssh/authorized_keys
```

## Renaming a NetworkManager connection does not rename the file

Changing the connection ID to `cloud-dhcp` may leave the path as:

```text
/etc/NetworkManager/system-connections/ens3.nmconnection
```

That is valid. Do not rename the file manually. Verify the logical connection with:

```bash
nmcli connection show
nmcli connection show cloud-dhcp
```

## Root disk does not expand

Check each layer independently:

```bash
lsblk
growpart --dry-run /dev/vda PARTITION_NUMBER
df -hT /
grep -nE 'growpart|resizefs' /etc/cloud/cloud.cfg
```

Root must be the final partition. A trailing swap partition prevents simple growth. Collect cloud-init logs before manually running `growpart` and `xfs_growfs`.

## Generalization was followed by an accidental reboot

Do not create a template from that booted image. Repeat:

- cloud-init clean
- machine-ID cleanup
- host-key deletion
- authorized-key deletion
- lease cleanup
- random-seed removal
- log/history cleanup
- root password lock
- trim and poweroff

## Useful upstream references

- [CloudStack template documentation](https://docs.cloudstack.apache.org/en/latest/adminguide/templates.html)
- [CloudStack User Data and Metadata](https://docs.cloudstack.apache.org/en/latest/adminguide/virtual_machines/user-data.html)
- [cloud-init CloudStack datasource](https://cloudinit.readthedocs.io/en/stable/reference/datasources/cloudstack.html)
- [cloud-init CloudStack password issue #5486](https://github.com/canonical/cloud-init/issues/5486)
- [CloudStack Rocky 9 KVM issue #8757](https://github.com/apache/cloudstack/issues/8757)

External content has been summarized and rephrased for licensing compliance.

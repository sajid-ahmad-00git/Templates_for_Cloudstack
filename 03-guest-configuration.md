# Guest configuration

Run this chapter inside the installed Rocky builder as root unless a step explicitly says to use the CloudStack Management Server.

## 1. Verify outbound access

Test the Virtual Router gateway and DNS:

```bash
ping -c 3 "$(ip route | awk '/default/ {print $3; exit}')"
getent ahostsv4 download.rockylinux.org
```

Test HTTPS as one command:

```bash
curl -fsSI -L --max-time 20 https://download.rockylinux.org/ >/dev/null \
  && echo 'HTTPS: PASS' \
  || echo 'HTTPS: FAIL'
```

If DHCP, gateway, and DNS work but HTTPS times out, inspect CloudStack egress rules. Do not mistake `dnf repolist` for a connectivity test; it can list locally configured repositories without downloading metadata.

```bash
dnf makecache --refresh
```

## 2. Update the operating system

```bash
dnf clean all
dnf -y upgrade --refresh
```

Reboot if the kernel or core system packages changed:

```bash
systemctl reboot
```

After reboot:

```bash
cat /etc/rocky-release
uname -r
```

## 3. Install required packages

```bash
dnf -y install \
  cloud-init \
  cloud-utils-growpart \
  qemu-guest-agent \
  wget \
  chrony \
  firewalld \
  openssh-server \
  NetworkManager \
  xfsprogs
```

Optional:

```bash
dnf -y install acpid
```

`acpid` may enable a socket rather than an `acpid.service` unit. It is not a release blocker. Normal Linux ACPI shutdown works without treating a missing `acpid.service` as a template failure.

> [!IMPORTANT]
> Keep `wget` in the final image. Rocky's packaged `DataSourceCloudStack` used it to request CloudStack's generated password from the Virtual Router. Without it, cloud-init logged `FileNotFoundError: ... b'wget'`, User Data still ran, but the generated password and Reset Password path failed.

Verify:

```bash
rpm -q cloud-init cloud-utils-growpart qemu-guest-agent wget chrony firewalld openssh-server NetworkManager xfsprogs
```

## 4. Enable services

```bash
systemctl enable --now NetworkManager
systemctl enable --now sshd
systemctl enable --now firewalld
systemctl enable --now chronyd
systemctl enable --now qemu-guest-agent
```

Check the QEMU channel:

```bash
test -e /dev/virtio-ports/org.qemu.guest_agent.0 \
  && echo 'QEMU CHANNEL: PASS' \
  || echo 'QEMU CHANNEL: MISSING'
```

Check services individually. Simple commands avoid quoting problems in browser consoles:

```bash
systemctl is-active NetworkManager
systemctl is-active sshd
systemctl is-active firewalld
systemctl is-active chronyd
systemctl is-active qemu-guest-agent
systemctl --failed --no-pager
```

A recurring `rc.local is not marked executable, skipping` message is informational when the template does not use `rc.local`. Do not make it executable merely to remove the message.

## 5. Configure locale, time, and generic hostname

```bash
timedatectl set-timezone UTC
timedatectl set-ntp true
localectl set-locale LANG=en_US.UTF-8
localectl set-keymap us
hostnamectl set-hostname localhost.localdomain
systemctl restart chronyd
```

Verify:

```bash
timedatectl
localectl
hostnamectl
chronyc sources -v
```

## 6. Configure cloud-init for CloudStack

Install [the example](../examples/90-cloudstack.cfg):

```bash
install -o root -g root -m 0644 \
  /path/to/90-cloudstack.cfg \
  /etc/cloud/cloud.cfg.d/90-cloudstack.cfg
```

If the repository is not available inside the VM, create the file exactly as follows:

```yaml
#cloud-config
datasource_list:
  - CloudStack
  - ConfigDrive
  - None

datasource:
  CloudStack:
    max_wait: 120
    timeout: 10

preserve_hostname: false
manage_etc_hosts: true

disable_root: false
ssh_pwauth: true

system_info:
  default_user:
    name: root
    lock_passwd: true
    shell: /bin/bash
```

Do not place a reusable password or key in this file.

The top-level string form `user: root` was tested temporarily but removed because cloud-init 24.4 reports it as deprecated. The `system_info.default_user` configuration was retained.

## 7. Make password reset run on later boots

Back up the packaged configuration:

```bash
cp -a /etc/cloud/cloud.cfg /etc/cloud/cloud.cfg.original
```

Inspect the exact module spelling:

```bash
grep -n -A30 cloud_init_modules /etc/cloud/cloud.cfg
grep -n password /etc/cloud/cloud.cfg
```

Rocky Linux 9 used:

```yaml
- set_passwords
```

not `set-passwords`.

Use this guarded edit:

```bash
python3 - <<'PY'
from pathlib import Path

path = Path('/etc/cloud/cloud.cfg')
old = '  - set_passwords\n'
new = '  - [set_passwords, always]\n'
text = path.read_text()
count = text.count(old)
if count != 1:
    raise SystemExit(f'Expected exactly one set_passwords entry, found {count}; no change made')
path.write_text(text.replace(old, new, 1))
print('Updated set_passwords frequency to always')
PY
```

Verify:

```bash
grep -n set_passwords /etc/cloud/cloud.cfg
grep -c set_passwords /etc/cloud/cloud.cfg
```

Expected:

```yaml
- [set_passwords, always]
```

with a count of `1`.

`growpart` and `resizefs` should already be in `cloud_init_modules`:

```bash
grep -nE 'growpart|resizefs' /etc/cloud/cloud.cfg
```

## 8. Configure root SSH access

Install [the OpenSSH example](../examples/00-cloudstack.conf) as `/etc/ssh/sshd_config.d/00-cloudstack.conf`:

```text
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
PermitEmptyPasswords no
KbdInteractiveAuthentication no
UsePAM yes
```

Set permissions and validate:

```bash
chown root:root /etc/ssh/sshd_config.d/00-cloudstack.conf
chmod 0600 /etc/ssh/sshd_config.d/00-cloudstack.conf
sshd -t
```

Check the effective settings:

```bash
sshd -T | grep -E 'permitrootlogin|passwordauthentication|pubkeyauthentication|permitemptypasswords|kbdinteractiveauthentication'
```

Expected:

```text
permitrootlogin yes
passwordauthentication yes
pubkeyauthentication yes
permitemptypasswords no
kbdinteractiveauthentication no
```

Restart SSH:

```bash
systemctl restart sshd
systemctl is-active sshd
```

## 9. Configure firewalld

```bash
firewall-cmd --permanent --add-service=ssh
firewall-cmd --permanent --remove-service=cockpit || true
firewall-cmd --reload
firewall-cmd --list-services
```

Allowing SSH in the guest firewall does not authorize public access. Restrict inbound TCP 22 at the CloudStack/upstream network layer.

Keep SELinux enforcing:

```bash
getenforce
```

## 10. Consolidate the NetworkManager profile

The installer may produce:

- A transient active profile named `System ens3`.
- A persistent DHCP keyfile such as `/etc/NetworkManager/system-connections/ens3.nmconnection`.

Inspect before changing:

```bash
nmcli connection show
nmcli device status
ls -la /etc/NetworkManager/system-connections
cat /etc/NetworkManager/system-connections/*.nmconnection
```

A suitable persistent profile has:

```ini
[connection]
type=ethernet
interface-name=ens3
autoconnect=true

[ethernet]

[ipv4]
method=auto

[ipv6]
method=auto
```

A UUID is safe. A static address or MAC binding is not.

Discover the persistent UUID from the keyfile:

```bash
PERSISTENT_FILE=$(find /etc/NetworkManager/system-connections -maxdepth 1 -type f -name '*.nmconnection' | head -n 1)
PERSISTENT_UUID=$(awk -F= '$1 == "uuid" {print $2}' "$PERSISTENT_FILE")
printf 'PERSISTENT_FILE=%s\nPERSISTENT_UUID=%s\n' "$PERSISTENT_FILE" "$PERSISTENT_UUID"
```

Record the currently active Ethernet profile UUID:

```bash
OLD_ACTIVE_UUID=$(nmcli -t -f NAME,UUID,DEVICE connection show --active | awk -F: '$3 == "ens3" {print $2; exit}')
printf 'OLD_ACTIVE_UUID=%s\n' "$OLD_ACTIVE_UUID"
```

Rename and prioritize the persistent profile:

```bash
nmcli connection modify "$PERSISTENT_UUID" connection.id cloud-dhcp
nmcli connection modify "$PERSISTENT_UUID" connection.autoconnect yes
nmcli connection modify "$PERSISTENT_UUID" connection.autoconnect-priority 100
nmcli connection modify "$PERSISTENT_UUID" 802-3-ethernet.mac-address ''
```

Activate from the console because networking reconnects:

```bash
nmcli connection up uuid "$PERSISTENT_UUID"
```

Verify gateway and HTTPS before deleting anything:

```bash
nmcli connection show --active
ip -br address
ip route
ping -c 3 "$(ip route | awk '/default/ {print $3; exit}')"
curl -fsSI -L --max-time 20 https://download.rockylinux.org/ >/dev/null
```

If the old UUID differs and the new profile is active, remove only the transient duplicate:

```bash
if [[ -n "$OLD_ACTIVE_UUID" && "$OLD_ACTIVE_UUID" != "$PERSISTENT_UUID" ]]; then
  nmcli connection delete uuid "$OLD_ACTIVE_UUID"
fi
```

Do not manually rename the `.nmconnection` file. Changing the connection ID to `cloud-dhcp` does not necessarily rename its on-disk filename.

Check for forbidden settings:

```bash
grep -RniE 'mac-address|cloned-mac-address|address1|method=manual' \
  /etc/NetworkManager/system-connections || true
```

Reboot-test the persistent profile before generalization:

```bash
systemctl reboot
```

After reboot, verify `cloud-dhcp`, DHCP, gateway, DNS, and HTTPS.

## 11. Verify disk expansion support

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
ROOT_SOURCE=$(findmnt -n -o SOURCE /)
ROOT_PARENT=$(lsblk -n -o PKNAME "$ROOT_SOURCE")
ROOT_PART=$(lsblk -n -o PARTN "$ROOT_SOURCE")
printf 'root=%s disk=/dev/%s partition=%s\n' "$ROOT_SOURCE" "$ROOT_PARENT" "$ROOT_PART"
```

Dry-run growpart:

```bash
growpart --dry-run "/dev/$ROOT_PARENT" "$ROOT_PART"
```

`NOCHANGE` is expected when the partition already fills the 20 GiB disk. An unsupported-layout error is not.

Confirm XFS:

```bash
xfs_info /
```

## 12. Final pre-cleanup gate

```bash
cloud-init schema --system
sshd -t
getenforce
systemctl is-active NetworkManager
systemctl is-active sshd
systemctl is-active firewalld
systemctl is-active chronyd
systemctl is-active qemu-guest-agent
systemctl --failed --no-pager
rpm -q wget cloud-init cloud-utils-growpart qemu-guest-agent
```

The builder may show a recoverable password-fetch warning because it was deployed from an ISO whose record was not password-enabled. That does not invalidate the template configuration. Final password validation occurs after template creation.

Continue with [Generalize, create, and test](04-generalize-create-and-test.md).

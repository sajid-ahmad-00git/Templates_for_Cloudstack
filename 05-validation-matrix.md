# Validation matrix

A successful template creation job is not production acceptance. Complete this matrix for every released template revision.

## Template manifest

| Field | Value |
|---|---|
| Template name | |
| Template ID | |
| Rocky point release | |
| Build date | |
| Kernel | |
| cloud-init version | |
| QEMU Guest Agent version | |
| Architecture | x86_64 |
| Boot firmware | Legacy BIOS |
| Image format | QCOW2 |
| Default root disk | 20 GiB |
| Root filesystem | XFS |
| Root login account | root |
| Password enabled | true |
| SHA-256/export checksum | |
| Build owner | |
| Approver | |

## Required result notation

Use:

- `PASS` — tested and met the stated criterion.
- `FAIL` — tested and did not meet it.
- `BLOCKED` — could not test because an external dependency was unavailable.
- `N/A` — formally out of scope, with an approved reason.

Do not use a blank result to imply success.

## Core image validation

| Test | Command/evidence | Expected | Result |
|---|---|---|---|
| Rocky release | `cat /etc/rocky-release` | Approved Rocky 9 point release | |
| Updated kernel | `uname -r` | Current approved kernel | |
| BIOS | `test ! -d /sys/firmware/efi` | Success | |
| Architecture | `uname -m` | `x86_64` | |
| Root filesystem | `findmnt /` | XFS standard partition | |
| Root size | `lsblk`, `df -hT /` | 20 GiB virtual disk | |
| No LVM | `lsblk` | No LVM root | |
| SELinux | `getenforce` | `Enforcing` | |
| Guest firewall | `firewall-cmd --list-all` | Enabled; SSH allowed | |
| QEMU Guest Agent | `systemctl is-active qemu-guest-agent` | Active | |
| Cloud-init | `cloud-init status --long` | Done; CloudStack datasource | |
| Required packages | `rpm -q ...` | All installed, including `wget` | |
| Failed services | `systemctl --failed` | Zero failed units | |

Run the helper after first boot:

```bash
chmod +x scripts/verify-rocky9-guest.sh
sudo scripts/verify-rocky9-guest.sh
```

## Authentication and injection

| Test | Procedure | Expected | Result |
|---|---|---|---|
| Native password | Deploy with no User Data; test password-only SSH | CloudStack-generated password logs in as root | |
| Password target | `passwd --status root` | `PS` after injection | |
| Password reset | Stop, Reset Password, start, test new and old values | New works; old fails | |
| SSH key | Deploy with selected key; key-only SSH | Root login succeeds | |
| Key fingerprint | `ssh-keygen -lf /root/.ssh/authorized_keys` | Matches selected key | |
| User Data password | Deploy with one-time hashed-password script | Caller-selected root password works | |
| User Data marker | Read marker file | Script completed once | |
| Startup shell script | Submit harmless marker script | Marker exists once | |
| Cloud-config | Submit harmless `#cloud-config` document | Requested change appears | |
| Root SSH policy | `sshd -T` | Password and public key enabled | |

Never mark native password as passed if login actually used a public key. Use:

```bash
ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password root@VM_ADDRESS
```

Never mark key injection as passed if SSH fell back to password:

```bash
ssh -o PasswordAuthentication=no -i PRIVATE_KEY root@VM_ADDRESS
```

## Identity and generalization

Deploy at least two independent VMs.

| Test | Expected | VM A | VM B |
|---|---|---|---|
| Machine ID | Nonempty and unique | | |
| ED25519 host-key fingerprint | Nonempty and unique | | |
| DHCP address | Assigned by target network | | |
| Hostname | Matches CloudStack metadata policy | | |
| No build key | Build-time key absent | | |
| No build password | Build-time password rejected | | |
| No diagnostic files | None of the documented markers unless requested | | |

## Network validation

| Test | Isolated VR network | Approved shared network |
|---|---|---|
| DHCP address | | |
| Correct gateway | | |
| DNS resolution | | |
| HTTPS repository access | | |
| User Data service | | |
| Native password service | | |
| SSH from approved CIDR | | |
| Hostname customization | | |
| Reboot persistence | | |
| Stop/start persistence | | |

Do not use an unrelated tenant shared network. If no approved shared network exists, mark shared testing `BLOCKED` and document the owner required to provision it.

## Root-volume expansion

| Test | Ceph RBD | NFS primary |
|---|---|---|
| Default 20 GiB root | | |
| 30 GiB root at deployment | | |
| Partition auto-grow | | |
| XFS auto-grow | | |
| Existing root-volume resize | | |
| Reboot after resize | | |
| Data persists | | |

NFS secondary storage does not count as NFS primary testing.

## Additional data disk

| Test | Ceph RBD | NFS primary |
|---|---|---|
| Attach detected | | |
| XFS creation | | |
| UUID-based fstab | | |
| Mount after reboot | | |
| Data after stop/start | | |
| Detach operation | | |
| Reattach operation | | |

## KVM host coverage

| Host | Physical CPU | Guest CPU model | BIOS boot | Network | Native password | Key | Migration/recovery |
|---|---|---|---|---|---|---|---|
| Host 1 | | | | | | | |
| Host 2 | | | | | | | |
| Host 3 | | | | | | | |

The VM's effective libvirt XML must not fall back to a CPU model that lacks Rocky's requirements.

## Lifecycle testing

| Operation | Expected | Result |
|---|---|---|
| Guest reboot | Returns with network and access | |
| CloudStack reboot | Returns with network and access | |
| Stop/start | Returns with data and access | |
| Password reset | New password applied | |
| SSH key reset, if required | New key applied | |
| Host migration | Boots and operates on target | |
| VM recovery | Filesystem and data intact | |
| Console access | Login prompt visible | |

## Security review

| Control | Expected | Result |
|---|---|---|
| Template private during test | Yes | |
| Root password unique | Yes | |
| No plaintext User Data password | Yes | |
| No private SSH key in CloudStack/image | Yes | |
| TCP 22 source-restricted | Yes | |
| SELinux enforcing | Yes | |
| firewalld enabled | Yes | |
| No host keys in source image | Yes | |
| No machine ID in source image | Yes | |
| No fixed IP/MAC in source image | Yes | |
| Agent property secrets not published | Yes | |

## Known limitations and pending work

Record environment-specific gaps. Examples:

```text
- NFS primary storage unavailable; NFS root/data operations are BLOCKED.
- Dedicated shared test network awaiting VLAN and IP allocation.
- Rocky 10 OS type/mapping requires separate planning.
- Root SSH password access is an approved security exception.
```

## Release approval

| Role | Name | Decision | Date |
|---|---|---|---|
| Template engineer | | | |
| CloudStack administrator | | | |
| Network/storage owner | | | |
| Security reviewer | | | |
| Production approver | | | |

A template may be made public or shared with tenants only after all mandatory rows are `PASS` or have an explicitly approved `N/A`/`BLOCKED` disposition.

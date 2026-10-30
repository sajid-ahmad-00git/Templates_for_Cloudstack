#!/usr/bin/env bash
# Read-only validation for a VM deployed from the finished Rocky 9 template.
# Run as root after cloud-init reaches its final state.

set -u

failures=0

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; failures=$((failures + 1)); }
info() { printf 'INFO: %s\n' "$1"; }

if [[ $(id -u) -ne 0 ]]; then
  echo "ERROR: run as root" >&2
  exit 2
fi

printf '\n===== OPERATING SYSTEM =====\n'
cat /etc/rocky-release
uname -r

printf '\n===== FIRMWARE =====\n'
if [[ -d /sys/firmware/efi ]]; then
  fail "guest booted with UEFI; legacy BIOS was required"
else
  pass "legacy BIOS"
fi

printf '\n===== CLOUD-INIT =====\n'
cloud-init --version
cloud-init status --long || failures=$((failures + 1))
if cloud-id 2>/dev/null | grep -qi cloudstack; then
  pass "CloudStack datasource"
else
  fail "CloudStack datasource not reported"
fi

for package_name in cloud-init cloud-utils-growpart qemu-guest-agent wget chrony firewalld openssh-server NetworkManager xfsprogs; do
  if rpm -q "$package_name" >/dev/null 2>&1; then
    pass "package $package_name"
  else
    fail "package $package_name is missing"
  fi
done

printf '\n===== SERVICES =====\n'
for service_name in NetworkManager sshd firewalld chronyd qemu-guest-agent; do
  if systemctl is-active --quiet "$service_name"; then
    pass "service $service_name active"
  else
    fail "service $service_name inactive"
  fi
  if systemctl is-enabled --quiet "$service_name"; then
    pass "service $service_name enabled"
  else
    fail "service $service_name not enabled"
  fi
done

printf '\n===== SECURITY =====\n'
if [[ $(getenforce) == Enforcing ]]; then
  pass "SELinux enforcing"
else
  fail "SELinux is not enforcing"
fi

sshd -t && pass "sshd syntax" || fail "sshd syntax"
sshd -T | grep -E 'permitrootlogin|passwordauthentication|pubkeyauthentication|permitemptypasswords'
firewall-cmd --list-all

printf '\n===== NETWORK =====\n'
nmcli connection show --active
ip -br address
ip route
cat /etc/resolv.conf

if grep -RqiE '(^|;)method=manual' /etc/NetworkManager/system-connections 2>/dev/null; then
  fail "static NetworkManager method found"
else
  pass "no static NetworkManager method"
fi

if grep -RqiE 'mac-address|cloned-mac-address' /etc/NetworkManager/system-connections 2>/dev/null; then
  fail "saved MAC binding found"
else
  pass "no saved MAC binding"
fi

if curl -fsSI -L --max-time 20 https://download.rockylinux.org/ >/dev/null; then
  pass "HTTPS egress"
else
  fail "HTTPS egress"
fi

printf '\n===== STORAGE =====\n'
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
findmnt /
df -hT /
if [[ $(findmnt -n -o FSTYPE /) == xfs ]]; then
  pass "XFS root filesystem"
else
  fail "root filesystem is not XFS"
fi

printf '\n===== INSTANCE IDENTITY =====\n'
if [[ -s /etc/machine-id ]]; then
  pass "machine-id is populated"
else
  fail "machine-id is empty after deployment"
fi

host_key_count=$(find /etc/ssh -maxdepth 1 -type f -name 'ssh_host_*_key' | wc -l)
if (( host_key_count > 0 )); then
  pass "SSH host keys generated"
else
  fail "SSH host keys missing"
fi

if [[ -s /root/.ssh/authorized_keys ]]; then
  pass "root authorized_keys is populated"
  ssh-keygen -lf /root/.ssh/authorized_keys || true
else
  info "root authorized_keys empty or absent; acceptable only when no key pair was selected"
fi

printf '\n===== FAILED UNITS =====\n'
systemctl --failed --no-pager

printf '\n===== RESULT =====\n'
if (( failures == 0 )); then
  echo "VALIDATION RESULT: PASS"
  exit 0
else
  echo "VALIDATION RESULT: FAIL ($failures checks)"
  exit 1
fi

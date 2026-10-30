# Security guidance

This workflow creates a reusable operating-system image with direct root SSH access. Treat the image, its build VM, CloudStack User Data, and all generated credentials as sensitive infrastructure assets.

## Root SSH risk

The example enables:

```text
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
```

This configuration exists because both root password and root public-key access were explicit requirements. A safer general-purpose default is a non-root sudo user and key-only SSH.

If you retain direct root password access:

- Restrict TCP 22 to approved administrative CIDRs using CloudStack firewall rules, security groups, network ACLs, VPN, or upstream firewalls.
- Never expose root password SSH to `0.0.0.0/0` unless a documented exception permits it.
- Prefer SSH keys for routine use.
- Use unique generated passwords per VM.
- Rotate a password after suspected disclosure.
- Keep SELinux enforcing and firewalld enabled.
- Monitor authentication failures and administrative logins.

## Never commit these files

The repository `.gitignore` excludes common secret and image formats. Do not commit:

- CloudMonkey configuration or API keys
- CloudStack API secret keys
- Passwords or password hashes used in production
- SSH private keys
- `agent.properties`
- Keystore passphrases
- Complete cloud-init instance directories
- VM images, ISOs, raw disks, or QCOW2 files
- Logs containing metadata, User Data, generated passwords, or internal topology

## CloudStack agent configuration

`/etc/cloudstack/agent/agent.properties` can contain sensitive values. Never paste or publish the entire file. Print only the property needed for a diagnostic, for example:

```bash
sudo grep -nE '^(guest\.)?cpu\.(mode|model)=' \
  /etc/cloudstack/agent/agent.properties
```

If an agent passphrase or other credential is exposed, follow your CloudStack TLS/keystore rotation procedure. Do not copy the disclosed value into tickets or documentation.

## User Data password handling

The example accepts a SHA-512 crypt hash rather than a plaintext password. A password hash is still sensitive because an attacker can perform offline guessing.

CloudStack may retain User Data in its database and expose it to the guest metadata service. Therefore:

- Generate the hash on a trusted administration workstation.
- Do not commit a populated User Data script.
- Do not reuse the hash across VMs.
- Limit who can read VM User Data through CloudStack.
- Remove the local cloud-init script copy after execution.
- Prefer CloudStack's native generated password when callers do not need to choose a password.

## Metadata and password service

The CloudStack datasource retrieves metadata and account data through the Virtual Router. The password service uses the default guest network and port 8080.

- Do not expose the password service outside the guest network.
- Do not print the password-server response during diagnostics.
- If response classification is required, save it to a root-only temporary file, classify it without displaying the content, then delete it.
- Do not include password strings in cloud-init log excerpts.

## Build credentials

The temporary root password used during ISO installation must not survive in the template. Before template creation:

```bash
passwd --lock root
rm -rf /root/.ssh
rm -f /etc/ssh/ssh_host_*
cloud-init clean --logs --seed --machine-id
```

After cleanup, power off. Do not boot the source VM again without repeating cleanup.

## Network policy

Use a dedicated build network. Do not borrow a tenant or production shared network.

A default-deny egress network should permit only what the build requires, commonly:

- TCP 443 for HTTPS repositories
- TCP 80 if mirrors or redirects require HTTP
- UDP 123 for NTP
- ICMP if operational testing requires ping

Restrict inbound SSH separately. Outbound repository rules do not authorize inbound administration.

## Image release policy

Keep every newly created template private. Release it only after:

- Native generated password works.
- Password reset works.
- User Data password works.
- SSH public-key injection works.
- Every VM receives a unique machine ID and SSH host keys.
- No build credentials remain.
- BIOS, DHCP, storage, resize, reboot, stop/start, recovery, and host-placement tests pass.
- Known limitations are documented.

## Vulnerability reporting

Do not open a public issue containing credentials, private IP plans, CloudStack API secrets, keystore values, complete logs, or customer data. Use your organization's private security-reporting channel.

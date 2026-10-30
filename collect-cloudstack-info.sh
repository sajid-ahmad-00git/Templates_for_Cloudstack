#!/usr/bin/env bash
# Read-only discovery for CloudStack 4.23 CloudMonkey JSON output.
# Run on the Management Server as a user with a configured cmk profile.
# This script does not print API credentials or storage URLs.

set -euo pipefail

for command_name in cmk jq; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $command_name" >&2
    exit 1
  fi
done

section() {
  printf '\n===== %s =====\n' "$1"
}

section "CLOUDSTACK VERSION"
cmk list capabilities | jq -r '
  .. | objects | .cloudstackversion? // empty
' | sort -u

section "ZONES"
cmk list zones listall=true | jq -r '
  .. | objects |
  select(.id? and .name? and .networktype?) |
  ["id=" + .id,
   "name=" + .name,
   "network=" + .networktype,
   "allocation=" + (.allocationstate // "unknown")] |
  join(" | ")
' | sort -u

section "KVM CLUSTERS"
cmk list clusters listall=true | jq -r '
  .. | objects |
  select(.hypervisortype? == "KVM") |
  ["id=" + .id,
   "name=" + .name,
   "pod=" + (.podname // "unknown"),
   "state=" + (.allocationstate // "unknown"),
   "managed=" + (.managedstate // "unknown")] |
  join(" | ")
' | sort -u

section "KVM HOSTS"
cmk list hosts listall=true hypervisor=KVM | jq -r '
  .. | objects |
  select((.hypervisor? == "KVM") and ((.type? // "Routing") == "Routing")) |
  ["id=" + .id,
   "name=" + .name,
   "ip=" + (.ipaddress // "unknown"),
   "cluster=" + (.clustername // .clusterid // "unknown"),
   "state=" + (.state // "unknown"),
   "resource=" + (.resourcestate // "unknown"),
   "version=" + (.version // "unknown")] |
  join(" | ")
' | sort -u

section "PRIMARY STORAGE"
cmk list storagepools listall=true | jq -r '
  .. | objects |
  select(.id? and .name? and .type? and .scope?) |
  ["id=" + .id,
   "name=" + .name,
   "type=" + .type,
   "scope=" + .scope,
   "state=" + (.state // "unknown"),
   "cluster=" + (.clustername // .clusterid // "zone-scoped"),
   "zone=" + (.zonename // .zoneid // "unknown"),
   "tags=" + (if (.tags | type) == "array" then (.tags | join(",")) else (.tags // "none" | tostring) end)] |
  join(" | ")
' | sort -u

section "SECONDARY STORAGE"
cmk list imagestores | jq -r '
  .. | objects |
  select(.id? and .name? and .protocol?) |
  ["id=" + .id,
   "name=" + .name,
   "protocol=" + .protocol,
   "provider=" + (.providertype // .provider // "unknown"),
   "scope=" + (.scope // "unknown"),
   "zone=" + (.zonename // .zoneid // "unknown")] |
  join(" | ")
' | sort -u

section "SYSTEM VMS"
cmk list systemvms listall=true | jq -r '
  .. | objects |
  select(.id? and .systemvmtype?) |
  ["id=" + .id,
   "name=" + (.name // "unknown"),
   "type=" + .systemvmtype,
   "state=" + (.state // "unknown"),
   "host=" + (.hostname // .hostid // "unknown"),
   "zone=" + (.zonename // .zoneid // "unknown")] |
  join(" | ")
' | sort -u

section "PHYSICAL NETWORKS"
cmk list physicalnetworks listall=true | jq -r '
  .. | objects |
  select(.id? and .name? and .broadcastdomainrange?) |
  ["id=" + .id,
   "name=" + .name,
   "zone=" + (.zonename // .zoneid // "unknown"),
   "range=" + .broadcastdomainrange,
   "state=" + (.state // "unknown")] |
  join(" | ")
' | sort -u

section "NETWORK OFFERINGS"
cmk list networkofferings listall=true | jq -r '
  .. | objects |
  select(.id? and .name? and .guestiptype? and .service?) |
  ["id=" + .id,
   "name=" + .name,
   "type=" + .guestiptype,
   "state=" + (.state // "unknown"),
   "services=" + ([.service[]? | (.name // "unknown") + ":" + ([.provider[]?.name] | join(","))] | join(";"))] |
  join(" | ")
' | sort -u

section "ROCKY GUEST OS TYPES"
cmk list ostypes | jq -r '
  .. | objects |
  select(.id? and .description?) |
  select(.description | ascii_downcase | contains("rocky")) |
  ["id=" + .id,
   "description=" + .description,
   "category=" + (.oscategoryname // "unknown")] |
  join(" | ")
' | sort -u

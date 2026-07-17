# firewalld-zone-tools

A small collection of tools for managing source-based firewalld zones and IP sets.

The repository contains two utilities:

* `migrate-zone-to-ipsets.sh` — converts individual source addresses in an existing firewalld zone into separate IPv4 and IPv6 IP sets.
* `fw-zone-ctl` — manages IP addresses, networks, ports, and services in an existing firewalld zone.

## Why use IP sets?

A zone containing many individual source entries may cause firewalld to generate a large number of nftables rules.

For example:

```xml
<source address="192.0.2.10/32"/>
<source address="192.0.2.11/32"/>
<source address="2001:db8::10/128"/>
```

After migration, the zone references two IP sets:

```xml
<source ipset="internal_sources_v4"/>
<source ipset="internal_sources_v6"/>
```

The addresses are stored separately:

```text
/etc/firewalld/ipsets/internal_sources_v4.xml
/etc/firewalld/ipsets/internal_sources_v6.xml
```

This reduces the number of generated rules and makes source address management easier.

## Requirements

* Linux
* firewalld
* Bash
* Python 3
* `xmllint`, usually provided by `libxml2-utils`
* root privileges

On Debian and Ubuntu:

```bash
sudo apt install firewalld python3 libxml2-utils
```

## Installation

```bash
sudo install -m 750 migrate-zone-to-ipsets.sh \
  /usr/local/sbin/migrate-zone-to-ipsets

sudo install -m 750 fw-zone-ctl \
  /usr/local/sbin/fw-zone-ctl
```

## Migrating a zone to IP sets

Validate the current permanent configuration:

```bash
sudo firewall-offline-cmd --check-config
```

Stop firewalld before running the migration:

```bash
sudo systemctl stop firewalld
```

Convert the `internal` zone:

```bash
sudo migrate-zone-to-ipsets internal
```

Convert another zone:

```bash
sudo migrate-zone-to-ipsets cloudflare
```

The migration script automatically:

* creates a backup of `/etc/firewalld`;
* extracts all `<source address="..."/>` entries;
* separates IPv4 and IPv6 entries;
* creates separate `hash:net` IP sets;
* replaces individual source addresses with IP set references;
* preserves services, ports, protocols, and rich rules;
* verifies that all source addresses were preserved;
* validates the generated XML files;
* runs `firewall-offline-cmd --check-config`;
* restores the backup automatically if the migration fails.

Example output files:

```text
/etc/firewalld/ipsets/internal_sources_v4.xml
/etc/firewalld/ipsets/internal_sources_v6.xml
```

Start firewalld after a successful migration:

```bash
sudo systemctl start firewalld
sudo firewall-cmd --state
sudo firewall-cmd --zone=internal --list-all
```

Keep the current SSH session open until access has been verified from a second session.

## Backups

Before every migration, the script creates a backup directory:

```text
/root/firewalld-backup-<zone>-<timestamp>
```

Example:

```text
/root/firewalld-backup-internal-20260718-020405
```

The migration tool is intended primarily for one-time conversion of an existing zone. After migration, use `fw-zone-ctl` for normal address management.

## IP set naming convention

Both tools use the following naming convention:

```text
<zone>_sources_v4
<zone>_sources_v6
```

For the `internal` zone:

```text
internal_sources_v4
internal_sources_v6
```

The required IP sets must already exist before using `fw-zone-ctl` to add or remove source addresses.

## fw-zone-ctl usage

General syntax:

```text
fw-zone-ctl <zone> <action> [value]
```

Show the available commands:

```bash
fw-zone-ctl --help
```

## Viewing a zone

```bash
sudo fw-zone-ctl internal list
```

View IPv4 and IPv6 source entries:

```bash
sudo fw-zone-ctl internal list-ip
```

## Managing source addresses

Add an IPv4 address:

```bash
sudo fw-zone-ctl internal add-ip 203.0.113.10
```

The address is automatically normalized to:

```text
203.0.113.10/32
```

Add an IPv4 network:

```bash
sudo fw-zone-ctl internal add-ip 192.0.2.0/24
```

Add an IPv6 address:

```bash
sudo fw-zone-ctl internal add-ip 2001:db8::10
```

The address is normalized to:

```text
2001:db8::10/128
```

Add an IPv6 network:

```bash
sudo fw-zone-ctl internal add-ip 2001:db8:100::/48
```

Remove an address:

```bash
sudo fw-zone-ctl internal del-ip 203.0.113.10
```

Check whether an address or network exists:

```bash
sudo fw-zone-ctl internal query-ip 203.0.113.10
```

## Managing ports

Add a TCP port:

```bash
sudo fw-zone-ctl internal add-port 9443/tcp
```

Add a UDP port:

```bash
sudo fw-zone-ctl internal add-port 5000/udp
```

Add a port range:

```bash
sudo fw-zone-ctl internal add-port 50000-50100/udp
```

Remove a port:

```bash
sudo fw-zone-ctl internal del-port 9443/tcp
```

## Managing services

Add a standard firewalld service:

```bash
sudo fw-zone-ctl internal add-service https
```

Remove a service:

```bash
sudo fw-zone-ctl internal del-service mdns
```

List the available firewalld services:

```bash
firewall-cmd --get-services
```

## Configuration checks

Check the zone and permanent configuration:

```bash
sudo fw-zone-ctl internal check
```

Force a firewalld reload:

```bash
sudo fw-zone-ctl internal reload
```

## Where configuration is stored

Zone configuration:

```text
/etc/firewalld/zones/
```

IP set configuration:

```text
/etc/firewalld/ipsets/
```

Example:

```text
/etc/firewalld/ipsets/internal_sources_v4.xml
/etc/firewalld/ipsets/internal_sources_v6.xml
```

Avoid editing these XML files manually while firewalld is running. Use `fw-zone-ctl` or `firewall-cmd` instead.

## Security

The scripts do not contain:

* passwords;
* access tokens;
* API keys;
* private keys;
* infrastructure-specific IP addresses;
* hostnames or domain names;
* user credentials.

The examples use documentation-only address ranges:

```text
192.0.2.0/24
203.0.113.0/24
2001:db8::/32
```

Before publishing, an additional basic check can be performed:

```bash
grep -RniE \
  'password|passwd|token|secret|api[_-]?key|private[_-]?key' \
  .
```

## Important notes

### migrate-zone-to-ipsets

* must be run as root;
* modifies `/etc/firewalld`;
* requires firewalld to be stopped;
* creates a backup before making changes;
* preserves services, ports, protocols, and rich rules;
* creates separate IPv4 and IPv6 IP sets;
* automatically restores the backup if validation fails.

### fw-zone-ctl

* must be run as root;
* writes changes to the permanent firewalld configuration;
* reloads firewalld after changes;
* expects the IP sets to use the `<zone>_sources_v4` and `<zone>_sources_v6` naming convention;
* is intended for zones that have already been converted to IP sets.

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE).

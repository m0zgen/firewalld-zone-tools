#!/usr/bin/env bash
#
# Convert firewalld zone source addresses into separate IPv4/IPv6 ipsets.
#
# Usage:
#   ./migrate-zone-to-ipsets.sh internal
#   ./migrate-zone-to-ipsets.sh cloudflare
#
# Only <source address="..."/> elements are replaced.
# Services, ports, protocols, rich rules and other zone settings are preserved.

set -Eeuo pipefail

ZONE_NAME="${1:-}"

if [[ -z "${ZONE_NAME}" ]]; then
    echo "Usage: $0 <zone-name>"
    echo
    echo "Examples:"
    echo "  $0 internal"
    echo "  $0 cloudflare"
    exit 1
fi

FIREWALLD_DIR="/etc/firewalld"
ZONE_FILE="${FIREWALLD_DIR}/zones/${ZONE_NAME}.xml"

IPSET_V4_NAME="${ZONE_NAME}_sources_v4"
IPSET_V6_NAME="${ZONE_NAME}_sources_v6"

IPSET_V4_FILE="${FIREWALLD_DIR}/ipsets/${IPSET_V4_NAME}.xml"
IPSET_V6_FILE="${FIREWALLD_DIR}/ipsets/${IPSET_V6_NAME}.xml"

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/firewalld-backup-${ZONE_NAME}-${TIMESTAMP}"

BEFORE_ALL="${BACKUP_DIR}/sources-before-all.txt"
BEFORE_V4="${BACKUP_DIR}/sources-before-v4.txt"
BEFORE_V6="${BACKUP_DIR}/sources-before-v6.txt"

AFTER_ALL="${BACKUP_DIR}/sources-after-all.txt"
AFTER_V4="${BACKUP_DIR}/sources-after-v4.txt"
AFTER_V6="${BACKUP_DIR}/sources-after-v6.txt"

ZONE_CONTENT_BEFORE="${BACKUP_DIR}/zone-content-before.txt"
ZONE_CONTENT_AFTER="${BACKUP_DIR}/zone-content-after.txt"

rollback() {
    local exit_code=$?

    echo
    echo "ERROR: migration failed, restoring backup..."

    if [[ -d "${BACKUP_DIR}/firewalld" ]]; then
        rm -rf "${FIREWALLD_DIR}"
        cp -a "${BACKUP_DIR}/firewalld" "${FIREWALLD_DIR}"
        echo "Backup restored from:"
        echo "  ${BACKUP_DIR}"
    fi

    exit "${exit_code}"
}

trap rollback ERR

if [[ ${EUID} -ne 0 ]]; then
    echo "ERROR: run as root."
    exit 1
fi

if [[ ! -f "${ZONE_FILE}" ]]; then
    echo "ERROR: zone file not found:"
    echo "  ${ZONE_FILE}"
    exit 1
fi

if systemctl is-active --quiet firewalld; then
    echo "ERROR: firewalld is running."
    echo
    echo "Stop it first:"
    echo "  systemctl stop firewalld"
    exit 1
fi

mkdir -p "${BACKUP_DIR}"
mkdir -p "${FIREWALLD_DIR}/ipsets"

cp -a "${FIREWALLD_DIR}" "${BACKUP_DIR}/firewalld"

echo "Backup created:"
echo "  ${BACKUP_DIR}"

python3 - \
    "${ZONE_FILE}" \
    "${BEFORE_ALL}" \
    "${BEFORE_V4}" \
    "${BEFORE_V6}" \
    "${ZONE_CONTENT_BEFORE}" <<'PY'
import ipaddress
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

zone_file = Path(sys.argv[1])
all_file = Path(sys.argv[2])
v4_file = Path(sys.argv[3])
v6_file = Path(sys.argv[4])
content_file = Path(sys.argv[5])

root = ET.parse(zone_file).getroot()

all_sources = []
v4_sources = []
v6_sources = []

for source in root.findall("source"):
    address = source.get("address")

    if not address:
        continue

    network = ipaddress.ip_network(address, strict=False)
    normalized = str(network)

    all_sources.append(normalized)

    if network.version == 4:
        v4_sources.append(normalized)
    else:
        v6_sources.append(normalized)

all_sources = sorted(set(all_sources))
v4_sources = sorted(set(v4_sources))
v6_sources = sorted(set(v6_sources))

all_file.write_text(
    "".join(f"{entry}\n" for entry in all_sources),
    encoding="utf-8",
)

v4_file.write_text(
    "".join(f"{entry}\n" for entry in v4_sources),
    encoding="utf-8",
)

v6_file.write_text(
    "".join(f"{entry}\n" for entry in v6_sources),
    encoding="utf-8",
)

# Preserve and compare all non-source zone elements.
content = []

for element in list(root):
    if element.tag != "source":
        content.append(
            ET.tostring(element, encoding="unicode").strip()
        )

content_file.write_text(
    "\n".join(content) + "\n",
    encoding="utf-8",
)

print(f"Found total source entries: {len(all_sources)}")
print(f"IPv4 entries: {len(v4_sources)}")
print(f"IPv6 entries: {len(v6_sources)}")
PY

TOTAL_COUNT="$(wc -l < "${BEFORE_ALL}")"
V4_COUNT="$(wc -l < "${BEFORE_V4}")"
V6_COUNT="$(wc -l < "${BEFORE_V6}")"

if [[ "${TOTAL_COUNT}" -eq 0 ]]; then
    if grep -qE \
        "ipset=\"${IPSET_V4_NAME}\"|ipset=\"${IPSET_V6_NAME}\"" \
        "${ZONE_FILE}"
    then
        echo "Zone ${ZONE_NAME} already uses generated ipsets."
        trap - ERR
        exit 0
    fi

    echo "ERROR: no source address entries found in ${ZONE_FILE}"
    exit 1
fi

echo
echo "Migrating:"
echo "  total: ${TOTAL_COUNT}"
echo "  IPv4:  ${V4_COUNT}"
echo "  IPv6:  ${V6_COUNT}"

python3 - \
    "${ZONE_FILE}" \
    "${IPSET_V4_FILE}" \
    "${IPSET_V6_FILE}" \
    "${IPSET_V4_NAME}" \
    "${IPSET_V6_NAME}" \
    "${BEFORE_V4}" \
    "${BEFORE_V6}" \
    "${ZONE_NAME}" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

zone_file = Path(sys.argv[1])
ipset_v4_file = Path(sys.argv[2])
ipset_v6_file = Path(sys.argv[3])

ipset_v4_name = sys.argv[4]
ipset_v6_name = sys.argv[5]

v4_file = Path(sys.argv[6])
v6_file = Path(sys.argv[7])

zone_name = sys.argv[8]

v4_entries = [
    line.strip()
    for line in v4_file.read_text(encoding="utf-8").splitlines()
    if line.strip()
]

v6_entries = [
    line.strip()
    for line in v6_file.read_text(encoding="utf-8").splitlines()
    if line.strip()
]


def write_ipset(path, name, family, entries):
    if not entries:
        if path.exists():
            path.unlink()
        return

    root = ET.Element("ipset", {"type": "hash:net"})

    ET.SubElement(root, "short").text = name

    ET.SubElement(root, "description").text = (
        f"Source networks migrated from firewalld zone {zone_name}."
    )

    ET.SubElement(
        root,
        "option",
        {
            "name": "family",
            "value": family,
        },
    )

    for entry in sorted(set(entries)):
        ET.SubElement(root, "entry").text = entry

    tree = ET.ElementTree(root)
    ET.indent(tree, space="  ")

    tree.write(
        path,
        encoding="utf-8",
        xml_declaration=True,
    )


write_ipset(
    ipset_v4_file,
    ipset_v4_name,
    "inet",
    v4_entries,
)

write_ipset(
    ipset_v6_file,
    ipset_v6_name,
    "inet6",
    v6_entries,
)

zone_tree = ET.parse(zone_file)
zone_root = zone_tree.getroot()

insert_position = None
removed = 0

# Remove only source address elements.
for index, source in reversed(list(enumerate(list(zone_root)))):
    if source.tag == "source" and source.get("address"):
        insert_position = index
        zone_root.remove(source)
        removed += 1

# Remove old generated ipset references if script is rerun.
for source in list(zone_root.findall("source")):
    if source.get("ipset") in {ipset_v4_name, ipset_v6_name}:
        zone_root.remove(source)

if insert_position is None:
    insert_position = len(zone_root)

new_sources = []

if v4_entries:
    new_sources.append(
        ET.Element("source", {"ipset": ipset_v4_name})
    )

if v6_entries:
    new_sources.append(
        ET.Element("source", {"ipset": ipset_v6_name})
    )

for offset, source in enumerate(new_sources):
    zone_root.insert(insert_position + offset, source)

ET.indent(zone_tree, space="  ")

zone_tree.write(
    zone_file,
    encoding="utf-8",
    xml_declaration=True,
)

print(f"Removed source address elements: {removed}")
print(f"Added ipset source references: {len(new_sources)}")
PY

python3 - \
    "${IPSET_V4_FILE}" \
    "${IPSET_V6_FILE}" \
    "${AFTER_ALL}" \
    "${AFTER_V4}" \
    "${AFTER_V6}" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ipset_v4_file = Path(sys.argv[1])
ipset_v6_file = Path(sys.argv[2])

all_file = Path(sys.argv[3])
v4_file = Path(sys.argv[4])
v6_file = Path(sys.argv[5])


def read_entries(path):
    if not path.exists():
        return []

    root = ET.parse(path).getroot()

    return sorted({
        entry.text.strip()
        for entry in root.findall("entry")
        if entry.text and entry.text.strip()
    })


v4_entries = read_entries(ipset_v4_file)
v6_entries = read_entries(ipset_v6_file)
all_entries = sorted(set(v4_entries + v6_entries))

v4_file.write_text(
    "".join(f"{entry}\n" for entry in v4_entries),
    encoding="utf-8",
)

v6_file.write_text(
    "".join(f"{entry}\n" for entry in v6_entries),
    encoding="utf-8",
)

all_file.write_text(
    "".join(f"{entry}\n" for entry in all_entries),
    encoding="utf-8",
)

print(f"Verified IPv4 entries: {len(v4_entries)}")
print(f"Verified IPv6 entries: {len(v6_entries)}")
print(f"Verified total entries: {len(all_entries)}")
PY

diff -u "${BEFORE_V4}" "${AFTER_V4}"
diff -u "${BEFORE_V6}" "${AFTER_V6}"
diff -u "${BEFORE_ALL}" "${AFTER_ALL}"

python3 - \
    "${ZONE_FILE}" \
    "${ZONE_CONTENT_AFTER}" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

zone_file = Path(sys.argv[1])
content_file = Path(sys.argv[2])

root = ET.parse(zone_file).getroot()

content = []

for element in list(root):
    if element.tag != "source":
        content.append(
            ET.tostring(element, encoding="unicode").strip()
        )

content_file.write_text(
    "\n".join(content) + "\n",
    encoding="utf-8",
)
PY

# Ensures services, ports, rich rules, etc. were not changed.
diff -u "${ZONE_CONTENT_BEFORE}" "${ZONE_CONTENT_AFTER}"

if grep -q '<source address=' "${ZONE_FILE}"; then
    echo "ERROR: source address elements remain in ${ZONE_FILE}"
    exit 1
fi

if [[ "${V4_COUNT}" -gt 0 ]]; then
    grep -q "<source ipset=\"${IPSET_V4_NAME}\"" "${ZONE_FILE}"
    xmllint --noout "${IPSET_V4_FILE}"
fi

if [[ "${V6_COUNT}" -gt 0 ]]; then
    grep -q "<source ipset=\"${IPSET_V6_NAME}\"" "${ZONE_FILE}"
    xmllint --noout "${IPSET_V6_FILE}"
fi

xmllint --noout "${ZONE_FILE}"

firewall-offline-cmd --check-config

trap - ERR

echo
echo "Migration completed successfully."
echo
echo "Zone:"
echo "  ${ZONE_FILE}"
echo
echo "IPv4 ipset:"
echo "  ${IPSET_V4_FILE}"
echo "  entries: ${V4_COUNT}"
echo
echo "IPv6 ipset:"
echo "  ${IPSET_V6_FILE}"
echo "  entries: ${V6_COUNT}"
echo
echo "Backup:"
echo "  ${BACKUP_DIR}"

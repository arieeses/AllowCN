#!/usr/bin/env python3
"""Extract mainland-China CIDR ranges from a GeoLite2-Country.mmdb.

Only entries whose ISO 3166-1 alpha-2 code is exactly ``CN`` are emitted, so
Hong Kong (HK), Macau (MO) and Taiwan (TW) are excluded — this matches the
"mainland China only" requirement.

IPv4 networks go to the first output file, IPv6 to the second.

Usage:
    mmdb_to_cidr.py <db.mmdb> <out_ipv4> <out_ipv6>
"""
import ipaddress
import sys

try:
    import maxminddb
except ImportError:
    sys.stderr.write(
        "error: python module 'maxminddb' is not installed "
        "(pip3 install 'maxminddb>=2.0')\n"
    )
    sys.exit(3)


def normalize(network):
    """Convert IPv4-mapped IPv6 networks (::ffff:0:0/96 subtree) back to IPv4.

    A GeoLite2 database has ip_version 6 and stores IPv4 data inside the
    ::ffff:0.0.0.0/96 range, so the reader yields those as IPv6Network objects.
    """
    if isinstance(network, ipaddress.IPv6Network):
        mapped = network.network_address.ipv4_mapped
        if mapped is not None:
            new_prefix = network.prefixlen - 96
            if new_prefix < 0:
                return None
            return ipaddress.ip_network(f"{mapped}/{new_prefix}", strict=False)
    return network


def main():
    if len(sys.argv) != 4:
        sys.stderr.write(__doc__)
        sys.exit(2)

    db_path, out4_path, out6_path = sys.argv[1:4]

    v4, v6 = [], []
    with maxminddb.open_database(db_path) as reader:
        for network, record in reader:
            if not record:
                continue
            country = record.get("country")
            if not country or country.get("iso_code") != "CN":
                continue
            net = normalize(network)
            if net is None:
                continue
            (v4 if net.version == 4 else v6).append(net)

    # collapse_addresses merges adjacent/overlapping nets and requires a single
    # address family, which is why v4 and v6 are handled separately.
    v4 = list(ipaddress.collapse_addresses(v4))
    v6 = list(ipaddress.collapse_addresses(v6))

    _write(out4_path, v4)
    _write(out6_path, v6)

    sys.stderr.write(f"CN networks extracted: {len(v4)} IPv4, {len(v6)} IPv6\n")


def _write(path, nets):
    with open(path, "w") as fh:
        for n in nets:
            fh.write(f"{n}\n")


if __name__ == "__main__":
    main()

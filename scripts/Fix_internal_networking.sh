#!/bin/bash
set -e

# ─── Macvlan Shim ───────────────────────────────────────────
echo "Configuring macvlan shim..."

if ! ip link show macvlan-shim &>/dev/null; then
    sudo ip link add macvlan-shim link enp2s0 type macvlan mode bridge
    sudo ip addr add 192.168.0.200/32 dev macvlan-shim
    sudo ip link set macvlan-shim up
    sudo ip route add 192.168.0.201/32 dev macvlan-shim
    echo "macvlan-shim created."
else
    echo "macvlan-shim already exists, skipping..."
fi

sudo tee /etc/systemd/network/macvlan-shim.netdev > /dev/null <<EOF
[NetDev]
Name=macvlan-shim
Kind=macvlan
MACVLANInterfaceName=enp2s0

[MACVLAN]
Mode=bridge
EOF

sudo tee /etc/systemd/network/macvlan-shim.network > /dev/null <<EOF
[Match]
Name=macvlan-shim

[Network]
Address=192.168.0.200/32

[Route]
Destination=192.168.0.201/32
EOF

sudo systemctl restart systemd-networkd

# ─── DNS Fallback ────────────────────────────────────────────
echo "Configuring DNS fallback..."

sudo tee /etc/systemd/resolved.conf > /dev/null <<EOF
[Resolve]
DNS=192.168.0.201
FallbackDNS=8.8.8.8 1.1.1.1
EOF

sudo systemctl restart systemd-resolved

# ─── Tests ───────────────────────────────────────────────────
echo "Testing connectivity..."
ping -c 3 192.168.0.201 && echo "DNS container reachable ✓" || echo "DNS container unreachable ✗"
ping -c 3 google.com    && echo "Internet reachable ✓"      || echo "Internet unreachable ✗"
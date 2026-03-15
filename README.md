# Hippity Internal Server

A self-contained server stack for remote and rural communities, providing educational tools and reference resources over a local network — no internet connection required once deployed.

All services are accessible through a central homepage at `https://hippity.internal`.

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Services](#services)
- [Prerequisites](#prerequisites)
- [Setup & Deployment](#setup--deployment)
- [Managing Content](#managing-content)
- [Scripts](#scripts)
- [Environment Variables](#environment-variables)
- [Accessing Services](#accessing-services)
- [Maintenance](#maintenance)
- [Troubleshooting](#troubleshooting)

---

## Overview

Once set up, this server runs entirely offline. Community members connect to the local network and visit `https://hippity.internal` in their browser to access all available tools.

The stack handles its own DNS (so `hippity.internal` resolves on the local network), HTTPS (so connections are secure), and routing (so each service lives at its own subdomain).

**Key points:**
- All services run as Docker containers and are managed together via Docker Compose
- Configuration is stored in a `.env` file — credentials and network settings stay out of version control
- Content for Kiwix and Kolibri is loaded separately via USB or file transfer and is not part of the repo

---

## Architecture

```
Community Devices
    |
    |---> 192.168.0.201:53 (DNS) ---> resolves *.hippity.internal -> this server
    |
    └---> server:443 / server:80 (SWAG reverse proxy)
              |
              |---> hippity.internal              -> Homepage
              |---> kolibri.hippity.internal      -> Kolibri
              |---> kiwix.hippity.internal        -> Kiwix
              |---> moodle.hippity.internal       -> Moodle
              └---> portainer.hippity.internal    -> Portainer (admin only)
```

The DNS container sits directly on the LAN with its own IP address. All other services are on a private internal network and are only reachable through the reverse proxy.

---

## Services

### Homepage
A static landing page at `https://hippity.internal` with links to all services. Edit `./proxy/data/www/index.html` to update it.

---

### DNS
Resolves `*.hippity.internal` for devices on the local network. Runs on the LAN at `192.168.0.201`. Built from a custom dnsmasq image — config is in `./DNS/dnsmasq.conf`.

> To rebuild the DNS image you need a network connection that does **not** route through this server's DNS. Comment in the `build:` block in `docker-compose.yml` when needed. Note there is also a commented-out section in the compose file for use when there is no internet, but this requires the image to already be present on the machine.

---

### SWAG (Reverse Proxy)
Handles HTTPS and routes traffic to each service by subdomain. Also serves the static homepage. Proxy configs are in `./proxy/data/nginx/proxy-confs/`. This does not need to be touched unless adding a new service.

---

### Kolibri
Offline learning platform with Khan Academy-style courses and educational content. New content can be added by plugging a USB drive directly into the server — see [Managing Content](#managing-content).

---

### Kiwix
Serves offline reference content — Wikipedia, StackOverflow, and other archives in `.zim` format. ZIM files live in `./kiwix/zim/` and are not tracked in git due to their size.

---

### Moodle
Full learning management system for structured courses, quizzes, and assignments. Backed by a MariaDB database. First startup takes up to 5 minutes while the database migrates — this is normal. Unlike Kolibri, Moodle content is uploaded through the browser by an admin user, not via USB to the server directly.

---

### Portainer
Web UI for managing the Docker stack. Intended for admins only. Accessible at `https://portainer.hippity.internal` or directly at `https://<server-ip>:9443`.

---

## Prerequisites

- Docker and Docker Compose installed on the host machine
- The host's physical network interface name and subnet details (see step 2 below)
- Router configured to assign `192.168.0.201` as a static IP to the server via DHCP

---

## Setup & Deployment

### 1. Clone the repo

```bash
git clone https://github.com/LotsaGeese/my-server.git
cd my-server
```

### 2. Configure environment

```bash
cp .env.example .env
nano .env
```

Before filling in the network values, run this on the host machine to find them:

```bash
ip route
```

The output will look something like this:

```
default via 192.168.0.1 dev enp2s0 proto dhcp
192.168.0.0/24 dev enp2s0 proto kernel scope link src 192.168.0.105
```

From that output you can read off three of the `.env` values directly:

| .env variable | Where to find it | Example |
|---|---|---|
| `SUBNET` | The `x.x.x.x/xx` on the second line | `192.168.0.0/24` |
| `GATEWAY` | The IP after `default via` | `192.168.0.1` |
| `PARENT_INTERFACE` | The interface name after `dev` | `enp2s0` |

Then fill in the remaining values — database credentials, Moodle admin details, and timezone.

### 3. Generate HTTPS certificates

Run once before starting the stack. Creates a local CA and wildcard certificate for `*.hippity.internal`.

```bash
bash scripts/setup_certs.sh
```

Keep a copy of `hippityCA.pem` before the script cleans it up — you will need it to remove certificate warnings on community devices. See [Troubleshooting](#troubleshooting) for per-platform install instructions.

### 4. Fix host-side networking (recommended)

By default, the Linux host cannot reach its own macvlan containers. This script creates a shim interface so the server itself can resolve `hippity.internal`.

```bash
bash scripts/Fix_internal_networking.sh
```

### 5. Set up USB automounting (if using USB content loading)

Required for Kolibri content import via USB drives.

```bash
sudo bash scripts/setup-usb-automount.sh
```

### 6. Start the stack

```bash
docker compose up -d
```

First run takes several minutes. Monitor Moodle's startup with:

```bash
docker compose logs -f moodle
```

### 7. Configure the router

Set the primary DNS in your router's DHCP settings to `192.168.0.201`. During development this was done on a TP-Link router via the DHCP configuration page. Once set, any device that joins the network will automatically resolve `hippity.internal`.

---

## Managing Content

### Kiwix — Adding reference archives (ZIM files)

ZIM files are large offline archives (Wikipedia, StackOverflow, etc.) that Kiwix serves to users.

1. Download `.zim` files from [library.kiwix.org](https://library.kiwix.org) on a machine with internet access
2. Transfer them to the server — via USB, SCP, or however is convenient
3. Place the files in `./kiwix/zim/`
4. Restart the Kiwix container to pick them up:

```bash
docker compose restart kiwix
```

Kiwix will automatically serve any `.zim` file in that folder.

---

### Kolibri — Adding educational content (channels)

Kolibri content can be loaded either through the web UI or via USB drives.

**Via the web UI (requires internet on the server):**
1. Go to `https://kolibri.hippity.internal`
2. Sign in as admin
3. Navigate to Device > Channels > Import
4. Search for and import channels

**Via USB drive (offline method):**
1. On a connected machine, use [Kolibri Studio](https://studio.learningequality.org) or the Kolibri app to export a channel to a USB drive
2. Plug the drive into the server — it will automount to `/mnt/usb-drives/<label>` (requires `setup-usb-automount.sh` to have been run)
3. In the Kolibri web UI, go to Device > Channels > Import > Local Drive
4. Select the drive and import

---

## Scripts

### `scripts/Fix_internal_networking.sh`
Creates a `macvlan-shim` network interface on the host so the server itself can reach the DNS container at `192.168.0.201`. Without this, only LAN clients can resolve `hippity.internal` — the server itself cannot. Also configures `systemd-resolved` to use the internal DNS with `8.8.8.8` / `1.1.1.1` as fallback. The shim persists across reboots via `systemd-networkd`.

```bash
bash scripts/Fix_internal_networking.sh
```

---

### `scripts/setup_certs.sh`
Generates a local Certificate Authority and a wildcard TLS certificate for `*.hippity.internal`, then installs them where SWAG expects them. The CA key and cert are cleaned up at the end — keep a copy of `hippityCA.pem` if you need to trust the cert on client devices later. The signed certificate is valid for 825 days (the maximum most browsers accept).

```bash
bash scripts/setup_certs.sh
```

---

### `scripts/setup-usb-automount.sh`
Installs a udev rule and systemd service on the host so USB drives are automatically mounted to `/mnt/usb-drives/<drive-label>` when plugged in. Supports FAT32, exFAT, NTFS, and ext4. Skips Windows system partitions automatically. Safe to re-run.

```bash
sudo bash scripts/setup-usb-automount.sh
```

---

## Environment Variables

Copy `.env.example` to `.env` and fill in the values below.

| Variable | Description | Example |
|---|---|---|
| `TZ` | Timezone | `Australia/Adelaide` |
| `PUID` | User ID for SWAG process | `1000` |
| `PGID` | Group ID for SWAG process | `1000` |
| `DOMAIN` | Internal domain | `hippity.internal` |
| `DNS_IP` | Fixed LAN IP for DNS container | `192.168.0.201` |
| `PARENT_INTERFACE` | Host network interface for macvlan | `enp2s0` |
| `SUBNET` | LAN subnet | `192.168.0.0/24` |
| `GATEWAY` | LAN gateway | `192.168.0.1` |
| `IP_RANGE` | IP range for macvlan assignment | `192.168.0.200/29` |
| `MARIADB_USER` | Moodle database username | *(set in .env)* |
| `MARIADB_PASSWORD` | Moodle database password | *(set in .env)* |
| `MARIADB_DATABASE` | Moodle database name | *(set in .env)* |
| `MOODLE_USERNAME` | Moodle admin username | *(set in .env)* |
| `MOODLE_PASSWORD` | Moodle admin password | *(set in .env)* |
| `MOODLE_HOST` | Moodle public hostname + port | `moodle.hippity.internal:443` |

---

## Accessing Services

| Service | URL |
|---|---|
| Homepage | `https://hippity.internal` |
| Moodle (LMS) | `https://moodle.hippity.internal` |
| Kolibri | `https://kolibri.hippity.internal` |
| Kiwix | `https://kiwix.hippity.internal` |
| Portainer (admin) | `https://portainer.hippity.internal` |

Browsers will show a certificate warning until `hippityCA.pem` is installed as a trusted CA on that device — see below.

---

## Maintenance

**Update all service images**
```bash
docker compose pull
docker compose up -d
```

**Rebuild the DNS image** (needs internet not routed through this DNS — comment in the `build:` block in `docker-compose.yml` first)
```bash
docker compose build dns
docker compose up -d dns
```

**View logs for a service**
```bash
docker compose logs -f <service-name>
```

**Check all container health**
```bash
docker compose ps
```

---

## Troubleshooting

**DNS not resolving `hippity.internal`**
- Confirm the device is using `192.168.0.201` as its DNS server
- Check the DNS container is healthy: `docker compose ps dns`
- Test directly: `nslookup hippity.internal 192.168.0.201`

**Host machine cannot reach the DNS container**
- Expected on Linux with macvlan — run `bash scripts/Fix_internal_networking.sh`

**Moodle stuck on startup**
- Normal on first run — can take up to 5 minutes. The logs will show `Restoring persisted Moodle installation` which is expected.
- Check the database is ready first: `docker compose ps moodle_db`

**SWAG returning 502 Bad Gateway**
- The upstream service isn't ready yet — check `docker compose ps`
- Double-check the proxy config in `./proxy/data/nginx/proxy-confs/`

**USB drives not appearing in Kolibri**
- Run `sudo bash scripts/setup-usb-automount.sh` if not done already
- Check mount activity: `journalctl -t usb-mount -f`
- Confirm the drive is mounted: `ls /mnt/usb-drives`

**Browser certificate warning**
- You need to install `hippityCA.pem` as a trusted certificate authority on each device
- Windows: double-click the file > Install Certificate > place in "Trusted Root Certification Authorities"
- macOS: double-click to add to Keychain, then open Keychain Access and set it to "Always Trust"
- Android / iOS: Settings > Security > Install Certificate
- Linux: import via browser settings, or run `sudo cp hippityCA.pem /usr/local/share/ca-certificates/hippityCA.crt && sudo update-ca-certificates`
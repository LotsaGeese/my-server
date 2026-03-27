#!/bin/bash

# ─────────────────────────────────────────────────────────────────
#  Startup script for hippity.internal
#  Checks everything is in order before launching docker compose
# ─────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colours
RED='\033[0;31m'
YEL='\033[1;33m'
GRN='\033[0;32m'
BLU='\033[0;34m'
NC='\033[0m'

ERRORS=0
WARNINGS=0

ok()   { echo -e "  ${GRN}✓${NC}  $1"; }
warn() { echo -e "  ${YEL}!${NC}  $1"; WARNINGS=$((WARNINGS+1)); }
fail() { echo -e "  ${RED}✗${NC}  $1"; ERRORS=$((ERRORS+1)); }
info() { echo -e "  ${BLU}→${NC}  $1"; }

# ── Pretty header ────────────────────────────────────────────────
echo ""
echo -e "${BLU}  hippity.internal — startup check${NC}"
echo    "  ──────────────────────────────────"
echo ""

# ── 1. Check .env exists and required keys are filled in ────────
echo "  [ Environment ]"

ENV_FILE="$PROJECT_ROOT/.env"

if [ ! -f "$ENV_FILE" ]; then
    fail ".env file not found — copy .env.example to .env and fill it in"
    echo ""
    echo -e "  ${RED}Cannot continue without .env. Exiting.${NC}"
    exit 1
else
    ok ".env file found"
fi

check_env() {
    local key=$1
    local val
    val=$(grep -E "^${key}=" "$ENV_FILE" | cut -d= -f2- | tr -d '[:space:]')
    if [ -z "$val" ]; then
        fail "$key is not set in .env"
    else
        ok "$key is set"
    fi
}

check_env "TZ"
check_env "DNS_IP"
check_env "SUBNET"
check_env "GATEWAY"
check_env "IP_RANGE"
check_env "PARENT_INTERFACE"
check_env "DOMAIN"
check_env "MARIADB_USER"
check_env "MARIADB_PASSWORD"
check_env "MARIADB_DATABASE"
check_env "MOODLE_USERNAME"
check_env "MOODLE_PASSWORD"
check_env "MOODLE_HOST"
check_env "FB_ADMIN_PASSWORD"
check_env "FB_STUDENT_PASSWORD"

echo ""

# ── 2. Check required tools are installed ───────────────────────
echo "  [ Dependencies ]"

check_cmd() {
    if command -v "$1" &>/dev/null; then
        ok "$1 is installed"
    else
        fail "$1 is not installed — run: sudo apt install $2"
    fi
}

check_cmd docker   docker.io
check_cmd openssl  openssl

if docker compose version &>/dev/null; then
    ok "docker compose is available"
else
    fail "docker compose not found — install Docker with the compose plugin"
fi

echo ""

# ── 3. Check network interface exists ───────────────────────────
echo "  [ Network ]"

PARENT_INTERFACE=$(grep -E "^PARENT_INTERFACE=" "$ENV_FILE" | cut -d= -f2- | tr -d '[:space:]')

if [ -n "$PARENT_INTERFACE" ]; then
    if ip link show "$PARENT_INTERFACE" &>/dev/null; then
        ok "Network interface $PARENT_INTERFACE exists"
    else
        fail "Network interface $PARENT_INTERFACE not found — check PARENT_INTERFACE in .env"
        info "Available interfaces: $(ip -o link show | awk '{print $2}' | tr -d ':' | tr '\n' ' ')"
    fi
fi

# Check port 53 isn't already in use
if ss -tulpn 2>/dev/null | grep -q ':53 '; then
    warn "Port 53 is already in use — DNS container may fail to start"
    info "If on Ubuntu, run: sudo systemctl disable --now systemd-resolved"
else
    ok "Port 53 is free"
fi

for port in 80 443; do
    if ss -tulpn 2>/dev/null | grep -q ":${port} "; then
        warn "Port $port is already in use — SWAG may fail to start"
    else
        ok "Port $port is free"
    fi
done

echo ""

# ── 4. DNS resolution check ─────────────────────────────────────
echo "  [ DNS ]"

DOMAIN=$(grep -E "^DOMAIN=" "$ENV_FILE" | cut -d= -f2- | tr -d '[:space:]')
DNS_IP=$(grep -E "^DNS_IP=" "$ENV_FILE" | cut -d= -f2- | tr -d '[:space:]')

# Check if dnsmasq config exists and looks sane
DNSMASQ_CONF="$PROJECT_ROOT/DNS/dnsmasq.conf"
if [ -f "$DNSMASQ_CONF" ]; then
    ok "dnsmasq.conf found"
    # Check the domain is referenced in the config
    if grep -q "$DOMAIN" "$DNSMASQ_CONF" 2>/dev/null; then
        ok "$DOMAIN is referenced in dnsmasq.conf"
    else
        warn "$DOMAIN not found in dnsmasq.conf — DNS may not resolve correctly"
    fi
else
    fail "DNS/dnsmasq.conf not found"
fi

# If DNS container is already running, test resolution
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "dns"; then
    if command -v nslookup &>/dev/null; then
        if nslookup "$DOMAIN" "$DNS_IP" &>/dev/null; then
            ok "$DOMAIN resolves correctly via $DNS_IP"
        else
            warn "$DOMAIN does not resolve via $DNS_IP — DNS container may still be starting"
        fi
        # Check a subdomain too
        if nslookup "moodle.$DOMAIN" "$DNS_IP" &>/dev/null; then
            ok "moodle.$DOMAIN resolves correctly (wildcard DNS working)"
        else
            warn "moodle.$DOMAIN did not resolve — check wildcard entry in dnsmasq.conf"
        fi
    fi
else
    info "DNS container not yet running — skipping live resolution check"
fi

echo ""

# ── 5. Certificate checks ────────────────────────────────────────
echo "  [ Certificates ]"

CERT_CRT="$PROJECT_ROOT/proxy/data/keys/cert.crt"
CERT_KEY="$PROJECT_ROOT/proxy/data/keys/cert.key"
CA_CRT="$PROJECT_ROOT/proxy/data/www/ca.crt"

if [ -f "$CERT_CRT" ] && [ -f "$CERT_KEY" ]; then
    ok "TLS cert and key found"

    EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_CRT" 2>/dev/null | cut -d= -f2)
    EXPIRY_EPOCH=$(date -d "$EXPIRY" +%s 2>/dev/null)
    NOW_EPOCH=$(date +%s)
    DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))

    if [ "$DAYS_LEFT" -lt 0 ]; then
        fail "TLS certificate has EXPIRED — re-run scripts/setup_certs.sh"
    elif [ "$DAYS_LEFT" -lt 30 ]; then
        warn "TLS certificate expires in $DAYS_LEFT days — re-run scripts/setup_certs.sh soon"
    else
        ok "TLS certificate valid ($DAYS_LEFT days remaining)"
    fi
else
    fail "TLS certificates not found — run scripts/setup_certs.sh first"
fi

if [ -f "$CA_CRT" ]; then
    ok "CA cert found in webroot (downloadable by clients)"
else
    warn "CA cert not found at proxy/data/www/ca.crt — run scripts/setup_certs.sh"
fi

echo ""

# ── 6. File permission checks ────────────────────────────────────
echo "  [ Permissions ]"

PUID=$(grep -E "^PUID=" "$ENV_FILE" | cut -d= -f2- | tr -d '[:space:]')
PGID=$(grep -E "^PGID=" "$ENV_FILE" | cut -d= -f2- | tr -d '[:space:]')
PUID=${PUID:-1000}
PGID=${PGID:-1000}

check_permissions() {
    local path=$1
    local label=$2
    if [ ! -e "$path" ]; then
        # Already caught in data dir check
        return
    fi
    local owner
    owner=$(stat -c '%u' "$path" 2>/dev/null)
    if [ "$owner" = "$PUID" ] || [ "$owner" = "0" ]; then
        ok "$label permissions OK (owner: $owner)"
    else
        warn "$label is owned by UID $owner, expected $PUID — run: sudo chown -R $PUID:$PGID $path"
    fi

    # Check the path is actually readable and writable
    if [ ! -r "$path" ]; then
        fail "$label is not readable by this user"
    fi
    if [ -d "$path" ] && [ ! -w "$path" ]; then
        fail "$label directory is not writable — containers will fail to write data"
    fi
}

check_permissions "$PROJECT_ROOT/proxy/data"           "proxy/data"
check_permissions "$PROJECT_ROOT/proxy/data/keys"      "proxy/data/keys"
check_permissions "$PROJECT_ROOT/proxy/data/www"       "proxy/data/www"
check_permissions "$PROJECT_ROOT/proxy/data/nginx"     "proxy/data/nginx"

DATA_PATH=$(grep -E "^DATA_PATH=" "$ENV_FILE" | cut -d= -f2- | tr -d '[:space:]')
DATA_PATH=${DATA_PATH:-"$PROJECT_ROOT/data"}

for dir in filebrowser/config filebrowser/db filebrowser/srv kiwix kolibri mariadb moodle moodledata; do
    check_permissions "$DATA_PATH/$dir" "data/$dir"
done

# Check key files are not world-writable (basic security check)
for f in "$PROJECT_ROOT/proxy/data/keys/cert.key" "$SCRIPT_DIR/hippityCA.pem"; do
    if [ -f "$f" ]; then
        perms=$(stat -c '%a' "$f")
        if [ "$perms" = "644" ] || [ "$perms" = "640" ] || [ "$perms" = "600" ]; then
            ok "$(basename $f) permissions are secure ($perms)"
        else
            warn "$(basename $f) has loose permissions ($perms) — run: chmod 600 $f"
        fi
    fi
done

echo ""

# ── 7. USB / mount point checks ─────────────────────────────────
echo "  [ USB / Mounts ]"

USB_MOUNT="/mnt/usb-drives"

if [ -d "$USB_MOUNT" ]; then
    ok "$USB_MOUNT directory exists"

    # Check if anything is actually mounted there
    if mountpoint -q "$USB_MOUNT"; then
        ok "$USB_MOUNT is mounted"

        # Check it's not mounted read-only unexpectedly
        if mount | grep "$USB_MOUNT" | grep -q "ro,\|ro)"; then
            warn "$USB_MOUNT is mounted read-only — Kolibri and Moodle may not be able to write to it"
        else
            ok "$USB_MOUNT is mounted read-write"
        fi

        # Check how much space is available
        AVAIL=$(df -BG "$USB_MOUNT" 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G')
        if [ -n "$AVAIL" ]; then
            if [ "$AVAIL" -lt 2 ]; then
                warn "USB drive is nearly full — only ${AVAIL}GB remaining"
            else
                ok "USB drive has ${AVAIL}GB available"
            fi
        fi
    else
        warn "$USB_MOUNT exists but nothing is mounted — USB drive may not be plugged in"
        info "Kolibri and Moodle use this for content — they will still start but content may be missing"
    fi
else
    warn "$USB_MOUNT directory does not exist — creating it"
    sudo mkdir -p "$USB_MOUNT"
    info "Plug in your USB drive and mount it at $USB_MOUNT before using Kolibri or Moodle content"
fi

echo ""

# ── 8. Data directory checks ─────────────────────────────────────
echo "  [ Data directories ]"

for dir in filebrowser/config filebrowser/db filebrowser/srv kiwix kolibri mariadb moodle moodledata; do
    if [ -d "$DATA_PATH/$dir" ]; then
        ok "$dir exists"
    else
        fail "$DATA_PATH/$dir is missing — creating it now"
        mkdir -p "$DATA_PATH/$dir"
    fi
done

echo ""

# ── 9. Disk space check ──────────────────────────────────────────
echo "  [ Disk space ]"

AVAIL_ROOT=$(df -BG "$PROJECT_ROOT" 2>/dev/null | awk 'NR==2 {print $4}' | tr -d 'G')
if [ -n "$AVAIL_ROOT" ]; then
    if [ "$AVAIL_ROOT" -lt 2 ]; then
        fail "Less than 2GB free on main disk — containers may fail to start or run"
    elif [ "$AVAIL_ROOT" -lt 5 ]; then
        warn "Only ${AVAIL_ROOT}GB free on main disk — running low"
    else
        ok "${AVAIL_ROOT}GB free on main disk"
    fi
fi

echo ""

# ── 10. Pre-flight summary ───────────────────────────────────────
echo "  ──────────────────────────────────"

if [ "$ERRORS" -gt 0 ]; then
    echo -e "  ${RED}✗ $ERRORS error(s) found — fix them before starting.${NC}"
    [ "$WARNINGS" -gt 0 ] && echo -e "  ${YEL}! $WARNINGS warning(s) also found.${NC}"
    echo ""
    exit 1
fi

if [ "$WARNINGS" -gt 0 ]; then
    echo -e "  ${YEL}! $WARNINGS warning(s) — starting anyway.${NC}"
else
    echo -e "  ${GRN}✓ All checks passed.${NC}"
fi

echo ""
info "Starting docker compose..."
echo ""

cd "$PROJECT_ROOT" && docker compose up -d

# ── 11. Post-startup container health check ──────────────────────
echo ""
echo "  [ Container health — waiting 20s for startup ]"
sleep 20

FAILED_CONTAINERS=()

# Get all containers defined in compose
COMPOSE_CONTAINERS=$(docker compose -f "$PROJECT_ROOT/docker-compose.yml" ps --format '{{.Name}}' 2>/dev/null)

for container in $COMPOSE_CONTAINERS; do
    STATUS=$(docker inspect --format '{{.State.Status}}' "$container" 2>/dev/null)
    HEALTH=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$container" 2>/dev/null)

    if [ "$STATUS" != "running" ]; then
        fail "$container is not running (status: $STATUS)"
        FAILED_CONTAINERS+=("$container")
    elif [ "$HEALTH" = "unhealthy" ]; then
        fail "$container is running but reports unhealthy"
        FAILED_CONTAINERS+=("$container")
    elif [ "$HEALTH" = "starting" ]; then
        warn "$container is still starting up — check again in a moment"
    else
        ok "$container is running"
    fi
done

# Print logs for any failed containers
if [ ${#FAILED_CONTAINERS[@]} -gt 0 ]; then
    echo ""
    echo -e "  ${RED}── Failed container logs ──────────────────────────${NC}"
    for container in "${FAILED_CONTAINERS[@]}"; do
        echo ""
        echo -e "  ${RED}[ $container — last 30 lines ]${NC}"
        echo "  ──────────────────────────────────"
        docker logs --tail 30 "$container" 2>&1 | sed 's/^/    /'
        echo ""
    done
    echo -e "  ${RED}✗ ${#FAILED_CONTAINERS[@]} container(s) failed. See logs above.${NC}"
    echo ""
    exit 1
fi

echo ""
echo -e "  ${GRN}✓ All containers healthy.${NC}"
info "Server is up at: http://$DOMAIN"
echo ""
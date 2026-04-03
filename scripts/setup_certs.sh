#!/bin/bash
set -e

# Always resolve paths relative to this script's location,
# regardless of where it is called from.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

DOMAIN="ktf.internal"
WILDCARD="*.$DOMAIN"

# Work in a temp directory so generated files don't litter anywhere
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Reclaim ownership of proxy/data in case a previous run locked us out
echo "Resetting proxy/data ownership..."
sudo chown -R "$(id -u):$(id -g)" "$PROJECT_ROOT/proxy/data"

echo "Creating local Certificate Authority..."
openssl genrsa -out "$WORK_DIR/hippityCA.key" 4096
openssl req -x509 -new -nodes -key "$WORK_DIR/hippityCA.key" -sha256 -days 3650 \
  -out "$WORK_DIR/hippityCA.pem" \
  -subj "/C=AU/ST=SA/L=Adelaide/O=Kokota/CN=ktf Internal CA"

echo "Creating wildcard certificate key..."
openssl genrsa -out "$WORK_DIR/wildcard.$DOMAIN.key" 2048

echo "Creating OpenSSL SAN config..."
cat > "$WORK_DIR/san.cnf" <<EOF
[req]
distinguished_name=req_distinguished_name
req_extensions=req_ext
prompt=no

[req_distinguished_name]
CN=$WILDCARD

[req_ext]
subjectAltName=@alt_names

[alt_names]
DNS.1=$WILDCARD
DNS.2=$DOMAIN
EOF

echo "Creating certificate signing request..."
openssl req -new -key "$WORK_DIR/wildcard.$DOMAIN.key" \
  -out "$WORK_DIR/wildcard.$DOMAIN.csr" \
  -config "$WORK_DIR/san.cnf"

echo "Signing certificate with local CA..."
openssl x509 -req \
  -in "$WORK_DIR/wildcard.$DOMAIN.csr" \
  -CA "$WORK_DIR/hippityCA.pem" \
  -CAkey "$WORK_DIR/hippityCA.key" \
  -CAcreateserial \
  -out "$WORK_DIR/wildcard.$DOMAIN.crt" \
  -days 825 -sha256 \
  -extfile "$WORK_DIR/san.cnf" -extensions req_ext

echo "Preparing SWAG keys folder..."
mkdir -p "$PROJECT_ROOT/proxy/data/keys"

cat "$WORK_DIR/wildcard.$DOMAIN.crt" "$WORK_DIR/hippityCA.pem" \
  > "$PROJECT_ROOT/proxy/data/keys/cert.crt"
cp "$WORK_DIR/wildcard.$DOMAIN.key" \
   "$PROJECT_ROOT/proxy/data/keys/cert.key"

SWAG_CERT_DIR="$PROJECT_ROOT/proxy/data/etc/letsencrypt/live/$DOMAIN"
mkdir -p "$SWAG_CERT_DIR"

cp "$WORK_DIR/wildcard.$DOMAIN.crt"  "$SWAG_CERT_DIR/fullchain.pem"
cp "$WORK_DIR/wildcard.$DOMAIN.key"  "$SWAG_CERT_DIR/privkey.pem"
cat "$WORK_DIR/wildcard.$DOMAIN.crt" "$WORK_DIR/hippityCA.pem" \
  > "$SWAG_CERT_DIR/priv-fullchain-bundle.pem"

# Convert to DER (binary) format — Windows requires this and will show
# "file is invalid" if given a raw PEM even with a .crt extension.
# DER is also accepted by macOS, iOS and Android so one file covers all.
echo "Converting CA cert to DER format and copying to webroot..."
mkdir -p "$PROJECT_ROOT/proxy/data/www"
openssl x509 -in "$WORK_DIR/hippityCA.pem" -outform DER \
  -out "$PROJECT_ROOT/proxy/data/www/ca.crt"

# Save CA cert backup next to the script
cp "$WORK_DIR/hippityCA.pem" "$SCRIPT_DIR/hippityCA.pem"

echo "Generating nginx CA download config..."
mkdir -p "$PROJECT_ROOT/proxy/data/nginx/site-confs"
cat > "$PROJECT_ROOT/proxy/data/nginx/site-confs/ca-download.conf" <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location /ca.crt {
        root /config/www;
        default_type application/x-x509-ca-cert;
        add_header Content-Disposition 'attachment; filename="${DOMAIN}-ca.crt"';
    }
}
EOF

echo "Fixing permissions for SWAG container (PUID 1000 / PGID 1000)..."
sudo chown -R 1000:1000 "$PROJECT_ROOT/proxy/data"
sudo chmod -R 755 "$PROJECT_ROOT/proxy/data"

echo ""
echo "Done! Files created:"
echo "  proxy/data/www/ca.crt                         <- served to clients for download (DER format)"
echo "  proxy/data/nginx/site-confs/ca-download.conf  <- nginx config for http://$DOMAIN/ca.crt"
echo "  proxy/data/keys/cert.crt                      <- SWAG TLS cert (chain)"
echo "  proxy/data/keys/cert.key                      <- SWAG TLS private key"
echo "  scripts/hippityCA.pem                         <- CA cert backup (keep this safe!)"
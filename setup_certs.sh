#!/bin/bash
set -e

DOMAIN="hippity.internal"
WILDCARD="*.$DOMAIN"

echo "Creating local Certificate Authority..."
openssl genrsa -out hippityCA.key 4096
openssl req -x509 -new -nodes -key hippityCA.key -sha256 -days 3650 \
  -out hippityCA.pem \
  -subj "/C=AU/ST=SA/L=Adelaide/O=Kokota/CN=Hippity Internal CA"

echo "Creating wildcard certificate key..."
openssl genrsa -out wildcard.$DOMAIN.key 2048

echo "Creating OpenSSL SAN config..."
cat > san.cnf <<EOF
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
openssl req -new -key wildcard.$DOMAIN.key -out wildcard.$DOMAIN.csr -config san.cnf

echo "Signing certificate with local CA..."
openssl x509 -req -in wildcard.$DOMAIN.csr -CA hippityCA.pem -CAkey hippityCA.key -CAcreateserial \
  -out wildcard.$DOMAIN.crt -days 825 -sha256 -extfile san.cnf -extensions req_ext

echo "Preparing SWAG keys folder..."
mkdir -p proxy/data/keys

# SWAG expects cert.crt and cert.key
cat wildcard.$DOMAIN.crt hippityCA.pem > proxy/data/keys/cert.crt
cp wildcard.$DOMAIN.key proxy/data/keys/cert.key

SWAG_CERT_DIR="proxy/data/etc/letsencrypt/live/hippity.internal"
mkdir -p "$SWAG_CERT_DIR"

cp wildcard.${DOMAIN}.crt "$SWAG_CERT_DIR/fullchain.pem"
cp wildcard.${DOMAIN}.key "$SWAG_CERT_DIR/privkey.pem"
cat wildcard.${DOMAIN}.crt hippityCA.pem > "$SWAG_CERT_DIR/priv-fullchain-bundle.pem"

echo "Fixing permissions for SWAG container (PUID 1000 / PGID 1000)..."
sudo chown -R 1000:1000 proxy/data
sudo chmod -R 755 proxy/data

echo "Cleaning temporary files..."
rm -f wildcard.$DOMAIN.csr san.cnf
rm -f wildcard.$DOMAIN.key wildcard.$DOMAIN.crt hippityCA.key hippityCA.srl
rm -f hippityCA.srl hippityCA.pem
 
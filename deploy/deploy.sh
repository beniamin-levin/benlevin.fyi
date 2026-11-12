#!/usr/bin/env bash
# deploy.sh — Build and deploy benlevin.fyi to the server
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Target host and SSH key come from the environment so that nothing
# deployment-specific lives in the repository. Set them in your shell, or put
# them in deploy/deploy.env (gitignored) — see README.
if [[ -f "${SCRIPT_DIR}/deploy.env" ]]; then
  # shellcheck disable=SC1091
  source "${SCRIPT_DIR}/deploy.env"
fi

SERVER_HOST="${BENLEVIN_HOST:?set BENLEVIN_HOST to the target server hostname or IP}"
SERVER_USER="${BENLEVIN_USER:-ubuntu}"
KEY_FILE="${BENLEVIN_SSH_KEY:?set BENLEVIN_SSH_KEY to the path of the SSH private key}"

if [[ ! -f "$KEY_FILE" ]]; then
  echo "SSH key not found: $KEY_FILE" >&2
  exit 1
fi

echo "==> 0. Stamping CSS/JS cache-busters..."
"${SCRIPT_DIR}/stamp-assets.sh"

echo "==> 1. Building Linux binary..."
cd "$ROOT_DIR"
mkdir -p bin
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o bin/server-linux ./cmd/server

echo "==> 2. Preparing directories on server..."
ssh -i "$KEY_FILE" "${SERVER_USER}@${SERVER_HOST}" "
  sudo mkdir -p /opt/benlevin.fyi/bin
  sudo chown -R ubuntu:ubuntu /opt/benlevin.fyi
"

echo "==> 3. Uploading binary and configurations..."
scp -i "$KEY_FILE" "${ROOT_DIR}/bin/server-linux" "${SERVER_USER}@${SERVER_HOST}:/tmp/benlevin-server"
scp -i "$KEY_FILE" "${SCRIPT_DIR}/benlevin-site.service" "${SERVER_USER}@${SERVER_HOST}:/tmp/benlevin-site.service"
scp -i "$KEY_FILE" "${SCRIPT_DIR}/benlevin.fyi.conf" "${SERVER_USER}@${SERVER_HOST}:/tmp/benlevin.fyi.conf"

# Fallback copy of the public CV, served from /cv.pdf when GitHub is down.
# Only the public PDF (no phone number) may ever be uploaded.
CV_PDF="${BENLEVIN_CV_PDF:-${ROOT_DIR}/../../ben/beniamin-levin-cv-public/Beniamin-Levin-CV-public.pdf}"
if [[ "$(basename "$CV_PDF")" != "Beniamin-Levin-CV-public.pdf" ]]; then
  echo "Refusing to upload $CV_PDF: only Beniamin-Levin-CV-public.pdf may be published" >&2
  exit 1
fi
if [[ -f "$CV_PDF" ]]; then
  ssh -i "$KEY_FILE" "${SERVER_USER}@${SERVER_HOST}" "mkdir -p /opt/benlevin.fyi/cv"
  scp -i "$KEY_FILE" "$CV_PDF" "${SERVER_USER}@${SERVER_HOST}:/opt/benlevin.fyi/cv/Beniamin-Levin-CV-public.pdf"
else
  echo "Warning: $CV_PDF not found; keeping the CV copy already on the server" >&2
fi

echo "==> 4. Configuring systemd and Nginx..."
ssh -i "$KEY_FILE" "${SERVER_USER}@${SERVER_HOST}" "
  sudo chmod +x /tmp/benlevin-server
  sudo mv /tmp/benlevin-server /opt/benlevin.fyi/bin/server
  sudo chown ubuntu:ubuntu /opt/benlevin.fyi/bin/server
  
  sudo mv /tmp/benlevin-site.service /etc/systemd/system/benlevin-site.service
  sudo systemctl daemon-reload
  sudo systemctl enable benlevin-site.service
  sudo systemctl restart benlevin-site.service

  sudo mv /tmp/benlevin.fyi.conf /etc/nginx/sites-available/benlevin.fyi.conf
  sudo ln -sf /etc/nginx/sites-available/benlevin.fyi.conf /etc/nginx/sites-enabled/benlevin.fyi.conf
  sudo nginx -t
  sudo systemctl reload nginx
"

echo "==> 5. Verifying deployment on server..."
ssh -i "$KEY_FILE" "${SERVER_USER}@${SERVER_HOST}" "
  echo 'Service Status:'
  sudo systemctl is-active benlevin-site.service
  echo 'Local endpoint test:'
  curl -s http://127.0.0.1:8081/healthz
  echo ''
"

echo "==> Deploy completed successfully!"

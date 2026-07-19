#!/usr/bin/env bash
set -euo pipefail

APP_REPOSITORY_URL="${APP_REPOSITORY_URL:-https://github.com/khantnaingset-kns/ape-aws-ec2-assessment-1.git}"
APP_DIRECTORY="/opt/storage-breaker"
SCRIPT_DIRECTORY="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIRECTORY="$(cd -- "${SCRIPT_DIRECTORY}/.." && pwd)"

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
    python3 python3-venv python3-pip git nginx logrotate awscli

if [[ ! -d "${APP_DIRECTORY}/.git" ]]; then
    sudo git clone "${APP_REPOSITORY_URL}" "${APP_DIRECTORY}"
fi

sudo chown -R ubuntu:ubuntu "${APP_DIRECTORY}"
sudo install -d -o ubuntu -g ubuntu -m 0755 /var/log/storage-breaker

python3 -m venv "${APP_DIRECTORY}/.venv"
"${APP_DIRECTORY}/.venv/bin/pip" install --upgrade pip
"${APP_DIRECTORY}/.venv/bin/pip" install -r "${APP_DIRECTORY}/requirements.txt"

sudo install -o root -g root -m 0644 \
    "${PROJECT_DIRECTORY}/systemd/storage-breaker.service" \
    /etc/systemd/system/storage-breaker.service
sudo install -o root -g root -m 0644 \
    "${PROJECT_DIRECTORY}/systemd/storage-breaker-logrotate.service" \
    /etc/systemd/system/storage-breaker-logrotate.service
sudo install -o root -g root -m 0644 \
    "${PROJECT_DIRECTORY}/systemd/storage-breaker-logrotate.timer" \
    /etc/systemd/system/storage-breaker-logrotate.timer
sudo install -o root -g root -m 0755 \
    "${PROJECT_DIRECTORY}/scripts/upload-storage-breaker-logs.sh" \
    /usr/local/sbin/upload-storage-breaker-logs.sh
sudo install -o root -g root -m 0644 \
    "${PROJECT_DIRECTORY}/systemd/storage-breaker-s3-upload.service" \
    /etc/systemd/system/storage-breaker-s3-upload.service
sudo install -o root -g root -m 0644 \
    "${PROJECT_DIRECTORY}/systemd/storage-breaker-s3-upload.timer" \
    /etc/systemd/system/storage-breaker-s3-upload.timer
sudo install -o root -g root -m 0644 \
    "${PROJECT_DIRECTORY}/logrotate/storage-breaker" \
    /etc/logrotate.d/storage-breaker
sudo install -o root -g root -m 0644 \
    "${PROJECT_DIRECTORY}/nginx/storage-breaker" \
    /etc/nginx/sites-available/storage-breaker

sudo ln -sfn /etc/nginx/sites-available/storage-breaker \
    /etc/nginx/sites-enabled/storage-breaker
if [[ -L /etc/nginx/sites-enabled/default ]]; then
    sudo unlink /etc/nginx/sites-enabled/default
fi

sudo nginx -t
sudo logrotate --debug /etc/logrotate.d/storage-breaker
sudo systemctl daemon-reload
sudo systemctl enable --now storage-breaker.service
sudo systemctl enable --now nginx.service
sudo systemctl reload nginx.service
sudo systemctl enable --now storage-breaker-logrotate.timer
sudo systemctl enable --now storage-breaker-s3-upload.timer

curl --fail --silent --show-error http://127.0.0.1:3000/health
curl --fail --silent --show-error http://127.0.0.1/health
echo
echo "Deployment completed successfully."

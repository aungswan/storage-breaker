# Storage Breaker EC2 Infrastructure Deployment

This repository documents and automates the infrastructure deployment for the
AWS EC2 Assessment 1 Storage Breaker FastAPI application.

## Architecture

```text
Client
  |
  | HTTP port 80
  v
Nginx reverse proxy
  |
  | http://127.0.0.1:3000
  v
Uvicorn (one worker) managed by systemd
  |
  v
/var/log/storage-breaker/application.log
  |
  v
logrotate (100 MiB, five rotations, compression)
```

Uvicorn binds only to the loopback interface. Port 3000 must not be allowed in
the EC2 security group. Only SSH port 22 and HTTP port 80 are required.

## Target environment

| Component | Configuration |
| --- | --- |
| EC2 | `t2.micro` |
| Operating system | Ubuntu Server 22.04 LTS |
| Root volume | 10 GiB `gp3` |
| Application path | `/opt/storage-breaker` |
| Application server | Uvicorn, one worker |
| Private listener | `127.0.0.1:3000` |
| Public listener | Nginx on port 80 |

## Repository contents

```text
.
├── logrotate/storage-breaker
├── nginx/storage-breaker
├── scripts/setup-instance.sh
└── systemd/
    ├── storage-breaker.service
    ├── storage-breaker-logrotate.service
    └── storage-breaker-logrotate.timer
```

## EC2 prerequisites

Create an Ubuntu 22.04 EC2 instance and configure its security group:

| Port | Source | Purpose |
| --- | --- | --- |
| TCP 22 | Student public IP | SSH administration |
| TCP 80 | Required client network | Nginx HTTP endpoint |

Do not expose TCP 3000.

Protect the SSH private key locally:

```bash
chmod 400 mykeypair.pem
```

Private keys must never be committed to Git. This repository ignores `*.pem`
and `*.key` files as an additional safeguard.

## Automated installation

Clone this infrastructure repository onto the instance, enter its directory,
and run:

```bash
chmod +x scripts/setup-instance.sh
./scripts/setup-instance.sh
```

The script uses this application repository by default:

```text
https://github.com/khantnaingset-kns/ape-aws-ec2-assessment-1.git
```

To use another application fork:

```bash
APP_REPOSITORY_URL=https://github.com/USER/REPOSITORY.git \
  ./scripts/setup-instance.sh
```

The script installs Python, venv, pip, Git, Nginx and logrotate; clones the
application; installs Python dependencies in a virtual environment; installs
all service configuration; and enables the services at boot.

## Manual deployment summary

The equivalent manual process is:

1. Install `python3`, `python3-venv`, `python3-pip`, `git`, `nginx`, and
   `logrotate` using APT.
2. Clone the application into `/opt/storage-breaker`.
3. Create `/var/log/storage-breaker` owned by `ubuntu:ubuntu`.
4. Create `/opt/storage-breaker/.venv` and install `requirements.txt`.
5. Install `systemd/storage-breaker.service` under `/etc/systemd/system/`.
6. Install the Nginx site and enable it under `/etc/nginx/sites-enabled/`.
7. Install the logrotate policy, service, and timer.
8. Validate the configuration and enable all services.

## Storage protection

The application intentionally produces approximately 10 GiB of logs over 2.5
hours. Changing the application was outside the assignment scope, so storage
is controlled entirely at the infrastructure layer.

The logrotate policy:

- checks the file every minute using a systemd timer;
- rotates once the active log exceeds 100 MiB;
- retains five rotations;
- compresses older rotations; and
- creates replacement logs as `ubuntu:ubuntu` without restarting the app.

`copytruncate` is not required because the application reopens the log path for
every record. After logrotate renames the active file, subsequent writes go to
the newly created `application.log`.

## Verification

Check the application and Nginx services:

```bash
sudo systemctl status storage-breaker
sudo systemctl status nginx
```

Confirm Uvicorn is private and Nginx is public:

```bash
sudo ss -ltnp | grep -E ':(80|3000)[[:space:]]'
```

Expected listeners:

```text
127.0.0.1:3000  uvicorn
0.0.0.0:80      nginx
```

Test the upstream and reverse proxy on the instance:

```bash
curl -i http://127.0.0.1:3000/health
curl -i http://127.0.0.1/health
```

Test through the public address:

```bash
curl -i http://EC2_PUBLIC_IP/health
```

A healthy response is:

```http
HTTP/1.1 200 OK
Content-Type: application/json

{"status":"healthy"}
```

Verify log rotation and disk capacity:

```bash
systemctl list-timers storage-breaker-logrotate.timer
sudo journalctl -u storage-breaker-logrotate.service
ls -lh /var/log/storage-breaker
df -h /
```

## Operations and troubleshooting

Restart the application after a deployment:

```bash
sudo systemctl restart storage-breaker
```

Inspect application output:

```bash
sudo journalctl -u storage-breaker -n 100 --no-pager
```

Validate and reload Nginx:

```bash
sudo nginx -t
sudo systemctl reload nginx
```

Run a non-destructive logrotate configuration check:

```bash
sudo logrotate --debug /etc/logrotate.d/storage-breaker
```

## Deployment result

The deployment was verified with the following outcomes:

- `storage-breaker.service` active and enabled;
- one Uvicorn worker listening only on `127.0.0.1:3000`;
- Nginx active on port 80 and proxying `/health` successfully;
- public `/health` endpoint returning HTTP 200;
- logrotate timer active and enabled; and
- application remained healthy during log rotation.

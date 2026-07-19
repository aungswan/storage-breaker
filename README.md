# Storage Breaker EC2 Infrastructure Deployment

This repository deploys and protects the Storage Breaker FastAPI application on
an Ubuntu 22.04 EC2 instance. The application deliberately generates a large
amount of log data, so the infrastructure must rotate, compress, upload, verify,
and remove old logs without interrupting the application.

## Architecture

```text
Internet client
      |
      | HTTP :80
      v
Nginx reverse proxy
      |
      | http://127.0.0.1:3000
      v
Uvicorn + FastAPI (systemd)
      |
      v
/var/log/storage-breaker/application.log
      |
      | logrotate: 100 MiB, compress, keep five locally
      v
application.log.N.gz
      |
      | systemd uploader: upload, verify size + SHA-256, then delete locally
      v
Amazon S3
```

Uvicorn is bound only to loopback. The EC2 security group exposes SSH port 22
from the administrator's IP address and HTTP port 80 from the required client
network. Port 3000 must not be exposed publicly.

## Repository layout

```text
.
├── logrotate/storage-breaker
├── nginx/storage-breaker
├── scripts/
│   ├── setup-instance.sh
│   └── upload-storage-breaker-logs.sh
└── systemd/
    ├── storage-breaker.service
    ├── storage-breaker-logrotate.service
    ├── storage-breaker-logrotate.timer
    ├── storage-breaker-s3-upload.service
    └── storage-breaker-s3-upload.timer
```

## Prerequisites

- Ubuntu Server 22.04 LTS EC2 instance
- 10 GiB or larger EBS root volume
- EC2 security group allowing TCP 22 and TCP 80
- SSH private key stored securely on the administrator's computer

Protect the local SSH key:

```bash
chmod 400 mykeypair.pem
```

## 1. Create the application log directory

The application runs as the `ubuntu` user, so that user needs permission to
write its log file. This single idempotent command creates the directory and
sets its owner, group, and mode:

```bash
sudo install -d -o ubuntu -g ubuntu -m 0755 /var/log/storage-breaker
```

It is equivalent to running `mkdir`, `chown`, and `chmod` separately:

```bash
sudo mkdir -p /var/log/storage-breaker
sudo chown ubuntu:ubuntu /var/log/storage-breaker
sudo chmod 0755 /var/log/storage-breaker
```

Using `install -d` is shorter and ensures the correct state every time the
deployment script runs. Verify it with:

```bash
stat -c '%A %U:%G %n' /var/log/storage-breaker
```

Expected result:

```text
drwxr-xr-x ubuntu:ubuntu /var/log/storage-breaker
```

## 2. Deploy the application

Install the application dependencies and clone the application:

```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  python3 python3-venv python3-pip git

sudo git clone \
  https://github.com/khantnaingset-kns/ape-aws-ec2-assessment-1.git \
  /opt/storage-breaker
sudo chown -R ubuntu:ubuntu /opt/storage-breaker

python3 -m venv /opt/storage-breaker/.venv
/opt/storage-breaker/.venv/bin/pip install --upgrade pip
/opt/storage-breaker/.venv/bin/pip install \
  -r /opt/storage-breaker/requirements.txt
```

### Application systemd service

The complete `systemd/storage-breaker.service` file is:

```ini
[Unit]
Description=Storage Breaker FastAPI application
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ubuntu
Group=ubuntu
WorkingDirectory=/opt/storage-breaker
ExecStart=/opt/storage-breaker/.venv/bin/uvicorn app:app --host 127.0.0.1 --port 3000 --workers 1 --no-access-log
Restart=on-failure
RestartSec=5
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
```

Important choices in this service are:

- `User=ubuntu` and `Group=ubuntu` match the application and log-directory
  ownership.
- Uvicorn listens only on `127.0.0.1:3000`, so it cannot be reached directly
  from the internet.
- A single worker is used to stay within the memory limits of the EC2 instance.
- `Restart=on-failure` automatically recovers from an unexpected process exit.
- `--no-access-log` avoids duplicating Nginx access logs in the system journal.

Install and activate the application service:

```bash
sudo install -o root -g root -m 0644 \
  systemd/storage-breaker.service \
  /etc/systemd/system/storage-breaker.service

sudo systemctl daemon-reload
sudo systemctl enable --now storage-breaker.service
```

Verify the private application endpoint before configuring Nginx:

```bash
sudo systemctl status storage-breaker --no-pager
curl -i http://127.0.0.1:3000/health
```

### Troubleshoot the application service

If the service does not start or port 3000 does not respond:

```bash
sudo systemctl status storage-breaker --no-pager
sudo journalctl -u storage-breaker -n 100 --no-pager
sudo ss -ltnp | grep ':3000[[:space:]]'
```

Confirm that `/opt/storage-breaker`, its virtual environment, and
`requirements.txt` exist and are readable by `ubuntu`. After correcting a
service file, reload systemd before restarting:

```bash
sudo systemctl daemon-reload
sudo systemctl restart storage-breaker
```

## 3. Configure Nginx and test the health check

Install Nginx:

```bash
sudo apt-get install -y nginx
```

The complete `nginx/storage-breaker` site file is:

```nginx
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 5s;
        proxy_read_timeout 60s;
    }
}
```

Nginx listens publicly on port 80 and forwards requests to the private Uvicorn
listener. Install and enable the site:

```bash
sudo install -o root -g root -m 0644 \
  nginx/storage-breaker \
  /etc/nginx/sites-available/storage-breaker

sudo ln -sfn /etc/nginx/sites-available/storage-breaker \
  /etc/nginx/sites-enabled/storage-breaker

if [ -L /etc/nginx/sites-enabled/default ]; then
  sudo unlink /etc/nginx/sites-enabled/default
fi

sudo nginx -t
sudo systemctl enable --now nginx.service
sudo systemctl reload nginx.service
```

Test Uvicorn directly, through local Nginx, and through the public address:

```bash
curl -i http://127.0.0.1:3000/health
curl -i http://127.0.0.1/health
curl -i http://EC2_PUBLIC_IP/health
```

Expected response:

```http
HTTP/1.1 200 OK
Content-Type: application/json

{"status":"healthy"}
```

### Fix an Nginx 404

If port 3000 returns HTTP 200 but Nginx returns its own HTML 404, Nginx is
still using the configuration loaded before the custom site was installed.

```bash
sudo nginx -t
sudo systemctl reload nginx
curl -i http://127.0.0.1/health
```

## 4. Configure log rotation as filesystem usage increases

The application intentionally generates approximately 10 GiB of logs over 2.5
hours. The EC2 root volume cannot safely keep one continuously growing file. A
full root filesystem could stop logging and disrupt the operating system or
application.

The policy installed at `/etc/logrotate.d/storage-breaker` is:

```text
/var/log/storage-breaker/application.log {
    size 100M
    rotate 5
    compress
    delaycompress
    missingok
    notifempty
    create 0640 ubuntu ubuntu
}
```

The directives mean:

| Directive | Purpose |
| --- | --- |
| `size 100M` | Rotate when the active file is at least 100 MiB when checked. |
| `rotate 5` | Retain at most five numbered rotations locally. |
| `compress` | Compress older rotations with gzip to save disk space. |
| `delaycompress` | Leave `.1` uncompressed until the next rotation, then create `.2.gz`. |
| `missingok` | Do not fail when the log does not yet exist. |
| `notifempty` | Do not rotate an empty log. |
| `create 0640 ubuntu ubuntu` | Create the new active log with safe ownership and permissions. |

The systemd timer checks the file every minute:

```bash
systemctl list-timers storage-breaker-logrotate.timer
sudo journalctl -u storage-breaker-logrotate.service --no-pager
```

Because checks occur once per minute, a fast-growing log may be larger than
exactly 100 MiB before it is noticed. That is normal for size-based logrotate.

The application opens the log path for each record, so logrotate can rename the
file and create a replacement without `copytruncate` and without restarting the
application. This avoids the small copy-and-truncate data-loss window.

Validate the policy without rotating anything:

```bash
sudo logrotate --debug /etc/logrotate.d/storage-breaker
```

For a controlled test, force one rotation:

```bash
sudo logrotate --force /etc/logrotate.d/storage-breaker
ls -lh /var/log/storage-breaker
```

### Logrotate systemd service

The complete `systemd/storage-breaker-logrotate.service` file is:

```ini
[Unit]
Description=Rotate Storage Breaker application logs

[Service]
Type=oneshot
ExecStart=/usr/sbin/logrotate /etc/logrotate.d/storage-breaker
```

The service runs logrotate once and exits. Scheduling is handled separately by
the timer.

### Logrotate systemd timer

The complete `systemd/storage-breaker-logrotate.timer` file is:

```ini
[Unit]
Description=Check Storage Breaker logs every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=10s
Unit=storage-breaker-logrotate.service

[Install]
WantedBy=timers.target
```

`OnBootSec=1min` performs the first check one minute after boot.
`OnUnitActiveSec=1min` repeats the check every minute, and `AccuracySec=10s`
allows systemd a small scheduling window.

Install the policy, service, and timer:

```bash
sudo install -o root -g root -m 0644 \
  logrotate/storage-breaker \
  /etc/logrotate.d/storage-breaker

sudo install -o root -g root -m 0644 \
  systemd/storage-breaker-logrotate.service \
  /etc/systemd/system/storage-breaker-logrotate.service

sudo install -o root -g root -m 0644 \
  systemd/storage-breaker-logrotate.timer \
  /etc/systemd/system/storage-breaker-logrotate.timer

sudo systemctl daemon-reload
sudo systemctl enable --now storage-breaker-logrotate.timer
```

### Troubleshoot log rotation and disk usage

Check the timer, service journal, current files, and root filesystem:

```bash
systemctl list-timers storage-breaker-logrotate.timer
sudo systemctl status storage-breaker-logrotate.service --no-pager
sudo journalctl -u storage-breaker-logrotate.service -n 100 --no-pager
ls -lh /var/log/storage-breaker
df -h /
```

Use debug mode to find syntax or permission problems without changing files:

```bash
sudo logrotate --debug /etc/logrotate.d/storage-breaker
```

If rotation reports `Permission denied`, verify both the directory and active
log ownership:

```bash
stat -c '%A %U:%G %n' \
  /var/log/storage-breaker \
  /var/log/storage-breaker/application.log
```

The directory should be owned by `ubuntu:ubuntu`; newly created active logs
should have mode `0640` and owner `ubuntu:ubuntu`. A rotation can exceed exactly
100 MiB because the timer checks only once per minute.

## 5. Upload compressed rotations to S3

### Configure the S3 bucket and EC2 IAM role

Create or use the S3 bucket `example-bucket-2586e24b2531` and keep **S3 Block
All Public Access enabled**. Public-access blocking does not prevent an
authenticated EC2 IAM role from accessing the bucket.

Attach an IAM role to the EC2 instance and add this least-privilege policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "UploadAndVerifyStorageBreakerLogs",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject"
      ],
      "Resource": "arn:aws:s3:::example-bucket-2586e24b2531/storage-breaker/*"
    }
  ]
}
```

`s3:PutObject` permits upload. `s3:GetObject` is required because `HeadObject`
verifies the uploaded size and SHA-256 metadata. A bucket policy is normally
unnecessary when the bucket and role are in the same AWS account.

Install AWS CLI and verify the instance role:

```bash
sudo apt-get install -y awscli
aws sts get-caller-identity
```

Never run `aws configure` with permanent IAM user keys on the instance. If the
bucket uses a customer-managed KMS key, grant the role the necessary KMS key
permissions as well.

The custom uploader is installed as:

```text
/usr/local/sbin/upload-storage-breaker-logs.sh
```

### Custom upload script

The complete `scripts/upload-storage-breaker-logs.sh` file is:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

readonly LOG_DIR="/var/log/storage-breaker"
readonly S3_BUCKET="example-bucket-2586e24b2531"
readonly S3_PREFIX="storage-breaker"
readonly HOST_NAME="$(hostname -s)"

exec 9>/run/storage-breaker-s3-upload.lock
flock -n 9 || exit 0

AWS_BIN="$(command -v aws)" || {
    logger -t storage-breaker-upload "ERROR: aws CLI is not installed"
    exit 1
}

upload_archive() {
    local log_file="$1"
    local timestamp year month day checksum file_size object_name object_key destination
    local remote_size remote_checksum

    timestamp="$(date -u -r "$log_file" +'%Y%m%dT%H%M%SZ')"
    year="${timestamp:0:4}"
    month="${timestamp:4:2}"
    day="${timestamp:6:2}"
    checksum="$(sha256sum "$log_file" | awk '{print $1}')"
    file_size="$(stat -c '%s' "$log_file")"
    object_name="${timestamp}-${checksum:0:12}-$(basename "$log_file")"
    object_key="${S3_PREFIX}/${HOST_NAME}/${year}/${month}/${day}/${object_name}"
    destination="s3://${S3_BUCKET}/${object_key}"

    if ! "$AWS_BIN" s3 cp "$log_file" "$destination" \
        --only-show-errors --metadata "sha256=${checksum}"; then
        logger -t storage-breaker-upload "ERROR: Failed to upload $log_file"
        return 1
    fi

    read -r remote_size remote_checksum < <(
        "$AWS_BIN" s3api head-object --bucket "$S3_BUCKET" --key "$object_key" \
            --query '[ContentLength, Metadata.sha256]' --output text
    )

    if [[ "$remote_size" != "$file_size" || "$remote_checksum" != "$checksum" ]]; then
        logger -t storage-breaker-upload \
            "ERROR: Verification failed for $log_file at $destination"
        return 1
    fi

    rm -f -- "$log_file"
    logger -t storage-breaker-upload "Uploaded and verified $log_file at $destination"
}

upload_failed=0
while IFS= read -r -d '' log_file; do
    upload_archive "$log_file" || upload_failed=1
done < <(
    find "$LOG_DIR" -maxdepth 1 -type f \
        -name 'application.log.*.gz' -mmin +1 -print0
)

exit "$upload_failed"
```

Install it with root ownership and executable mode `0755`:

```bash
sudo install -o root -g root -m 0755 \
  scripts/upload-storage-breaker-logs.sh \
  /usr/local/sbin/upload-storage-breaker-logs.sh
```

### S3 uploader systemd service

The complete `systemd/storage-breaker-s3-upload.service` file is:

```ini
[Unit]
Description=Upload rotated Storage Breaker logs to Amazon S3
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/upload-storage-breaker-logs.sh
User=root
Group=root
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
```

This is a `oneshot` service because it performs one upload scan and exits. It
runs with a lower CPU and I/O priority so log archival does not unnecessarily
compete with the application.

### S3 uploader systemd timer

The complete `systemd/storage-breaker-s3-upload.timer` file is:

```ini
[Unit]
Description=Upload rotated Storage Breaker logs to Amazon S3 every minute

[Timer]
OnCalendar=*-*-* *:*:30
Persistent=true
Unit=storage-breaker-s3-upload.service

[Install]
WantedBy=timers.target
```

`OnCalendar=*-*-* *:*:30` starts the service at 30 seconds past every minute.
`Persistent=true` causes a missed run to be triggered after the instance starts
again.

Install and activate both units:

```bash
sudo install -o root -g root -m 0644 \
  systemd/storage-breaker-s3-upload.service \
  /etc/systemd/system/storage-breaker-s3-upload.service

sudo install -o root -g root -m 0644 \
  systemd/storage-breaker-s3-upload.timer \
  /etc/systemd/system/storage-breaker-s3-upload.timer

sudo systemctl daemon-reload
sudo systemctl enable --now storage-breaker-s3-upload.timer
```

It processes only completed compressed files matching:

```text
application.log.*.gz
```

The workflow for each archive is:

1. Wait until the gzip file is older than one minute.
2. Calculate its full SHA-256 checksum and local byte size.
3. Build a unique S3 key using hostname, UTC date, checksum, and filename.
4. Upload the archive with its SHA-256 value stored as S3 metadata.
5. Call `HeadObject` and compare the remote size and SHA-256 metadata.
6. Delete the local archive only after both values match.
7. Retain the local file and return an error if upload or verification fails.

Example S3 object key:

```text
storage-breaker/ip-172-31-24-135/2026/07/19/20260719T042520Z-97ab385d87b4-application.log.2.gz
```

Unique keys prevent one rotation from overwriting another. A `flock` lock also
prevents overlapping uploader processes. If one archive fails, the script still
attempts the remaining eligible archives and reports failure at the end.

The upload timer runs every minute at 30 seconds past the minute:

```bash
systemctl list-timers storage-breaker-s3-upload.timer
```

Run and inspect it manually:

```bash
sudo systemctl start storage-breaker-s3-upload.service
sudo systemctl status storage-breaker-s3-upload.service
sudo journalctl -t storage-breaker-upload -n 30 --no-pager
```

Successful output resembles:

```text
Uploaded and verified /var/log/storage-breaker/application.log.2.gz at s3://example-bucket-2586e24b2531/storage-breaker/...
```

Confirm that the timer starts automatically after reboot:

```bash
sudo systemctl enable --now storage-breaker-s3-upload.timer
```

### Troubleshoot an S3 upload that verifies with 403

Cause: the role has `s3:PutObject` but lacks `s3:GetObject` on the object prefix.

Fix the IAM role policy using the policy in this section, wait briefly for the IAM
change to propagate, and retry:

```bash
sudo systemctl start storage-breaker-s3-upload.service
sudo journalctl -t storage-breaker-upload -n 30 --no-pager
```

The script keeps the local archive when verification fails.

### Troubleshoot missing AWS credentials

Confirm that the IAM role is attached to the EC2 instance:

```bash
aws sts get-caller-identity
```

Do not solve this by running `aws configure` with a permanent IAM user key.

### Troubleshoot an uploader service failure

```bash
sudo systemctl status storage-breaker-s3-upload.service
sudo journalctl -u storage-breaker-s3-upload.service -n 100 --no-pager
sudo journalctl -t storage-breaker-upload -n 100 --no-pager
```

Files are intentionally retained locally when a run fails and will be retried
by the next timer invocation.

### Check retained archives during an S3 outage

```bash
df -h /
ls -lh /var/log/storage-breaker
```

No finite disk can guarantee unlimited retention during a long S3 or network
outage. Production improvements should include disk-usage alarms, uploader
failure alerts, an EBS volume sized for the expected outage window, S3
Versioning, and an S3 Lifecycle retention policy.

## Final verification checklist

- `storage-breaker.service` is active and enabled.
- Uvicorn listens only on `127.0.0.1:3000`.
- Nginx listens on port 80 and `/health` returns HTTP 200.
- `/var/log/storage-breaker` is owned by `ubuntu:ubuntu` with mode `0755`.
- The active log is rotated when checked above 100 MiB.
- Older rotations are gzip-compressed.
- Both systemd timers are active and enabled.
- The EC2 instance assumes its IAM role without static AWS keys.
- Uploaded objects use unique S3 keys.
- Local gzip archives are deleted only after remote verification succeeds.

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
- S3 bucket `example-bucket-2586e24b2531`
- EC2 IAM role with access to the bucket's `storage-breaker/` prefix
- SSH private key stored securely on the administrator's computer

Protect the local SSH key:

```bash
chmod 400 mykeypair.pem
```

Never copy permanent AWS access keys to the instance. The application uses the
temporary credentials supplied automatically by an EC2 IAM role.

## 1. Configure the S3 bucket and IAM role

Keep **S3 Block All Public Access enabled**. It blocks public access but does
not block an authenticated EC2 IAM role that has permission to use the bucket.

Attach an IAM role to the EC2 instance and add this least-privilege policy to
the role:

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

`s3:PutObject` permits upload. `s3:GetObject` is also required because the
uploader calls `HeadObject` to verify the uploaded object's size and SHA-256
metadata. Without it, upload can succeed but verification returns HTTP 403, so
the fail-safe uploader retains the local file.

A bucket policy is normally unnecessary when the role and bucket are in the
same AWS account. If the bucket uses a customer-managed KMS key, the role also
needs the appropriate KMS permissions for that key.

After attaching the role, verify it from the instance:

```bash
aws sts get-caller-identity
```

Do not use `aws s3api head-bucket` as the only access test unless the role also
has `s3:ListBucket`. The uploader intentionally does not require bucket listing.

## 2. Create the application log directory

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

## 3. Deploy the application and infrastructure

Clone this infrastructure repository on the instance, enter it, and run:

```bash
chmod +x scripts/setup-instance.sh
./scripts/setup-instance.sh
```

The setup script:

1. Installs Python, Git, Nginx, logrotate, and AWS CLI.
2. Clones the FastAPI application into `/opt/storage-breaker`.
3. Creates the Python virtual environment and installs dependencies.
4. Creates `/var/log/storage-breaker` with the correct ownership and mode.
5. Installs the application, logrotate, uploader, and timer units.
6. Installs and enables the Nginx reverse-proxy site.
7. Validates Nginx and logrotate configuration.
8. Enables all services and timers at boot.
9. Reloads Nginx and tests both health-check paths.

The default application repository is:

```text
https://github.com/khantnaingset-kns/ape-aws-ec2-assessment-1.git
```

To deploy another fork:

```bash
APP_REPOSITORY_URL=https://github.com/USER/REPOSITORY.git \
  ./scripts/setup-instance.sh
```

## 4. Why log rotation is required

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

## 5. Upload compressed rotations to S3

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

## 6. Verify the application and Nginx

Check the services:

```bash
sudo systemctl status storage-breaker nginx
sudo ss -ltnp | grep -E ':(80|3000)[[:space:]]'
```

Expected listeners:

```text
127.0.0.1:3000  uvicorn
0.0.0.0:80      nginx
```

Test Uvicorn directly and then through Nginx:

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

### Fix an Nginx 404 after deployment

APT may start Nginx before the custom site is installed. `systemctl enable
--now nginx` does not reload an already-running Nginx process. In that case,
Uvicorn returns 200 on port 3000 while Nginx still returns its own HTML 404.

Validate and reload it:

```bash
sudo nginx -t
sudo systemctl reload nginx
curl -i http://127.0.0.1/health
```

The automated setup includes this reload.

## 7. Troubleshooting

### S3 upload succeeds but verification returns 403

Cause: the role has `s3:PutObject` but lacks `s3:GetObject` on the object prefix.

Fix the IAM role policy using the policy in section 1, wait briefly for the IAM
change to propagate, and retry:

```bash
sudo systemctl start storage-breaker-s3-upload.service
sudo journalctl -t storage-breaker-upload -n 30 --no-pager
```

The script keeps the local archive when verification fails.

### AWS reports that credentials cannot be found

Confirm that the IAM role is attached to the EC2 instance:

```bash
aws sts get-caller-identity
```

Do not solve this by running `aws configure` with a permanent IAM user key.

### Uploader service fails

```bash
sudo systemctl status storage-breaker-s3-upload.service
sudo journalctl -u storage-breaker-s3-upload.service -n 100 --no-pager
sudo journalctl -t storage-breaker-upload -n 100 --no-pager
```

Files are intentionally retained locally when a run fails and will be retried
by the next timer invocation.

### Check disk usage and retained logs

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

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

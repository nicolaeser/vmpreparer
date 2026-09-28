#!/bin/bash
set -e

export TIMEZONE="${TIMEZONE:-Europe/Berlin}"
export KEYBOARD_LAYOUT="${KEYBOARD_LAYOUT:-de}"
export LIBGUESTFS_BACKEND="${LIBGUESTFS_BACKEND:-direct}"
export REGENERATE_SCHEDULE="${REGENERATE_SCHEDULE:-03:00}"

TZ="$TIMEZONE"
if [ -f /usr/share/zoneinfo/"$TZ" ]; then
    ln -sf /usr/share/zoneinfo/"$TZ" /etc/localtime
    echo "$TZ" > /etc/timezone
    echo "Timezone set to $TZ"
else
    echo "Timezone $TZ not found, using default (UTC)."
fi

OUTPUT_DIR="${OUTPUT_DIR:-/output}"
SCHEDULE="$REGENERATE_SCHEDULE"

printenv | grep -v "no_proxy" >> /etc/environment

run_builder() {
    echo "Starting build process at $(date)..."
    /app/src/builder.sh > /proc/1/fd/1 2>/proc/1/fd/2
    echo "Build process finished at $(date)."
}

if [ -n "$(find "$OUTPUT_DIR" -maxdepth 1 -name '*.qcow2' -print -quit)" ]; then
    echo "Existing images detected in $OUTPUT_DIR. Skipping immediate build."
else
    echo "No existing images found. Starting immediate build..."
    run_builder
fi

if [[ -z "$SCHEDULE" ]]; then
    echo "No REGENERATE_SCHEDULE set. Exiting."
    exit 0
fi

IFS=':' read -r HOUR MINUTE <<< "$SCHEDULE"
CRON_EXPRESSION="$MINUTE $HOUR * * *"

echo "Setting up cron schedule: $CRON_EXPRESSION"
echo "$CRON_EXPRESSION root . /etc/environment; /app/src/builder.sh > /proc/1/fd/1 2>/proc/1/fd/2" > /etc/cron.d/image-builder
chmod 0644 /etc/cron.d/image-builder

echo "Starting cron..."
cron -f
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
    if /app/src/builder.sh "$@" > /proc/1/fd/1 2>/proc/1/fd/2; then
        echo "Build process finished at $(date)."
    else
        echo "Build process failed at $(date)."
    fi
}

# Drop images that are no longer in images.conf and build the ones that are
# missing. The scheduled run below re-downloads and rebuilds all of them.
echo "Syncing $OUTPUT_DIR with images.conf..."
run_builder --missing-only

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
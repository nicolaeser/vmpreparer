#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

function info()    { echo -e "${CYAN}[VM-PREPARER-INFO]${NC} $*\n"; }
function warn()    { echo -e "${YELLOW}[VM-PREPARER-WARN]${NC} $*\n"; }
function error()   { echo -e "${RED}[VM-PREPARER-ERROR]${NC} $*\n"; exit 1; }
function success() { echo -e "${GREEN}[VM-PREPARER-OK]${NC} $*\n"; }

SCRIPT_TMP_DIR=$(mktemp -d)
trap '[[ -d "$SCRIPT_TMP_DIR" ]] && rm -rf "$SCRIPT_TMP_DIR"' EXIT

SERVE_DIR="${OUTPUT_DIR:-/output}"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
BUILD_DIR="$SCRIPT_DIR/../builds"
CONFIG_DIR="$SCRIPT_DIR/../config"
KEYBOARD_LAYOUT="${KEYBOARD_LAYOUT:-de}"
TZ="${TIMEZONE:-Europe/Berlin}"
export LIBGUESTFS_BACKEND="${LIBGUESTFS_BACKEND:-direct}"

declare -A IMAGES
CONFIG_FILE="$CONFIG_DIR/images.conf"

if [[ ! -f "$CONFIG_FILE" ]]; then
    error "Images config file not found at $CONFIG_FILE"
fi

while IFS='=' read -r key value; do
    [[ "$key" =~ ^#.*$ ]] && continue
    [[ -z "$key" ]] && continue
    IMAGES["$key"]="$value"
done < "$CONFIG_FILE"

VARIANTS_CONFIG="${BUILD_VARIANTS:-password sshkey}"
read -ra VARIANTS <<< "$VARIANTS_CONFIG"

check_prerequisites() {
    mkdir -p "$SERVE_DIR" "$BUILD_DIR"
    if ! command -v virt-customize &>/dev/null; then error "virt-customize not found"; fi
    if ! command -v virt-sparsify  &>/dev/null; then error "virt-sparsify not found"; fi
    if ! command -v jq             &>/dev/null; then error "jq not found"; fi
    if ! command -v qemu-img       &>/dev/null; then error "qemu-img not found"; fi
}

download_image() {
    local url="$1" output="$2"
    if [[ -f "$output" ]]; then
        info "Base image already exists, skipping download (remove to force).\n"
        return 0
    fi
    info "Downloading $url...\n"
    wget --tries=3 --timeout=60 -q --show-progress -O "$output" "$url"
}

get_os_type() {
    local name="$1"
    local prefix="${name%%-*}"
    case "$prefix" in
        debian) echo "debian" ;;
        ubuntu) echo "ubuntu" ;;
        *)      echo "unknown" ;;
    esac
}

customize_image() {
    local source_img="$1"
    local dest_img="$2"
    local name="$3"
    local variant="$4"
    local os_type
    os_type=$(get_os_type "$name")

    info "Building variant '$variant' for $name ($os_type)...\n"

    local overlay_cfg="$CONFIG_DIR/cloud.cfg.d/99-overrides.cfg"
    if [[ ! -f "$overlay_cfg" ]]; then
        error "Cloud-init overlay not found at $overlay_cfg"
    fi

    cp "$source_img" "$dest_img"

    local sshd_block
    if [[ "$variant" == "password" ]]; then
        sshd_block=$'PermitRootLogin yes\nPasswordAuthentication yes\nPubkeyAuthentication yes'
    else
        sshd_block=$'PermitRootLogin prohibit-password\nPasswordAuthentication no\nPubkeyAuthentication yes'
    fi

    local COMMANDS=(
        --network
        --install rsync,qemu-guest-agent,cloud-init,cloud-guest-utils,git,curl,wget,nano,net-tools,console-setup,ca-certificates
        --run-command "mkdir -p /etc/ssh/sshd_config.d /etc/cloud/cloud.cfg.d && find /etc/ssh/sshd_config.d /etc/cloud/cloud.cfg.d -mindepth 1 -maxdepth 1 -exec rm -rf {} +"
        --copy-in "$overlay_cfg":/etc/cloud/cloud.cfg.d/
        --run-command "echo 'keyboard-configuration keyboard-configuration/layoutcode select $KEYBOARD_LAYOUT' | debconf-set-selections"
        --run-command "dpkg-reconfigure -f noninteractive keyboard-configuration || true"
        --run-command "sed -i 's/XKBLAYOUT=.*/XKBLAYOUT=\"$KEYBOARD_LAYOUT\"/' /etc/default/keyboard || true"
        --run-command "setupcon || true"
        --run-command "sed -i -E '/^[[:space:]]*#?[[:space:]]*(PermitRootLogin|PasswordAuthentication|PubkeyAuthentication)\b/d' /etc/ssh/sshd_config"
        --run-command "printf '\n# config overrides\n%s\n' '$sshd_block' >> /etc/ssh/sshd_config"
    )

    case "$os_type" in
        ubuntu)
            info "Applying Ubuntu tweaks...\n"
            COMMANDS+=(
                --run-command "apt-get purge -y --auto-remove snapd ubuntu-advantage-tools landscape-common popularity-contest || true"
                --run-command "rm -rf /var/lib/snapd /snap /root/snap /home/*/snap"
            )
            ;;
    esac

    COMMANDS+=(
        --run-command "apt-get autoremove -y && apt-get clean"
        --run-command "rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb"
        --run-command "cloud-init clean --logs --seed || rm -rf /var/lib/cloud /var/log/cloud-init*.log"
        --run-command "rm -f /etc/ssh/ssh_host_*"
        --run-command "rm -rf /root/.ssh /home/*/.ssh /etc/ssh/authorized_keys"
        --run-command "rm -f /etc/netplan/50-cloud-init.yaml /etc/netplan/00-installer-config.yaml"
        --run-command "rm -f /etc/hostname && echo localhost > /etc/hostname"
        --run-command "rm -rf /var/log/*.log /var/log/*.gz /var/log/journal/* /var/log/installer /var/log/unattended-upgrades"
        --run-command "rm -f /root/.bash_history /home/*/.bash_history"
        --truncate /etc/machine-id
        --run-command "[ -f /var/lib/dbus/machine-id ] && : > /var/lib/dbus/machine-id || true"
    )

    if virt-customize -a "$dest_img" "${COMMANDS[@]}"; then
        info "Customization OK. Sparsifying...\n"

        if ! virt-sparsify --in-place "$dest_img"; then
            warn "virt-sparsify --in-place failed, continuing with plain compress"
        fi

        info "Compressing image...\n"
        local compressed_img="${dest_img}.compressed"
        if qemu-img convert -O qcow2 -c "$dest_img" "$compressed_img"; then
            mv "$compressed_img" "$dest_img"
            success "Built $name [$variant]\n"
        else
            error "Failed to compress $name"
        fi
    else
        error "Failed to customize $name [$variant]\n"
    fi
}

update_json() {
    local filename="$1"
    local name="$2"
    local variant="$3"
    local os_type="$4"

    local size
    size=$(du -h "$SERVE_DIR/$filename" | cut -f1)
    local built_date
    built_date=$(date +"%Y-%m-%d %H:%M:%S")
    local list_file="$SERVE_DIR/images.json"

    if [[ ! -f "$list_file" ]]; then echo '{"images": []}' > "$list_file"; fi

    local temp_json
    temp_json=$(mktemp)

    jq --arg fname "$filename" \
       --arg name "$name" \
       --arg variant "$variant" \
       --arg os "$os_type" \
       --arg size "$size" \
       --arg date "$built_date" \
       '.images |= (map(select(.filename != $fname)) + [{
           "filename": $fname,
           "base_name": $name,
           "variant": $variant,
           "os": $os,
           "size": $size,
           "built": $date
       }] | sort_by([.base_name, .variant]))' \
       "$list_file" > "$temp_json" && mv "$temp_json" "$list_file"

    chmod 644 "$list_file"
}

main() {
    check_prerequisites

    for img_key in "${!IMAGES[@]}"; do
        if [[ -n "${SPECIFIC_IMAGES:-}" ]] && [[ ",$SPECIFIC_IMAGES," != *",$img_key,"* ]]; then
            continue
        fi

        local url="${IMAGES[$img_key]}"
        local base_file="$BUILD_DIR/${img_key}-base.qcow2"

        download_image "$url" "$base_file"

        for variant in "${VARIANTS[@]}"; do
            local final_filename="${img_key}-${variant}.qcow2"
            local build_path="$BUILD_DIR/$final_filename"
            local serve_path="$SERVE_DIR/$final_filename"
            local serve_partial="${serve_path}.partial"

            customize_image "$base_file" "$build_path" "$img_key" "$variant"

            mv "$build_path" "$serve_partial"
            chmod 644 "$serve_partial"
            mv "$serve_partial" "$serve_path"

            update_json "$final_filename" "$img_key" "$variant" "$(get_os_type "$img_key")"
        done
    done
}

main "$@"
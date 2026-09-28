#!/bin/bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[0;36m'
NC='\033[0m'

IMAGE_SERVER_DEFAULT="https://example.com"

info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }

echo -e "${CYAN}Proxmox VM Manager (Pull & Configure)${NC}"
echo "--------------------------------------------------------"
read -rp "$(echo -e "${YELLOW}Enter image server URL [${IMAGE_SERVER_DEFAULT}]:${NC} ")" IMAGE_SERVER
IMAGE_SERVER=${IMAGE_SERVER:-$IMAGE_SERVER_DEFAULT}
IMAGE_SERVER="${IMAGE_SERVER%/}"
info "Using image server: $IMAGE_SERVER"

info "Fetching available images from server..."
TEMP_JSON=$(mktemp)

if curl -s -f "$IMAGE_SERVER/images.json" > "$TEMP_JSON" 2>/dev/null; then
    info "Found JSON image list"

    mapfile -t IMAGES < <(grep -oE '"filename"[[:space:]]*:[[:space:]]*"[^"]+"' "$TEMP_JSON" | cut -d'"' -f4)

    if [[ ${#IMAGES[@]} -eq 0 ]]; then
        error "No images found in JSON response"
        exit 1
    fi

    echo -e "${BLUE}Available images:${NC}"
    echo "----------------------------------------"
    grep -E '"(filename|size|built)"' "$TEMP_JSON" | \
    sed -E 's/.*"([^"]+)":[[:space:]]*"([^"]+)".*/\2/' | \
    awk 'NR%3==1 {f=$0} NR%3==2 {s=$0} NR%3==0 {print ++i ") " f " - Size: " s " - Built: " $0}'
    echo "----------------------------------------"
else
    error "Could not fetch image list from server. Check if server is running and accessible."
    exit 1
fi

PS3=$(echo -e "${BLUE}Select image to download (number): ${NC}")
select IMAGE_NAME in "${IMAGES[@]}"; do
    if [[ -n "$IMAGE_NAME" ]]; then
        info "You selected: $IMAGE_NAME"
        break
    else
        warn "Invalid selection. Try again."
    fi
done

read -rp "$(echo -e "${YELLOW}Enter VMID:${NC} ")" VMID
if ! [[ "$VMID" =~ ^[0-9]+$ ]] || [[ $VMID -lt 100 ]]; then
    error "VMID must be a number >= 100"
    exit 1
fi

if command -v qm &>/dev/null; then
    if qm status "$VMID" &>/dev/null; then
        error "VM with ID $VMID already exists"
        exit 1
    fi
fi

read -rp "$(echo -e "${YELLOW}Enter VM Name [${IMAGE_NAME%.*}]:${NC} ")" VM_NAME
VM_NAME=${VM_NAME:-${IMAGE_NAME%.*}}

read -rp "$(echo -e "${YELLOW}Memory in MB [4096]:${NC} ")" MEMORY
MEMORY=${MEMORY:-4096}

read -rp "$(echo -e "${YELLOW}CPUs [2]:${NC} ")" CPUS
CPUS=${CPUS:-2}
CPU_TYPE="host"

read -rp "$(echo -e "${YELLOW}Storage [local-lvm]:${NC} ")" STORAGE
STORAGE=${STORAGE:-local-lvm}

read -rp "$(echo -e "${YELLOW}Network Bridge [vmbr0]:${NC} ")" NET_BRIDGE
NET_BRIDGE=${NET_BRIDGE:-vmbr0}

read -rp "$(echo -e "${YELLOW}Enable Firewall? (y/n) [y]:${NC} ")" ENABLE_FIREWALL
ENABLE_FIREWALL=${ENABLE_FIREWALL:-y}

read -rp "$(echo -e "${YELLOW}VLAN Tag (empty for none):${NC} ")" VLAN_TAG

read -rp "$(echo -e "${YELLOW}IPv4 Address/CIDR [dhcp]:${NC} ")" IPV4
IPV4=${IPV4:-dhcp}
GW4=""
if [[ "$IPV4" != "dhcp" ]]; then
    read -rp "$(echo -e "${YELLOW}IPv4 Gateway:${NC} ")" GW4
fi

read -rp "$(echo -e "${YELLOW}IPv6 Address/CIDR [auto]:${NC} ")" IPV6
IPV6=${IPV6:-auto}
GW6=""
if [[ "$IPV6" != "auto" && "$IPV6" != "dhcp" ]]; then
    read -rp "$(echo -e "${YELLOW}IPv6 Gateway (empty for none):${NC} ")" GW6
fi

read -rp "$(echo -e "${YELLOW}Cloud-Init user [root]:${NC} ")" CIUSER
CIUSER=${CIUSER:-root}

read -rsp "$(echo -e "${YELLOW}Cloud-Init password (empty = none):${NC} ")" CIPASSWORD
echo

IMAGE_URL="$IMAGE_SERVER/$IMAGE_NAME"
LOCAL_IMAGE_FILE="/tmp/$IMAGE_NAME"

if [[ -f "$LOCAL_IMAGE_FILE" ]]; then
    info "Removing existing file $LOCAL_IMAGE_FILE to ensure fresh download..."
    rm -f "$LOCAL_IMAGE_FILE"
fi

info "Downloading image from: $IMAGE_URL"

if curl --fail -L --progress-bar -o "$LOCAL_IMAGE_FILE" "$IMAGE_URL"; then
    success "Downloaded $IMAGE_NAME successfully."
    FILE_SIZE=$(stat -f%z "$LOCAL_IMAGE_FILE" 2>/dev/null || stat -c%s "$LOCAL_IMAGE_FILE" 2>/dev/null || echo "0")
    if [[ $FILE_SIZE -lt 1048576 ]]; then
        error "Downloaded file seems too small ($FILE_SIZE bytes). Check server response."
        rm -f "$LOCAL_IMAGE_FILE"
        exit 1
    fi
else
    error "Failed to download $IMAGE_NAME from $IMAGE_URL"
    exit 1
fi

if ! command -v qm &>/dev/null; then
    warn "Proxmox 'qm' command not found. Skipping VM creation (Dry Run)."
    info "Image is saved at $LOCAL_IMAGE_FILE"
else
    info "Creating VM $VMID named '$VM_NAME'..."
    
    FW_VAL=0
    if [[ "$ENABLE_FIREWALL" =~ ^[Yy]$ ]]; then
        FW_VAL=1
    fi
    NET_OPTS="virtio,bridge=$NET_BRIDGE,firewall=$FW_VAL"
    if [[ -n "$VLAN_TAG" ]]; then
        NET_OPTS="$NET_OPTS,tag=$VLAN_TAG"
    fi

    IP_OPTS="ip=$IPV4"
    if [[ -n "$GW4" ]]; then
        IP_OPTS="$IP_OPTS,gw=$GW4"
    fi
    IP_OPTS="$IP_OPTS,ip6=$IPV6"
    if [[ -n "$GW6" ]]; then
        IP_OPTS="$IP_OPTS,gw6=$GW6"
    fi

    qm create "$VMID" --name "$VM_NAME" --memory "$MEMORY" --cores "$CPUS" --cpu "$CPU_TYPE" --net0 "$NET_OPTS"
    info "Importing disk..."
    qm importdisk "$VMID" "$LOCAL_IMAGE_FILE" "$STORAGE"
    qm set "$VMID" --scsihw virtio-scsi-single --scsi0 "$STORAGE":vm-"$VMID"-disk-0
    qm set "$VMID" --boot c --bootdisk scsi0
    qm set "$VMID" --ide2 "$STORAGE":cloudinit
    qm set "$VMID" --ciuser "$CIUSER"
    if [[ -n "$CIPASSWORD" ]]; then
        qm set "$VMID" --cipassword "$CIPASSWORD"
    fi
    qm set "$VMID" --ipconfig0 "$IP_OPTS"
    qm set "$VMID" --agent enabled=1
    qm set "$VMID" --vga std
    qm set "$VMID" --serial0 socket
    qm set "$VMID" --ostype l26

    read -rp "$(echo -e "${YELLOW}Extra disk size in GB (leave empty to skip):${NC} ")" EXTRA_DISK
    if [[ -n "$EXTRA_DISK" ]]; then
        if [[ "$EXTRA_DISK" =~ ^[0-9]+$ ]] && [[ "$EXTRA_DISK" -gt 0 ]]; then
            info "Resizing disk by ${EXTRA_DISK}G..."
            qm resize "$VMID" scsi0 +"${EXTRA_DISK}G"
            success "Disk resized successfully."
        else
            warn "Invalid disk size entered. Skipping resize."
        fi
    fi

    success "VM $VMID created successfully!"
    echo -e "${CYAN}  Start VM: ${NC}qm start $VMID"
    echo -e "${YELLOW}  Note: CPU Type is set to 'host' (standard).${NC}"
fi

info "Cleaning up temporary files..."
rm -f "$LOCAL_IMAGE_FILE" "$TEMP_JSON"
#!/bin/bash

TAG=punoko
NAME=arch
FILE=image.qcow2
DATE=$(date -I)

image_create() {
    openstack image create \
        --disk-format qcow2 \
        --file $FILE \
        --min-disk 2 \
        --min-ram 1 \
        --private \
        --property architecture=x86_64 \
        --property hw_disk_bus=virtio \
        --property hw_firmware_type=uefi \
        --property hw_video_model=virtio \
        --property hw_vif_model=virtio \
        --property os_distro=arch \
        --property os_type=linux \
        --property os_version=$DATE \
        --tag $TAG \
        $NAME
}

# Get existing images
IMAGES=$(openstack image list --private --format value --column ID --tag $TAG --name $NAME)

echo "Uploading image $FILE..."
if ! image_create; then
    echo "Failed to upload image" 1>&2
    exit 1
fi

# Deleting previous images
if [[ -n $IMAGES ]]; then
    openstack image delete $IMAGES && echo -e "Deleted images:\n$IMAGES"
fi

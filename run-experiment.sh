#!/bin/bash

#set -ex

function usage() {
    echo "Usage: $0 <experiment_number>"
    echo "The experiments are explained in the README of the repository."
    echo "The init experiment will install the required packages to conduct this experimentation."
}

if [ $# -eq 0 ]; then
    usage
    exit 1
fi


function create_base_ostree() {
    echo "🕛 Importing the base blueprint and building a new ostree"
    sudo composer-cli blueprints push blueprints/test-ostree-base.toml
    sudo composer-cli blueprints depsolve test-ostree

    COMPOSE_STATUS=$(sudo composer-cli compose status | grep test-ostree | awk '{print $2}')

    if [[ "$COMPOSE_STATUS" == "FINISHED" || "$COMPOSE_STATUS" == "RUNNING" ]]; then
        echo "🕛 The compose has already been initiated and its status is $COMPOSE_STATUS. Skipping the compose creation"
        OSTREE_COMPOSE_ID=$(sudo composer-cli compose status | grep test-ostree | awk '{print $1}')
    else
        echo "🕛 The compose has not been created yet. Creating it now"
        OSTREE_COMPOSE_ID=$(sudo composer-cli compose start-ostree test-ostree --ref "rhel/9/$(uname -i)/edge"  edge-container | grep -oP '(?<=Compose ).*(?= added to the queue)')

        while true; do
        COMPOSE_STATUS=$(sudo composer-cli compose status | grep $OSTREE_COMPOSE_ID | awk '{print $2}')
        if [ "$COMPOSE_STATUS" == "FAILED" ]; then
            echo "🕛 The compose failed"
            exit 1
        elif [ "$COMPOSE_STATUS" == "FINISHED" ]; then
            echo "🕛 The compose finished successfully"
            break
        fi
        sleep 5
    done
    fi

    if [ ! -d "artifacts" ]; then
        mkdir artifacts
    fi
    sudo composer-cli compose image $OSTREE_COMPOSE_ID --filename artifacts/test-ostree-base-container.tar
}

function expose_ostree_container() {
    OSTREE_CONTAINER_ID=$(sudo podman load -i artifacts/test-ostree-base-container.tar | grep sha256 | awk '{print $3}' | cut -d: -f2)
    sudo podman tag $OSTREE_CONTAINER_ID localhost/test-ostree-base-container:latest
    sudo podman container exists test-ostree-base-container
    if [ $? -eq 1 ]; then
        sudo podman run --rm -d --name=test-ostree-base-container -p 8080:8080 localhost/test-ostree-base-container:latest
    fi

    # Save commit id for future builds
    curl http://localhost:8080/repo/refs/heads/rhel/9/x86_64/edge > artifacts/commit_id
}

function init() {
    echo "🕛 Running init experiment"
    sudo dnf install -y composer-cli osbuild-composer cockpit-composer
    sudo dnf group install -y "Virtualization Host"
}

function experiment_1() {
    echo "🕛 Running experiment 1"
    create_base_ostree
    expose_ostree_container

    if [ ! -f "kickstarts/ks-ostree.ks" ]; then
        echo "🕛 The kickstart file does not exist. Creating it now"
        cp kickstarts/ks-ostree.ks.template kickstarts/ks-ostree.ks
        sed -e "s/#ostreesetup/ostreesetup/g" -i kickstarts/ks-ostree.ks
        sed -e "s/ARCH/$(uname -i)/g" -i kickstarts/ks-ostree.ks
    fi


    # Create a new VM that pulls the ostree hosted in the container
    sudo virt-install --name test-ostree-base-vm \
    --memory 2048 \
    --disk size=10 \
    --os-variant rhel9 \
    --import \
    --network network=default \
    --graphics none \
    --initrd-inject kickstarts/ks-ostree.ks \
    --boot kernel=/var/lib/libvirt/boot/rhel9/vmlinuz,initrd=/var/lib/libvirt/boot/rhel9/initrd.img,kernel_args="console=ttyS0 ostree=/ostree/repo rhgb quiet" \
    --qemu-commandline="-fw_cfg name=opt/com.coreos/config,file=/ostree/repo/config.ign"



    exit 0
}

case $1 in
    init)
        init
        ;;
    1)
        experiment_1
        ;;
    *)
        usage
        exit 1
        ;;
esac

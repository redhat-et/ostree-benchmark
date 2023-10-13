#!/bin/bash
#set -ex

QUAY_USER="oglok"

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


function create_ostree_container() {
    echo "🕛 Extracting the ostree container"
    echo "🕛 Login into quay.io"
    sudo podman login quay.io
    OSTREE_CONTAINER_PATH=$(sudo podman inspect test-ostree-base-container | grep -i "overlay" | grep merged | awk '{print $2}' | cut -d\" -f2)
    sudo rpm-ostree compose container-encapsulate --repo="$OSTREE_CONTAINER_PATH/usr/share/nginx/html/repo/" rhel/9/x86_64/edge docker://quay.io/$QUAY_USER/rhel9.2-base:latest

}

function init() {
    echo "🕛 Running init experiment"
    sudo dnf install -y composer-cli osbuild-composer cockpit-composer
    sudo dnf group install -y "Virtualization Host"
}

function experiment_1() {
    echo "🕛 Running experiment 1: Deploying a remote OSTree"
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
    --os-variant rhel9.2 \
    --disk path=/var/lib/libvirt/images/test-ostree-base-vm.qcow2,size=10 \
    --location /var/lib/libvirt/images/Fedora-Server-netinstall-rawhide.iso \
    --initrd-inject ./kickstarts/ks-ostree.ks \
    --network network=default \
    --extra-args="inst.ks=file:/ks-ostree.ks console=ttyS0" \
    --debug --noautoconsole --autostart

    VM_INTERFACE=$(sudo virsh domiflist test-ostree-base-vm | grep default | awk '{print $1}')

    # if artifacts/traffic.txt exists, remove it
    if [ -f "artifacts/traffic.csv" ]; then
        rm artifacts/traffic.csv
    fi

    # Start capturing traffic
    python tools/monitor_iface.py $VM_INTERFACE artifacts/traffic.csv &

    exit 0
}

function experiment_6() {
    echo "🕛 Running experiment 6: Deploying a OSTree Native Container"

    #Ask if you want to create the ostree container
    read -p "Do you want to create the ostree container? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        create_ostree_container
    fi

    if [ ! -f "kickstarts/ks-ostree-container.ks" ]; then
        echo "🕛 The kickstart file does not exist. Creating it now"
        cp kickstarts/ks-ostree.ks.template kickstarts/ks-ostree-container.ks
        sed -e "s/#ostreecontainer/ostreecontainer/g" -i kickstarts/ks-ostree-container.ks
        sed -e "s/QUAY_USER/$QUAY_USER/g" -i kickstarts/ks-ostree-container.ks
    fi

    # Create a new VM that pulls the ostree hosted in the container
    sudo virt-install --name test-ostree-container-vm \
    --memory 2048 \
    --os-variant rhel9.2 \
    --disk path=/var/lib/libvirt/images/test-container-base-vm.qcow2,size=10 \
    --location /var/lib/libvirt/images/Fedora-Server-netinstall-rawhide.iso \
    --initrd-inject ./kickstarts/ks-ostree-container.ks \
    --network network=default \
    --extra-args="inst.ks=file:/ks-ostree-container.ks console=ttyS0" \
    --debug --noautoconsole --autostart

    VM_INTERFACE=$(sudo virsh domiflist test-ostree-container-vm | grep default | awk '{print $1}')

    # if artifacts/traffic.txt exists, remove it
    if [ -f "artifacts/traffic_container.csv" ]; then
        rm artifacts/traffic_container.csv
    fi

    # Start capturing traffic
    python tools/monitor_iface.py $VM_INTERFACE artifacts/traffic_container.csv &

    exit 0
}

function cleanup() {
    # Clean up all VMs
    sudo virsh destroy test-ostree-base-vm
    sudo virsh undefine test-ostree-base-vm
    sudo virsh destroy test-ostree-container-vm
    sudo virsh undefine test-ostree-container-vm

    # Clean up all containers
    sudo podman rm -f test-ostree-base-container

    # Clean up artifacts
    sudo rm -rf artifacts

    # Clean up kickstarts
    sudo rm -rf kickstarts/ks-ostree.ks
    sudo rm -rf kickstarts/ks-ostree-container.ks

    # Clean up composes
    for i in $(sudo composer-cli compose list | grep -v ID | awk '{print $1}'); do sudo composer-cli compose delete $i; done
    # Clean up blueprints
    sudo composer-cli blueprints delete test-ostree
}

case $1 in
    init)
        init
        ;;
    1)
        experiment_1
        ;;
    6)
        experiment_6
        ;;
    create_ostree_container)
        create_ostree_container
        ;;
    cleanup)
        cleanup
        ;;
    *)
        usage
        exit 1
        ;;
esac

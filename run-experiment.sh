#!/bin/bash
set -x

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
    sudo composer-cli blueprints delete test-ostree
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

function expose_ostree() {
    if [ ! -f "artifacts/test-ostree-base-container.tar" ]; then
        echo "🕛 The ostree container does not exist. Please run the create_base_ostree function first"
        exit 1
    fi
    OSTREE_CONTAINER_ID=$(sudo podman load -i artifacts/test-ostree-base-container.tar | grep sha256 | awk '{print $3}' | cut -d: -f2)
    sudo podman tag $OSTREE_CONTAINER_ID localhost/test-ostree-base-container:latest
    sudo podman container exists test-ostree-base-container
    if [ $? -eq 1 ]; then
        sudo podman rm -f test-ostree-base-container-upgrade
        sudo podman run --rm -d --name=test-ostree-base-container -p 8080:8080 localhost/test-ostree-base-container:latest
    fi

    # Save commit id for future builds
    curl http://localhost:8080/repo/refs/heads/rhel/9/x86_64/edge > artifacts/commit_id
}

function create_ostree_upgrade() {
    echo "🕛 Importing the upgrade blueprint and building a new ostree"
    sudo composer-cli blueprints delete test-ostree
    sudo composer-cli blueprints push blueprints/test-ostree-base-upgrade.toml
    sudo composer-cli blueprints depsolve test-ostree

    COMPOSE_STATUS=$(sudo composer-cli compose status | grep test-ostree | grep 0.0.2 | awk '{print $2}')

    if [[ "$COMPOSE_STATUS" == "FINISHED" || "$COMPOSE_STATUS" == "RUNNING" ]]; then
        echo "🕛 The compose has already been initiated and its status is $COMPOSE_STATUS. Skipping the compose creation"
        OSTREE_COMPOSE_ID=$(sudo composer-cli compose status | grep test-ostree | grep 0.0.2 | awk '{print $1}')
    else
        echo "🕛 The compose has not been created yet. Creating it now"
        OSTREE_COMPOSE_ID=$(sudo composer-cli compose start-ostree test-ostree --parent "rhel/9/$(uname -i)/edge" --url http://localhost:8080/repo/ --ref "rhel/9-devel/$(uname -i)/edge" edge-container | grep -oP '(?<=Compose ).*(?= added to the queue)')

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
    sudo composer-cli compose image $OSTREE_COMPOSE_ID --filename artifacts/test-ostree-upgrade-container.tar

}

function expose_ostree_upgrade() {
    if [ ! -f "artifacts/test-ostree-upgrade-container.tar" ]; then
        echo "🕛 The ostree container does not exist. Please run the create_ostree_upgrade function first"
        exit 1
    fi
    OSTREE_CONTAINER_ID=$(sudo podman load -i artifacts/test-ostree-upgrade-container.tar | grep sha256 | awk '{print $3}' | cut -d: -f2)
    sudo podman tag $OSTREE_CONTAINER_ID localhost/test-ostree-base-container-upgrade:latest
    sudo podman container exists test-ostree-base-container
    if [ $? -eq 0 ]; then
        sudo podman rm -f test-ostree-base-container
        sudo podman run --rm -d --name=test-ostree-base-container-upgrade -p 8080:8080 localhost/test-ostree-base-container-upgrade:latest
    fi

    # Save commit id for future builds
    curl http://localhost:8080/repo/refs/heads/rhel/9/x86_64/edge > artifacts/commit_id_upgrade
}


function create_ostree_native_container() {
    echo "🕛 Login into quay.io"
    sudo podman login quay.io
    echo "🕛 Creating a new ostree native container"
    OSTREE_CONTAINER_PATH=$(sudo podman inspect test-ostree-base-container | grep -i "overlay" | grep merged | awk '{print $2}' | cut -d\" -f2)
    if [ -z "$OSTREE_CONTAINER_PATH" ]; then
        echo "🕛 The ostree container is not running. Please run the expose_ostree function first"
        exit 1
    fi
    sudo rpm-ostree compose container-encapsulate --repo="$OSTREE_CONTAINER_PATH/usr/share/nginx/html/repo/" rhel/9/x86_64/edge docker://quay.io/$QUAY_USER/rhel9.2-base:latest

}

function create_ostree_native_container_upgrade() {
    echo "🕛 Login into quay.io"
    sudo podman login quay.io

    # Replace QUAY_USER with the user of quay.io in Containerfile.template to Containerfile
    cp blueprints/Containerfile.template blueprints/Containerfile
    sed -e "s/QUAY_USER/$QUAY_USER/g" -i blueprints/Containerfile

    #TODO: Add python -m http.server & to where we store the libreswan rpm

    echo "🕛 Creating a new ostree native container upgrade"
    sudo podman build -t quay.io/$QUAY_USER/rhel9.2-base:latest -f blueprints/Containerfile

    echo "🕛 Pushing the container to quay.io"
    # Push the container to quay.io
    sudo podman push quay.io/$QUAY_USER/rhel9.2-base:latest

}

function create_rpm_repo() {
    echo "🕛 Creating a local RPM repository"
    if [ ! -d "artifacts" ]; then
        mkdir artifacts
    fi
    if [ ! -f "artifacts/libreswan-4.12-1.el9.x86_64.rpm" ]; then
        curl -L https://rpmfind.net/linux/centos-stream/9-stream/AppStream/x86_64/os/Packages/libreswan-4.12-1.el9.x86_64.rpm -o artifacts/libreswan-4.12-1.el9.x86_64.rpm
    fi

    createrepo artifacts/

    if [ -f "blueprints/local-repo-source.toml" ]; then
        rm blueprints/local-repo-source.toml
    fi
    cp blueprints/local-repo-source.toml.template blueprints/local-repo-source.toml

    echo url = \"file://$(pwd)/artifacts/\" >> blueprints/local-repo-source.toml
    sudo composer-cli sources add blueprints/local-repo-source.toml

    # Expose that directory via http and create a .repo file
    if [ -f "blueprints/local-repo.repo" ]; then
        rm blueprints/local-repo.repo
    fi
    cp blueprints/local-repo.repo.template blueprints/local-repo.repo
    LOCAL_IP=$(ip addr show dev $(ip route show default | awk '/default/ {print $5}') | grep "inet " | awk '{print $2}' | cut -d/ -f1)
    echo baseurl=http://$LOCAL_IP:8000 >> blueprints/local-repo.repo

    pushd artifacts/
    python -m http.server 8000 &
    popd
}


function init() {
    echo "🕛 Installing dependencies..."
    sudo dnf install -y composer-cli osbuild-composer cockpit-composer sshpass podman python
    sudo dnf group install -y "Virtualization Host"
}

function experiment_1() {
    echo "🕛 Running experiment 1: Deploying a remote OSTree"
    create_base_ostree
    expose_ostree

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

    # Start capturing traffic
    python tools/monitor_iface.py $VM_INTERFACE artifacts/traffic.csv &

    # wait until VM is stopped
    while true; do
        VM_STATUS=$(sudo virsh domstate test-ostree-base-vm)
        if [ "$VM_STATUS" == "shut off" ]; then
            echo "🕛 The VM is shut off"
            break
        fi
        sleep 5
    done

    create_rpm_repo
    create_ostree_upgrade
    expose_ostree_upgrade

    sudo virsh start --domain test-ostree-base-vm
    sleep 10
    VM_INTERFACE=$(sudo virsh domiflist test-ostree-base-vm | grep default | awk '{print $1}')
    VM_IP=$(sudo virsh domifaddr test-ostree-base-vm | grep vnet | awk '{print $4}' | cut -d/ -f1)
    sleep 5
    # Start capturing traffic
    python tools/monitor_iface.py $VM_INTERFACE artifacts/traffic_upgrade_raw.csv &

    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S ipsec --version"
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S rpm-ostree upgrade"
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S systemctl reboot"
    sleep 20
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S ipsec --version"
    sudo virsh destroy --domain test-ostree-base-vm
    exit 0
}

function experiment_6() {
    echo "🕛 Running experiment 6: Deploying a OSTree Native Container"
    expose_ostree

    #Ask if you want to create the ostree container
    read -p "Do you want to create the ostree native container? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        create_ostree_native_container
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

    # Start capturing traffic
    python tools/monitor_iface.py $VM_INTERFACE artifacts/traffic_container.csv &


    # Start VM
    sudo virsh start --domain test-ostree-container-vm
    sleep 10
    VM_INTERFACE=$(sudo virsh domiflist test-ostree-container-vm | grep default | awk '{print $1}')
    VM_IP=$(sudo virsh domifaddr test-ostree-container-vm | grep vnet | awk '{print $4}' | cut -d/ -f1)
    sleep 5
    # Start capturing traffic
    python tools/monitor_iface.py $VM_INTERFACE artifacts/traffic_container_upgrade.csv &
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S ipsec --version"
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S rpm-ostree upgrade"
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S systemctl reboot"
    sleep 20
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S poweroff"
    sudo virsh destroy --domain test-ostree-container-vm
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

    # Clean up blueprints
    sudo rm -rf blueprints/Containerfile
    sudo rm -rf blueprints/local-repo-source.toml
    sudo rm -rf blueprints/local-repo.repo

    # Clean up python http server
    sudo pkill -f http.server

    # Clean up composes
    for i in $(sudo composer-cli compose list | grep -v ID | awk '{print $1}'); do sudo composer-cli compose delete $i; done
    # Clean up blueprints
    sudo composer-cli blueprints delete test-ostree
    sudo composer-cli sources delete local_repo
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
    create-base-ostree)
        create_base_ostree
        ;;
    expose-ostree)
        expose_ostree
        ;;
    create-ostree-upgrade)
        create_ostree_upgrade
        ;;
    expose-ostree-upgrade)
        expose_ostree_upgrade
        ;;
    create-ostree-native-container)
        create_ostree_native_container
        ;;
    create-ostree-native-container-upgrade)
        create_ostree_native_container_upgrade
        ;;
    create-rpm-repo)
        create_rpm_repo
        ;;
    cleanup)
        cleanup
        ;;
    *)
        usage
        exit 1
        ;;
esac

#!/bin/bash
set -x

QUAY_USER="oglok"
REF="rhel/9/$(uname -i)/edge"
UPD_REF="rhel/9/$(uname -i)/edge"
IMAGE="rhel9.2-base:latest"

function usage() {
    echo "Usage: $0 <experiment_number>"
    echo "The experiments are explained in the README of the repository."
    echo "The init experiment will install the required packages to conduct this experimentation."
}

if [ $# -eq 0 ]; then
    usage
    exit 1
fi

function generate_random_binary() {
    echo "🕛 Generating a random binary"
    if [ ! -d "artifacts" ]; then
        mkdir artifacts
    fi
    if [ ! -f "artifacts/random_binary" ]; then
        dd if=/dev/urandom of=artifacts/application.bin bs=1M count=100
    fi
}

function update_incremental_random_binary() {
    echo "🕛 Updating the random binary"
    if [ ! -d "artifacts" ]; then
        mkdir artifacts
    fi
    if [ ! -f "artifacts/application.bin" ]; then
        echo "🕛 The random binary does not exist. Generating it now"
        generate_random_binary
    fi
    if [ ! -f "artifacts/application.bin.updated" ]; then
        cp artifacts/application.bin artifacts/application.bin.updated
        dd if=/dev/urandom of=artifacts/application.bin.updated bs=1M count=20 seek=80 conv=notrunc
    fi
    #mv artifacts/application.bin.updated artifacts/application.bin

}

function generate_rpm_binary() {
    echo "🕛 Generating a random binary"
    if [ ! -d "artifacts" ]; then
        mkdir artifacts
    fi
    if [ ! -f "artifacts/application.bin" ]; then
       generate_random_binary
    fi
    pushd artifacts/
    tar cvf application.tar application.bin
    popd
    rpmbuild -ba rpm/myapplication.spec --define "_sourcedir $PWD/artifacts" --define "_topdir $PWD/rpmbuild"
    cp rpmbuild/RPMS/x86_64/myapplication-1.0-1.el9.x86_64.rpm artifacts/

}

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
        OSTREE_COMPOSE_ID=$(sudo composer-cli compose start-ostree test-ostree --ref $REF  edge-container | grep -oP '(?<=Compose ).*(?= added to the queue)')

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
        echo "🕛 The ostree container does not exist. Please run the create-base-ostree function first"
        exit 1
    fi
    OSTREE_CONTAINER_ID=$(sudo podman load -i artifacts/test-ostree-base-container.tar | grep sha256 | awk '{print $3}' | cut -d: -f2)
    sudo podman tag $OSTREE_CONTAINER_ID localhost/test-ostree-base-container:latest
    sudo podman container exists test-ostree-base-container
    if [ $? -eq 1 ]; then
        sudo podman rm -f test-ostree-base-container-upgrade
        sudo podman run --rm -d --name=test-ostree-base-container -p 8080:8080 localhost/test-ostree-base-container:latest
        sleep 5
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
        OSTREE_COMPOSE_ID=$(sudo composer-cli compose start-ostree test-ostree --parent $REF --url http://localhost:8080/repo/ --ref $UPD_REF edge-container | grep -oP '(?<=Compose ).*(?= added to the queue)')

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

function create_ostree_upgrade_no_parent() {
    echo "🕛 Importing the upgrade blueprint and building a new ostree without parent commit id"
    sudo composer-cli blueprints delete test-ostree
    sudo composer-cli blueprints push blueprints/test-ostree-base-upgrade.toml
    sudo composer-cli blueprints depsolve test-ostree

    COMPOSE_STATUS=$(sudo composer-cli compose status | grep test-ostree | grep 0.0.2 | awk '{print $2}')

    if [[ "$COMPOSE_STATUS" == "FINISHED" || "$COMPOSE_STATUS" == "RUNNING" ]]; then
        echo "🕛 The compose has already been initiated and its status is $COMPOSE_STATUS. Skipping the compose creation"
        OSTREE_COMPOSE_ID=$(sudo composer-cli compose status | grep test-ostree | grep 0.0.2 | awk '{print $1}')
    else
        echo "🕛 The compose has not been created yet. Creating it now"
        OSTREE_COMPOSE_ID=$(sudo composer-cli compose start-ostree test-ostree --ref $UPD_REF edge-container | grep -oP '(?<=Compose ).*(?= added to the queue)')

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
        sleep 5
    fi

    # Save commit id for future builds
    curl http://localhost:8080/repo/refs/heads/rhel/9/x86_64/edge > artifacts/commit_id_upgrade
}

function create_base_ostree_binary() {
    echo "🕛 Importing the base blueprint and building a new ostree with binary"
    sudo composer-cli blueprints delete test-ostree
    sudo composer-cli blueprints push blueprints/test-ostree-base-binary.toml
    sudo composer-cli blueprints depsolve test-ostree

    COMPOSE_STATUS=$(sudo composer-cli compose status | grep test-ostree | awk '{print $2}')

    if [[ "$COMPOSE_STATUS" == "FINISHED" || "$COMPOSE_STATUS" == "RUNNING" ]]; then
        echo "🕛 The compose has already been initiated and its status is $COMPOSE_STATUS. Skipping the compose creation"
        OSTREE_COMPOSE_ID=$(sudo composer-cli compose status | grep test-ostree | awk '{print $1}')
    else
        echo "🕛 The compose has not been created yet. Creating it now"
        OSTREE_COMPOSE_ID=$(sudo composer-cli compose start-ostree test-ostree --ref $REF  edge-container | grep -oP '(?<=Compose ).*(?= added to the queue)')

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


function create_ostree_upgrade_binary() {
    echo "🕛 Importing the upgrade blueprint and building a new ostree"
    sudo composer-cli blueprints delete test-ostree
    sudo composer-cli blueprints push blueprints/test-ostree-base-binary-upgrade.toml
    sudo composer-cli blueprints depsolve test-ostree

    COMPOSE_STATUS=$(sudo composer-cli compose status | grep test-ostree | grep 0.0.2 | awk '{print $2}')

    if [[ "$COMPOSE_STATUS" == "FINISHED" || "$COMPOSE_STATUS" == "RUNNING" ]]; then
        echo "🕛 The compose has already been initiated and its status is $COMPOSE_STATUS. Skipping the compose creation"
        OSTREE_COMPOSE_ID=$(sudo composer-cli compose status | grep test-ostree | grep 0.0.2 | awk '{print $1}')
    else
        echo "🕛 The compose has not been created yet. Creating it now"
        OSTREE_COMPOSE_ID=$(sudo composer-cli compose start-ostree test-ostree --parent $REF --url http://localhost:8080/repo/ --ref $UPD_REF edge-container | grep -oP '(?<=Compose ).*(?= added to the queue)')

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

function create_ostree_upgrade_binary_no_parent() {
    echo "🕛 Importing the upgrade blueprint and building a new ostree without parent commit id"
    sudo composer-cli blueprints delete test-ostree
    sudo composer-cli blueprints push blueprints/test-ostree-base-binary-upgrade.toml
    sudo composer-cli blueprints depsolve test-ostree

    COMPOSE_STATUS=$(sudo composer-cli compose status | grep test-ostree | grep 0.0.2 | awk '{print $2}')

    if [[ "$COMPOSE_STATUS" == "FINISHED" || "$COMPOSE_STATUS" == "RUNNING" ]]; then
        echo "🕛 The compose has already been initiated and its status is $COMPOSE_STATUS. Skipping the compose creation"
        OSTREE_COMPOSE_ID=$(sudo composer-cli compose status | grep test-ostree | grep 0.0.2 | awk '{print $1}')
    else
        echo "🕛 The compose has not been created yet. Creating it now"
        OSTREE_COMPOSE_ID=$(sudo composer-cli compose start-ostree test-ostree --ref $UPD_REF edge-container | grep -oP '(?<=Compose ).*(?= added to the queue)')

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

    echo "🕛 Creating a new ostree native container upgrade"
    sudo podman build -t quay.io/$QUAY_USER/$IMAGE -f blueprints/Containerfile

    echo "🕛 Pushing the container to quay.io"
    # Push the container to quay.io
    sudo podman push quay.io/$QUAY_USER/$IMAGE

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
    sudo dnf install -y composer-cli osbuild-composer cockpit-composer sshpass podman python rpm-build
    sudo dnf group install -y "Virtualization Host"
    curl -LO https://dl.fedoraproject.org/pub/fedora/linux/development/rawhide/Server/x86_64/iso/Fedora-Server-netinst-x86_64-Rawhide-20231018.n.0.iso
    sudo mv Fedora-Server-netinst-x86_64-Rawhide-20231018.n.0.iso /var/lib/libvirt/images/Fedora-Server-netinstall-rawhide.iso
}

function experiment_1() {
    echo "🕛 Running experiment 1: Deploying a remote OSTree and upgrade"
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

    ssh-keygen -R $VM_IP
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S ipsec --version"
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S rpm-ostree upgrade"
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S systemctl reboot"
    sleep 20
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S ipsec --version"
    sudo virsh destroy --domain test-ostree-base-vm
    exit 0
}

function experiment_2() {
    echo "🕛 Running experiment 2: Deploying a remote OSTree and rebase"
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
    python tools/monitor_iface.py $VM_INTERFACE artifacts/traffic_rebase.csv &

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
    UPD_REF="rhel/10/$(uname -i)/edge" create_ostree_upgrade
    expose_ostree_upgrade

    sudo virsh start --domain test-ostree-base-vm
    sleep 10
    VM_INTERFACE=$(sudo virsh domiflist test-ostree-base-vm | grep default | awk '{print $1}')
    VM_IP=$(sudo virsh domifaddr test-ostree-base-vm | grep vnet | awk '{print $4}' | cut -d/ -f1)
    sleep 10
    # Start capturing traffic
    python tools/monitor_iface.py $VM_INTERFACE artifacts/traffic_rebase_upgrade.csv &
    sleep 10
    ssh-keygen -R $VM_IP
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S ipsec --version"
    sshpass -p "redhat" ssh -o "StrictHostKeyChecking=no" redhat@$VM_IP "UPD_REF=rhel/10/$(uname -i)/edge && echo redhat | sudo -S rpm-ostree rebase -b \$UPD_REF"
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S systemctl reboot"
    sleep 20
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S ipsec --version"
    sudo virsh destroy --domain test-ostree-base-vm
    exit 0


}

function experiment_3() {
    echo "🕛 Running experiment 3: Deploying a remote OSTree and rebase without parent commit id"
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
    python tools/monitor_iface.py $VM_INTERFACE artifacts/traffic_rebase.csv &

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
    UPD_REF="rhel/10/$(uname -i)/edge" create_ostree_upgrade_no_parent
    expose_ostree_upgrade

    sudo virsh start --domain test-ostree-base-vm
    sleep 10
    VM_INTERFACE=$(sudo virsh domiflist test-ostree-base-vm | grep default | awk '{print $1}')
    VM_IP=$(sudo virsh domifaddr test-ostree-base-vm | grep vnet | awk '{print $4}' | cut -d/ -f1)
    sleep 10
    # Start capturing traffic
    python tools/monitor_iface.py $VM_INTERFACE artifacts/traffic_rebase_upgrade.csv &
    sleep 10
    ssh-keygen -R $VM_IP
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S ipsec --version"
    sshpass -p "redhat" ssh -o "StrictHostKeyChecking=no" redhat@$VM_IP "UPD_REF=rhel/10/$(uname -i)/edge && echo redhat | sudo -S rpm-ostree rebase -b \$UPD_REF"
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S systemctl reboot"
    sleep 20
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S ipsec --version"
    sudo virsh destroy --domain test-ostree-base-vm
    exit 0
}

function experiment_4() {
    echo "🕛 Running experiment 4: Deploying a OSTree Native Container and upgrade"
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
        sed -e "s/IMAGE/$IMAGE/g" -i kickstarts/ks-ostree-container.ks
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

    # wait until VM is stopped
    while true; do
        VM_STATUS=$(sudo virsh domstate test-ostree-container-vm)
        if [ "$VM_STATUS" == "shut off" ]; then
            echo "🕛 The VM is shut off"
            break
        fi
        sleep 5
    done

    create_rpm_repo
    create_ostree_native_container_upgrade

    # Start VM
    sudo virsh start --domain test-ostree-container-vm
    sleep 10
    VM_INTERFACE=$(sudo virsh domiflist test-ostree-container-vm | grep default | awk '{print $1}')
    VM_IP=$(sudo virsh domifaddr test-ostree-container-vm | grep vnet | awk '{print $4}' | cut -d/ -f1)
    sleep 5
    # Start capturing traffic
    python tools/monitor_iface.py $VM_INTERFACE artifacts/traffic_container_upgrade.csv &

    ssh-keygen -R $VM_IP
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S ipsec --version"
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S rpm-ostree upgrade"
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S systemctl reboot"
    sleep 20
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S poweroff"
    sudo virsh destroy --domain test-ostree-container-vm
    exit 0
}

function experiment_5() {
    echo "🕛 Running experiment 5: Deploying a OSTree Native Container and rebase"
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
        sed -e "s/IMAGE/$IMAGE/g" -i kickstarts/ks-ostree-container.ks
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

    # wait until VM is stopped
    while true; do
        VM_STATUS=$(sudo virsh domstate test-ostree-container-vm)
        if [ "$VM_STATUS" == "shut off" ]; then
            echo "🕛 The VM is shut off"
            break
        fi
        sleep 5
    done

    create_rpm_repo
    IMAGE=rhel9.2-upgrade:latest create_ostree_native_container_upgrade

    # Start VM
    sudo virsh start --domain test-ostree-container-vm
    sleep 10
    VM_INTERFACE=$(sudo virsh domiflist test-ostree-container-vm | grep default | awk '{print $1}')
    VM_IP=$(sudo virsh domifaddr test-ostree-container-vm | grep vnet | awk '{print $4}' | cut -d/ -f1)
    sleep 5
    # Start capturing traffic
    python tools/monitor_iface.py $VM_INTERFACE artifacts/traffic_container_upgrade.csv &

    ssh-keygen -R $VM_IP
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S ipsec --version"
    sshpass -p "redhat" ssh -o "StrictHostKeyChecking=no" redhat@$VM_IP "IMAGE=rhel9.2-upgrade:latest && QUAY_USER=${QUAY_USER} && echo redhat | sudo -S rpm-ostree rebase ostree-unverified-registry:quay.io/\$QUAY_USER/\$IMAGE"
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S systemctl reboot"
    sleep 20
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S poweroff"
    sudo virsh destroy --domain test-ostree-container-vm
    exit 0

}

function experiment_6() {
    echo "🕛 Running experiment 6: Build two base layers and a binary on top. Upgrade from one to the other."
    expose_ostree

    OSTREE_CONTAINER_PATH=$(sudo podman inspect test-ostree-base-container | grep -i "overlay" | grep merged | awk '{print $2}' | cut -d\" -f2)
    if [ -z "$OSTREE_CONTAINER_PATH" ]; then
        echo "🕛 The ostree container is not running. Please run the expose_ostree function first"
        exit 1
    fi
    sudo rpm-ostree compose container-encapsulate --repo="$OSTREE_CONTAINER_PATH/usr/share/nginx/html/repo/" rhel/9/x86_64/edge docker://quay.io/$QUAY_USER/rhel9.2-base:0.0.0

    create_rpm_repo
    create_ostree_upgrade_no_parent
    expose_ostree_upgrade

    OSTREE_CONTAINER_PATH=$(sudo podman inspect test-ostree-base-container-upgrade | grep -i "overlay" | grep merged | awk '{print $2}' | cut -d\" -f2)
    if [ -z "$OSTREE_CONTAINER_PATH" ]; then
        echo "🕛 The ostree container is not running. Please run the expose_ostree function first"
        exit 1
    fi
    sudo rpm-ostree compose container-encapsulate --repo="$OSTREE_CONTAINER_PATH/usr/share/nginx/html/repo/" rhel/9/x86_64/edge docker://quay.io/$QUAY_USER/rhel9.2-base:0.0.1

    echo "🕛 Login into quay.io"
    sudo podman login quay.io

    generate_random_binary
    cp artifacts/application.bin blueprints/
    # Replace QUAY_USER with the user of quay.io in Containerfile.template to Containerfile1
    cp blueprints/Containerfile.template.binary blueprints/Containerfile1
    sed -e "s/QUAY_USER/$QUAY_USER/g" -i blueprints/Containerfile1
    sed -e "s/VERSION/0.0.0/g" -i blueprints/Containerfile1

    echo "🕛 Creating a new ostree native container upgrade"
    sudo podman build -t quay.io/$QUAY_USER/myapplication:stable -f blueprints/Containerfile1

    echo "🕛 Pushing the container to quay.io"
    # Push the container to quay.io
    sudo podman push quay.io/$QUAY_USER/myapplication:stable

    if [ ! -f "kickstarts/ks-ostree-container.ks" ]; then
        echo "🕛 The kickstart file does not exist. Creating it now"
        cp kickstarts/ks-ostree.ks.template kickstarts/ks-ostree-container.ks
        sed -e "s/#ostreecontainer/ostreecontainer/g" -i kickstarts/ks-ostree-container.ks
        sed -e "s/QUAY_USER/$QUAY_USER/g" -i kickstarts/ks-ostree-container.ks
        IMAGE=myapplication:stable && sed -e "s/IMAGE/$IMAGE/g" -i kickstarts/ks-ostree-container.ks
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

    # wait until VM is stopped
    while true; do
        VM_STATUS=$(sudo virsh domstate test-ostree-container-vm)
        if [ "$VM_STATUS" == "shut off" ]; then
            echo "🕛 The VM is shut off"
            break
        fi
        sleep 5
    done

    # Replace QUAY_USER with the user of quay.io in Containerfile.template to Containerfile2
    cp blueprints/Containerfile.template.binary blueprints/Containerfile2
    sed -e "s/QUAY_USER/$QUAY_USER/g" -i blueprints/Containerfile2
    sed -e "s/VERSION/0.0.1/g" -i blueprints/Containerfile2

    sudo podman build -t quay.io/$QUAY_USER/myapplication:stable -f blueprints/Containerfile2

    echo "🕛 Pushing the container to quay.io"
    # Push the container to quay.io
    sudo podman push quay.io/$QUAY_USER/myapplication:stable

    # Start VM
    sudo virsh start --domain test-ostree-container-vm
    sleep 10
    VM_INTERFACE=$(sudo virsh domiflist test-ostree-container-vm | grep default | awk '{print $1}')
    VM_IP=$(sudo virsh domifaddr test-ostree-container-vm | grep vnet | awk '{print $4}' | cut -d/ -f1)
    sleep 5
    # Start capturing traffic
    python tools/monitor_iface.py $VM_INTERFACE artifacts/traffic_container_upgrade.csv &

    ssh-keygen -R $VM_IP
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S ipsec --version"
    sshpass -p "redhat" ssh -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S rpm-ostree upgrade"
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S systemctl reboot"
    sleep 20
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S poweroff"
    sudo virsh destroy --domain test-ostree-container-vm
    rm blueprints/application.bin
}

function experiment_7() {
    echo "🕛 Running experiment 7: Deploying a remote OSTree with application binary and upgrade"
    generate_rpm_binary
    create_rpm_repo

    create_base_ostree_binary
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

    create_ostree_upgrade_binary
    expose_ostree_upgrade

    sudo virsh start --domain test-ostree-base-vm
    sleep 10
    VM_INTERFACE=$(sudo virsh domiflist test-ostree-base-vm | grep default | awk '{print $1}')
    VM_IP=$(sudo virsh domifaddr test-ostree-base-vm | grep vnet | awk '{print $4}' | cut -d/ -f1)
    sleep 5
    # Start capturing traffic
    python tools/monitor_iface.py $VM_INTERFACE artifacts/traffic_upgrade_raw.csv &

    sleep 10
    ssh-keygen -R $VM_IP
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S ipsec --version"
    sshpass -p "redhat" ssh -o "StrictHostKeyChecking=no" redhat@$VM_IP "UPD_REF=rhel/10/$(uname -i)/edge && echo redhat | sudo -S rpm-ostree rebase -b \$UPD_REF"
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S systemctl reboot"
    sleep 20
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S ipsec --version"
    sudo virsh destroy --domain test-ostree-base-vm
    exit 0
}


function experiment_8() {
    echo "🕛 Running experiment 8: Deploying a remote OSTree with application binary and upgrade"
    generate_rpm_binary
    create_rpm_repo

    create_base_ostree_binary
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

    UPD_REF="rhel/10/$(uname -i)/edge" create_ostree_upgrade_binary
    expose_ostree_upgrade

    sudo virsh start --domain test-ostree-base-vm
    sleep 10
    VM_INTERFACE=$(sudo virsh domiflist test-ostree-base-vm | grep default | awk '{print $1}')
    VM_IP=$(sudo virsh domifaddr test-ostree-base-vm | grep vnet | awk '{print $4}' | cut -d/ -f1)
    sleep 5
    # Start capturing traffic
    python tools/monitor_iface.py $VM_INTERFACE artifacts/traffic_rebase_raw.csv &

    sleep 10
    ssh-keygen -R $VM_IP
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S ipsec --version"
    sshpass -p "redhat" ssh -o "StrictHostKeyChecking=no" redhat@$VM_IP "UPD_REF=rhel/10/$(uname -i)/edge && echo redhat | sudo -S rpm-ostree rebase -b \$UPD_REF"
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S systemctl reboot"
    sleep 20
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S ipsec --version"
    sudo virsh destroy --domain test-ostree-base-vm
    exit 0
}

function experiment_9() {
    echo "🕛 Running experiment 9: Deploying a remote OSTree with application binary and upgrade"
    generate_rpm_binary
    create_rpm_repo

    create_base_ostree_binary
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

    UPD_REF="rhel/10/$(uname -i)/edge" create_ostree_upgrade_binary_no_parent
    expose_ostree_upgrade

    sudo virsh start --domain test-ostree-base-vm
    sleep 10
    VM_INTERFACE=$(sudo virsh domiflist test-ostree-base-vm | grep default | awk '{print $1}')
    VM_IP=$(sudo virsh domifaddr test-ostree-base-vm | grep vnet | awk '{print $4}' | cut -d/ -f1)
    sleep 5
    # Start capturing traffic
    python tools/monitor_iface.py $VM_INTERFACE artifacts/traffic_rebase_raw.csv &

    sleep 10
    ssh-keygen -R $VM_IP
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S ipsec --version"
    sshpass -p "redhat" ssh -o "StrictHostKeyChecking=no" redhat@$VM_IP "UPD_REF=rhel/10/$(uname -i)/edge && echo redhat | sudo -S rpm-ostree rebase -b \$UPD_REF"
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S systemctl reboot"
    sleep 20
    sshpass -p "redhat" ssh  -o "StrictHostKeyChecking=no" redhat@$VM_IP "echo redhat | sudo -S ipsec --version"
    sudo virsh destroy --domain test-ostree-base-vm
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
    sudo rm -rf blueprints/Containerfile1
    sudo rm -rf blueprints/Containerfile2
    sudo rm -rf blueprints/local-repo-source.toml
    sudo rm -rf blueprints/local-repo.repo

    # Clean up python http server
    sudo pkill -f http.server

    # Clean up composes
    for i in $(sudo composer-cli compose list | grep -v ID | awk '{print $1}'); do sudo composer-cli compose delete $i; done
    # Clean up blueprints
    sudo composer-cli blueprints delete test-ostree
    sudo composer-cli sources delete local_repo

    # Clean up rpmbuild
    rm -rf rpmbuild
}

case $1 in
    init)
        init
        ;;
    1)
        experiment_1
        ;;
    2)
        experiment_2
        ;;
    3)
        experiment_3
        ;;
    4)
        experiment_4
        ;;
    5)
        experiment_5
        ;;
    6)
        experiment_6
        ;;
    7)
        experiment_7
        ;;
    8)
        experiment_8
        ;;
    9)
        experiment_9
        ;;
    generate-random-binary)
        generate_random_binary
        ;;
    update-incremental-random-binary)
        update_incremental_random_binary
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
    create-ostree-upgrade-no-parent)
        create_ostree_upgrade_no_parent
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
    generate-rpm-binary)
        generate_rpm_binary
        ;;
    cleanup)
        cleanup
        ;;
    *)
        usage
        exit 1
        ;;
esac

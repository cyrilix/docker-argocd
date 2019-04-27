#! /bin/bash

IMG_NAME=cyrilix/argocd
VERSION=0.12.2
MAJOR_VERSION=0.12
export DOCKER_CLI_EXPERIMENTAL=enabled
export DOCKER_USERNAME=cyrilix

GOLANG_VERSION_MULTIARCH=1.11.9-stretch

set -e

init_qemu() {
    echo "#############"
    echo "# Init qemu #"
    echo "#############"

    local qemu_url='https://github.com/multiarch/qemu-user-static/releases/download/v2.9.1-1'

    docker run --rm --privileged multiarch/qemu-user-static:register --reset

    for target_arch in aarch64 arm x86_64; do
        wget -N "${qemu_url}/x86_64_qemu-${target_arch}-static.tar.gz";
        tar -xvf "x86_64_qemu-${target_arch}-static.tar.gz";
    done
}

fetch_sources() {
    local project_name=argo-cd

    if [[ ! -d  ${project_name} ]] ;
    then
        git clone https://github.com/argoproj/${project_name}.git
    fi
    cd ${project_name}
    git reset --hard
    git checkout v${VERSION}

    go get github.com/prometheus/node_exporter
}

build_and_push_images() {
    local arch="$1"
    local dockerfile="$2"

    docker build --file "${dockerfile}" --tag "${IMG_NAME}:${arch}-latest" .
    docker tag "${IMG_NAME}:${arch}-latest" "${IMG_NAME}:${arch}-${VERSION}"
    docker tag "${IMG_NAME}:${arch}-latest" "${IMG_NAME}:${arch}-${MAJOR_VERSION}"
    docker push "${IMG_NAME}:${arch}-latest"
    docker push "${IMG_NAME}:${arch}-${VERSION}"
    docker push "${IMG_NAME}:${arch}-${MAJOR_VERSION}"
}


build_manifests() {
    docker -D manifest create "${IMG_NAME}:${VERSION}" "${IMG_NAME}:amd64-${VERSION}" "${IMG_NAME}:arm-${VERSION}" "${IMG_NAME}:arm64-${VERSION}"
    docker -D manifest annotate "${IMG_NAME}:${VERSION}" "${IMG_NAME}:arm-${VERSION}" --os=linux --arch=arm --variant=v6
    docker -D manifest annotate "${IMG_NAME}:${VERSION}" "${IMG_NAME}:arm64-${VERSION}" --os=linux --arch=arm64 --variant=v8
    docker -D manifest push "${IMG_NAME}:${VERSION}"

    docker -D manifest create "${IMG_NAME}:latest" "${IMG_NAME}:amd64-latest" "${IMG_NAME}:arm-latest" "${IMG_NAME}:arm64-latest"
    docker -D manifest annotate "${IMG_NAME}:latest" "${IMG_NAME}:arm-latest" --os=linux --arch=arm --variant=v6
    docker -D manifest annotate "${IMG_NAME}:latest" "${IMG_NAME}:arm64-latest" --os=linux --arch=arm64 --variant=v8
    docker -D manifest push "${IMG_NAME}:latest"

    docker -D manifest create "${IMG_NAME}:${MAJOR_VERSION}" "${IMG_NAME}:amd64-${MAJOR_VERSION}" "${IMG_NAME}:arm-${MAJOR_VERSION}" "${IMG_NAME}:arm64-${MAJOR_VERSION}"
    docker -D manifest annotate "${IMG_NAME}:${MAJOR_VERSION}" "${IMG_NAME}:arm-${MAJOR_VERSION}" --os=linux --arch=arm --variant=v6
    docker -D manifest annotate "${IMG_NAME}:${MAJOR_VERSION}" "${IMG_NAME}:arm64-${MAJOR_VERSION}" --os=linux --arch=arm64 --variant=v8
    docker -D manifest push "${IMG_NAME}:${MAJOR_VERSION}"
}

patch_dockerfile() {
    local dockerfile_orig=$1
    local dockerfile_dest=$2
    local docker_arch=$3
    local qemu_arch=$4
    local k8s_arch=$5

    sed "s#\(.*/kubernetes-release.*\)amd64\(.*\)#\1${k8s_arch}\2#" ${dockerfile_orig} > ${dockerfile_dest}
    sed -i "s#\(.*helm.*\)amd64\(.*\)#\1${k8s_arch}\2#" ${dockerfile_dest}
    sed -i "s#\(.*\)/tmp/linux-amd64/helm\(.*\)#\1/tmp/linux-${k8s_arch}/helm\2#" ${dockerfile_dest}

    sed -i "s#kubectl version --client#ls /usr/local/bin#" ${dockerfile_dest}
    sed -i "s#helm version --client#ls /usr/local/bin#" ${dockerfile_dest}
    sed -i "s#ks version#ls /usr/local/bin#" ${dockerfile_dest}
    sed -i "s#kustomize version#ls /usr/local/bin#" ${dockerfile_dest}
    sed -i "s#kustomize1 version#ls /usr/local/bin#" ${dockerfile_dest}

    # Fix ksonnet
    sed -i "s#RUN wget https://github.com/ksonnet/ksonnet/.*#COPY ks.${k8s_arch} /usr/local/bin/ks\nRUN \\\\#" ${dockerfile_dest}
    # Delete lines
    sed -i "/.*ks_.*_linux_amd64.*/d" ${dockerfile_dest}

    # Kustomize
    sed -i "s#.*RUN curl -L -o /usr/local/bin/kustomize1 .*#COPY kustomize1.${k8s_arch} /usr/local/bin/kustomize1\nRUN \\\\#" ${dockerfile_dest}
    sed -i "s#.*RUN curl -L -o /usr/local/bin/kustomize .*#COPY kustomize.${k8s_arch} /usr/local/bin/kustomize\nRUN \\\\#" ${dockerfile_dest}

    # aws-iam-authenticator
    sed -i "s#.*RUN curl -L -o /usr/local/bin/aws-iam-authenticator .*#COPY aws-iam-authenticator.${k8s_arch} /usr/local/bin/aws-iam-authenticator\nRUN \\\\#" ${dockerfile_dest}

    # argobase
    sed -i "s#\(FROM \)\(debian:.* as argocd-base\)\(.*\)#\1${docker_arch}/\2-${k8s_arch}\3\n\nCOPY qemu-arm-static /usr/bin/\n#" ${dockerfile_dest}
    sed -i "s#FROM argocd-base#FROM argocd-base-${k8s_arch}#" ${dockerfile_dest}

    # Go build
    sed -i "s#.*\(RUN make cli server.*\) \(&&.*\)#\1 GOARCH=${k8s_arch}\2#" ${dockerfile_dest}

}

build_ksonnet_dependencies() {
    echo "##############################"
    echo "# Build Ksonnet dependencies #"
    echo "##############################"

    export GOPATH=${PWD}/go
    echo "./go" >> .dockerignore
    mkdir -p ${GOPATH}
    SRC_DIR=${PWD}
    KSONNET_VERSION=$(grep KSONNET_VERSION= ${SRC_DIR}/argo-cd/Dockerfile | cut -f 2 -d=)
    set +e
    go get github.com/ksonnet/ksonnet
    set -e
    cd ${GOPATH}/src/github.com/ksonnet/ksonnet
    git co v${KSONNET_VERSION}
    for arch in arm arm64; do
        echo "Build ${arch} binary"
        GOARCH=${arch} make install && mv ${GOPATH}/bin/ks ${SRC_DIR}/ks.${arch}
    done
    cd ${SRC_DIR}
}
build_kustomize_dependencies() {
    echo "################################"
    echo "# Build Kustomize dependencies #"
    echo "################################"
    local github_pkg="github.com/kubernetes-sigs/kustomize"
    export GOPATH=${PWD}/go
    mkdir -p ${GOPATH}
    SRC_DIR=${PWD}
    KUSTOMIZE1_VERSION=$(grep KUSTOMIZE1_VERSION= ${SRC_DIR}/argo-cd/Dockerfile | cut -f 2 -d=)
    KUSTOMIZE_VERSION=$(grep KUSTOMIZE_VERSION= ${SRC_DIR}/argo-cd/Dockerfile | cut -f 2 -d=)
    set +e
    go get ${github_pkg}
    set -e
    cd ${GOPATH}/src/${github_pkg}
    echo "Download dep tool"
    wget https://github.com/golang/dep/releases/download/v0.5.0/dep-linux-amd64 -O dep && chmod 755 dep

    git reset --hard
    git co v${KUSTOMIZE1_VERSION}
    ./dep ensure
    echo "Fix go dependencies"
    for arch in arm arm64; do
        echo "Build ${arch} binary ${KUSTOMIZE1_VERSION}"
        GOARCH=${arch} go build && mv kustomize ${SRC_DIR}/kustomize1.${arch}
    done

    git reset --hard
    git co v${KUSTOMIZE_VERSION}
    echo "Fix go dependencies"
    ./dep ensure
    for arch in arm arm64; do
        echo "Build ${arch} binary ${KUSTOMIZE_VERSION}"
        GOARCH=${arch} go build && mv kustomize ${SRC_DIR}/kustomize.${arch}
    done
    cd ${SRC_DIR}
}
build_aws_iam_authenticator() {
    echo "############################################"
    echo "# Build aws-iam-authenticator dependencies #"
    echo "############################################"
    local github_pkg="github.com/kubernetes-sigs/aws-iam-authenticator"
    export GOPATH=${PWD}/go
    mkdir -p ${GOPATH}
    SRC_DIR=${PWD}
    AWS_IAM_AUTHENTICATOR_VERSION=$(grep  AWS_IAM_AUTHENTICATOR_VERSION= ${SRC_DIR}/argo-cd/Dockerfile | cut -f 2 -d=)
    set +e
    go get ${github_pkg}
    set -e
    cd ${GOPATH}/src/${github_pkg}
    echo "Download dep tool"
    wget https://github.com/golang/dep/releases/download/v0.5.0/dep-linux-amd64 -O dep && chmod 755 dep

    git reset --hard
    git co ${AWS_IAM_AUTHENTICATOR_VERSION}
    ./dep ensure
    echo "Fix go dependencies"
    for arch in arm arm64; do
        echo "Build ${arch} binary ${AWS_IAM_AUTHENTICATOR_VERSION}"
        GOARCH=${arch}  go build ./cmd/aws-iam-authenticator && mv aws-iam-authenticator ${SRC_DIR}/aws-iam-authenticator.${arch}
    done

    cd ${SRC_DIR}
}
fetch_sources
init_qemu

build_ksonnet_dependencies
build_kustomize_dependencies
build_aws_iam_authenticator

echo "$DOCKER_PASSWORD" | docker login -u "$DOCKER_USERNAME" --password-stdin
build_and_push_images amd64 ./Dockerfile

patch_dockerfile Dockerfile Dockerfile.arm armv7 arm arm
build_and_push_images arm ./Dockerfile.arm

patch_dockerfile Dockerfile Dockerfile.arm64 arm64v8 aarch64 arm64
build_and_push_images arm64 ./Dockerfile.arm64

build_manifests

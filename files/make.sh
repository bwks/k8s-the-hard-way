#!/bin/bash

set -e

K8S_VERSION="v1.32.3";

### Install kubectl on host machine
#
# curl -LO "https://dl.k8s.io/v1.32.3/bin/linux/amd64/kubectl"
# chmod +x kubectl
# mkdir -p ~/.local/bin
# mv ./kubectl ~/.local/bin/kubectl
#
# Optionally, add an alias k for kubectl which is a ballache to type all the time
# ~/.zshrc
# alias k='kubectl'
# source <(kubectl completion zsh)
# compdef kubectl k

### Setup ###
echo "### Setup ###";

# Ensure directories exist
mkdir -p {bins,certs,configs,ssh,units}
mkdir -p bins/{client,cni-plugins,controller,worker}

### SSH Config ###
echo "### SSH Config ###";

rm -f certs/k8s_ssh_key*

ssh-keygen -t ed25519 -f certs/k8s_ssh_key -N "" -q -C "kubernetes"

cat > ssh/k8s_ssh_config << 'EOF'
Host *
    User sherpa
    IdentityFile ~/.ssh/k8s_ssh_key
    IdentitiesOnly yes
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    PubkeyAcceptedAlgorithms +ssh-rsa
    HostkeyAlgorithms +ssh-rsa
    KexAlgorithms +diffie-hellman-group-exchange-sha1,diffie-hellman-group14-sha1
EOF

### Binaries ###
echo "### Binaries ###";

# Download Binaries (only using plain URLs)
binaries=(
"https://dl.k8s.io/${K8S_VERSION}/bin/linux/amd64/kubectl"
"https://dl.k8s.io/${K8S_VERSION}/bin/linux/amd64/kube-apiserver"
"https://dl.k8s.io/${K8S_VERSION}/bin/linux/amd64/kube-controller-manager"
"https://dl.k8s.io/${K8S_VERSION}/bin/linux/amd64/kube-scheduler"
"https://dl.k8s.io/${K8S_VERSION}/bin/linux/amd64/kube-proxy"
"https://dl.k8s.io/${K8S_VERSION}/bin/linux/amd64/kubelet"
"https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.32.0/crictl-v1.32.0-linux-amd64.tar.gz"
"https://github.com/containernetworking/plugins/releases/download/v1.6.2/cni-plugins-linux-amd64-v1.6.2.tgz"
"https://github.com/etcd-io/etcd/releases/download/v3.6.0-rc.3/etcd-v3.6.0-rc.3-linux-amd64.tar.gz"
"https://github.com/opencontainers/runc/releases/download/v1.3.0-rc.1/runc.amd64"
"https://github.com/containerd/containerd/releases/download/v2.1.0-beta.0/containerd-2.1.0-beta.0-linux-amd64.tar.gz"
"https://get.helm.sh/helm-v3.19.0-linux-amd64.tar.gz"
"https://github.com/cilium/cilium-cli/releases/download/v0.18.6/cilium-linux-amd64.tar.gz"
)

for url in "${binaries[@]}"; do
  fname="bins/$(basename "$url")";
  echo "Downloading $fname ...";
  wget -q --show-progress --https-only -O "$fname" "$url";
done

# Extract compressed files
tar -xvf bins/crictl-v1.32.0-linux-amd64.tar.gz -C bins/worker/
tar -xvf bins/cni-plugins-linux-amd64-v1.6.2.tgz -C bins/cni-plugins/
tar -xvf bins/etcd-v3.6.0-rc.3-linux-amd64.tar.gz -C bins/ \
  --strip-components 1 etcd-v3.6.0-rc.3-linux-amd64/etcdctl \
  etcd-v3.6.0-rc.3-linux-amd64/etcd
tar -xvf bins/containerd-2.1.0-beta.0-linux-amd64.tar.gz \
  --strip-components 1 \
  -C bins/worker/
tar -xvf bins/helm-v3.19.0-linux-amd64.tar.gz -C bins/client
tar -xvf bins/cilium-linux-amd64.tar.gz -C bins/client

# Move files to bins directory
mv bins/{etcdctl,kubectl} bins/client/
mv bins/{etcd,kube-apiserver,kube-controller-manager,kube-scheduler} bins/controller/
mv bins/{kubelet,kube-proxy} bins/worker/
mv bins/runc.amd64 bins/worker/runc
mv bins/client/linux-amd64/helm bins/client/helm

# Make binaries executable
chmod +x bins/{client,cni-plugins,controller,worker}/*

# Remove tar files
rm bins/*.tar.gz;
rm bins/*.tgz;
rm -rf bins/client/linux-amd64/;

### Certificates ###
echo "### Certificates ###";

openssl genrsa -out certs/ca.key 4096
openssl req -x509 -new -sha512 -noenc \
  -key certs/ca.key -days 3653 \
  -config certs/ca.conf \
  -out certs/ca.crt

certs=(
    "admin"
    "ctl01"
    "wrk01"
    "wrk02"
    "wrk03"
    "kube-proxy"
    "kube-scheduler"
    "kube-controller-manager"
    "kube-api-server"
    "service-accounts"
)

for i in ${certs[*]}; do
  openssl genrsa -out "certs/${i}.key" 4096
  openssl req -new -key "certs/${i}.key" -sha256 \
    -config "certs/ca.conf" -section ${i} \
    -out "certs/${i}.csr"
  openssl x509 -req -days 3653 -in "certs/${i}.csr" \
    -copy_extensions copyall \
    -sha256 -CA "certs/ca.crt" \
    -CAkey "certs/ca.key" \
    -CAcreateserial \
    -out "certs/${i}.crt"
done

### Configs ###
echo "### Configs ###";

# Worker Nodes
for host in wrk01 wrk02 wrk03; do
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=certs/ca.crt \
    --embed-certs=true \
    --server=https://ctl01.sherpa.lab.local:6443 \
    --kubeconfig=configs/${host}.kubeconfig

  kubectl config set-credentials system:node:${host} \
    --client-certificate=certs/${host}.crt \
    --client-key=certs/${host}.key \
    --embed-certs=true \
    --kubeconfig=configs/${host}.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:node:${host} \
    --kubeconfig=configs/${host}.kubeconfig

  kubectl config use-context default \
    --kubeconfig=configs/${host}.kubeconfig
done

# Kube Proxy
kubectl config set-cluster kubernetes-the-hard-way \
  --certificate-authority=certs/ca.crt \
  --embed-certs=true \
  --server=https://ctl01.sherpa.lab.local:6443 \
  --kubeconfig=configs/kube-proxy.kubeconfig

kubectl config set-credentials system:kube-proxy \
  --client-certificate=certs/kube-proxy.crt \
  --client-key=certs/kube-proxy.key \
  --embed-certs=true \
  --kubeconfig=configs/kube-proxy.kubeconfig

kubectl config set-context default \
  --cluster=kubernetes-the-hard-way \
  --user=system:kube-proxy \
  --kubeconfig=configs/kube-proxy.kubeconfig

kubectl config use-context default \
  --kubeconfig=configs/kube-proxy.kubeconfig

# Kube Controller
kubectl config set-cluster kubernetes-the-hard-way \
  --certificate-authority=certs/ca.crt \
  --embed-certs=true \
  --server=https://ctl01.sherpa.lab.local:6443 \
  --kubeconfig=configs/kube-controller-manager.kubeconfig

kubectl config set-credentials system:kube-controller-manager \
  --client-certificate=certs/kube-controller-manager.crt \
  --client-key=certs/kube-controller-manager.key \
  --embed-certs=true \
  --kubeconfig=configs/kube-controller-manager.kubeconfig

kubectl config set-context default \
  --cluster=kubernetes-the-hard-way \
  --user=system:kube-controller-manager \
  --kubeconfig=configs/kube-controller-manager.kubeconfig

kubectl config use-context default \
  --kubeconfig=configs/kube-controller-manager.kubeconfig

# Kube Scheduler
kubectl config set-cluster kubernetes-the-hard-way \
  --certificate-authority=certs/ca.crt \
  --embed-certs=true \
  --server=https://ctl01.sherpa.lab.local:6443 \
  --kubeconfig=configs/kube-scheduler.kubeconfig

kubectl config set-credentials system:kube-scheduler \
  --client-certificate=certs/kube-scheduler.crt \
  --client-key=certs/kube-scheduler.key \
  --embed-certs=true \
  --kubeconfig=configs/kube-scheduler.kubeconfig

kubectl config set-context default \
  --cluster=kubernetes-the-hard-way \
  --user=system:kube-scheduler \
  --kubeconfig=configs/kube-scheduler.kubeconfig

kubectl config use-context default \
  --kubeconfig=configs/kube-scheduler.kubeconfig

# Admin
kubectl config set-cluster kubernetes-the-hard-way \
  --certificate-authority=certs/ca.crt \
  --embed-certs=true \
  --server=https://ctl01.sherpa.lab.local:6443 \
  --kubeconfig=configs/admin.kubeconfig

kubectl config set-credentials admin \
  --client-certificate=certs/admin.crt \
  --client-key=certs/admin.key \
  --embed-certs=true \
  --kubeconfig=configs/admin.kubeconfig

kubectl config set-context default \
  --cluster=kubernetes-the-hard-way \
  --user=admin \
  --kubeconfig=configs/admin.kubeconfig

kubectl config use-context default \
  --kubeconfig=configs/admin.kubeconfig

### Data Encryption ###
echo "### Data Encryption ###";

export ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64);
sed -i "s|^\([[:space:]]*\)secret:.*|\1secret: $ENCRYPTION_KEY|" configs/encryption-config.yaml;

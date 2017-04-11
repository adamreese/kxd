#!/bin/bash -x

## Using new Python client would be nice, there is a lot of dancing around already
## and we will have more and more of it... Otherwise we can do it in Go.

set -o errexit
set -o pipefail
set -o nounset

readonly image_name="errordeveloper/kxd"

## TODO rootfs should be mounted read-only, this is because of CNI hack...
readonly sys_volumes=(
  /sys:/sys:rw
  /sys/fs/cgroup:/sys/fs/cgroup:rw
  /dev:/dev:rw
  /port:/port:rw
  /var/run:/var/run:rw
  /var/lib:/var/lib:rw
)

readonly kxd_volumes=(
  /opt/cni:/opt/cni:ro
  /etc/cni:/etc/cni:ro
  /etc/kubernetes:/etc/kubernetes:rw
  /var/lib/kubelet:/var/lib/kubelet:rw,rshared
  /var/log/containers:/var/log/containers:rw
)

readonly infra_label="kxd.k8s.io/infra=true"

readonly kill_list=(
  $(docker ps --all --filter "label=${infra_label}" --quiet)
  $(docker ps --all --filter "label=io.kubernetes.pod.name" --quiet)
)

test "${#kill_list}" -gt 0 && docker rm --volumes --force "${kill_list[@]}"

args=(
  --privileged --net=host --pid=host
)

for v in "${sys_volumes[@]}" ; do args+=("--volume=${v}") ; done
rootfs_vol="--volume=/:/rootfs:rw"

## TODO this will fail on the first run for numerous reasons
# - directories missing in /, so Docker for Mac will refuse mounts
# - does kubeadm reset fail miserably?
docker run "${args[@]}" "${rootfs_vol}" --rm "${image_name}:shell" "mkdir -p /rootfs/etc/kubernetes"
docker run "${args[@]}" "${rootfs_vol}" --rm "${image_name}:shell" "mkdir -p /rootfs/var/lib/kubelet"
docker run "${args[@]}" "${rootfs_vol}" --rm "${image_name}:shell" "mkdir -p /rootfs/var/log/containers"
docker run "${args[@]}" "${rootfs_vol}" --rm "${image_name}:shell" "mkdir -p /rootfs/etc/cni"
docker run "${args[@]}" "${rootfs_vol}" --rm "${image_name}:shell" "mkdir -p /rootfs/opt/cni"
docker run "${args[@]}" "${rootfs_vol}" --rm "${image_name}:shell" "cp -r /opt/cni/bin /rootfs/opt/cni"
docker run "${args[@]}" "${rootfs_vol}" --rm "${image_name}:shell" "nsenter --mount=/proc/1/ns/mnt -- mount --bind /var/lib/kubelet /var/lib/kubelet"
docker run "${args[@]}" "${rootfs_vol}" --rm "${image_name}:shell" "nsenter --mount=/proc/1/ns/mnt -- mount --make-rshared /var/lib/kubelet"

for v in "${kxd_volumes[@]}" ; do args+=("--volume=${v}") ; done
rootfs_vol="--volume=/:/rootfs:ro"

docker run "${args[@]}" "${rootfs_vol}" --rm "${image_name}:shell" "rm -r -f /var/lib/etcd && mkdir -p /var/lib/etcd"
docker run "${args[@]}" "${rootfs_vol}" --rm "${image_name}:shell" "kubeadm reset"

if [ "$#" -gt 0 ] ; then
  echo "$*" | grep -q '\--only-reset' && exit
  echo "$*" | grep -q '\--reset-only' && exit
fi

readonly labels="--label=${infra_label}"

docker run "${args[@]}" "${rootfs_vol}" --name=kxd-kubelet --detach "${labels}" "${image_name}:kubelet"

## TODO it is possible Docker for Mac VM gets a different address on eth0
readonly primary_address="192.168.65.2"
readonly localhost="127.0.0.1"

docker_exec() {
  docker exec --tty --interactive kxd-kubelet "$@"
}

docker_exec kubeadm init --skip-preflight-checks --apiserver-advertise-address="${primary_address}" --apiserver-cert-extra-sans="${localhost}" --kubernetes-version="v1.6.1"
docker_exec kubectl apply -f https://git.io/weave-kube-1.6
docker_exec kubectl taint node moby node-role.kubernetes.io/master:NoSchedule-

readonly proxy_port="6443"
readonly kubernetes_service_ip="10.96.0.1"
readonly kubernetes_service_port="443"
readonly slirp_proxy_kubernetes_service=" \
  /rootfs/usr/bin/slirp-proxy \
    -i -no-local-ip -proto tcp \
    -host-ip ${localhost} -host-port ${proxy_port} \
    -container-ip ${kubernetes_service_ip} -container-port ${kubernetes_service_port} \
"
readonly kubernetes_insecure_port="8080"
readonly slirp_proxy_kubernetes_localhost=" \
  /rootfs/usr/bin/slirp-proxy \
    -i -no-local-ip -proto tcp \
    -host-ip ${localhost} -host-port ${kubernetes_insecure_port} \
    -container-ip ${localhost} -container-port ${kubernetes_insecure_port} \
"

docker run "${args[@]}" "${rootfs_vol}" --name=kxd-api-proxy --detach "${labels}" \
  --volume="/lib/ld-musl-x86_64.so.1:/lib/ld-musl-x86_64.so.1:ro" \
  --volume="/lib/libc.musl-x86_64.so.1:/lib/libc.musl-x86_64.so.1:ro" \
  "${image_name}:shell" "${slirp_proxy_kubernetes_service}"

docker run "${args[@]}" "${rootfs_vol}" --name=kxd-api-proxy-insecure --detach "${labels}" \
  --volume="/lib/ld-musl-x86_64.so.1:/lib/ld-musl-x86_64.so.1:ro" \
  --volume="/lib/libc.musl-x86_64.so.1:/lib/libc.musl-x86_64.so.1:ro" \
  "${image_name}:shell" "${slirp_proxy_kubernetes_localhost}"

docker cp kxd-kubelet:/etc/kubernetes/admin.conf kubeconfig
export KUBECONFIG=kubeconfig
kubectl config set-cluster kubernetes --server="https://${localhost}:${proxy_port}"
kubectl get nodes

# k8s_gateway

A CoreDNS plugin that is very similar to [k8s_external](https://coredns.io/plugins/k8s_external/) but supporting all types of Kubernetes external resources - Ingress, Service of type LoadBalancer, HTTPRoutes, TLSRoutes, GRPCRoutes from the [Gateway API project](https://gateway-api.sigs.k8s.io/).

This plugin relies on its own connection to the k8s API server and doesn't share any code with the existing [kubernetes](https://coredns.io/plugins/kubernetes/) plugin. The assumption is that this plugin can now be deployed as a separate instance (alongside the internal kube-dns) and act as a single external DNS interface into your Kubernetes cluster(s).

## Description

`k8s_gateway` resolves Kubernetes resources with their external IP addresses based on zones specified in the configuration. This plugin will resolve the following type of resources:

| Kind | Matching Against | External IPs are from | 
| ---- | ---------------- | -------- |
| HTTPRoute<sup>[1](#foot1)</sup> | all FQDNs from `spec.hostnames` matching configured zones | `gateway.status.addresses`<sup>[2](#foot2)</sup> |
| TLSRoute<sup>[1](#foot1) | all FQDNs from `spec.hostnames` matching configured zones | `gateway.status.addresses`<sup>[2](#foot2)</sup> |
| GRPCRoute<sup>[1](#foot1) | all FQDNs from `spec.hostnames` matching configured zones | `gateway.status.addresses`<sup>[2](#foot2)</sup> |
| Ingress | all FQDNs from `spec.rules[*].host` matching configured zones | `.status.loadBalancer.ingress` |
| Service<sup>[3](#foot3)</sup> | `name.namespace` + any of the configured zones OR any string consisting of lower case alphanumeric characters, '-' or '.', specified in the `coredns.io/hostname` or `external-dns.alpha.kubernetes.io/hostname` annotations (see [this](https://github.com/ori-edge/k8s_gateway/blob/master/test/service-annotation.yml#L8) for an example) | `.status.loadBalancer.ingress` |
| VirtualServer<sup>[4](#foot4)</sup> | `spec.host` | `.status.externalEnpoints.ip` |


<a name="f1">1</a>: Currently supported version of GatewayAPI CRDs is v1.0.0+ experimental channel.</br>
<a name="f2">2</a>: Gateway is a separate resource specified in the `spec.parentRefs` of HTTPRoute|TLSRoute|GRPCRoute.</br>
<a name="f3">3</a>: Only resolves service of type LoadBalancer</br>
<a name="f4">4</a>: Currently supported version of [nginxinc kubernetes-ingress](https://github.com/nginxinc/kubernetes-ingress) is 1.12.3</br>

Currently only supports A-type queries, all other queries result in NODATA responses.

This plugin is **NOT** supposed to be used for intra-cluster DNS resolution and does not contain the default upstream [kubernetes](https://coredns.io/plugins/kubernetes/) plugin.

## Install

The recommended installation method is using the helm chart provided in the repo:

```
helm repo add k8s_gateway https://ori-edge.github.io/k8s_gateway/
helm install exdns --set domain=foo k8s_gateway/k8s-gateway
```

Alternatively, for labbing and testing purposes `k8s_gateway` can be deployed with a single manifest:

```
kubectl apply -f https://raw.githubusercontent.com/ori-edge/k8s_gateway/master/examples/install-clusterwide.yml
```

## Configure

The only required configuration option is the zone that plugin should be authoritative for:

```
k8s_gateway ZONE 
```

Additional configuration options can be used to further customize the behaviour of a plugin:

```
{
k8s_gateway ZONE 
    resources [RESOURCES...]
    ttl TTL
    apex APEX
    secondary SECONDARY
    kubeconfig KUBECONFIG [CONTEXT]
    fallthrough [ZONES...]
}
```


* `resources` a subset of supported Kubernetes resources to watch. By default all supported resources are monitored. Available options are `[ Ingress | Service | HTTPRoute | TLSRoute | GRPCRoute | VirtualServer ]`.
* `ttl` can be used to override the default TTL value of 60 seconds.
* `apex` can be used to override the default apex record value of `{ReleaseName}-k8s-gateway.{Namespace}`
* `secondary` can be used to specify the optional apex record value of a peer nameserver running in the cluster (see `Dual Nameserver Deployment` section below).
* `kubeconfig` can be used to connect to a remote Kubernetes cluster using a kubeconfig file. `CONTEXT` is optional, if not set, then the current context specified in kubeconfig will be used. It supports TLS, username and password, or token-based authentication.
* `fallthrough` if zone matches and no record can be generated, pass request to the next plugin. If **[ZONES...]** is omitted, then fallthrough happens for all zones for which the plugin is authoritative. If specific zones are listed (for example `in-addr.arpa` and `ip6.arpa`), then only queries for those zones will be subject to fallthrough.

Example: 

```
k8s_gateway example.com {
    resources Ingress
    ttl 30
    apex exdns-1-k8s-gateway.kube-system
    secondary exdns-2-k8s-gateway.kube-system
    kubeconfig /.kube/config
}
```

## Dual Nameserver Deployment

Most of the time, deploying a single `k8s_gateway` instance is enough to satisfy most popular DNS resolvers. However, some of the stricter resolvers expect a zone to be available on at least two servers (RFC1034, section 4.1). In order to satisfy this requirement, a pair of `k8s_gateway` instances need to be deployed, each with its own unique loadBalancer IP. This way the zone NS record will point to a pair of glue records, hard-coded to these IPs. 

Another consideration is that in this case `k8s_gateway` instances need to know about their peers in order to provide consistent responses (at least the same set of nameservers). Configuration-wise this would require the following:

1. Two separate `k8s_gateway` deployments with two separate `type: LoadBalancer` services in front of them.
2. No apex override, which would default to `releaseName.namespace`
3. A peer nameserver's apex must be included in `secondary` configuration option
4. Glue records must match the `releaseName.namespace.zone` of each of the running plugin

For example, the above requirements could be satisfied with the following commands:

1. Install two instances of `k8s_plugin` gateway pointing at each other:
```
helm install -n kube-system exdns-1 --set domain=zone.example.com --set secondary=exdns-2.kube-system ./charts/k8s-gateway
helm install -n kube-system exdns-2 --set domain=zone.example.com --set secondary=exdns-1.kube-system ./charts/k8s-gateway
```

2. Obtain their external IPs

```
kubectl -n kube-system get svc -l app.kubernetes.io/name=k8s-gateway
NAME                  TYPE           CLUSTER-IP       EXTERNAL-IP   PORT(S)        AGE
exdns-1-k8s-gateway   LoadBalancer   10.103.229.129   198.51.100.1  53:32122/UDP   5m22s
exdns-2-k8s-gateway   LoadBalancer   10.107.87.145    203.0.113.11 53:30009/UDP   4m21s

```

3. Delegate the domain from the parent zone by creating a pair of NS records and a pair of glue records pointing to the above IPs:

```
zone.example.com (NS record) -> exdns-1-k8s-gateway.zone.example.com (A record) -> 198.51.100.1
zone.example.com (NS record) -> exdns-2-k8s-gateway.zone.example.com (A record) -> 203.0.113.11
```


## Build

### With compile-time configuration file

```
$ git clone https://github.com/coredns/coredns
$ cd coredns
$ vim plugin.cfg
# Replace lines with kubernetes and k8s_external with k8s_gateway:github.com/ori-edge/k8s_gateway
$ go generate
$ go build
$ ./coredns -plugins | grep k8s_gateway
```

### With external golang source code
```
$ git clone https://github.com/ori-edge/k8s_gateway.git
$ cd k8s_gateway
$ go build cmd/coredns.go
$ ./coredns -plugins | grep k8s_external
```

For more details refer to [this CoreDNS doc](https://coredns.io/2017/07/25/compile-time-enabling-or-disabling-plugins/)


## Release

### Helm Charts 

If the change was made only to helm charts, only two things are required:

* Bump the chart version in `./charts/k8s-gateway/Chart.yaml`
* Run `make helm-update`

### Plugin

To cut a new plugin release the following is required:

* Bump the app `pluginVersion` in `./cmd/coredns.go` and commit.
* Tag the last commit with the save version number.
* Bump the `appVersion` and `tag` in `./charts/k8s-gateway/Chart.yaml` and `./charts/k8s-gateway/values.yaml` respectively.
* Run `make helm-update`

## Hack

This repository contains a [Tiltfile](https://tilt.dev/) that can be used for local development. To build a local k8s cluster with kind run:

```
make setup
```

To bring up a tilt development enviornment run `tilt up` or:

```
make up
```

Some test resources can be added to the k8s cluster with:

```
# ingress and service resources
kubectl apply -f ./test/ingress-services.yml

# gateway API resources
kubectl apply -f ./test/gateway-api/resources.yml

# nginxinc's VirtualService  resources
kubectl apply -f test/nginxinc-kubernetes-ingress/resources.yaml
```

Test queries can be sent to the exposed CoreDNS service like this:

```
$ ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}')

# ingress resource
$ dig @$ip -p 32553 myservicea.foo.org +short
198.51.100.0

# loadBalancer
$ dig @$ip -p 32553 test.default.foo.org +short
198.51.100.3

# HTTPRoute/gateway-API
$ dig @$ip -p 32553 myservicea.gw.foo.org +short
198.51.100.4
$ dig @$ip -p 32553 myserviceb.gw.foo.org +short
198.51.100.4

# multi-gateway HTTPRoute
$ dig @$ip -p 32553 myserviced.gw.foo.org +short
198.51.100.5
198.51.100.4

# nginxinc's Ingress
$ dig @$ip -p 32553 myserviceb.foo.org +short
198.51.100.2

# nginxinc's VirtualServer
$ dig @$ip -p 32553 virtualservera.foo.org +short
198.51.100.2
```

To cleanup local environment do:

```
make nuke
```

## Apple Silicon Development

Developing with apple silicon requires lima/colima installed on your machine. It sadly, did not work at all with kind.
Below, you'll find the `yaml` used for developing with Cilium CNI and k3s.

Colima version at the time: [v0.5.6](https://github.com/abiosoft/colima/releases/tag/v0.5.6)

```yaml
cpu: 6
disk: 60
memory: 16
arch: host
runtime: containerd
kubernetes:
  enabled: true
  version: v1.28.2+k3s1
  k3sArgs:
    - --flannel-backend=none
    - --disable=servicelb
    - --disable=traefik
    - --disable-network-policy
    - --disable-kube-proxy
autoActivate: true
network:
  address: false
  dns: []
  dnsHosts:
    host.docker.internal: host.lima.internal
  driver: slirp
forwardAgent: false
docker:
  insecure-registries:
    - localhost:5000
    - host.docker.internal:5000
vmType: vz
rosetta: true
mountType: virtiofs
mountInotify: false
cpuType: host
layer: false
provision:
  - mode: system
    script: |
      set -e

      # needed for cilium
      mount bpffs -t bpf /sys/fs/bpf
      mount --make-shared /sys/fs/bpf

      mkdir -p /run/cilium/cgroupv2
      mount -t cgroup2 none /run/cilium/cgroupv2
      mount --make-shared /run/cilium/cgroupv2/
      ln -s /opt/cni/bin/cilium-cni /usr/libexec/cni/cilium-cni
sshConfig: true
mounts: []
env: {}
cgroupsV2: false
```

### Steps

1. In `Tiltfile.nerdctl`
2. `colima start` with above configuration
3. `tilt up -f Tiltfile.nerdctl` + space bar for the environment to trigger.

The stacks should deploy and you'll have a proper stack that builds `k8s-gateway` with `coredns` and deploys to `kube-system` namespace.

## Also see

[Blogpost](https://medium.com/from-the-edge/a-self-hosted-external-dns-resolver-for-kubernetes-111a27d6fc2c)  
[Helm repo guide](https://medium.com/@mattiaperi/create-a-public-helm-chart-repository-with-github-pages-49b180dbb417)

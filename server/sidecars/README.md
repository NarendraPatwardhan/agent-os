# AgentOS sidecar runners

AgentOS owns sidecar identity, grants, leases, cancellation, cleanup, and fork behavior in its core
server package. A runner is an operator-installed execution backend. The reference backend uses a
jailed Firecracker microVM and communicates with a generated, versioned runner protocol over vsock.

The ordinary `agent_os_package` contains the portable Elixir lifecycle and provider code. It does not
silently install privileged binaries or add a large machine-specific VM payload. Build the reference
runner bundle separately:

```sh
bazel build //server/sidecars:firecracker_runner_bundle
```

The resulting tar contains the pinned Firecracker and jailer binaries, pinned Linux kernel, the health
and browser runner initramfs images, root helper, and a configuration template. The health runner is the
small KVM conformance probe. The browser runner is a complete Chromium + Bun environment implementing
the generated browser contract over the same lifecycle and runner envelope. OCI conversion strips all
setuid and setgid bits; browser processes cannot regain root through general-purpose base-image tools.

## Host installation

Firecracker runners require Linux with KVM and cgroup v2. Installation is deliberately an operator
action because it creates a narrow setuid boundary.

1. Create a dedicated unprivileged runner account and group. Set their numeric IDs in
   `/etc/agent-os/sidecar-helper.conf`.
2. Create `/var/lib/agent-os/jailer` as a root-owned directory that is not writable by group or other
   users.
3. Install Firecracker, jailer, the kernel, and runner initramfs at the absolute root-owned paths in
   the configuration. Executables must not be group/other writable.
4. Install the configuration as root-owned and mode `0644` or stricter.
5. Install `agentos-sidecar-helper` as root-owned mode `4755`. The helper accepts only fixed lifecycle
   verbs and validated AgentOS sidecar IDs; the BEAM cannot supply commands or artifact paths.
6. If any configured runner kind enables network egress, set `uplink` to the host interface those
   sidecars may use and initialize the dedicated nftables table once after install:

   ```sh
   /path/to/agentos-sidecar-helper network-host-init
   ```

7. Verify KVM, cgroup, ownership, and artifact permissions as the runner account:

   ```sh
   /path/to/agentos-sidecar-helper sys-test
   ```

Every jailed runner receives its own network namespace. Network-enabled runners additionally receive a
TAP and owned veth route; the dedicated nftables table permits public IPv4 traffic through `uplink`,
with NAT at both isolation boundaries. Host, loopback, link-local, private, carrier-grade NAT,
documentation, multicast, and reserved destinations are denied, including cloud metadata ranges. The
table also denies special-purpose destinations from the IANA registry, traffic from runner interfaces
to host input, and installs no inbound route. Interface
ownership is tied to the full sidecar ID so a hash or address collision fails creation instead of
cleaning up another runner's network. Runners without the network option do not depend on that table and
receive no guest NIC.

## Server wiring

Configure the provider when adding `AgentOS.Supervisor` to the consuming OTP application:

```elixir
{AgentOS.Supervisor,
 sidecars: [
   max_firecracker_instances: 64,
   providers: [
     {AgentOS.Sidecars.Providers.Firecracker,
      helper: "/usr/local/libexec/agentos-sidecar-helper",
      browser_runner: true}
   ]
 ]}
```

Production launch defaults to the jailed helper. Direct Firecracker launch is rejected unless both
`launch: :direct` and `development: true` are explicit; it is only for local KVM conformance.

The host application remains responsible for authentication, tenancy, quotas, scheduling, and mapping
its HTTP or WebSocket edge onto `AgentOS.Sidecars`. Guests receive only grant names and the reserved
binary `mc.sidecar` binding. Provider references, helper paths, endpoints, and credentials never enter
guest memory.

Run the real reference vertical on a KVM host with:

```sh
bazel test //server:kvm_test
bazel test //server:browser_kvm_test
```

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

The resulting tar contains the pinned Firecracker and jailer binaries, pinned Linux kernel, static
health runner initramfs, root helper, and a configuration template. The health runner exists for KVM
conformance testing; a real sidecar kind supplies a runner initramfs implementing that kind's generated
contract while retaining the same host lifecycle and runner envelope.

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
6. Initialize the dedicated nftables table once after install or network-policy changes:

   ```sh
   /path/to/agentos-sidecar-helper network-host-init
   ```

7. Verify KVM, cgroup, ownership, and artifact permissions as the runner account:

   ```sh
   /path/to/agentos-sidecar-helper sys-test
   ```

The sample network policy is fail-closed: the runner namespace receives a TAP device but no external
route. Kind-specific outbound networking should be installed by an operator-owned policy component,
not accepted from a VM request.

## Server wiring

Configure the provider when adding `AgentOS.Supervisor` to the consuming OTP application:

```elixir
{AgentOS.Supervisor,
 sidecars: [
   max_firecracker_instances: 64,
   providers: [
     {AgentOS.Sidecars.Providers.Firecracker,
      helper: "/usr/local/libexec/agentos-sidecar-helper",
      capability: my_generated_sidecar_capability}
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
```

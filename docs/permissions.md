# Permissions and policy

AgentOS begins without ambient network, credentials, host directories, or application callbacks.
Capabilities are installed explicitly by the embedder.

## Filesystem permission

`permissions.fs` accepts:

```js
"allow";
"deny";
{
  allow: ["read"];
}
{
  allow: ["read", "write"];
}
```

This policy applies to guest-spawned work such as an internal agent. The host control surface remains
the trusted operator, so `vm.fs.write()` can stage inputs for a read-only guest.

Filesystem permissions are distinct from image tiers and mount-level `readOnly`. Effective authority
is the intersection of all relevant restrictions.

## Network permission

`permissions.network` accepts:

```js
"allow";
"deny";
{
  allow: ["api.example.com", "objects.example.com"];
}
```

Behavior:

- `deny` disables network even if `net: true`.
- `allow` enables unrestricted host-routed network.
- an allowlist object enables network and allows listed hosts without prompting;
- an empty or omitted `allow` list prompts for every host;
- connections implicitly require the network bridge.

The allowlist contains host names, not arbitrary URL prefixes.

## Permission callback

```js
const vm = await mc.create({
  net: true,
  permissions: { network: { allow: ["api.example.com"] } },
  async onPermission(request) {
    if (request.kind === "network") {
      console.log(request.host, request.url);
      request.reject("host not approved");
      return;
    }

    console.log(request.connection, request.method, request.origin);
    request.allow({ remember: "once" });
  },
});
```

Every request must be resolved exactly once with `allow()` or `reject()`. If the callback throws or no
callback exists, prompted operations fail closed.

### Network request

| Field                  | Meaning                            |
| ---------------------- | ---------------------------------- |
| `id`                   | Host-generated request id          |
| `kind`                 | `"network"`                        |
| `host`                 | Requested hostname                 |
| `url`                  | Requested URL                      |
| `allow({ remember? })` | Permit once or for the session     |
| `reject(message?)`     | Deny with an optional host message |

### Tool-approval request

| Field        | Meaning                            |
| ------------ | ---------------------------------- |
| `id`         | Host-generated request id          |
| `kind`       | `"tool_approval"`                  |
| `connection` | Resolved connection ref            |
| `method`     | Actual outgoing HTTP method        |
| `url`        | Actual outgoing URL                |
| `origin`     | Credential recipient origin        |
| `argsDigest` | Optional digest of arguments/facts |

These facts are computed from the actual outgoing request. They are not trusted catalog prose
supplied by the guest.

## Connection policy rules

```js
const policies = [
  { owner: "org", pattern: "github.org.main.*", action: "require_approval" },
  { owner: "user", pattern: "github.*", action: "block" },
];
```

| Field     | Values                                 |
| --------- | -------------------------------------- |
| `owner`   | `org`, `user`                          |
| `pattern` | connection or coarser prefix           |
| `action`  | `approve`, `require_approval`, `block` |

Policy is connection-granular because credential splicing knows the connection, method, URL, and
origin—not the catalog tool address. Valid patterns include:

- `integration.owner.connection.*`
- `integration.owner.*`
- `integration.*`
- `*`

A per-tool pattern is rejected during construction rather than silently pretending to enforce a
boundary the host cannot observe.

Across owners, the most restrictive matching action wins. Within one owner's rules, the first match
wins. If no rule matches, method classification decides whether an operation is destructive and needs
approval.

## Remembering approval

`allow({ remember: "once" })` permits only the pending operation. `"session"` remembers the decision
for the host's matching session key. Session memory is host state, not guest state, and should not be
treated as a durable policy database.

## Failure behavior

A denied network or connection operation becomes an ordinary guest network/I/O error. It must never
trap the host or expose a credential in the error. Host applications should record the permission event
and their decision if they need an audit trail.

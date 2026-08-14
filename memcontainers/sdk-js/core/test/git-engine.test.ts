import assert from "node:assert/strict";
import { GitEngine, MemoryDurable, gitHostCallHandler } from "../src/git/index.js";

const durable = new MemoryDurable("adapter-runtime");
const identity = { name: "SDK Test", email: "sdk@example.invalid" };
const engine = await GitEngine.load({ durable, identity });
assert.match(engine.version(), /agentos-gitz-v1/);

const mount = engine.asMountDriver();
await mount.write!("nested/hello.txt", new TextEncoder().encode("hello from sdk\n"));
assert.equal(new TextDecoder().decode(await mount.open("nested/hello.txt")), "hello from sdk\n");
assert.equal((await mount.stat("nested/hello.txt")).kind, "file");
assert.deepEqual(await mount.readdir("nested"), [{ name: "hello.txt", kind: "file" }]);
await assert.rejects(
  () => mount.open("nested/missing.txt"),
  (error: unknown) => (error as { code?: string }).code === "ENOENT",
  "generated path errors must survive the Wasm and mount adapters",
);

assert.equal((await engine.run({ op: "status" })).ok, true);
assert.equal((await engine.run({ op: "add", args: { paths: ["nested/hello.txt"] } })).ok, true);
const committed = await engine.run({
  op: "commit",
  args: { message: "typed SDK adapter", unix_seconds: 1_700_000_000 },
});
assert.equal(committed.ok, true);
assert.match(committed.stdout ?? "", /^[0-9a-f]{40}\n$/);
const head = await engine.run({ op: "rev-parse", args: { rev: "HEAD" } });
assert.equal(head.stdout, committed.stdout);

const log = await engine.run({ op: "log" });
assert.equal(log.ok, true, log.stderr ?? "");
assert.match(log.stdout ?? "", /typed SDK adapter/);
const checkout = await engine.run({
  op: "checkout",
  args: { rev: "HEAD" },
});
assert.equal(checkout.ok, true, checkout.stderr ?? "");
await mount.write!("topic.txt", new TextEncoder().encode("on topic\n"));
assert.equal((await engine.run({ op: "add", args: { paths: ["topic.txt"] } })).ok, true);
const staged = await engine.run({ op: "diff", args: { cached: true } });
assert.equal(staged.ok, true, staged.stderr ?? "");
assert.match(staged.stdout ?? "", /topic\.txt/);
const second = await engine.run({
  op: "commit",
  args: { message: "topic commit", unix_seconds: 1_700_000_001 },
});
assert.equal(second.ok, true);
assert.match(second.stdout ?? "", /^[0-9a-f]{40}\n$/);

assert.equal((await engine.run({ op: "branch", args: { name: "browser-branch" } })).ok, true);
assert.equal(
  (await engine.run({ op: "branch", args: { name: "browser-branch", delete: true } })).ok,
  true,
);
assert.equal((await engine.run({ op: "tag", args: { name: "browser-tag" } })).ok, true);
assert.equal(
  (await engine.run({ op: "tag", args: { name: "browser-tag", delete: true } })).ok,
  true,
);
assert.equal(
  (
    await engine.run({
      op: "remote",
      args: { action: "add", name: "artifact-peer", url: "https://example.invalid/repo.git" },
    })
  ).ok,
  true,
);
assert.equal(
  (await engine.run({ op: "remote", args: { action: "get", name: "artifact-peer" } })).stdout,
  "https://example.invalid/repo.git",
);
assert.equal(
  (await engine.run({ op: "remote", args: { action: "list" } })).stdout,
  "artifact-peer\thttps://example.invalid/repo.git\n",
);
assert.equal(
  (
    await engine.run({
      op: "remote",
      args: { action: "remove", name: "artifact-peer" },
    })
  ).ok,
  true,
);
assert.equal(
  (
    await engine.run({
      op: "config",
      args: { action: "set", key: "user.name", value: "Browser User" },
    })
  ).ok,
  true,
);
assert.equal(
  (
    await engine.run({
      op: "config",
      args: { action: "set", key: "user.email", value: "browser@example.invalid" },
    })
  ).ok,
  true,
);
assert.equal(
  (await engine.run({ op: "config", args: { action: "get", key: "user.name" } })).stdout,
  "Browser User",
);
assert.equal(
  (await engine.run({ op: "config", args: { action: "list" } })).stdout,
  "user.name=Browser User\nuser.email=browser@example.invalid\n",
);
assert.equal(
  (
    await engine.run({
      op: "config",
      args: { action: "set", key: "core.hooksPath", value: "/tmp/hooks" },
    })
  ).ok,
  false,
);
assert.equal(
  (
    await engine.run({
      op: "config",
      args: { action: "remove", key: "user.email" },
    })
  ).ok,
  true,
);
assert.equal(
  (await engine.run({ op: "config", args: { action: "list" } })).stdout,
  "user.name=Browser User\n",
);
for (const mode of ["soft", "mixed", "hard", "merge"] as const) {
  assert.equal((await engine.run({ op: "reset", args: { mode, rev: "HEAD" } })).ok, true);
}
assert.equal((await engine.run({ op: "reset", args: { mode: "invalid", rev: "HEAD" } })).ok, false);

const hostCall = gitHostCallHandler({
  engines: new Map([["/workspace/repo", engine]]),
  defaultMount: "/workspace/repo",
});
const hostStatus = JSON.parse(
  await hostCall(
    JSON.stringify({
      op: "status",
      args: { mount: "/workspace/repo" },
    }),
  ),
);
assert.equal(hostStatus.ok, true, "local host calls must dispatch to engine.run");
const missingMount = JSON.parse(
  await hostCall(
    JSON.stringify({
      op: "status",
      args: { mount: "/missing" },
    }),
  ),
);
assert.equal(missingMount.ok, false, "host calls must preserve mount selection");
await engine.close();

const reopened = await GitEngine.load({ durable, identity });
assert.equal(
  new TextDecoder().decode(await reopened.asMountDriver().open("nested/hello.txt")),
  "hello from sdk\n",
);
assert.equal(
  (await reopened.run({ op: "rev-parse", args: { rev: "HEAD" } })).stdout,
  second.stdout,
);
await reopened.close();

console.log("git wasm SDK adapter: ok");

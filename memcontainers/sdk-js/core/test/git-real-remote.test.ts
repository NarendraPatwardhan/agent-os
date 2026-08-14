import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawn, spawnSync } from "node:child_process";
import { GitEngine, GitRemoteEffectPump } from "../src/git/index.js";
import { ACTION_GET, OP_OBJECT, decodeObjectResult, encodeObjectRequest } from "@mc/contracts/git";

const root = mkdtempSync(join(tmpdir(), "agentos-gitz-peer-"));
const remote = join(root, "repo.git");
const upstream = join(root, "upstream");
const subRemote = join(root, "sub.git");
const subUpstream = join(root, "sub-upstream");

function git(cwd: string, args: string[]): string {
  const result = spawnSync("git", args, {
    cwd,
    encoding: "utf8",
    env: {
      ...process.env,
      GIT_AUTHOR_NAME: "Peer Test",
      GIT_AUTHOR_EMAIL: "peer@example.invalid",
      GIT_COMMITTER_NAME: "Peer Test",
      GIT_COMMITTER_EMAIL: "peer@example.invalid",
    },
  });
  if (result.status !== 0) throw new Error(`git ${args.join(" ")} failed: ${result.stderr}`);
  return result.stdout.trim();
}

try {
  git(root, ["init", "--bare", "--initial-branch=main", subRemote]);
  git(root, ["init", "--initial-branch=main", subUpstream]);
  writeFileSync(join(subUpstream, "SUBMODULE"), "nested wasm\n");
  git(subUpstream, ["add", "SUBMODULE"]);
  git(subUpstream, ["commit", "-m", "submodule initial"]);
  git(subUpstream, ["remote", "add", "origin", subRemote]);
  git(subUpstream, ["push", "origin", "refs/heads/main:refs/heads/main"]);
  const subTip = git(subUpstream, ["rev-parse", "HEAD"]);

  git(root, ["init", "--bare", "--initial-branch=main", remote]);
  git(root, ["init", "--initial-branch=main", upstream]);
  writeFileSync(join(upstream, "README.md"), "initial\n");
  writeFileSync(
    join(upstream, ".gitmodules"),
    '[submodule "deps/lib"]\n\tpath = deps/lib\n\turl = ../sub.git\n',
  );
  git(upstream, ["add", "README.md", ".gitmodules"]);
  git(upstream, ["update-index", "--add", "--cacheinfo", `160000,${subTip},deps/lib`]);
  git(upstream, ["commit", "-m", "initial"]);
  git(upstream, ["remote", "add", "origin", remote]);
  git(upstream, ["push", "origin", "refs/heads/main:refs/heads/main"]);
  git(root, ["--git-dir", remote, "config", "http.receivepack", "true"]);

  const server = createServer(async (request, response) => {
    const url = new URL(request.url ?? "/", "http://127.0.0.1");
    const body: Uint8Array[] = [];
    for await (const chunk of request) body.push(Uint8Array.from(chunk as Uint8Array));
    const child = spawn("git", ["http-backend"], {
      env: {
        ...process.env,
        GIT_PROJECT_ROOT: root,
        GIT_HTTP_EXPORT_ALL: "1",
        PATH_INFO: url.pathname,
        QUERY_STRING: url.search.slice(1),
        REQUEST_METHOD: request.method ?? "GET",
        CONTENT_TYPE: request.headers["content-type"] ?? "",
        CONTENT_LENGTH: String(body.reduce((size, chunk) => size + chunk.byteLength, 0)),
        SERVER_PROTOCOL: "HTTP/1.1",
        SERVER_NAME: "127.0.0.1",
        REMOTE_ADDR: "127.0.0.1",
      },
      stdio: ["pipe", "pipe", "pipe"],
    });
    for (const chunk of body) child.stdin.write(chunk);
    child.stdin.end();
    const stdout: Uint8Array[] = [];
    const stderr: Uint8Array[] = [];
    child.stdout.on("data", (chunk: Uint8Array) => stdout.push(Uint8Array.from(chunk)));
    child.stderr.on("data", (chunk: Uint8Array) => stderr.push(Uint8Array.from(chunk)));
    child.on("error", (error) => {
      response.destroy(error);
    });
    child.on("close", (code) => {
      if (code !== 0) {
        response.statusCode = 500;
        response.end(new TextDecoder().decode(joinBytes(stderr)));
        return;
      }
      const raw = joinBytes(stdout);
      const boundary = findHeaderBoundary(raw);
      if (boundary < 0) {
        response.statusCode = 500;
        response.end("invalid CGI response");
        return;
      }
      const headerText = new TextDecoder().decode(raw.subarray(0, boundary));
      for (const line of headerText.split(/\r?\n/)) {
        const colon = line.indexOf(":");
        if (colon < 1) continue;
        const name = line.slice(0, colon).trim();
        const value = line.slice(colon + 1).trim();
        if (name.toLowerCase() === "status") response.statusCode = Number.parseInt(value, 10);
        else response.setHeader(name, value);
      }
      response.end(raw.subarray(boundary + (raw[boundary] === 13 ? 4 : 2)));
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  assert.ok(address && typeof address === "object");
  const origin = `http://127.0.0.1:${address.port}`;
  const url = `${origin}/repo.git`;

  try {
    const engine = await GitEngine.load({
      identity: { name: "Wasm Test", email: "wasm@example.invalid" },
    });
    try {
      const pump = new GitRemoteEffectPump(engine, { allowOrigins: [origin] });
      assert.equal((await pump.handle({ op: "clone", args: { url } })).ok, true);
      assert.equal(new TextDecoder().decode(await engine.fileRead("README.md")), "initial\n");
      const initialHead = (
        await engine.run({ op: "rev-parse", args: { rev: "HEAD" } })
      ).stdout?.trim();
      assert.equal(initialHead, git(root, ["--git-dir", remote, "rev-parse", "refs/heads/main"]));

      const listed = await engine.run({ op: "submodule", args: { action: "list" } });
      assert.equal(listed.ok, true, JSON.stringify(listed));
      assert.equal(listed.stdout, `-${subTip} deps/lib\n`);
      const updatedSubmodule = await pump.handle({
        op: "submodule",
        args: { action: "update", path: "deps/lib" },
      });
      assert.equal(updatedSubmodule.ok, true, JSON.stringify(updatedSubmodule));
      assert.equal(
        new TextDecoder().decode(await engine.fileRead("deps/lib/SUBMODULE")),
        "nested wasm\n",
      );
      const submoduleStatus = await engine.run({ op: "submodule", args: { action: "status" } });
      assert.equal(submoduleStatus.ok, true);
      assert.equal(submoduleStatus.stdout, ` ${subTip} deps/lib\n`);
      const cleanAfterSubmodule = await engine.run({ op: "status" });
      assert.equal(cleanAfterSubmodule.ok, true, JSON.stringify(cleanAfterSubmodule));
      assert.equal(cleanAfterSubmodule.stdout, "");

      assert.equal((await pump.handle({ op: "push", args: { url, refspecs: [] } })).ok, false);
      assert.equal(
        (await pump.handle({ op: "push", args: { url, refspecs: ["refs/heads/main"] } })).ok,
        false,
      );
      assert.equal(
        (
          await pump.handle({
            op: "push",
            args: { url, refspecs: ["refs/heads/main:refs/heads/other:refs/heads/main"] },
          })
        ).ok,
        false,
      );

      await engine.fileWrite("browser.txt", new TextEncoder().encode("from wasm\n"));
      assert.equal((await engine.run({ op: "add", args: { paths: ["browser.txt"] } })).ok, true);
      const commit = await engine.run({
        op: "commit",
        args: { message: "browser", unix_seconds: 1_700_000_001 },
      });
      assert.equal(commit.ok, true);
      const pushed = await pump.handle({
        op: "push",
        args: { url, refspecs: ["refs/heads/main:refs/heads/main"] },
      });
      assert.equal(pushed.ok, true);
      assert.equal(
        git(root, ["--git-dir", remote, "rev-parse", "refs/heads/main"]),
        commit.stdout?.trim(),
      );

      const fresh = await GitEngine.load({});
      try {
        const freshPump = new GitRemoteEffectPump(fresh, { allowOrigins: [origin] });
        assert.equal((await freshPump.handle({ op: "clone", args: { url, depth: 1 } })).ok, true);
        assert.equal(new TextDecoder().decode(await fresh.fileRead("browser.txt")), "from wasm\n");
      } finally {
        await fresh.close();
      }

      git(upstream, ["pull", "--ff-only", "origin", "main"]);
      writeFileSync(join(upstream, "README.md"), "upstream changed\n");
      git(upstream, ["add", "README.md"]);
      git(upstream, ["commit", "-m", "upstream change"]);
      git(upstream, ["push", "origin", "refs/heads/main:refs/heads/main"]);
      const upstreamTip = git(upstream, ["rev-parse", "HEAD"]);
      assert.equal(
        (await engine.run({ op: "rev-parse", args: { rev: "HEAD" } })).stdout?.trim(),
        commit.stdout?.trim(),
      );
      assert.equal(git(upstream, ["show", "-s", "--format=%P", "HEAD"]), commit.stdout?.trim());
      assert.equal((await pump.handle({ op: "fetch", args: { url } })).ok, true);
      assert.equal(
        (await engine.run({ op: "rev-parse", args: { rev: "HEAD" } })).stdout?.trim(),
        commit.stdout?.trim(),
      );
      assert.equal(
        (
          await engine.run({ op: "rev-parse", args: { rev: "refs/remotes/origin/main" } })
        ).stdout?.trim(),
        upstreamTip,
      );
      const importedCommit = await engine.run({ op: "show", args: { rev: upstreamTip } });
      assert.equal(importedCommit.ok, true, JSON.stringify(importedCommit));
      const rawCommit = decodeObjectResult(
        engine.bridge.execute(
          OP_OBJECT,
          Uint8Array.from(
            encodeObjectRequest({
              action: ACTION_GET,
              kind: 1,
              object_id: { algorithm: 1, bytes: hexBytes(upstreamTip) },
            }),
          ),
        ).payload,
      );
      assert.ok(rawCommit.data);
      assert.match(
        new TextDecoder().decode(Uint8Array.from(rawCommit.data)),
        new RegExp(`parent ${commit.stdout?.trim()}`),
      );
      await engine.fileWrite("README.md", new TextEncoder().encode("dirty local\n"));
      const rejectedPull = await pump.handle({ op: "pull", args: { url } });
      assert.equal(rejectedPull.ok, false);
      assert.equal(new TextDecoder().decode(await engine.fileRead("README.md")), "dirty local\n");
      assert.equal(
        (await engine.run({ op: "reset", args: { mode: "hard", rev: "HEAD" } })).ok,
        true,
      );
      const resetHead = await engine.run({ op: "rev-parse", args: { rev: "HEAD" } });
      assert.equal(resetHead.stdout?.trim(), commit.stdout?.trim(), JSON.stringify(resetHead));
      const resetStatus = await engine.run({ op: "status" });
      assert.equal(resetStatus.stdout, "", JSON.stringify(resetStatus));
      assert.equal(
        (
          await engine.run({ op: "rev-parse", args: { rev: "refs/remotes/origin/main" } })
        ).stdout?.trim(),
        upstreamTip,
      );
      const recoveredPull = await pump.handle({ op: "pull", args: { url } });
      assert.equal(recoveredPull.ok, true, JSON.stringify(recoveredPull));
      assert.equal(
        new TextDecoder().decode(await engine.fileRead("README.md")),
        "upstream changed\n",
      );
    } finally {
      await engine.close();
    }
  } finally {
    await new Promise<void>((resolve, reject) =>
      server.close((error) => (error ? reject(error) : resolve())),
    );
  }
} finally {
  rmSync(root, { recursive: true, force: true });
}

function joinBytes(chunks: Uint8Array[]): Uint8Array {
  const output = new Uint8Array(chunks.reduce((size, chunk) => size + chunk.byteLength, 0));
  let offset = 0;
  for (const chunk of chunks) {
    output.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return output;
}

function findHeaderBoundary(bytes: Uint8Array): number {
  for (let i = 0; i + 3 < bytes.length; i++) {
    if (bytes[i] === 13 && bytes[i + 1] === 10 && bytes[i + 2] === 13 && bytes[i + 3] === 10)
      return i;
  }
  for (let i = 0; i + 1 < bytes.length; i++) if (bytes[i] === 10 && bytes[i + 1] === 10) return i;
  return -1;
}

function hexBytes(hex: string): Uint8Array {
  assert.match(hex, /^[0-9a-f]{40}$/);
  return Uint8Array.from({ length: hex.length / 2 }, (_, index) =>
    Number.parseInt(hex.slice(index * 2, index * 2 + 2), 16),
  );
}

console.log("git real remote artifact acceptance: ok");

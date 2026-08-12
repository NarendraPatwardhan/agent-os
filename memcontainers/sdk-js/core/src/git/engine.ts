/** Public browser Git engine backed by the freestanding Gitz Wasm module. */

import type { Driver } from "../types.js";
import {
  ACTION_CREATE,
  ACTION_DELETE,
  ACTION_GET,
  ACTION_LIST,
  ACTION_UPDATE,
  MOUNT_CREATE,
  MOUNT_READ,
  MOUNT_READDIR,
  MOUNT_REMOVE,
  MOUNT_RENAME,
  MOUNT_STAT,
  MOUNT_WRITE,
  OP_ADD,
  OP_BRANCH,
  OP_CHECKOUT,
  OP_CHECKPOINT,
  OP_COMMIT,
  OP_CONFIG,
  OP_DIFF,
  OP_ENGINE_DESCRIBE,
  OP_FILE_READ,
  OP_FILE_READDIR,
  OP_FILE_REMOVE,
  OP_FILE_RENAME,
  OP_FILE_STAT,
  OP_FILE_WRITE,
  OP_IGNORE_QUERY,
  OP_LOG,
  OP_MOUNT,
  OP_REMOTE_METADATA,
  OP_REMOVE,
  OP_REPOSITORY_INIT,
  OP_REPOSITORY_OPEN,
  OP_RESET,
  OP_RESOLVE_REVISION,
  OP_SHOW,
  OP_STATUS,
  OP_SUBMODULE,
  OP_TAG,
  RESET_HARD,
  RESET_MERGE,
  RESET_MIXED,
  RESET_SOFT,
  decodeDirectoryResult,
  decodeFileResult,
  decodeResult,
  decodeSnapshotResult,
  decodeStatusResult,
  decodeSubmoduleResult,
  encodeFileRequest,
  encodeMountRequest,
  encodePorcelainRequest,
  encodeSubmoduleRequest,
  type DirectoryResult,
  type FileResult,
  type PorcelainRequest,
  type Signature,
} from "@mc/contracts/git";
import { GitBridge } from "./bridge.js";
import type { DurableBackend } from "./durable.js";
import { createGitFsDriver } from "./gitfs.js";
import type { GitEngineLoadOptions, GitIdentity, GitRequest, GitResponse } from "./types.js";

const REMOTE_OPS = new Set(["clone", "fetch", "pull", "push"]);
const text = new TextDecoder();

function identity(value: GitIdentity | undefined): GitIdentity | undefined {
  const name = value?.name?.trim();
  const email = value?.email?.trim();
  return name && email ? { name, email } : undefined;
}

function signature(value: GitIdentity, args: Record<string, unknown>): Signature {
  const seconds = numberArg(args, "unix_seconds", "when_unix") ?? Math.floor(Date.now() / 1000);
  return {
    name: value.name,
    email: value.email,
    unix_seconds: seconds,
    timezone_minutes: numberArg(args, "timezone_minutes") ?? 0,
  };
}

function numberArg(args: Record<string, unknown>, ...keys: string[]): number | undefined {
  for (const key of keys) {
    const value = args[key];
    if (typeof value === "number" && Number.isFinite(value)) return Math.trunc(value);
  }
  return undefined;
}

function stringArg(args: Record<string, unknown>, ...keys: string[]): string | undefined {
  for (const key of keys) if (typeof args[key] === "string") return String(args[key]);
  return undefined;
}

function pathsArg(args: Record<string, unknown>): Record<string, string> {
  if (args.all === true) return { ".": "" };
  const value = args.paths ?? args.path;
  const values = Array.isArray(value) ? value : typeof value === "string" ? [value] : [];
  return Object.fromEntries(values.map((path) => [String(path), ""]));
}

function requiredStringArg(args: Record<string, unknown>, ...keys: string[]): string {
  const value = stringArg(args, ...keys)?.trim();
  if (!value) throw new Error(`missing ${keys[0]}`);
  return value;
}

function namedAction(value: unknown): number {
  switch (value) {
    case "list": return ACTION_LIST;
    case "get": return ACTION_GET;
    case "add": return ACTION_CREATE;
    case "set": return ACTION_UPDATE;
    case "remove": return ACTION_DELETE;
    default: throw new Error("invalid Git metadata action");
  }
}

function resetAction(value: unknown): number {
  switch (value ?? "mixed") {
    case "soft": return RESET_SOFT;
    case "mixed": return RESET_MIXED;
    case "hard": return RESET_HARD;
    case "merge": return RESET_MERGE;
    default: throw new Error("invalid Git reset mode");
  }
}

function porcelain(args: Record<string, unknown>, id?: GitIdentity): PorcelainRequest {
  const authorName = stringArg(args, "name", "author_name") ?? id?.name;
  const authorEmail = stringArg(args, "email", "author_email") ?? id?.email;
  const committerName = stringArg(args, "committer_name") ?? authorName;
  const committerEmail = stringArg(args, "committer_email") ?? authorEmail;
  const author = authorName && authorEmail ? signature({ name: authorName, email: authorEmail }, args) : undefined;
  const committer = committerName && committerEmail
    ? signature({ name: committerName, email: committerEmail }, args)
    : undefined;
  return {
    action: ACTION_GET,
    flags: numberArg(args, "flags") ?? 0,
    revision: stringArg(args, "revision", "rev", "name"),
    target: stringArg(args, "target", "new_name", "value"),
    message: stringArg(args, "message"),
    paths: pathsArg(args),
    limit: numberArg(args, "limit", "max_count"),
    author,
    committer,
  };
}

export class GitEngine {
  private snapshot: Uint8Array | null = null;
  private readonly identity: GitIdentity | undefined;
  private constructor(
    readonly bridge: GitBridge,
    readonly readOnly: boolean,
    private readonly durable: DurableBackend | undefined,
    identityValue: GitIdentity | undefined,
  ) {
    this.identity = identity(identityValue);
  }

  static async load(opts: GitEngineLoadOptions): Promise<GitEngine> {
    const durable = opts.durable;
    const restore = durable ? (await durable.load()) ?? undefined : undefined;
    const { resolveGitEngineWasm } = await import("../artifacts.js");
    const bridge = await GitBridge.create(await resolveGitEngineWasm(opts.engine), {
      workRoot: opts.workRoot,
      readOnly: !!opts.readOnly,
      restore: restore ? owned(restore) : undefined,
    });
    const engine = new GitEngine(bridge, !!opts.readOnly, durable, opts.identity);
    engine.snapshot = restore?.slice() ?? null;
    try {
      bridge.execute(restore ? OP_REPOSITORY_OPEN : OP_REPOSITORY_INIT);
      return engine;
    } catch (error) {
      bridge.close();
      throw error;
    }
  }

  get durableSnapshot(): Uint8Array | null { return this.snapshot?.slice() ?? null; }
  async checkpoint(): Promise<void> {
    if (!this.durable) return;
    await this.bridge.serial(async () => {
      const result = decodeSnapshotResult(owned(this.bridge.execute(OP_CHECKPOINT).payload));
      this.snapshot = result.image.slice();
      await this.durable!.save(this.snapshot);
    });
  }

  async run(request: GitRequest): Promise<GitResponse> {
    return this.bridge.serial(() => {
      const op = String(request.op ?? "").toLowerCase();
      if (REMOTE_OPS.has(op)) return failure("remotes require the host HTTP effect pump");
      const args = request.args && typeof request.args === "object" && !Array.isArray(request.args)
        ? request.args as Record<string, unknown>
        : {};
      try {
        switch (op) {
          case "init":
            this.bridge.execute(OP_REPOSITORY_INIT);
            return success();
          case "status": {
            const result = decodeStatusResult(owned(this.bridge.execute(OP_STATUS).payload));
            const stdout = result.entries.map((entry) =>
              `${String.fromCharCode(entry.index)}${String.fromCharCode(entry.worktree)} ${entry.path}\n`,
            ).join("");
            return success(stdout, result);
          }
          case "add":
            return resultResponse(owned(this.bridge.execute(OP_ADD, owned(encodePorcelainRequest({
              ...porcelain(args), action: ACTION_UPDATE,
            }))).payload));
          case "rm":
          case "remove":
            return resultResponse(owned(this.bridge.execute(OP_REMOVE, owned(encodePorcelainRequest({
              ...porcelain(args), action: ACTION_UPDATE,
            }))).payload));
          case "commit": {
            const result = this.bridge.commit(OP_COMMIT, {
              ...porcelain(args, this.identity), action: ACTION_CREATE,
            });
            return success(`${objectIdHex(result.object_id.bytes)}\n`, result);
          }
          case "rev-parse":
          case "resolve": {
            const result = this.bridge.resolve(OP_RESOLVE_REVISION, {
              ...porcelain(args),
              action: ACTION_GET,
              revision: stringArg(args, "rev", "revision") ?? "HEAD",
            });
            return success(`${objectIdHex(result.object_id.bytes)}\n`, result);
          }
          case "log": return rawPorcelainRequest(this.bridge, OP_LOG, {
            ...porcelain(args), action: ACTION_LIST, limit: numberArg(args, "max_count", "limit"),
          });
          case "diff": return rawPorcelainRequest(this.bridge, OP_DIFF, {
            ...porcelain(args), action: ACTION_GET, flags: args.cached === true ? 1 : 0,
          });
          case "show": return rawPorcelainRequest(this.bridge, OP_SHOW, {
            ...porcelain(args), action: ACTION_GET,
            revision: stringArg(args, "rev", "revision") ?? "HEAD",
          });
          case "checkout":
          case "switch": {
            const name = stringArg(args, "name");
            const rev = stringArg(args, "rev", "revision");
            if (!name && !rev) throw new Error("missing name");
            return rawPorcelainRequest(this.bridge, OP_CHECKOUT, {
              ...porcelain(args),
              action: ACTION_UPDATE,
              target: name,
              revision: rev,
            });
          }
          case "reset": return rawPorcelainRequest(this.bridge, OP_RESET, {
            ...porcelain(args),
            action: resetAction(args.mode),
            revision: stringArg(args, "rev", "revision") ?? "HEAD",
          });
          case "branch": return rawPorcelainRequest(this.bridge, OP_BRANCH, {
            ...porcelain(args),
            action: stringArg(args, "name") ? (args.delete === true ? ACTION_DELETE : ACTION_CREATE) : ACTION_LIST,
            target: stringArg(args, "name"),
            revision: stringArg(args, "rev", "revision"),
          });
          case "tag": return rawPorcelainRequest(this.bridge, OP_TAG, {
            ...porcelain(args),
            action: args.delete === true ? ACTION_DELETE : ACTION_CREATE,
            target: requiredStringArg(args, "name"),
            revision: stringArg(args, "rev", "revision"),
          });
          case "config": return rawPorcelainRequest(this.bridge, OP_CONFIG, {
            ...porcelain(args),
            action: namedAction(args.action),
            target: stringArg(args, "key", "name"),
            message: stringArg(args, "value"),
          });
          case "remote": return rawPorcelainRequest(this.bridge, OP_REMOTE_METADATA, {
            ...porcelain(args),
            action: namedAction(args.action),
            target: stringArg(args, "name"),
            message: stringArg(args, "url", "value"),
            revision: stringArg(args, "fetch", "refspec", "rev"),
          });
          case "check-ignore": return rawPorcelainRequest(this.bridge, OP_IGNORE_QUERY, {
            ...porcelain(args), action: ACTION_GET,
            paths: { [requiredStringArg(args, "path")]: "" },
          });
          case "submodule": {
            const action = stringArg(args, "action") ?? "list";
            if (action === "update") return failure("submodule update requires the host HTTP effect pump");
            if (action !== "list" && action !== "status") return failure("unsupported submodule action");
            const result = decodeSubmoduleResult(owned(this.bridge.execute(OP_SUBMODULE,
              owned(encodeSubmoduleRequest({
                action: action === "list" ? ACTION_LIST : ACTION_GET,
                path: stringArg(args, "path"),
              }))).payload));
            return success(submoduleText(result.entries), result);
          }
          default: return failure(`unsupported Git operation: ${op}`);
        }
      } catch (error) {
        return failure(error instanceof Error ? error.message : String(error));
      }
    });
  }

  async fileStat(path: string): Promise<FileResult> {
    return this.bridge.serial(() => decodeFileResult(owned(this.bridge.execute(OP_FILE_STAT,
      owned(encodeFileRequest({ path }))).payload)));
  }

  async fileRead(path: string): Promise<Uint8Array> {
    return this.bridge.serial(() => {
      const result = decodeFileResult(owned(this.bridge.execute(OP_FILE_READ,
        owned(encodeFileRequest({ path }))).payload));
      if (!result.data) return new Uint8Array();
      return result.data.slice();
    });
  }

  async fileWrite(path: string, data: Uint8Array, mode?: number): Promise<void> {
    await this.bridge.serial(() => this.bridge.execute(OP_FILE_WRITE,
      owned(encodeFileRequest({ path, data: owned(data), mode }))));
  }

  async fileRemove(path: string): Promise<void> {
    await this.bridge.serial(() => this.bridge.execute(OP_FILE_REMOVE,
      owned(encodeFileRequest({ path }))));
  }

  async fileRename(from: string, to: string): Promise<void> {
    await this.bridge.serial(() => this.bridge.execute(OP_FILE_RENAME,
      owned(encodeFileRequest({ path: from, other_path: to }))));
  }

  async fileReadDir(path: string): Promise<DirectoryResult> {
    return this.bridge.serial(() => decodeDirectoryResult(owned(this.bridge.execute(OP_FILE_READDIR,
      owned(encodeFileRequest({ path }))).payload)));
  }

  async mountStat(path: string): Promise<FileResult> {
    return this.bridge.serial(() => decodeFileResult(owned(this.bridge.execute(OP_MOUNT,
      owned(encodeMountRequest({ action: MOUNT_STAT, path, flags: 0 }))).payload)));
  }

  async mountRead(path: string): Promise<Uint8Array> {
    return this.bridge.serial(() => decodeFileResult(owned(this.bridge.execute(OP_MOUNT,
      owned(encodeMountRequest({ action: MOUNT_READ, path, flags: 0 }))).payload)).data?.slice() ?? new Uint8Array());
  }

  async mountReadDir(path: string): Promise<DirectoryResult> {
    return this.bridge.serial(() => decodeDirectoryResult(owned(this.bridge.execute(OP_MOUNT,
      owned(encodeMountRequest({ action: MOUNT_READDIR, path, flags: 0 }))).payload)));
  }

  async mountWrite(path: string, data: Uint8Array): Promise<void> {
    await this.bridge.serial(() => this.bridge.execute(OP_MOUNT,
      owned(encodeMountRequest({ action: MOUNT_WRITE, path, flags: 0, data: owned(data) }))));
  }

  async mountMkdir(path: string): Promise<void> {
    await this.bridge.serial(() => this.bridge.execute(OP_MOUNT,
      owned(encodeMountRequest({ action: MOUNT_CREATE, path, flags: 1, mode: 0o040000, data: new Uint8Array() }))));
  }

  async mountRemove(path: string): Promise<void> {
    await this.bridge.serial(() => this.bridge.execute(OP_MOUNT,
      owned(encodeMountRequest({ action: MOUNT_REMOVE, path, flags: 0 }))));
  }

  async mountRename(from: string, to: string): Promise<void> {
    await this.bridge.serial(() => this.bridge.execute(OP_MOUNT,
      owned(encodeMountRequest({ action: MOUNT_RENAME, path: from, other_path: to, flags: 0 }))));
  }

  asMountDriver(): Driver {
    return createGitFsDriver(this, { readOnly: this.readOnly });
  }

  version(): string {
    const description = this.bridge.describe(OP_ENGINE_DESCRIBE);
    return `${description.build_id} (${description.gitz_commit})`;
  }

  async close(): Promise<void> {
    try { await this.checkpoint(); } finally { this.bridge.close(); }
  }
}

function rawPorcelainRequest(bridge: GitBridge, opcode: number, request: PorcelainRequest): GitResponse {
  const payload = owned(bridge.execute(opcode, owned(encodePorcelainRequest(request))).payload);
  try {
    const result = decodeResult(payload);
    return success(result.data ? text.decode(result.data) : "", result);
  } catch {
    return success(text.decode(payload));
  }
}

function resultResponse(payload: Uint8Array): GitResponse {
  const result = decodeResult(payload);
  return success("", result);
}

function objectIdHex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function submoduleText(entries: Array<{ path: string; gitlink?: { bytes: Uint8Array } | null; head?: { bytes: Uint8Array } | null }>): string {
  return entries.map((entry) => {
    const oid = entry.gitlink ? objectIdHex(entry.gitlink.bytes) : "-".repeat(40);
    const prefix = entry.head && entry.gitlink && objectIdHex(entry.head.bytes) === oid ? " " : "-";
    return `${prefix}${oid} ${entry.path}\n`;
  }).join("");
}

function owned(bytes: Uint8Array): Uint8Array<ArrayBuffer> { return Uint8Array.from(bytes); }

function success(stdout = "", result?: unknown): GitResponse {
  return { ok: true, code: 0, stdout, stderr: "", result };
}

function failure(stderr: string): GitResponse {
  return { ok: false, code: 1, stdout: "", stderr: `${stderr.replace(/\n?$/, "\n")}` };
}

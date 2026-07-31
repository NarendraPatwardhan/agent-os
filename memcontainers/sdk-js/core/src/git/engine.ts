/**
 * SDK GitEngine — single-writer via GitBridge.serial + optional gitfs driver.
 * Local Run only; remotes go through host_call `"git"` + GitRemoteOrchestrator.
 */

import type { Driver } from "../types.js";
import { GitBridge } from "./bridge.js";
import {
  decodeDurableBlob,
  encodeDurableBlob,
  type DecodedDurableBlob,
  type DurableBackend,
  type DurableRefTip,
} from "./durable.js";
import { createGitFsDriver } from "./gitfs.js";
import type {
  GitEngineLoadOptions,
  GitIdentity,
  GitRequest,
  GitResponse,
} from "./types.js";

const REMOTE_OPS = new Set(["clone", "fetch", "pull", "push"]);
const OID_RE = /^[0-9a-f]{40}$/i;

function normalizeIdentity(
  id: GitIdentity | undefined,
): GitIdentity | undefined {
  if (!id) return undefined;
  const name = typeof id.name === "string" ? id.name.trim() : "";
  const email = typeof id.email === "string" ? id.email.trim() : "";
  if (!name || !email) return undefined;
  return { name, email };
}

export class GitEngine {
  private readonly durable: DurableBackend | undefined;
  /** Last durable snapshot bytes (AGIT envelope when produced by checkpoint). */
  private _durableSnapshot: Uint8Array | null = null;
  /** Default cone prefixes for asMountDriver (cone-only, not full sparse parity). */
  private readonly sparseCone: string[] | undefined;
  /** Host policy identity for commit inject (K28). */
  private readonly identity: GitIdentity | undefined;

  constructor(
    readonly bridge: GitBridge,
    readonly readOnly = false,
    durable?: DurableBackend,
    sparseCone?: string[],
    identity?: GitIdentity,
  ) {
    this.durable = durable;
    this.sparseCone = sparseCone?.length ? sparseCone : undefined;
    this.identity = normalizeIdentity(identity);
  }

  static async load(opts: GitEngineLoadOptions): Promise<GitEngine> {
    const bridge = await GitBridge.create(opts.baseUrl, {
      workRoot: opts.workRoot,
    });
    const engine = new GitEngine(
      bridge,
      !!opts.readOnly,
      opts.durable,
      opts.sparseCone,
      opts.gitIdentity,
    );
    if (opts.durable) {
      const snap = await opts.durable.load();
      if (snap && snap.byteLength > 0) {
        engine._durableSnapshot = snap.slice();
        const decoded = decodeDurableBlob(snap);
        if (decoded) {
          await engine.rebindFromEnvelope(decoded);
        }
        // Non-AGIT legacy opaque: attach engine-level only (no MEMFS rebind).
      }
    }
    return engine;
  }

  /**
   * Last durable snapshot bytes (AGIT envelope when produced by
   * {@link checkpoint} / {@link close}). Copy returned.
   */
  get durableSnapshot(): Uint8Array | null {
    return this._durableSnapshot ? this._durableSnapshot.slice() : null;
  }

  /**
   * Persist durable state. With no `snapshot` arg, serializes the live repo
   * (pack of local tips + refs + HEAD) as an AGIT envelope. Explicit `snapshot`
   * overrides (advanced/tests) and is saved as-is without re-export.
   */
  async checkpoint(snapshot?: Uint8Array): Promise<void> {
    if (!this.durable) return;
    const data =
      snapshot !== undefined
        ? snapshot
        : await this.exportDurableSnapshot();
    const copy = data.slice();
    await this.durable.save(copy);
    this._durableSnapshot = copy;
  }

  /** Function face: Run({op,args}) → Response. */
  async run(req: GitRequest): Promise<GitResponse> {
    return this.bridge.serial(() => {
      const op = String(req.op || "").toLowerCase();
      if (REMOTE_OPS.has(op)) {
        return {
          ok: false,
          code: 1,
          stdout: "",
          stderr:
            "remotes require host_call git + orchestrator (PR9–PR10); engine must not dial\n",
        };
      }
      return this.bridge.run(this.injectCommitIdentity(req));
    });
  }

  /**
   * K28: when host identity is configured and commit args omit name/email,
   * inject them. Never invents a default identity when unset.
   */
  private injectCommitIdentity(req: GitRequest): GitRequest {
    if (!this.identity) return req;
    const op = String(req.op || "").toLowerCase();
    if (op !== "commit") return req;
    const base =
      req.args && typeof req.args === "object" && !Array.isArray(req.args)
        ? { ...(req.args as Record<string, unknown>) }
        : {};
    const name =
      typeof base.name === "string" && base.name.trim()
        ? base.name
        : this.identity.name;
    const email =
      typeof base.email === "string" && base.email.trim()
        ? base.email
        : this.identity.email;
    return { ...req, args: { ...base, name, email } };
  }

  async importPack(
    chunk: Uint8Array,
    meta: { final?: boolean } = {},
  ): Promise<void> {
    return this.bridge.serial(() => {
      this.bridge.importPack(chunk, !!meta.final);
    });
  }

  /**
   * Build a push pack (objects reachable from tip OIDs) via engine packbuilder.
   * Optional `haves` are remote tip OIDs already present (lease oldHash) — objects
   * reachable only from them are omitted (R48 thin-pack / have negotiation).
   * Empty oids fail closed. Result always starts with PACK magic.
   */
  async buildPushPack(oids: string[], haves?: string[]): Promise<Uint8Array> {
    return this.bridge.serial(() => this.bridge.packBuild(oids, haves));
  }

  /**
   * MountFs driver (worktree + ctl). Coherence: close write then status via open.
   * `sparseCone` overrides load-time default; cone-only projection (not full
   * sparse-checkout parity).
   */
  asMountDriver(opts?: { sparseCone?: string[] }): Driver {
    return createGitFsDriver(this.bridge, {
      readOnly: this.readOnly,
      sparseCone: opts?.sparseCone ?? this.sparseCone,
    });
  }

  version(): string {
    return this.bridge.version();
  }

  async close(): Promise<void> {
    // Export real pack+refs when durable is attached (same path as checkpoint).
    if (this.durable) {
      try {
        const snap = await this.exportDurableSnapshot();
        await this.durable.save(snap);
        this._durableSnapshot = snap;
      } catch {
        // Fall back to last known good snapshot if live export fails
        // (e.g. unborn HEAD / no commits yet).
        if (this._durableSnapshot) {
          await this.durable.save(this._durableSnapshot);
        }
      }
    }
    this.bridge.close();
  }

  /**
   * Serialize live repo as AGIT envelope: all tip OIDs in a pack + refs + HEAD.
   * Uses pack+refs (ODB-correct), not a MEMFS path dump.
   */
  private async exportDurableSnapshot(): Promise<Uint8Array> {
    return this.bridge.serial(() => {
      const tips = this.listTipsSync();
      if (!tips.length) {
        throw new Error(
          "durable export: no refs to serialize (unborn or empty repo)",
        );
      }
      const oids = [
        ...new Set(
          tips
            .map((t) => t.hash)
            .filter((h) => typeof h === "string" && OID_RE.test(h)),
        ),
      ];
      if (!oids.length) {
        throw new Error("durable export: no tip oids");
      }
      const pack = this.bridge.packBuild(oids);
      const head = this.readHeadNameSync(tips);
      return encodeDurableBlob({ v: 1, refs: tips, head }, pack);
    });
  }

  /** Rebind a fresh engine from a decoded AGIT envelope (init → pack → refs → checkout). */
  private async rebindFromEnvelope(
    decoded: DecodedDurableBlob,
  ): Promise<void> {
    const { meta, pack } = decoded;
    return this.bridge.serial(() => {
      const init = this.bridge.run({ op: "init" });
      if (!init.ok) {
        throw new Error(
          `durable rebind init failed: ${String(init.stderr || init.stdout || "")}`,
        );
      }
      if (pack.byteLength > 0) {
        this.bridge.importPack(pack, true);
      }
      if (meta.refs.length > 0) {
        const imp = this.bridge.run({
          op: "refs.import",
          args: { refs: meta.refs },
        });
        if (!imp.ok) {
          throw new Error(
            `durable rebind refs.import failed: ${String(imp.stderr || imp.stdout || "")}`,
          );
        }
      }
      const head = meta.head || "refs/heads/main";
      const apply = this.bridge.run({
        op: "clone.apply",
        args: { head },
      });
      if (!apply.ok) {
        throw new Error(
          `durable rebind clone.apply failed: ${String(apply.stderr || apply.stdout || "")}`,
        );
      }
    });
  }

  /** Sync tips list (must run inside bridge.serial). */
  private listTipsSync(): DurableRefTip[] {
    const tipsResp = this.bridge.run({ op: "tips" });
    if (!tipsResp.ok || tipsResp.result == null) return [];
    let tips = tipsResp.result as DurableRefTip[] | string;
    if (typeof tips === "string") {
      try {
        tips = JSON.parse(tips) as DurableRefTip[];
      } catch {
        return [];
      }
    }
    if (!Array.isArray(tips)) return [];
    const out: DurableRefTip[] = [];
    for (const t of tips) {
      if (
        t &&
        typeof t.name === "string" &&
        t.name &&
        typeof t.hash === "string" &&
        OID_RE.test(t.hash)
      ) {
        out.push({ name: t.name, hash: t.hash.toLowerCase() });
      }
    }
    return out;
  }

  /** Read symbolic HEAD name; fallback to first heads tip or main. */
  private readHeadNameSync(tips: DurableRefTip[]): string {
    try {
      const path = `${this.bridge.workRoot}/.git/HEAD`;
      const raw = this.bridge.FS.readFile(path, { encoding: "utf8" });
      const text =
        typeof raw === "string" ? raw : new TextDecoder().decode(raw);
      const m = text.trim().match(/^ref:\s*(\S+)/);
      if (m?.[1]) return m[1];
    } catch {
      /* missing HEAD */
    }
    const headTip = tips.find((t) => t.name.startsWith("refs/heads/"));
    return headTip?.name ?? "refs/heads/main";
  }
}

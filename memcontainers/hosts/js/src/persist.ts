import {
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
  renameSync,
  rmSync,
  readdirSync,
} from "node:fs";
import { join } from "node:path";
import {
  PERSIST_OP_DELETE,
  PERSIST_OP_GET,
  PERSIST_OP_LIST,
  PERSIST_OP_PUT,
  ReadyPersist,
  compareBytes,
  encodeKeyList,
  getAbsentBody,
  getPresentBody,
  hexDecode,
  hexEncode,
  startsWith,
} from "./persist_core.js";

export * from "./persist_core.js";

/** A directory-backed key/value store (mirrors Rust `DiskPersist`). */
export class DiskPersist extends ReadyPersist {
  constructor(private readonly dir: string) {
    super();
    mkdirSync(dir, { recursive: true });
  }

  protected run(op: number, key: Uint8Array, value: Uint8Array): Uint8Array {
    switch (op) {
      case PERSIST_OP_GET:
        return this.getBody(key);
      case PERSIST_OP_PUT:
        this.putValue(key, value);
        return new Uint8Array(0);
      case PERSIST_OP_DELETE:
        this.deleteValue(key);
        return new Uint8Array(0);
      case PERSIST_OP_LIST:
        return this.listBody(key);
      default:
        throw new Error(`unknown persist op ${op}`);
    }
  }

  private pathFor(key: Uint8Array): string {
    return join(this.dir, hexEncode(key));
  }

  private getBody(key: Uint8Array): Uint8Array {
    const path = this.pathFor(key);
    if (!existsSync(path)) return getAbsentBody();
    return getPresentBody(new Uint8Array(readFileSync(path)));
  }

  private putValue(key: Uint8Array, val: Uint8Array): void {
    const tmp = this.pathFor(key) + ".tmp";
    try {
      writeFileSync(tmp, val);
      renameSync(tmp, this.pathFor(key));
    } catch (e) {
      try {
        rmSync(tmp, { force: true });
      } catch {
        /* best effort */
      }
      throw e;
    }
  }

  private deleteValue(key: Uint8Array): void {
    rmSync(this.pathFor(key), { force: true });
  }

  private listBody(prefix: Uint8Array): Uint8Array {
    const keys: Uint8Array[] = [];
    for (const name of readdirSync(this.dir)) {
      if (name.endsWith(".tmp")) continue;
      const key = hexDecode(name);
      if (key && startsWith(key, prefix)) keys.push(key);
    }
    keys.sort(compareBytes);
    return encodeKeyList(keys);
  }
}

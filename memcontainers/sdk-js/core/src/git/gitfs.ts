/** Thin VM mount relay. Path, sparse, symlink, and metadata semantics live in Zig. */

import type { Driver, DriverEntry, DriverError, DriverMeta } from "../types.js";
import {
  ERROR_CODE_DENIED,
  ERROR_CODE_EXISTS,
  ERROR_CODE_INVALID,
  ERROR_CODE_IS_DIRECTORY,
  ERROR_CODE_MISSING,
  ERROR_CODE_NOT_DIRECTORY,
  ERROR_CODE_NOT_EMPTY,
  ERROR_PATH,
} from "@mc/contracts/git";
import type { GitEngine } from "./engine.js";

export const GITFS_DRIVER_KIND = Symbol.for("agentos.gitfs");

export interface GitFsDriverOptions {
  readOnly?: boolean;
}

export function isGitFsDriver(driver: unknown): boolean {
  return !!driver && typeof driver === "object" &&
    (driver as { [GITFS_DRIVER_KIND]?: boolean })[GITFS_DRIVER_KIND] === true;
}

export function createGitFsDriver(engine: GitEngine, opts: GitFsDriverOptions = {}): Driver {
  const readOnly = !!opts.readOnly;
  const driver: Driver = {
    readOnly,

    async open(path: string): Promise<Uint8Array> {
      try {
        return await engine.mountRead(path);
      } catch (error) {
        throw driverError(error, path);
      }
    },

    async stat(path: string): Promise<DriverMeta> {
      try {
        // The kernel's MountFs stats the mount point as the empty relative path.
        // The Git engine path policy rejects "" / "." (and readDir already maps
        // those to the worktree root via validateDirectory). Treat the mount
        // root as a directory without asking the engine for a reserved path.
        if (isMountRoot(path)) {
          return { kind: "dir", size: 0 };
        }
        const result = await engine.mountStat(path);
        return {
          kind: isDirectoryMode(result.mode) ? "dir" : "file",
          size: safeSize(result.size_low, result.size_high),
        };
      } catch (error) {
        throw driverError(error, path);
      }
    },

    async readdir(path: string): Promise<DriverEntry[]> {
      try {
        const result = await engine.mountReadDir(path);
        return result.entries.map((entry) => ({
          name: entry.name,
          kind: isDirectoryMode(entry.mode) ? "dir" as const : "file" as const,
        }));
      } catch (error) {
        throw driverError(error, path);
      }
    },

    async write(path: string, data: Uint8Array): Promise<void> {
      if (readOnly) throw readonlyError();
      try {
        await engine.mountWrite(path, data);
      } catch (error) {
        throw driverError(error, path);
      }
    },

    async mkdir(path: string): Promise<void> {
      if (readOnly) throw readonlyError();
      try {
        await engine.mountMkdir(path);
      } catch (error) {
        throw driverError(error, path);
      }
    },

    async unlink(path: string): Promise<void> {
      if (readOnly) throw readonlyError();
      try {
        await engine.mountRemove(path);
      } catch (error) {
        throw driverError(error, path);
      }
    },

    async rename(from: string, to: string): Promise<void> {
      if (readOnly) throw readonlyError();
      try {
        await engine.mountRename(from, to);
      } catch (error) {
        throw driverError(error, from);
      }
    },
  };

  Object.defineProperty(driver, GITFS_DRIVER_KIND, {
    value: true,
    enumerable: false,
    configurable: false,
    writable: false,
  });
  return driver;
}

function isMountRoot(path: string): boolean {
  const trimmed = path.replace(/\\/g, "/").replace(/^\/+|\/+$/g, "");
  return trimmed === "" || trimmed === ".";
}

function isDirectoryMode(mode: number): boolean {
  return (mode & 0o170000) === 0o040000;
}

function safeSize(low: number, high: number): number {
  const value = high * 0x1_0000_0000 + low;
  if (!Number.isSafeInteger(value)) throw new Error("Git mount entry exceeds JavaScript safe size");
  return value;
}

function readonlyError(): DriverError {
  const error = new Error("read-only Git mount") as DriverError;
  error.code = "EACCES";
  return error;
}

function driverError(error: unknown, path: string): DriverError {
  if (error && typeof error === "object" && "code" in error) return error as DriverError;
  const value = error as { domain?: number; engineCode?: number; message?: string } | undefined;
  const out = new Error(value?.message ?? path) as DriverError;
  if (value?.domain === ERROR_PATH) {
    out.code = pathErrorCode(value.engineCode);
  }
  return out;
}

function pathErrorCode(code: number | undefined): DriverError["code"] {
  switch (code) {
    case ERROR_CODE_MISSING: return "ENOENT";
    case ERROR_CODE_EXISTS: return "EEXIST";
    case ERROR_CODE_NOT_DIRECTORY: return "ENOTDIR";
    case ERROR_CODE_IS_DIRECTORY: return "EISDIR";
    case ERROR_CODE_NOT_EMPTY: return "ENOTEMPTY";
    case ERROR_CODE_INVALID: return "EINVAL";
    case ERROR_CODE_DENIED: return "EACCES";
    default: return undefined;
  }
}

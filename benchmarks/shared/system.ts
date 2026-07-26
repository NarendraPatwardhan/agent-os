import { readFile } from "node:fs/promises";
import { arch, cpus, hostname, platform, release, totalmem } from "node:os";

export async function sha256(bytes: Uint8Array): Promise<string> {
  const digest = new Uint8Array(
    await crypto.subtle.digest("SHA-256", bytes as Uint8Array<ArrayBuffer>),
  );
  return [...digest].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function maybeFile(path: string): Promise<string | undefined> {
  try {
    return await readFile(path, "utf8");
  } catch {
    return undefined;
  }
}

function procKiB(text: string | undefined, key: string): number | undefined {
  const match = text?.match(new RegExp(`^${key}:\\s+(\\d+)\\s+kB$`, "m"));
  return match ? Number(match[1]) * 1024 : undefined;
}

export async function processMemory(): Promise<Record<string, number>> {
  const [status, rollup] = await Promise.all([
    maybeFile("/proc/self/status"),
    maybeFile("/proc/self/smaps_rollup"),
  ]);
  const values = {
    rssBytes: procKiB(status, "VmRSS"),
    peakRssBytes: procKiB(status, "VmHWM"),
    pssBytes: procKiB(rollup, "Pss"),
  };
  return Object.fromEntries(
    Object.entries(values).filter((entry): entry is [string, number] => entry[1] !== undefined),
  );
}

export async function systemMetadata(): Promise<Record<string, unknown>> {
  const cpuList = cpus();
  return {
    hostname: hostname(),
    os: platform(),
    osRelease: release(),
    architecture: arch(),
    logicalCpus: cpuList.length,
    cpuModel: cpuList[0]?.model ?? "unknown",
    totalMemoryBytes: totalmem(),
    runtime: `${process.release.name} ${process.version}`,
    process: await processMemory(),
  };
}

export function monotonicMs(): number {
  return performance.now();
}

import { useState } from "react";
import { mc } from "@mc/elements";
import type { Vm } from "@mc/elements";
import type { VmSession } from "./useVmSession";

function randomVmId(): string {
  return `vm-${Math.random().toString(36).slice(2, 10)}`;
}

export type RemoteLifecycle = {
  readonly url: string;
  readonly setUrl: (v: string) => void;
  readonly apiKey: string;
  readonly setApiKey: (v: string) => void;
  readonly vmId: string;
  readonly setVmId: (v: string) => void;
  readonly regenId: () => void;
  readonly vm: Vm | null;
  readonly connected: boolean;
  readonly busy: boolean;
  readonly locked: boolean;
  readonly create: () => void;
  readonly connect: () => void;
  readonly kill: () => void;
};

/** The create → connect → kill lifecycle for a remote VM, driving a session. The
 *  field is the base host; `mc.connect` appends `/v1/vms` (the "/v1" is shown on the
 *  input). `connect` attaches the created VM to the session's `manual` terminal;
 *  `kill` closes it server-side (DELETE) and tears the terminal down. */
export function useRemoteLifecycle(session: VmSession, defaultUrl = "https://agentos.opyt.cloud"): RemoteLifecycle {
  const [url, setUrl] = useState(defaultUrl);
  const [apiKey, setApiKey] = useState("");
  const [vmId, setVmId] = useState(randomVmId);
  const [vm, setVm] = useState<Vm | null>(null);
  const [connected, setConnected] = useState(false);
  const [busy, setBusy] = useState(false);

  const fail = (what: string, e: unknown): void =>
    session.print(`${what} failed — ${e instanceof Error ? e.message : String(e)}`);

  const create = (): void => {
    if (busy || vm || !url) return;
    setBusy(true);
    const base = url.trim().replace(/\/+$/, "");
    void (async () => {
      try {
        const v = await mc.connect(base, apiKey || undefined).vm(vmId);
        setVm(v);
        session.print(`created VM "${vmId}" on ${base} — not booted`);
      } catch (e) {
        fail("create", e);
      } finally {
        setBusy(false);
      }
    })();
  };

  const connect = (): void => {
    if (!vm) {
      session.print("create a VM first");
      return;
    }
    session.print(`connecting to "${vmId}" — opening a shell`);
    session.attach(vm);
    setConnected(true);
  };

  const kill = (): void => {
    if (busy || !vm) return;
    setBusy(true);
    const v = vm;
    void (async () => {
      try {
        await v.close();
        session.print(`killed VM "${vmId}"`);
      } catch (e) {
        fail("kill", e);
      } finally {
        setVm(null);
        setConnected(false);
        setBusy(false);
        session.close();
      }
    })();
  };

  return {
    url,
    setUrl,
    apiKey,
    setApiKey,
    vmId,
    setVmId,
    regenId: () => setVmId(randomVmId()),
    vm,
    connected,
    busy,
    locked: !!vm,
    create,
    connect,
    kill,
  };
}

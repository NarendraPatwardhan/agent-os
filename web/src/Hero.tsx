import { useCallback, useEffect, useRef, useState } from "react";
import { mc } from "@mc/core";
import type { CreateOptions, Vm } from "@mc/core";
import { Terminal, TerminalFrame, useVmHost, VmProvider, type VmFactory } from "./components";
import { loadBrowserVmArtifacts } from "./browserArtifacts";
import { runAutoDemo, type AutoDemoHandle } from "./heroDemo";
import styles from "./Hero.module.css";

const HERO_CREATE_OPTIONS: CreateOptions = {
  runtime: "browser",
  net: true,
};

function abortError(): Error {
  return new Error("hero VM boot was aborted");
}

const createHeroVm: VmFactory = async (options, signal): Promise<Vm> => {
  const artifacts = await loadBrowserVmArtifacts(signal);
  if (signal.aborted) throw abortError();
  const vm = await mc.create({
    ...options,
    runtime: "browser",
    kernel: artifacts.kernel,
    image: artifacts.image,
  });
  if (signal.aborted) {
    await vm.close().catch(() => {});
    throw abortError();
  }
  return vm;
};

function HeroTerminalInner() {
  const host = useVmHost();
  const demoRef = useRef<AutoDemoHandle | null>(null);
  const [userInteracted, setUserInteracted] = useState(false);

  useEffect(() => {
    if (host.status !== "ready" || !host.shell || userInteracted) return undefined;
    const demo = runAutoDemo(host.shell);
    demoRef.current = demo;
    return () => {
      demo.cancel();
      if (demoRef.current === demo) demoRef.current = null;
    };
  }, [host.shell, host.status, userInteracted]);

  const handleInput = useCallback((): void => {
    demoRef.current?.cancel();
    demoRef.current = null;
    setUserInteracted(true);
  }, []);

  return (
    <TerminalFrame title="agent - live in your browser" status={host.status} error={host.error} className={styles.terminal}>
      <Terminal cursorStyle="block" lineHeight={1.55} onData={handleInput} />
    </TerminalFrame>
  );
}

function HeroTerminal() {
  return (
    <VmProvider createOptions={HERO_CREATE_OPTIONS} createVm={createHeroVm} autoBoot>
      <HeroTerminalInner />
    </VmProvider>
  );
}

export function Hero() {
  return (
    <main className={styles.page}>
      <div className={styles.shell}>
        <section className={styles.hero}>
          <div className={styles.copy}>
            <span className={styles.eyebrow}>an operating system for AI agents</span>
            <h1 className={styles.headline}>
              Give the agent <em>its own</em> computer.
            </h1>
            <p className={styles.lede}>
              A WebAssembly VM with a Unix shell, files, processes, pipes, snapshots, and a host-controlled
              capability boundary.
            </p>
          </div>

          <aside className={styles.aside}>
            <HeroTerminal />
            <p className={styles.caption}>
              Browser VM shell from <code>@mc/core</code>, booted from Bazel-built artifacts.
            </p>
          </aside>
        </section>
      </div>
    </main>
  );
}

import { useEffect, useRef } from "react";
import { setArtifactSources } from "@mc/elements";
import type { McTerminal } from "@mc/elements";
import { runAutoDemo, type AutoDemoHandle } from "./heroDemo";
import styles from "./Hero.module.css";

// Point @mc/elements' artifact loader at the Bazel-staged kernel/image that Vite
// serves from /mc/ (see web/BUILD.bazel `hero_vm_assets`). Module scope: runs once,
// before any <mc-terminal> boots.
setArtifactSources({ kernel: "/mc/kernel.wasm", image: "/mc/image.tar" });

function HeroTerminal() {
  const ref = useRef<McTerminal>(null);

  useEffect(() => {
    const term = ref.current;
    if (!term) return undefined;
    let demo: AutoDemoHandle | null = null;

    // Run the scripted demo once the shell is live; cancel the instant the user types.
    const onReady = (): void => {
      demo?.cancel();
      demo = runAutoDemo((bytes) => term.send(bytes));
    };
    const onData = (): void => {
      demo?.cancel();
      demo = null;
    };
    term.addEventListener("mc-ready", onReady);
    term.addEventListener("mc-data", onData);
    return () => {
      term.removeEventListener("mc-ready", onReady);
      term.removeEventListener("mc-data", onData);
      demo?.cancel();
    };
  }, []);

  return (
    <mc-terminal
      ref={ref}
      className={styles.terminal}
      label="agent · live in your browser"
      net
      cursor="block"
      line-height={1.55}
    />
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

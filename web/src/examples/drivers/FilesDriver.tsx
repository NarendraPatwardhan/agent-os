import { useEffect, useRef, useState } from "react";
import * as stylex from "@stylexjs/stylex";
import { controls, surface, text } from "instrument";
import { color } from "instrument/tokens/color.stylex.js";
import { radius } from "instrument/tokens/radius.stylex.js";
import { space } from "instrument/tokens/space.stylex.js";
import { mc, resolveCreateOptions } from "@mc/elements";
import type { Driver, McEditor, Vm } from "@mc/elements";
import { Icon } from "../../Icon";
import { styles } from "../styles";
import { useVmSession } from "../useVmSession";
import { runProgram } from "../runProgram";
import { ExampleShell, TerminalPanel, PlayButton, Hint } from "../panel";
import type { Example } from "../types";

type DirectoryHandle = FileSystemDirectoryHandle & {
  entries(): AsyncIterableIterator<[string, FileSystemHandle]>;
};

type DirectoryPickerWindow = Window & {
  showDirectoryPicker?: (options?: { mode?: "read" }) => Promise<FileSystemDirectoryHandle>;
};

type HandleItem = DataTransferItem & {
  getAsFileSystemHandle?: () => Promise<FileSystemHandle | null>;
};

const pickerStyles = stylex.create({
  root: {
    width: "100%",
    minHeight: "136px",
    paddingBlock: space.s6,
    paddingInline: space.s5,
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    justifyContent: "center",
    gap: space.s3,
    textAlign: "center",
    borderWidth: "1px",
    borderStyle: "dashed",
    borderColor: color.borderStrong,
    borderRadius: radius.card,
    color: color.inkMuted,
    transitionProperty: "border-color, background-color, color",
    transitionDuration: "150ms",
  },
  dragging: {
    borderColor: color.signal,
    backgroundColor: color.signalSoft,
    color: color.ink,
  },
  selected: {
    borderStyle: "solid",
    borderColor: color.border,
    backgroundColor: color.bgSunken,
  },
  icon: {
    display: "flex",
    color: color.inkSubtle,
  },
  selectedName: {
    maxWidth: "100%",
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
    color: color.ink,
  },
  actions: {
    display: "flex",
    alignItems: "center",
    gap: space.s2,
  },
});

function posixError(code: "ENOENT" | "EACCES" | "ENOTDIR" | "EISDIR", message: string): Error {
  return Object.assign(new Error(message), { code });
}

function mountParts(path: string): string[] {
  const parts = path.split("/").filter((part) => part !== "" && part !== ".");
  if (parts.includes("..")) throw posixError("EACCES", `path escapes mount root: ${path}`);
  return parts;
}

/** Resolve paths lazily against a browser File System Access directory handle.
 *  The page retains the handle; only bytes requested by the VM cross the bridge. */
function directoryDriver(root: FileSystemDirectoryHandle): Driver {
  const resolve = async (path: string): Promise<FileSystemHandle> => {
    const parts = mountParts(path);
    let current: FileSystemHandle = root;
    for (const part of parts) {
      if (current.kind !== "directory") throw posixError("ENOTDIR", `${part} is below a file`);
      const dir = current as FileSystemDirectoryHandle;
      try {
        current = await dir.getFileHandle(part);
      } catch {
        try {
          current = await dir.getDirectoryHandle(part);
        } catch {
          throw posixError("ENOENT", `missing ${path}`);
        }
      }
    }
    return current;
  };

  return {
    readOnly: true,
    async open(path) {
      const handle = await resolve(path);
      if (handle.kind !== "file") throw posixError("EISDIR", `${path} is a directory`);
      return new Uint8Array(await (await (handle as FileSystemFileHandle).getFile()).arrayBuffer());
    },
    async stat(path) {
      const handle = await resolve(path);
      if (handle.kind === "directory") return { kind: "dir", size: 0 };
      return { kind: "file", size: (await (handle as FileSystemFileHandle).getFile()).size };
    },
    async readdir(path) {
      const handle = await resolve(path);
      if (handle.kind !== "directory") throw posixError("ENOTDIR", `${path} is not a directory`);
      const out: { name: string; kind: "file" | "dir" }[] = [];
      for await (const [name, child] of (handle as DirectoryHandle).entries()) {
        out.push({ name, kind: child.kind === "directory" ? "dir" : "file" });
      }
      return out;
    },
  };
}

/** Normal file-input fallback for browsers (notably some Brave configurations)
 *  that withhold showDirectoryPicker. Files are mounted flat by name; unlike a
 *  webkitdirectory input, this does not trigger Brave's folder-upload warning. */
function selectedFilesDriver(files: readonly File[]): Driver {
  const byName = new Map(files.map((file) => [file.name, file]));
  const at = (path: string): File => {
    const name = mountParts(path).join("/");
    const file = byName.get(name);
    if (!file) throw posixError("ENOENT", `missing ${path}`);
    return file;
  };
  return {
    readOnly: true,
    async open(path) {
      return new Uint8Array(await at(path).arrayBuffer());
    },
    async stat(path) {
      if (mountParts(path).length === 0) return { kind: "dir", size: 0 };
      return { kind: "file", size: at(path).size };
    },
    async readdir(path) {
      if (mountParts(path).length !== 0) throw posixError("ENOTDIR", `${path} is not a directory`);
      return [...byName.keys()].map((name) => ({ name, kind: "file" as const }));
    },
  };
}

/** Browser counterpart to hostDir: a granted directory handle stays lazy, while
 *  the normal-picker fallback mounts explicitly selected files without using the
 *  webkitdirectory flow that triggers Brave's extra folder confirmation. */
export function FilesDriver({ example }: { example: Extract<Example, { kind: "files" }> }) {
  const editorRef = useRef<McEditor>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);
  const vmRef = useRef<Vm | null>(null);
  const busyRef = useRef(false);
  const [directory, setDirectory] = useState<{
    readonly name: string;
    readonly driver: Driver;
    readonly kind: "directory" | "files";
  } | null>(null);
  const [dragging, setDragging] = useState(false);
  const canPickDirectory = typeof window !== "undefined" && typeof (window as DirectoryPickerWindow).showDirectoryPicker === "function";
  const session = useVmSession({
    onReady: (vm, s) =>
      runProgram(editorRef.current?.source ?? example.code.source, vm, s, {}, { image: example.image ?? "posix" }),
  });

  useEffect(
    () => () => {
      void vmRef.current?.close().catch(() => {});
    },
    [],
  );

  const select = (handle: FileSystemDirectoryHandle): void => {
    setDirectory({ name: handle.name, driver: directoryDriver(handle), kind: "directory" });
    session.setLogs([`${handle.name} is ready to mount read-only — no files were uploaded`]);
  };

  const pick = (): void => {
    const picker = (window as DirectoryPickerWindow).showDirectoryPicker;
    if (!picker) {
      fileInputRef.current?.click();
      return;
    }
    void picker.call(window, { mode: "read" }).then(select).catch((error: unknown) => {
      if ((error as DOMException | undefined)?.name !== "AbortError") {
        session.setLogs([error instanceof Error ? error.message : String(error)]);
      }
    });
  };

  const drop = (event: React.DragEvent<HTMLDivElement>): void => {
    event.preventDefault();
    setDragging(false);
    void (async () => {
      const item = Array.from(event.dataTransfer.items).find((candidate) => candidate.kind === "file") as HandleItem | undefined;
      const handle = await item?.getAsFileSystemHandle?.();
      if (handle?.kind === "directory") {
        select(handle as FileSystemDirectoryHandle);
        return;
      }
      const files = Array.from(event.dataTransfer.files);
      if (files.length > 0) {
        setDirectory({
          name: `${files.length} selected file${files.length === 1 ? "" : "s"}`,
          driver: selectedFilesDriver(files),
          kind: "files",
        });
        session.setLogs([`${files.length} file${files.length === 1 ? "" : "s"} ready to mount flat at ${example.mountPath}`]);
        return;
      }
      session.setLogs(["drop a directory or one or more files here"]);
    })();
  };

  const play = (): void => {
    if (!directory) {
      session.setLogs(["choose files or drop a directory first — the browser never grants host files implicitly"]);
      return;
    }
    if (busyRef.current) return;
    busyRef.current = true;
    session.close();
    session.clearLogs();
    void (async () => {
      try {
        await vmRef.current?.close().catch(() => {});
        vmRef.current = null;
        session.print(`mounting ${directory.name} at ${example.mountPath} before the shell starts…`);
        const base = await resolveCreateOptions({
          image: example.image ?? "posix",
          net: example.net,
          deterministic: example.deterministic,
        });
        // Declare the mount as machine creation state so the scripted calls and
        // the interactive login shell begin with the same filesystem view.
        const vm = await mc.create({
          ...base,
          mounts: [{ path: example.mountPath, driver: directory.driver, readOnly: true }],
        });
        vmRef.current = vm;
        session.clearLogs();
        session.attach(vm);
      } catch (error) {
        session.print(error instanceof Error ? error.message : String(error));
      } finally {
        busyRef.current = false;
      }
    })();
  };

  return (
    <ExampleShell
      example={example}
      left={
        <>
          <input
            ref={fileInputRef}
            type="file"
            multiple
            hidden
            onChange={(event) => {
              const files = Array.from(event.target.files ?? []);
              if (files.length === 0) return;
              setDirectory({
                name: `${files.length} selected file${files.length === 1 ? "" : "s"}`,
                driver: selectedFilesDriver(files),
                kind: "files",
              });
              session.setLogs([`${files.length} file${files.length === 1 ? "" : "s"} ready to mount flat at ${example.mountPath}`]);
              event.target.value = "";
            }}
          />
          <div
            role="group"
            aria-label="Directory to expose read-only"
            onDragEnter={(event) => { event.preventDefault(); setDragging(true); }}
            onDragOver={(event) => event.preventDefault()}
            onDragLeave={() => setDragging(false)}
            onDrop={drop}
            {...stylex.props(
              surface.dotGrid,
              pickerStyles.root,
              dragging && pickerStyles.dragging,
              directory && pickerStyles.selected,
            )}
          >
            <span {...stylex.props(pickerStyles.icon)}><Icon id="file" size={24} /></span>
            {directory ? (
              <>
                <span {...stylex.props(pickerStyles.selectedName, text.label)}>{directory.name}</span>
                <span {...stylex.props(text.caption, text.muted)}>
                  {directory.kind === "directory"
                    ? "Directory handle granted · mounted only when you press ▶"
                    : "Files selected · mounted flat only when you press ▶"}
                </span>
              </>
            ) : (
              <>
                <span {...stylex.props(text.label)}>Drop a directory or files here</span>
                <span {...stylex.props(text.caption, text.muted)}>
                  {canPickDirectory
                    ? "The handle stays in this page; requested bytes stream into the VM."
                    : "Brave fallback: selected files mount flat and stay in this page."}
                </span>
              </>
            )}
            <div {...stylex.props(pickerStyles.actions)}>
              <button type="button" onClick={pick} {...stylex.props(controls.button, controls.buttonGhost)}>
                {directory ? "Choose another" : canPickDirectory ? "Choose directory" : "Choose files"}
              </button>
            </div>
          </div>
          <div {...stylex.props(styles.codeWrap)}>
            <mc-editor ref={editorRef} {...stylex.props(styles.editor)} value={example.code.source} language="typescript" />
            <PlayButton place="abs" onClick={play} label="Mount directory and run" />
          </div>
        </>
      }
      terminal={
        <TerminalPanel
          session={session}
          label={`agent · ${example.mountPath}`}
          hint={<Hint>choose files or drop a directory, then press ▶</Hint>}
        />
      }
    />
  );
}

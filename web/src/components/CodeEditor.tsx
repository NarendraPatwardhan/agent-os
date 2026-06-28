import {
  forwardRef,
  useEffect,
  useImperativeHandle,
  useLayoutEffect,
  useMemo,
  useRef,
  type HTMLAttributes,
  type MutableRefObject,
} from "react";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { javascript } from "@codemirror/lang-javascript";
import {
  HighlightStyle,
  bracketMatching,
  defaultHighlightStyle,
  indentOnInput,
  syntaxHighlighting,
} from "@codemirror/language";
import { EditorState, Prec, type Extension } from "@codemirror/state";
import {
  EditorView,
  drawSelection,
  highlightActiveLine,
  highlightActiveLineGutter,
  keymap,
  lineNumbers,
} from "@codemirror/view";
import { tags as t } from "@lezer/highlight";
import styles from "./CodeEditor.module.css";

export type CodeEditorLanguage = "javascript" | "typescript" | "plain";

export interface CodeEditorHandle {
  readonly view: EditorView | null;
  focus(): void;
  getValue(): string;
  setValue(value: string): void;
}

export interface CodeEditorProps
  extends Omit<HTMLAttributes<HTMLDivElement>, "children" | "defaultValue" | "onChange" | "onInput"> {
  value?: string;
  defaultValue?: string;
  language?: CodeEditorLanguage;
  readOnly?: boolean;
  lineWrapping?: boolean;
  autoFocus?: boolean;
  extensions?: Extension[];
  onChange?: (value: string, view: EditorView) => void;
  onRun?: (value: string, view: EditorView) => void;
  onReady?: (handle: CodeEditorHandle) => void;
}

function useLatest<T>(value: T): MutableRefObject<T> {
  const ref = useRef(value);
  useEffect(() => {
    ref.current = value;
  }, [value]);
  return ref;
}

const tokenHighlight = HighlightStyle.define([
  {
    tag: [t.keyword, t.modifier, t.controlKeyword, t.operatorKeyword],
    color: "var(--mc-code-key, var(--accent-text, oklch(0.46 0.15 65)))",
  },
  {
    tag: [t.string, t.special(t.string), t.regexp],
    color: "var(--mc-code-str, oklch(0.55 0.13 150))",
  },
  {
    tag: [t.number, t.bool, t.null, t.atom],
    color: "var(--mc-code-num, oklch(0.55 0.13 60))",
  },
  {
    tag: [t.lineComment, t.blockComment, t.docComment],
    color: "var(--mc-code-com, var(--fg-subtle, oklch(0.6 0.01 250)))",
    fontStyle: "italic",
  },
  {
    tag: [t.function(t.variableName), t.function(t.propertyName)],
    color: "var(--mc-code-fn, oklch(0.52 0.13 250))",
  },
  {
    tag: [t.definitionKeyword, t.typeName, t.className],
    color: "var(--mc-code-key, var(--accent-text, oklch(0.46 0.15 65)))",
  },
  {
    tag: [t.propertyName, t.variableName],
    color: "var(--mc-fg, var(--fg, inherit))",
  },
  {
    tag: [t.operator, t.punctuation, t.separator, t.bracket],
    color: "var(--mc-fg-muted, var(--fg-muted, inherit))",
  },
]);

const tokenTheme = EditorView.theme({
  "&": {
    color: "var(--mc-fg, var(--fg, #1a1a1d))",
    backgroundColor: "transparent",
    height: "100%",
    fontSize: "var(--mc-code-fs, 13px)",
  },
  "&.cm-focused": {
    outline: "none",
  },
  ".cm-scroller": {
    fontFamily:
      'var(--mc-font-mono, var(--font-mono, ui-monospace, "SF Mono", Menlo, monospace))',
    lineHeight: "1.65",
    overflow: "auto",
  },
  ".cm-scroller::-webkit-scrollbar": {
    width: "8px",
    height: "8px",
  },
  ".cm-scroller::-webkit-scrollbar-track": {
    background: "transparent",
  },
  ".cm-scroller::-webkit-scrollbar-thumb": {
    background: "color-mix(in oklab, currentColor 16%, transparent)",
    borderRadius: "999px",
    border: "2px solid transparent",
    backgroundClip: "padding-box",
  },
  ".cm-scroller::-webkit-scrollbar-thumb:hover": {
    background: "color-mix(in oklab, currentColor 30%, transparent)",
    backgroundClip: "padding-box",
  },
  ".cm-content": {
    caretColor: "var(--mc-accent, var(--accent, #d8a531))",
    padding: "14px 0",
  },
  ".cm-gutters": {
    backgroundColor: "transparent",
    color: "var(--mc-fg-subtle, var(--fg-subtle, #9a9aa0))",
    border: "none",
    paddingRight: "4px",
  },
  ".cm-activeLine": {
    backgroundColor: "var(--mc-active-line, color-mix(in oklab, currentColor 5%, transparent))",
  },
  ".cm-activeLineGutter": {
    backgroundColor: "transparent",
    color: "var(--mc-fg-muted, var(--fg-muted, inherit))",
  },
  ".cm-lineNumbers .cm-gutterElement": {
    padding: "0 6px 0 10px",
  },
  ".cm-cursor, .cm-dropCursor": {
    borderLeftColor: "var(--mc-accent, var(--accent, #d8a531))",
    borderLeftWidth: "2px",
  },
  "&.cm-focused .cm-selectionBackground, .cm-selectionBackground, .cm-content ::selection": {
    backgroundColor:
      "var(--mc-selection, color-mix(in oklab, var(--mc-accent, var(--accent, #d8a531)) 22%, transparent))",
  },
  ".cm-matchingBracket": {
    backgroundColor: "color-mix(in oklab, var(--mc-accent, var(--accent, #d8a531)) 22%, transparent)",
    outline: "none",
  },
});

function languageExtension(language: CodeEditorLanguage): Extension[] {
  if (language === "plain") return [];
  return [javascript({ typescript: language === "typescript" })];
}

export const CodeEditor = forwardRef<CodeEditorHandle, CodeEditorProps>(function CodeEditor(
  {
    className,
    value,
    defaultValue = "",
    language = "typescript",
    readOnly = false,
    lineWrapping = false,
    autoFocus = false,
    extensions = [],
    onChange,
    onRun,
    onReady,
    ...divProps
  },
  ref,
) {
  const rootRef = useRef<HTMLDivElement | null>(null);
  const hostRef = useRef<HTMLDivElement | null>(null);
  const viewRef = useRef<EditorView | null>(null);
  const applyingExternalValueRef = useRef(false);
  const onChangeRef = useLatest(onChange);
  const onRunRef = useLatest(onRun);
  const onReadyRef = useLatest(onReady);

  const setValue = (nextValue: string): void => {
    const view = viewRef.current;
    if (!view) return;
    const currentValue = view.state.doc.toString();
    if (currentValue === nextValue) return;
    applyingExternalValueRef.current = true;
    try {
      view.dispatch({
        changes: { from: 0, to: currentValue.length, insert: nextValue },
      });
    } finally {
      applyingExternalValueRef.current = false;
    }
  };

  const handle = useMemo<CodeEditorHandle>(
    () => ({
      get view() {
        return viewRef.current;
      },
      focus() {
        viewRef.current?.focus();
      },
      getValue() {
        return viewRef.current?.state.doc.toString() ?? "";
      },
      setValue,
    }),
    [],
  );

  useImperativeHandle(ref, () => handle, [handle]);

  useLayoutEffect(() => {
    const host = hostRef.current;
    if (!host) return undefined;

    const updateListener = EditorView.updateListener.of((update) => {
      if (update.docChanged && !applyingExternalValueRef.current) {
        onChangeRef.current?.(update.state.doc.toString(), update.view);
      }
    });
    const runKeymap = Prec.highest(
      keymap.of([
        {
          key: "Mod-Enter",
          preventDefault: true,
          run: (view) => {
            onRunRef.current?.(view.state.doc.toString(), view);
            return true;
          },
        },
      ]),
    );
    const state = EditorState.create({
      doc: value ?? defaultValue,
      extensions: [
        lineNumbers(),
        highlightActiveLine(),
        highlightActiveLineGutter(),
        history(),
        drawSelection(),
        indentOnInput(),
        bracketMatching(),
        EditorState.readOnly.of(readOnly),
        EditorView.editable.of(!readOnly),
        syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
        syntaxHighlighting(tokenHighlight),
        tokenTheme,
        runKeymap,
        keymap.of([...defaultKeymap, ...historyKeymap, indentWithTab]),
        ...(lineWrapping ? [EditorView.lineWrapping] : []),
        ...languageExtension(language),
        ...extensions,
        updateListener,
      ],
    });

    const view = new EditorView({ state, parent: host });
    viewRef.current = view;
    if (autoFocus) view.focus();
    onReadyRef.current?.(handle);

    return () => {
      viewRef.current = null;
      view.destroy();
    };
  }, [
    autoFocus,
    language,
    lineWrapping,
    onChangeRef,
    onReadyRef,
    onRunRef,
    readOnly,
  ]);

  useEffect(() => {
    if (value !== undefined) setValue(value);
  }, [value]);

  return (
    <div {...divProps} ref={rootRef} className={[styles.root, className].filter(Boolean).join(" ")}>
      <div ref={hostRef} className={styles.editor} />
    </div>
  );
});

export type { EditorView, Extension };

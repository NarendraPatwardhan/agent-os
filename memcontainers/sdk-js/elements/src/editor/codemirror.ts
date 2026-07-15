// CodeMirror 6 setup for <mc-editor>. Lazy-loaded (dynamic import) so it only ships
// to pages that actually use an editor. The theme is driven entirely by design
// tokens, so the editor inherits the host page's palette; Mod-Enter dispatches a
// run. `root` is resolved from the mount point so CodeMirror injects its StyleModule
// and measures against the correct tree (works in light DOM and shadow DOM alike).
//
// Structural options (language / read-only / line-wrapping) live in Compartments so
// <mc-editor> can reconfigure them in place — no editor teardown, doc and history
// survive. makeEditor returns an EditorHandle, not a bare view, so the element gets
// both the view and the reconfigure seam.

import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { javascript } from "@codemirror/lang-javascript";
import {
  HighlightStyle,
  bracketMatching,
  defaultHighlightStyle,
  indentOnInput,
  syntaxHighlighting,
} from "@codemirror/language";
import { Compartment, EditorState } from "@codemirror/state";
import type { Extension } from "@codemirror/state";
import {
  EditorView,
  drawSelection,
  highlightActiveLine,
  highlightActiveLineGutter,
  keymap,
  lineNumbers,
} from "@codemirror/view";
import { tags as t } from "@lezer/highlight";

/** JS grammar with TypeScript syntax, plain JS, or no grammar at all. */
export type EditorLanguage = "javascript" | "typescript" | "plain";

export interface MakeEditorOptions {
  parent: HTMLElement | ShadowRoot;
  doc?: string;
  language?: EditorLanguage;
  readOnly?: boolean;
  lineWrapping?: boolean;
  autoFocus?: boolean;
  /** Extra extensions appended after the defaults (JS-only; not attribute-driven). */
  extraExtensions?: readonly Extension[];
  onChange?: (doc: string) => void;
  onRun?: (doc: string) => void;
}

/** The live editor plus the seam to reconfigure structural options in place. */
export interface EditorHandle {
  readonly view: EditorView;
  /** Swap language / read-only / line-wrapping without losing doc or history. */
  update(opts: { language?: EditorLanguage; readOnly?: boolean; lineWrapping?: boolean }): void;
}

// Syntax colors, every value a token with a tasteful fallback so it reads well even
// with no design system loaded.
const tokenHighlight = HighlightStyle.define([
  {
    tag: [t.keyword, t.modifier, t.controlKeyword, t.operatorKeyword],
    color: "var(--mc-code-key, var(--accent-text, oklch(0.46 0.15 65)))",
  },
  {
    tag: [t.string, t.special(t.string), t.regexp],
    color: "var(--mc-code-str, oklch(0.55 0.13 150))",
  },
  { tag: [t.number, t.bool, t.null, t.atom], color: "var(--mc-code-num, oklch(0.55 0.13 60))" },
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
  { tag: [t.propertyName, t.variableName], color: "var(--mc-fg, var(--fg, inherit))" },
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
    fontSize: "var(--mc-code-fs, var(--fs-13, 13px))",
  },
  ".cm-scroller": {
    fontFamily: 'var(--mc-font-mono, var(--font-mono, ui-monospace, "SF Mono", Menlo, monospace))',
    lineHeight: "1.65",
    overflow: "auto",
  },
  // Slim scrollbar for the editor's own scroller (currentColor-driven, so it works
  // on any substrate without knowing the surface).
  ".cm-scroller::-webkit-scrollbar": { width: "8px", height: "8px" },
  ".cm-scroller::-webkit-scrollbar-track": { background: "transparent" },
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
  ".cm-lineNumbers .cm-gutterElement": { padding: "0 6px 0 10px" },
  "&.cm-focused": { outline: "none" },
  ".cm-cursor, .cm-dropCursor": {
    borderLeftColor: "var(--mc-accent, var(--accent, #d8a531))",
    borderLeftWidth: "2px",
  },
  "&.cm-focused .cm-selectionBackground, .cm-selectionBackground, .cm-content ::selection": {
    backgroundColor:
      "var(--mc-selection, color-mix(in oklab, var(--mc-accent, var(--accent, #d8a531)) 22%, transparent))",
  },
  ".cm-matchingBracket": {
    backgroundColor:
      "color-mix(in oklab, var(--mc-accent, var(--accent, #d8a531)) 22%, transparent)",
    outline: "none",
  },
});

/** The grammar for a language mode. `plain` drops syntax parsing entirely. */
function languageExtension(language: EditorLanguage): Extension {
  return language === "plain" ? [] : javascript({ typescript: language === "typescript" });
}

/** read-only pairs the state flag with editor.editable so the caret + edits both stop. */
function readOnlyExtension(readOnly: boolean): Extension {
  return [EditorState.readOnly.of(readOnly), EditorView.editable.of(!readOnly)];
}

export function makeEditor(opts: MakeEditorOptions): EditorHandle {
  const languageConf = new Compartment();
  const readOnlyConf = new Compartment();
  const wrapConf = new Compartment();

  const runKeymap = keymap.of([
    {
      key: "Mod-Enter",
      preventDefault: true,
      run: (view) => {
        opts.onRun?.(view.state.doc.toString());
        return true;
      },
    },
  ]);

  const updateListener = EditorView.updateListener.of((u) => {
    if (u.docChanged) opts.onChange?.(u.state.doc.toString());
  });

  const state = EditorState.create({
    doc: opts.doc ?? "",
    extensions: [
      lineNumbers(),
      highlightActiveLine(),
      highlightActiveLineGutter(),
      history(),
      drawSelection(),
      indentOnInput(),
      bracketMatching(),
      readOnlyConf.of(readOnlyExtension(opts.readOnly ?? false)),
      wrapConf.of(opts.lineWrapping ? EditorView.lineWrapping : []),
      // defaultHighlightStyle (fallback) colors any tag tokenHighlight has no opinion
      // on; tokenHighlight, added after, wins where it does — so the token palette
      // leads and nothing renders unstyled.
      syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
      syntaxHighlighting(tokenHighlight),
      tokenTheme,
      languageConf.of(languageExtension(opts.language ?? "javascript")),
      runKeymap,
      keymap.of([...defaultKeymap, ...historyKeymap, indentWithTab]),
      updateListener,
      ...(opts.extraExtensions ?? []),
    ],
  });

  const root =
    opts.parent instanceof ShadowRoot
      ? opts.parent
      : (opts.parent.getRootNode() as ShadowRoot | Document);
  const view = new EditorView({ state, parent: opts.parent, root });
  if (opts.autoFocus) view.focus();

  return {
    view,
    update(next) {
      const effects = [];
      if (next.language !== undefined)
        effects.push(languageConf.reconfigure(languageExtension(next.language)));
      if (next.readOnly !== undefined)
        effects.push(readOnlyConf.reconfigure(readOnlyExtension(next.readOnly)));
      if (next.lineWrapping !== undefined)
        effects.push(wrapConf.reconfigure(next.lineWrapping ? EditorView.lineWrapping : []));
      if (effects.length > 0) view.dispatch({ effects });
    },
  };
}

export type { EditorView, Extension };

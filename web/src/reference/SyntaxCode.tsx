import { useMemo, type ReactNode } from "react";
import * as stylex from "@stylexjs/stylex";
import { classHighlighter, highlightTree } from "@lezer/highlight";
import { parser as javascriptParser } from "@lezer/javascript";
import { color } from "instrument/tokens/color.stylex.js";

type Token = Readonly<{ from: number; to: number; classes: string }>;

function javascriptTokens(code: string): Token[] {
  const tokens: Token[] = [];
  highlightTree(javascriptParser.parse(code), classHighlighter, (from, to, classes) => {
    tokens.push({ from, to, classes });
  });
  return tokens;
}

function matchedTokens(
  code: string,
  expression: RegExp,
  classify: (value: string) => string,
): Token[] {
  const tokens: Token[] = [];
  for (const match of code.matchAll(expression)) {
    const value = match[0];
    const from = match.index;
    tokens.push({ from, to: from + value.length, classes: classify(value) });
  }
  return tokens;
}

function shellTokens(code: string): Token[] {
  return matchedTokens(
    code,
    /#[^\n]*|'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*"|\$\{?[_A-Za-z][_A-Za-z0-9]*\}?|\b(?:case|do|done|elif|else|esac|export|fi|for|function|if|in|local|then|while)\b|(?:&&|\|\||[|<>])/g,
    (value) => {
      if (value.startsWith("#")) return "tok-comment";
      if (value.startsWith("'") || value.startsWith('"')) return "tok-string";
      if (value.startsWith("$")) return "tok-variableName";
      if (/^[A-Za-z]/.test(value)) return "tok-keyword";
      return "tok-operator";
    },
  );
}

function htmlTokens(code: string): Token[] {
  return matchedTokens(
    code,
    /<!--[\s\S]*?-->|<\/?[A-Za-z][^>]*>|&(?:[A-Za-z]+|#[0-9]+);/g,
    (value) =>
      value.startsWith("<!--")
        ? "tok-comment"
        : value.startsWith("&")
          ? "tok-string"
          : "tok-typeName",
  );
}

function tokensFor(code: string, language: string): Token[] {
  switch (language.toLowerCase()) {
    case "js":
    case "javascript":
    case "mjs":
    case "jsx":
      return javascriptTokens(code);
    case "sh":
    case "shell":
    case "bash":
      return shellTokens(code);
    case "html":
      return htmlTokens(code);
    default:
      return [];
  }
}

// This is the same semantic palette used by <mc-editor>, expressed as static
// spans so a reference page does not mount dozens of full CodeMirror editors.
const styles = stylex.create({
  keyword: { color: "var(--mc-code-key, oklch(0.76 0.11 75))" },
  string: { color: "var(--mc-code-str, oklch(0.75 0.11 150))" },
  number: { color: "var(--mc-code-num, oklch(0.78 0.11 70))" },
  comment: { color: color.inkSubtle, fontStyle: "italic" },
  functionName: { color: "var(--mc-code-fn, oklch(0.76 0.10 245))" },
  typeName: { color: "var(--mc-code-key, oklch(0.76 0.11 75))" },
  variable: { color: color.ink },
  operator: { color: color.inkMuted },
  invalid: { color: color.dangerText, textDecorationLine: "underline" },
});

function styleFor(classes: string) {
  if (classes.includes("tok-invalid")) return styles.invalid;
  if (classes.includes("tok-comment")) return styles.comment;
  if (classes.includes("tok-string") || classes.includes("tok-regexp")) return styles.string;
  if (
    classes.includes("tok-number") ||
    classes.includes("tok-bool") ||
    classes.includes("tok-null") ||
    classes.includes("tok-atom")
  )
    return styles.number;
  if (classes.includes("tok-keyword") || classes.includes("tok-meta")) return styles.keyword;
  if (
    classes.includes("tok-typeName") ||
    classes.includes("tok-className") ||
    classes.includes("tok-namespace")
  )
    return styles.typeName;
  if (classes.includes("tok-function") || classes.includes("tok-labelName"))
    return styles.functionName;
  if (classes.includes("tok-variableName") || classes.includes("tok-propertyName"))
    return styles.variable;
  return styles.operator;
}

export function SyntaxCode({ code, language }: Readonly<{ code: string; language: string }>) {
  const content = useMemo<ReactNode[]>(() => {
    const nodes: ReactNode[] = [];
    let offset = 0;
    for (const token of tokensFor(code, language)) {
      if (token.from > offset) nodes.push(code.slice(offset, token.from));
      nodes.push(
        <span key={`${token.from}:${token.to}`} {...stylex.props(styleFor(token.classes))}>
          {code.slice(token.from, token.to)}
        </span>,
      );
      offset = token.to;
    }
    if (offset < code.length) nodes.push(code.slice(offset));
    return nodes;
  }, [code, language]);

  return <code>{content}</code>;
}

import { useState, type ReactNode } from "react";
import * as stylex from "@stylexjs/stylex";
import { controls, text } from "instrument";
import { color } from "instrument/tokens/color.stylex.js";
import { font } from "instrument/tokens/type.stylex.js";
import { radius } from "instrument/tokens/radius.stylex.js";
import { space } from "instrument/tokens/space.stylex.js";
import { CopyIcon } from "../CopyIcon";
import { SyntaxCode } from "./SyntaxCode";

type Navigate = (slug: string, anchor?: string) => void;

type Block =
  | { kind: "heading"; depth: number; text: string; anchor: string }
  | { kind: "paragraph"; text: string }
  | { kind: "code"; language: string; code: string }
  | { kind: "quote"; text: string }
  | { kind: "list"; ordered: boolean; items: string[] }
  | { kind: "table"; head: string[]; rows: string[][] }
  | { kind: "rule" };

function slugifyHeading(value: string): string {
  return value
    .toLowerCase()
    .replace(/`([^`]+)`/g, "$1")
    .replace(/[<>]/g, "")
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");
}

function isTableDivider(line: string): boolean {
  return /^\s*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|?\s*$/.test(line);
}

function cells(line: string): string[] {
  return line.trim().replace(/^\||\|$/g, "").split("|").map((cell) => cell.trim());
}

function startsBlock(lines: string[], index: number): boolean {
  const line = lines[index] ?? "";
  return (
    /^#{1,6}\s+/.test(line) ||
    /^```/.test(line) ||
    /^>\s?/.test(line) ||
    /^\s*(?:[-*+] |\d+\. )/.test(line) ||
    /^\s*(?:---+|___+|\*\*\*+)\s*$/.test(line) ||
    (line.includes("|") && isTableDivider(lines[index + 1] ?? ""))
  );
}

function parseMarkdown(source: string): Block[] {
  const lines = source.replace(/\r\n/g, "\n").split("\n");
  const blocks: Block[] = [];
  const anchors = new Map<string, number>();
  let index = 0;

  while (index < lines.length) {
    const line = lines[index];
    if (!line.trim()) {
      index += 1;
      continue;
    }

    const fence = line.match(/^```([^\s]*)\s*$/);
    if (fence) {
      const body: string[] = [];
      index += 1;
      while (index < lines.length && !/^```\s*$/.test(lines[index])) body.push(lines[index++]);
      if (index < lines.length) index += 1;
      blocks.push({ kind: "code", language: fence[1] || "text", code: body.join("\n") });
      continue;
    }

    const heading = line.match(/^(#{1,6})\s+(.+)$/);
    if (heading) {
      const base = slugifyHeading(heading[2]);
      const occurrence = anchors.get(base) ?? 0;
      anchors.set(base, occurrence + 1);
      blocks.push({
        kind: "heading",
        depth: heading[1].length,
        text: heading[2],
        anchor: occurrence === 0 ? base : `${base}-${occurrence + 1}`,
      });
      index += 1;
      continue;
    }

    if (line.includes("|") && isTableDivider(lines[index + 1] ?? "")) {
      const head = cells(line);
      const rows: string[][] = [];
      index += 2;
      while (index < lines.length && lines[index].includes("|") && lines[index].trim()) {
        rows.push(cells(lines[index++]));
      }
      blocks.push({ kind: "table", head, rows });
      continue;
    }

    if (/^>\s?/.test(line)) {
      const quote: string[] = [];
      while (index < lines.length && /^>\s?/.test(lines[index])) {
        quote.push(lines[index++].replace(/^>\s?/, ""));
      }
      blocks.push({ kind: "quote", text: quote.join(" ") });
      continue;
    }

    const item = line.match(/^\s*([-*+]|\d+\.)\s+(.+)$/);
    if (item) {
      const ordered = /\d+\./.test(item[1]);
      const items: string[] = [];
      while (index < lines.length) {
        const next = lines[index].match(/^\s*([-*+]|\d+\.)\s+(.+)$/);
        if (!next || /\d+\./.test(next[1]) !== ordered) break;
        let value = next[2];
        index += 1;
        while (index < lines.length && lines[index].trim() && !startsBlock(lines, index)) {
          value += ` ${lines[index].trim()}`;
          index += 1;
        }
        items.push(value);
      }
      blocks.push({ kind: "list", ordered, items });
      continue;
    }

    if (/^\s*(?:---+|___+|\*\*\*+)\s*$/.test(line)) {
      blocks.push({ kind: "rule" });
      index += 1;
      continue;
    }

    const paragraph = [line.trim()];
    index += 1;
    while (index < lines.length && lines[index].trim() && !startsBlock(lines, index)) {
      paragraph.push(lines[index++].trim());
    }
    blocks.push({ kind: "paragraph", text: paragraph.join(" ") });
  }

  return blocks;
}

function localTarget(target: string, currentSlug: string): { slug: string; anchor?: string } | null {
  if (/^(?:https?:|mailto:)/.test(target)) return null;
  if (target.startsWith("#")) return { slug: currentSlug, anchor: target.slice(1) };
  const [path, anchor] = target.split("#", 2);
  if (!path.endsWith(".md")) return null;
  return { slug: path.replace(/^\.\//, "").replace(/\.md$/, ""), anchor: anchor || undefined };
}

function inline(textValue: string, currentSlug: string, navigate: Navigate, heading = false): ReactNode[] {
  const pieces = textValue.split(/(\[[^\]]+\]\([^)]+\)|`[^`]+`|\*\*[^*]+\*\*|\*[^*]+\*)/g);
  return pieces.filter(Boolean).map((piece, index) => {
    const link = piece.match(/^\[([^\]]+)\]\(([^)]+)\)$/);
    if (link) {
      const local = localTarget(link[2], currentSlug);
      const href = local
        ? `#reference/${local.slug}${local.anchor ? `/${local.anchor}` : ""}`
        : link[2];
      return (
        <a
          key={index}
          href={href}
          onClick={local ? (event) => { event.preventDefault(); navigate(local.slug, local.anchor); } : undefined}
          rel={local ? undefined : "noreferrer"}
          target={local ? undefined : "_blank"}
          {...stylex.props(text.link)}
        >
          {inline(link[1], currentSlug, navigate, heading)}
        </a>
      );
    }
    if (/^`[^`]+`$/.test(piece)) {
      return <code key={index} {...stylex.props(heading ? styles.headingCode : styles.inlineCode)}>{piece.slice(1, -1)}</code>;
    }
    if (/^\*\*[^*]+\*\*$/.test(piece)) {
      return <strong key={index} {...stylex.props(text.strong)}>{inline(piece.slice(2, -2), currentSlug, navigate, heading)}</strong>;
    }
    if (/^\*[^*]+\*$/.test(piece)) return <em key={index}>{piece.slice(1, -1)}</em>;
    return piece;
  });
}

const styles = stylex.create({
  article: { width: "100%", maxWidth: "880px", color: color.ink },
  h1: { marginBottom: space.s6, fontSize: "clamp(36px, 30px + 2vw, 54px)" },
  h2: { marginTop: "52px", marginBottom: space.s4, scrollMarginTop: space.s6 },
  h3: { marginTop: space.s6, marginBottom: space.s3, scrollMarginTop: space.s6 },
  h4: { marginTop: space.s5, marginBottom: space.s2, scrollMarginTop: space.s6 },
  paragraph: { marginBottom: space.s4, maxWidth: "76ch", color: color.inkMuted },
  list: { marginBottom: space.s5, paddingLeft: space.s5, display: "grid", gap: space.s2, color: color.inkMuted },
  unordered: { listStyleType: "disc" },
  ordered: { listStyleType: "decimal" },
  listItem: { paddingLeft: space.s1 },
  quote: {
    marginBottom: space.s5,
    paddingBlock: space.s3,
    paddingLeft: space.s4,
    borderLeftWidth: "2px",
    borderLeftStyle: "solid",
    borderLeftColor: color.signalBorder,
    color: color.inkMuted,
  },
  codeShell: {
    marginBottom: space.s5,
    overflow: "hidden",
    borderWidth: "1px",
    borderStyle: "solid",
    borderColor: color.border,
    borderRadius: radius.card,
    backgroundColor: color.bgSunken,
  },
  codeHead: {
    minHeight: "34px",
    display: "flex",
    alignItems: "center",
    justifyContent: "space-between",
    paddingInline: space.s3,
    borderBottomWidth: "1px",
    borderBottomStyle: "solid",
    borderBottomColor: color.border,
  },
  codeBody: {
    margin: 0,
    padding: space.s4,
    overflowX: "auto",
    color: color.ink,
    fontFamily: font.mono,
    fontSize: "12.5px",
    lineHeight: 1.65,
  },
  copy: { color: color.inkMuted },
  copyDone: { color: color.successText },
  copyIcon: { display: "block" },
  inlineCode: {
    paddingBlock: "1px",
    paddingInline: "5px",
    borderRadius: radius.chip,
    backgroundColor: color.frost,
    color: color.ink,
    fontFamily: font.mono,
    fontSize: "0.9em",
  },
  headingCode: { color: "inherit", fontFamily: font.mono, fontSize: "0.9em" },
  tableScroll: { width: "100%", marginBottom: space.s6, overflowX: "auto" },
  table: { width: "100%", minWidth: "560px", borderCollapse: "collapse" },
  tableHead: { color: color.ink },
  tableCell: {
    paddingBlock: space.s3,
    paddingInline: space.s3,
    borderBottomWidth: "1px",
    borderBottomStyle: "solid",
    borderBottomColor: color.border,
    color: color.inkMuted,
    textAlign: "left",
    verticalAlign: "top",
  },
  tableHeadCell: { color: color.ink, fontWeight: 550 },
  rule: { marginBlock: "48px", backgroundColor: color.border },
});

function CodeBlock({ language, code }: Readonly<{ language: string; code: string }>) {
  const [copied, setCopied] = useState(false);
  const renderedCode = typeof window === "undefined" ? code : code.replaceAll("{domain}", window.location.origin);
  const copy = async (): Promise<void> => {
    if (!navigator.clipboard) return;
    try {
      await navigator.clipboard.writeText(renderedCode);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1400);
    } catch {
      // Clipboard access can be blocked by the browser or embedding policy. The
      // code remains selectable, and a denied convenience action stays quiet.
    }
  };
  return (
    <div {...stylex.props(styles.codeShell)}>
      <div {...stylex.props(styles.codeHead)}>
        <span {...stylex.props(text.micro, text.subtle)}>{language}</span>
        <button
          type="button"
          aria-label={copied ? "Code copied" : "Copy code"}
          title={copied ? "Copied" : "Copy"}
          onClick={() => void copy()}
          {...stylex.props(
            controls.button,
            controls.buttonQuiet,
            controls.buttonSm,
            controls.buttonIcon,
            styles.copy,
            copied && styles.copyDone,
          )}
        >
          <CopyIcon copied={copied} {...stylex.props(styles.copyIcon)} />
        </button>
      </div>
      <pre {...stylex.props(styles.codeBody)}>
        <SyntaxCode code={renderedCode} language={language} />
      </pre>
    </div>
  );
}

export function MarkdownArticle({
  source,
  slug,
  navigate,
}: Readonly<{ source: string; slug: string; navigate: Navigate }>) {
  const blocks = parseMarkdown(source);
  return (
    <article {...stylex.props(styles.article)}>
      {blocks.map((block, index) => {
        if (block.kind === "heading") {
          const id = `reference-${slug}-${block.anchor}`;
          if (block.depth === 1) return <h1 key={index} id={id} {...stylex.props(text.display, styles.h1)}>{inline(block.text, slug, navigate, true)}</h1>;
          if (block.depth === 2) return <h2 key={index} id={id} {...stylex.props(text.heading, styles.h2)}>{inline(block.text, slug, navigate, true)}</h2>;
          if (block.depth === 3) return <h3 key={index} id={id} {...stylex.props(text.title, styles.h3)}>{inline(block.text, slug, navigate, true)}</h3>;
          return <h4 key={index} id={id} {...stylex.props(text.body, text.strong, styles.h4)}>{inline(block.text, slug, navigate, true)}</h4>;
        }
        if (block.kind === "paragraph") return <p key={index} {...stylex.props(text.bodyLg, styles.paragraph)}>{inline(block.text, slug, navigate)}</p>;
        if (block.kind === "quote") return <blockquote key={index} {...stylex.props(text.bodyLg, styles.quote)}>{inline(block.text, slug, navigate)}</blockquote>;
        if (block.kind === "code") return <CodeBlock key={index} language={block.language} code={block.code} />;
        if (block.kind === "rule") return <hr key={index} {...stylex.props(styles.rule)} />;
        if (block.kind === "list") {
          const List = block.ordered ? "ol" : "ul";
          return <List key={index} role="list" {...stylex.props(text.bodyLg, styles.list, block.ordered ? styles.ordered : styles.unordered)}>{block.items.map((item, itemIndex) => <li key={itemIndex} {...stylex.props(styles.listItem)}>{inline(item, slug, navigate)}</li>)}</List>;
        }
        return (
          <div key={index} {...stylex.props(styles.tableScroll)}>
            <table {...stylex.props(text.body, styles.table)}>
              <thead {...stylex.props(styles.tableHead)}><tr>{block.head.map((cell, cellIndex) => <th key={cellIndex} {...stylex.props(styles.tableCell, styles.tableHeadCell)}>{inline(cell, slug, navigate)}</th>)}</tr></thead>
              <tbody>{block.rows.map((row, rowIndex) => <tr key={rowIndex}>{row.map((cell, cellIndex) => <td key={cellIndex} {...stylex.props(styles.tableCell)}>{inline(cell, slug, navigate)}</td>)}</tr>)}</tbody>
            </table>
          </div>
        );
      })}
    </article>
  );
}

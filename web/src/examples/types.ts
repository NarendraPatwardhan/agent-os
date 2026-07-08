// "AgentOS by Example" — the chapter TOC only (the shell). Section content is
// authored later; this holds just what the marker-scale nav needs.

export type IconId =
  | "play"
  | "terminal"
  | "xlsx"
  | "docx"
  | "pptx"
  | "pdf"
  | "sqlite"
  | "tar"
  | "file"
  | "vector"
  | "github"
  | "microsoft"
  | "google"
  | "graphql"
  | "mcp"
  | "stripe"
  | "fork"
  | "snapshot"
  | "cron"
  | "globe"
  | "lock"
  | "key"
  | "mount"
  | "tools"
  | "luau"
  | "build";

export type Chapter = {
  /** URL-hash target — the chapter you jump to. */
  readonly id: string;
  /** Chapter number, "1".."10". */
  readonly num: string;
  readonly title: string;
  /** One sentence — the chapter's thesis. */
  readonly tagline: string;
  /** Section count (shown in the scale). */
  readonly count: number;
};

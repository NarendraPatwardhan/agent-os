import type { ReactElement } from "react";
import type { IconId } from "./examples/types";

// One small SVG per icon id. File formats get recognizable file-type logos
// (spreadsheet green, word-processor blue, deck orange, PDF red, SQLite blue);
// UI glyphs stay stroke-based on currentColor so they inherit text color.

type IconProps = {
  readonly id: IconId;
  readonly size?: number;
  readonly className?: string;
};

function doc(fill: string, letter: string): ReactElement {
  return (
    <g>
      <path d="M4 1h8.6L17 5.4V19H4z" fill={fill} />
      <path d="M12.6 1L17 5.4h-4.4z" fill="#fff" opacity="0.35" />
      <text x="10" y="14.6" textAnchor="middle" fontSize="8.4" fontWeight="700" fontFamily="system-ui, sans-serif" fill="#fff">
        {letter}
      </text>
    </g>
  );
}

const STROKE = {
  fill: "none",
  stroke: "currentColor",
  strokeWidth: 1.6,
  strokeLinecap: "round",
  strokeLinejoin: "round",
} as const;

const ICONS: Record<IconId, ReactElement> = {
  play: <path d="M6 3.5v13l10.5-6.5z" fill="#3fcf6f" stroke="#3fcf6f" strokeWidth="1.4" strokeLinejoin="round" />,
  terminal: (
    <g {...STROKE}>
      <rect x="2" y="3.5" width="16" height="13" rx="2" />
      <path d="M5.5 8l2.8 2.2L5.5 12.4M10.5 12.8h4" />
    </g>
  ),
  xlsx: (
    <g>
      <path d="M4 1h8.6L17 5.4V19H4z" fill="#1d6f42" />
      <path d="M12.6 1L17 5.4h-4.4z" fill="#fff" opacity="0.35" />
      <path d="M7 8.2l6 7m0-7l-6 7" stroke="#fff" strokeWidth="1.8" strokeLinecap="round" />
    </g>
  ),
  docx: doc("#2b579a", "W"),
  pptx: doc("#c43e1c", "P"),
  pdf: (
    <g>
      <path d="M4 1h8.6L17 5.4V19H4z" fill="#d93831" />
      <path d="M12.6 1L17 5.4h-4.4z" fill="#fff" opacity="0.35" />
      <path d="M6.6 9.4h7.8M6.6 12.2h7.8M6.6 15h5" stroke="#fff" strokeWidth="1.5" strokeLinecap="round" />
    </g>
  ),
  sqlite: (
    <g fill="none" stroke="#4aa8e0" strokeWidth="1.6">
      <ellipse cx="10" cy="4.6" rx="6.4" ry="2.6" fill="#0f80cc" stroke="none" />
      <ellipse cx="10" cy="4.6" rx="6.4" ry="2.6" />
      <path d="M3.6 4.6v10.8c0 1.4 2.9 2.6 6.4 2.6s6.4-1.2 6.4-2.6V4.6M3.6 10c0 1.4 2.9 2.6 6.4 2.6s6.4-1.2 6.4-2.6" />
    </g>
  ),
  tar: (
    <g {...STROKE}>
      <path d="M3 6.2L10 2.8l7 3.4v7.6l-7 3.4-7-3.4z" />
      <path d="M3 6.2l7 3.4 7-3.4M10 9.6v7.6" />
    </g>
  ),
  file: (
    <g {...STROKE}>
      <path d="M5 2h7l4 4v12H5z" />
      <path d="M12 2v4h4" />
    </g>
  ),
  vector: (
    <g fill="currentColor">
      <circle cx="4.6" cy="14.8" r="1.7" />
      <circle cx="8.4" cy="6.2" r="1.7" />
      <circle cx="14.2" cy="10.4" r="1.7" opacity="0.55" />
      <circle cx="16.2" cy="4.4" r="1.7" opacity="0.55" />
      <path d="M5.4 13.4l2.5-5.6" stroke="currentColor" strokeWidth="1.2" opacity="0.6" />
    </g>
  ),
  github: (
    <g>
      <circle cx="10" cy="10.6" r="7.6" fill="#181717" stroke="#8b8d92" strokeWidth="0.9" />
      <path d="M5.4 4.4l2.5 1.2M14.6 4.4l-2.5 1.2" stroke="#8b8d92" strokeWidth="1.4" strokeLinecap="round" />
      <circle cx="7.4" cy="9.8" r="1.1" fill="#e8e8ea" />
      <circle cx="12.6" cy="9.8" r="1.1" fill="#e8e8ea" />
      <path d="M8.2 13.4c1.1.9 2.5.9 3.6 0" stroke="#e8e8ea" strokeWidth="1.2" strokeLinecap="round" fill="none" />
    </g>
  ),
  microsoft: (
    <g>
      <rect x="3" y="3" width="6.6" height="6.6" fill="#f25022" />
      <rect x="10.4" y="3" width="6.6" height="6.6" fill="#7fba00" />
      <rect x="3" y="10.4" width="6.6" height="6.6" fill="#00a4ef" />
      <rect x="10.4" y="10.4" width="6.6" height="6.6" fill="#ffb900" />
    </g>
  ),
  google: (
    <g strokeWidth="2.6" fill="none">
      <path d="M17.2 10a7.2 7.2 0 1 1-2.1-5.1" stroke="none" />
      <path d="M10 2.8a7.2 7.2 0 0 1 5.1 2.1l-2 2A4.4 4.4 0 0 0 10 5.6z" fill="#ea4335" />
      <path d="M4.4 7.7a7.2 7.2 0 0 1 5.6-4.9v2.8a4.4 4.4 0 0 0-3.2 2.5z" fill="#fbbc05" />
      <path d="M4.4 12.3a7.2 7.2 0 0 1 0-4.6l2.4 1.9a4.4 4.4 0 0 0 0 .8z" fill="#fbbc05" />
      <path d="M10 17.2a7.2 7.2 0 0 1-5.6-4.9l2.4-1.9a4.4 4.4 0 0 0 3.2 2.5z" fill="#34a853" />
      <path d="M17.2 10c0 3.6-2.6 6.6-6.2 7.1v-3.3a4.4 4.4 0 0 0 2.9-2.1H10V9h7z" fill="#4285f4" />
    </g>
  ),
  graphql: (
    <g stroke="#e10098" strokeWidth="1.3" fill="none">
      <path d="M10 2.6l6.4 3.7v7.4L10 17.4l-6.4-3.7V6.3z" />
      <path d="M3.6 13.7L16.4 6.3M3.6 6.3l12.8 7.4M10 2.6v14.8" opacity="0.7" />
      <circle cx="10" cy="2.6" r="1.5" fill="#e10098" stroke="none" />
      <circle cx="16.4" cy="6.3" r="1.5" fill="#e10098" stroke="none" />
      <circle cx="16.4" cy="13.7" r="1.5" fill="#e10098" stroke="none" />
      <circle cx="10" cy="17.4" r="1.5" fill="#e10098" stroke="none" />
      <circle cx="3.6" cy="13.7" r="1.5" fill="#e10098" stroke="none" />
      <circle cx="3.6" cy="6.3" r="1.5" fill="#e10098" stroke="none" />
    </g>
  ),
  mcp: (
    <g {...STROKE}>
      <path d="M7 3v4M13 3v4" />
      <path d="M5 7h10v3a5 5 0 0 1-10 0z" />
      <path d="M10 15v3" />
    </g>
  ),
  stripe: (
    <g>
      <rect x="2.5" y="2.5" width="15" height="15" rx="3.4" fill="#635bff" />
      <text x="10" y="14" textAnchor="middle" fontSize="10" fontWeight="700" fontFamily="system-ui, sans-serif" fill="#fff">
        S
      </text>
    </g>
  ),
  fork: (
    <g {...STROKE}>
      <circle cx="6" cy="4.6" r="2" />
      <circle cx="14" cy="4.6" r="2" />
      <circle cx="10" cy="15.4" r="2" />
      <path d="M6 6.6v1.2a4 4 0 0 0 4 4 4 4 0 0 0 4-4V6.6M10 11.8v1.6" />
    </g>
  ),
  snapshot: (
    <g {...STROKE}>
      <circle cx="10" cy="10" r="7.4" />
      <circle cx="10" cy="10" r="2.6" />
      <path d="M10 2.6L12 7.4M17.4 10l-4.8 2M10 17.4L8 12.6M2.6 10l4.8-2" />
    </g>
  ),
  cron: (
    <g {...STROKE}>
      <circle cx="10" cy="10.6" r="6.8" />
      <path d="M10 6.6v4l2.8 1.8M7.4 2.4h5.2" />
    </g>
  ),
  globe: (
    <g {...STROKE}>
      <circle cx="10" cy="10" r="7.4" />
      <path d="M2.6 10h14.8M10 2.6c-4.6 4.6-4.6 10.2 0 14.8 4.6-4.6 4.6-10.2 0-14.8z" />
    </g>
  ),
  lock: (
    <g {...STROKE}>
      <rect x="4.5" y="9" width="11" height="8.5" rx="1.6" />
      <path d="M7 9V6.4a3 3 0 0 1 6 0V9" />
      <circle cx="10" cy="13.2" r="1.1" fill="currentColor" stroke="none" />
    </g>
  ),
  key: (
    <g {...STROKE}>
      <circle cx="6.6" cy="13.4" r="3.6" />
      <path d="M9.2 10.8L16.6 3.4M13.6 6.4l2.4 2.4M11.4 8.6l2 2" />
    </g>
  ),
  mount: (
    <g {...STROKE}>
      <path d="M2.5 5.5a1.5 1.5 0 0 1 1.5-1.5h4l1.8 2h6.7a1.5 1.5 0 0 1 1.5 1.5v8a1.5 1.5 0 0 1-1.5 1.5H4a1.5 1.5 0 0 1-1.5-1.5z" />
      <path d="M10 9v5m0-5l-2 2m2-2l2 2" />
    </g>
  ),
  tools: (
    <g {...STROKE}>
      <path d="M12.4 4a3.8 3.8 0 0 0-4.9 4.6L3 13.1a1.8 1.8 0 1 0 2.6 2.6l4.7-4.6A3.8 3.8 0 0 0 15 6.4l-2.3 2.2-1.7-1.6z" />
    </g>
  ),
  luau: (
    <g>
      <circle cx="10" cy="10" r="7.4" fill="#00227d" />
      <circle cx="13.2" cy="6.8" r="2.4" fill="#fff" />
      <circle cx="16.8" cy="3.4" r="1.1" fill="#00227d" stroke="#8b8d92" strokeWidth="0.7" />
    </g>
  ),
  build: (
    <g {...STROKE}>
      <path d="M3 6.4L10 3l7 3.4-7 3.4z" />
      <path d="M3 10.2l7 3.4 7-3.4M3 14l7 3.4 7-3.4" />
    </g>
  ),
};

export function Icon({ id, size = 18, className }: IconProps) {
  return (
    <svg
      className={className}
      width={size}
      height={size}
      viewBox="0 0 20 20"
      role="img"
      aria-hidden="true"
      focusable="false"
    >
      {ICONS[id]}
    </svg>
  );
}

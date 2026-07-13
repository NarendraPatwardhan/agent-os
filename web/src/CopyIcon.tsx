import type { SVGProps } from "react";

export function CopyIcon({ copied, ...props }: Readonly<{ copied: boolean } & SVGProps<SVGSVGElement>>) {
  return (
    <svg
      width="16"
      height="16"
      viewBox="0 0 20 20"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      {...props}
    >
      {copied ? (
        <path d="m4.5 10.5 3.4 3.4 7.6-7.8" />
      ) : (
        <>
          <rect x="7" y="6" width="9" height="10" rx="1.5" />
          <path d="M13 6V4.5A1.5 1.5 0 0 0 11.5 3h-7A1.5 1.5 0 0 0 3 4.5v8A1.5 1.5 0 0 0 4.5 14H7" />
        </>
      )}
    </svg>
  );
}

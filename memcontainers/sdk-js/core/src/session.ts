import type { ExecOptions } from "./types.js";

export const SESSION_PROMPT_ENV = "MC_SESSION_PROMPT_PATH";

const AGENT_SEGMENT = /^[A-Za-z0-9_.-]+$/;

export function sessionExec(
  agentType: string,
  promptPath: string,
): { cmd: string; opts: ExecOptions } {
  assertSessionAgentType(agentType);
  return {
    cmd: `${agentType} "$${SESSION_PROMPT_ENV}"`,
    opts: { env: { [SESSION_PROMPT_ENV]: promptPath } },
  };
}

export function assertSessionAgentType(agentType: string): void {
  if (!validSessionAgentType(agentType)) {
    throw new Error(
      "agentType must be a bare command or absolute guest path without shell metacharacters",
    );
  }
}

function validSessionAgentType(agentType: string): boolean {
  if (!agentType || agentType.includes("\0")) return false;

  if (!agentType.includes("/")) {
    return validSegment(agentType);
  }

  if (!agentType.startsWith("/")) return false;
  const parts = agentType.split("/").slice(1);
  return parts.length > 0 && parts.every(validSegment);
}

function validSegment(part: string): boolean {
  return (
    part !== "" &&
    part !== "." &&
    part !== ".." &&
    !part.startsWith("-") &&
    AGENT_SEGMENT.test(part)
  );
}

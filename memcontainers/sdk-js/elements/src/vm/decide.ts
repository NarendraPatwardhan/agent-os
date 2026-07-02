// The VM-source resolution policy a bound widget follows, factored out of the Lit
// controller (binding.ts) as a pure function: no DOM, no side effects, so the
// priority order is unit-testable in isolation. VmBinding.decide() calls this and
// then acts on the result.

import type { Vm } from "@mc/core";
import type { VmHost } from "./host.js";

/** Which VM source a bound widget resolves to. */
export type VmSource =
  | { kind: "explicit"; vm: Vm } // an explicit `.vm` property — the app wired one in (highest)
  | { kind: "provided"; host: VmHost } // a VmHost from a wrapping <mc-sandbox>, via context
  | { kind: "standalone" } // boot our own VM — only if the element opts in
  | { kind: "undecided" }; // nothing to bind yet; a late provider can still arrive

export interface DecideInput {
  /** Explicit VM set as a property (highest priority). */
  explicitVm: Vm | undefined;
  /** A VmHost offered by a wrapping provider, if any. */
  providedHost: VmHost | undefined;
  /** Whether this element may boot its own VM when nothing provides one. */
  standaloneAllowed: boolean;
}

/** Resolution priority: explicit `.vm` › provider host › standalone boot › undecided.
 *  The "undecided" result is deliberate: with no provider yet and standalone not
 *  allowed, a provider that connects later can still bind the widget. */
export function decideVmSource(input: DecideInput): VmSource {
  if (input.explicitVm) return { kind: "explicit", vm: input.explicitVm };
  if (input.providedHost) return { kind: "provided", host: input.providedHost };
  if (input.standaloneAllowed) return { kind: "standalone" };
  return { kind: "undecided" };
}

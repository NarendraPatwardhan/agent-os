import { SIDECAR_ERROR_CONTRACT_MISMATCH } from "@mc/contracts/sidecar";
import {
  GUEST_LAYER,
  SidecarError,
  validateSidecarDescriptor,
  type SidecarGrantDescriptor,
} from "./sidecars.js";

function sameBytes(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) return false;
  for (let i = 0; i < left.length; i += 1) {
    if (left[i] !== right[i]) return false;
  }
  return true;
}

function contractKey(descriptor: SidecarGrantDescriptor): string {
  const { kind, version, digest } = descriptor.contract;
  return `${kind}\0${version}\0${digest}`;
}

/** Validate embedded grants before boot and collect their caller-supplied guest layers.
 * One exact sidecar contract may contribute at most one byte-identical layer to a VM. */
export function embeddedGuestLayers(
  descriptors: Readonly<Record<string, SidecarGrantDescriptor>> | undefined,
): Uint8Array[] {
  const byContract = new Map<string, Uint8Array>();
  for (const [name, descriptor] of Object.entries(descriptors ?? {})) {
    validateSidecarDescriptor(name, descriptor, "embedded");
    const layer = descriptor[GUEST_LAYER];
    if (!(layer instanceof Uint8Array)) continue;

    const key = contractKey(descriptor);
    const existing = byContract.get(key);
    if (existing && !sameBytes(existing, layer)) {
      throw new SidecarError(
        SIDECAR_ERROR_CONTRACT_MISMATCH,
        `sidecar grants for '${descriptor.contract.kind}' provide different guest layers`,
      );
    }
    if (!existing) byContract.set(key, layer);
  }
  return [...byContract.values()];
}

import type { Example } from "../types";
import { ProgramDriver } from "./ProgramDriver";
import { CommandsDriver } from "./CommandsDriver";
import { FlavorsDriver } from "./FlavorsDriver";
import { RemoteDriver } from "./RemoteDriver";
import { ProseDriver } from "./ProseDriver";

/** The driver registry: dispatch an example to its component by `kind`. The switch
 *  narrows the discriminated union, so each driver receives its exact variant. Adding
 *  an example kind = a union member (types.ts) + a driver + a case here. */
export function ExampleDriver({ example }: { example: Example }) {
  switch (example.kind) {
    case "program":
      return <ProgramDriver example={example} />;
    case "commands":
      return <CommandsDriver example={example} />;
    case "flavors":
      return <FlavorsDriver example={example} />;
    case "remote":
      return <RemoteDriver example={example} />;
    case "prose":
      return <ProseDriver example={example} />;
  }
}

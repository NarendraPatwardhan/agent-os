import type { Example } from "../types";
import { ProgramDriver } from "./ProgramDriver";
import { CommandsDriver } from "./CommandsDriver";
import { ConnectDriver } from "./ConnectDriver";
import { FlavorsDriver } from "./FlavorsDriver";
import { RemoteDriver } from "./RemoteDriver";
import { FilesDriver } from "./FilesDriver";
import { S3Driver } from "./S3Driver";
import { ApprovalDriver } from "./ApprovalDriver";
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
    case "connect":
      return <ConnectDriver example={example} />;
    case "flavors":
      return <FlavorsDriver example={example} />;
    case "remote":
      return <RemoteDriver example={example} />;
    case "files":
      return <FilesDriver example={example} />;
    case "s3":
      return <S3Driver example={example} />;
    case "approval":
      return <ApprovalDriver example={example} />;
    case "prose":
      return <ProseDriver example={example} />;
  }
}

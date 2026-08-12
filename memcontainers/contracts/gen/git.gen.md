<!-- generated from git.kdl; do not edit -->

# Git engine protocol

Envelope: `AOGQ|AOGR`, version `1.0`, 20-byte little-endian header.

## Operations

| Name | Opcode |
|---|---:|
| `OP_ENGINE_DESCRIBE` | `0x0001` |
| `OP_SESSION_OPEN` | `0x0002` |
| `OP_SESSION_CLOSE` | `0x0003` |
| `OP_REPOSITORY_INIT` | `0x0010` |
| `OP_REPOSITORY_OPEN` | `0x0011` |
| `OP_FILE_STAT` | `0x0100` |
| `OP_FILE_READ` | `0x0101` |
| `OP_FILE_WRITE` | `0x0102` |
| `OP_FILE_REMOVE` | `0x0103` |
| `OP_FILE_RENAME` | `0x0104` |
| `OP_FILE_READDIR` | `0x0105` |
| `OP_STATUS` | `0x0110` |
| `OP_ADD` | `0x0111` |
| `OP_REMOVE` | `0x0112` |
| `OP_COMMIT` | `0x0113` |
| `OP_LOG` | `0x0114` |
| `OP_RESOLVE_REVISION` | `0x0115` |
| `OP_DIFF` | `0x0116` |
| `OP_SHOW` | `0x0117` |
| `OP_CHECKOUT` | `0x0118` |
| `OP_RESET` | `0x0119` |
| `OP_BRANCH` | `0x011a` |
| `OP_TAG` | `0x011b` |
| `OP_CONFIG` | `0x011c` |
| `OP_REMOTE_METADATA` | `0x011d` |
| `OP_IGNORE_QUERY` | `0x011e` |
| `OP_SPARSE` | `0x011f` |
| `OP_SUBMODULE` | `0x0120` |
| `OP_OBJECT` | `0x0200` |
| `OP_REF` | `0x0210` |
| `OP_REF_TRANSACTION` | `0x0211` |
| `OP_PACK_IMPORT` | `0x0220` |
| `OP_PACK_BUILD` | `0x0221` |
| `OP_SHALLOW` | `0x0222` |
| `OP_MOUNT` | `0x0300` |
| `OP_STREAM` | `0x0310` |
| `OP_CLONE` | `0x0400` |
| `OP_FETCH` | `0x0401` |
| `OP_PULL` | `0x0402` |
| `OP_PUSH` | `0x0403` |
| `OP_HTTP_EFFECT` | `0x0410` |
| `OP_REMOTE_CANCEL` | `0x0411` |
| `OP_CHECKPOINT` | `0x0500` |
| `OP_RESTORE` | `0x0501` |

## Payload messages

| Message | ID | Version |
|---|---:|---:|
| `SessionConfig` | `1` | `1` |
| `EngineDescription` | `2` | `1` |
| `ObjectId` | `3` | `1` |
| `Signature` | `4` | `1` |
| `PathList` | `5` | `1` |
| `FileRequest` | `6` | `1` |
| `PorcelainRequest` | `7` | `1` |
| `RefUpdate` | `8` | `1` |
| `StreamRequest` | `10` | `1` |
| `RemoteRequest` | `11` | `1` |
| `HttpEffect` | `12` | `1` |
| `HttpResponse` | `13` | `1` |
| `EngineError` | `14` | `1` |
| `Result` | `15` | `1` |
| `FileResult` | `16` | `1` |
| `StatusEntry` | `17` | `1` |
| `StatusResult` | `18` | `1` |
| `CommitResult` | `19` | `1` |
| `ResolveResult` | `20` | `1` |
| `DirectoryEntry` | `21` | `1` |
| `DirectoryResult` | `22` | `1` |
| `ReferenceResult` | `23` | `1` |
| `ReferenceList` | `24` | `1` |
| `ObjectRequest` | `25` | `1` |
| `ObjectResult` | `26` | `1` |
| `PackRequest` | `27` | `1` |
| `PackResult` | `28` | `1` |
| `SnapshotResult` | `29` | `1` |
| `StreamChunk` | `30` | `1` |
| `MountRequest` | `31` | `1` |
| `RemoteResult` | `32` | `1` |
| `PathQuery` | `33` | `1` |
| `IgnoreResult` | `34` | `1` |
| `RefTransactionRequest` | `35` | `1` |
| `RefTransactionResult` | `36` | `1` |
| `ShallowRequest` | `37` | `1` |
| `ShallowResult` | `38` | `1` |
| `SubmoduleRequest` | `39` | `1` |
| `SubmoduleEntry` | `40` | `1` |
| `SubmoduleResult` | `41` | `1` |

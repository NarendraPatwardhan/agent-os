# Symbol index

Alphabetical lookup for JavaScript runtime exports. Object-shape names are documented on the page that
uses them rather than as TypeScript-only interfaces.

## `@mc/core`

| Symbol                   | Level    | Reference                                                                     |
| ------------------------ | -------- | ----------------------------------------------------------------------------- |
| `capabilityConnection`   | internal | [Advanced API](./advanced-api.md#capabilityconnection)                        |
| `defaultCatalogCompiler` | stable   | [Connections](./connections.md#catalog-compiler)                              |
| `defaultImage`           | stable   | [Installation](./installation.md#default-artifact-loaders)                    |
| `defaultKernel`          | stable   | [Installation](./installation.md#default-artifact-loaders)                    |
| `defaultStore`           | stable   | [Images and stores](./images-stores.md#defaultstore)                          |
| `EmbeddedBackend`        | advanced | [Advanced API](./advanced-api.md#embeddedbackend)                             |
| `FanoutSink`             | advanced | [Advanced API](./advanced-api.md#fanoutsink)                                  |
| `FsContentStore`         | stable   | [Images and stores](./images-stores.md#fscontentstore)                        |
| `kit`                    | stable   | [Host tools](./tools.md#kit-spec)                                             |
| `llb`                    | stable   | [LLB](./llb.md)                                                               |
| `mc`                     | stable   | [`mc`](./mc.md)                                                               |
| `MemoryContentStore`     | stable   | [Images and stores](./images-stores.md#memorycontentstore)                    |
| `OpfsContentStore`       | stable   | [Images and stores](./images-stores.md#opfscontentstore)                      |
| `parseSchedule`          | advanced | [Cron](./cron.md#parseschedule-schedule-utc)                                  |
| `record`                 | stable   | [Recording](./recording-remote-build.md#record-options-and-mc-record-options) |
| `RemoteBackend`          | advanced | [Advanced API](./advanced-api.md#remotebackend)                               |
| `remoteSidecars`         | advanced | [Sidecars](./sidecars.md#remotesidecars-options)                              |
| `remoteBuild`            | stable   | [Remote build](./recording-remote-build.md#remotebuild-input-options)         |
| `SidecarError`           | stable   | [Sidecars](./sidecars.md#sidecarerror)                                        |
| `startCron`              | internal | [Cron](./cron.md#startcron)                                                   |
| `tool`                   | stable   | [Host tools](./tools.md#tool-spec)                                            |
| `Vm`                     | stable   | [`Vm`](./vm.md)                                                               |
| `VmSidecars`             | stable   | [Sidecars](./sidecars.md#vm-sidecars)                                         |
| `z`                      | stable   | [Host tools](./tools.md#z)                                                    |

## `@mc/core/drivers`

| Symbol        | Availability                     | Reference                                                     |
| ------------- | -------------------------------- | ------------------------------------------------------------- |
| `hostDir`     | Node/Bun                         | [Mounts and drivers](./mounts-drivers.md#hostdir-options)     |
| `s3`          | JavaScript fetch/WebCrypto hosts | [Mounts and drivers](./mounts-drivers.md#s3-options)          |
| `vectorStore` | All JS hosts                     | [Mounts and drivers](./mounts-drivers.md#vectorstore-options) |

## `@mc/elements`

Core symbols re-exported by `@mc/elements` link to their owning reference above.

| Symbol                   | Level     | Reference                                                                |
| ------------------------ | --------- | ------------------------------------------------------------------------ |
| `defineElements`         | stable    | [Browser elements](./browser-elements.md#setup)                          |
| `defaultCatalogCompiler` | re-export | [Connections](./connections.md#catalog-compiler)                         |
| `installContextRoot`     | internal  | [Advanced API](./advanced-api.md#installcontextroot)                     |
| `kit`                    | re-export | [Host tools](./tools.md#kit-spec)                                        |
| `llb`                    | re-export | [LLB](./llb.md)                                                          |
| `loadCatalogCompiler`    | advanced  | [Browser elements](./browser-elements.md#loadcatalogcompiler)            |
| `makeVmHost`             | advanced  | [Browser elements](./browser-elements.md#vmhost)                         |
| `mc`                     | re-export | [`mc`](./mc.md)                                                          |
| `McEditor`               | stable    | [Browser elements](./browser-elements.md#mc-editor)                      |
| `McSandbox`              | stable    | [Browser elements](./browser-elements.md#mc-sandbox)                     |
| `McTerminal`             | stable    | [Browser elements](./browser-elements.md#mc-terminal)                    |
| `McXterm`                | stable    | [Browser elements](./browser-elements.md#mc-xterm)                       |
| `MemoryContentStore`     | re-export | [Images and stores](./images-stores.md#memorycontentstore)               |
| `prefetchArtifacts`      | stable    | [Browser elements](./browser-elements.md#prefetchartifacts-kernel-image) |
| `resolveCreateOptions`   | advanced  | [Browser elements](./browser-elements.md#vmhost)                         |
| `s3`                     | re-export | [Mounts and drivers](./mounts-drivers.md#s3-options)                     |
| `setArtifactSources`     | stable    | [Browser elements](./browser-elements.md#setartifactsources-options)     |
| `tool`                   | re-export | [Host tools](./tools.md#tool-spec)                                       |
| `vectorStore`            | re-export | [Mounts and drivers](./mounts-drivers.md#vectorstore-options)            |
| `vmHostContext`          | advanced  | [Browser elements](./browser-elements.md#vmhost)                         |
| `z`                      | re-export | [Host tools](./tools.md#z)                                               |

## Method indexes

- [`mc` methods](./mc.md#method-summary)
- [`Vm` methods](./vm.md#complete-method-index)
- [`vm.fs` methods](./execution-files.md#vm-fs)
- [`llb` graph operations](./llb.md)
- [Custom-element attributes, methods, and events](./browser-elements.md)

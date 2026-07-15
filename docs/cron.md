# Cron

`vm.cron()` schedules host-side work against a live VM handle. It is backend-neutral because every
action uses the public `Vm` surface.

Cron is client-resident, not a durable server scheduler. If the JavaScript process exits, a browser
tab closes, or the VM handle is closed, the job stops.

## `vm.cron(schedule, action, options?)`

```js
const job = vm.cron(
  "0,30 * * * *",
  { type: "exec", cmd: "collect-metrics >> /var/persist/metrics.log" },
  {
    timezone: "utc",
    onError(error) {
      console.error(error);
    },
  },
);
```

## Schedule forms

| Form            | Example         | Meaning                                        |
| --------------- | --------------- | ---------------------------------------------- |
| Milliseconds    | `5000`          | Fixed interval                                 |
| Interval string | `"@every 30s"`  | Fixed wall-clock duration                      |
| Cron expression | `"0 9 * * 1-5"` | Five fields: minute, hour, day, month, weekday |
| Macro           | `"@daily"`      | Named cron expression                          |
| One shot        | `"@reboot"`     | Run once on the next event-loop turn           |

Intervals accept `ms`, `s`, `m`, `h`, `d`, and `w`, including compounds such as `1h30m`.

Cron fields support `*`, `?`, comma lists, ranges, and `/step`. `?` is accepted as the unrestricted
value for day-of-month or day-of-week. Three-letter month and weekday names are accepted.
Supported macros include `@hourly`, `@daily`, `@midnight`, `@weekly`, `@monthly`, `@yearly`, and
`@annually`.

## Actions

### Exec action

```js
{ type: "exec", cmd: "refresh-cache" }
```

The run result contains `exec`, an ordinary `ExecResult`. A nonzero command exit is still a completed
action; inspect it in `onRun` if failure should be escalated.

### Session action

```js
{ type: "session", prompt: "Process the next item", agentType: "agent" }
```

The run result contains the prompt's `session` event list.

### Callback action

```js
async (liveVm) => {
  const status = await liveVm.status();
  console.log(status);
};
```

The callback receives the live `Vm` and may use any method. Its result is not retained in
`CronRunResult`.

## Options

| Field       | Default   | Meaning                                              |
| ----------- | --------- | ---------------------------------------------------- |
| `immediate` | `false`   | Fire once on the next turn, then continue scheduling |
| `maxRuns`   | unlimited | Stop after this many firings                         |
| `timezone`  | `"local"` | Interpret cron expressions in local time or UTC      |
| `onRun`     | none      | Called after a successful action                     |
| `onError`   | none      | Called when an action throws                         |

Timezone does not affect interval schedules. A throwing action does not kill a repeating job. Without
`onError`, that exception is swallowed so later firings still occur.

## `CronHandle`

| Member     | Meaning                                |
| ---------- | -------------------------------------- |
| `id`       | Unique client-side job id              |
| `schedule` | Registered string, or `<number>ms`     |
| `runs`     | Number of firings started              |
| `stopped`  | Whether the job is permanently stopped |
| `next()`   | Next `Date`, or `null`                 |
| `stop()`   | Idempotently stop and clear the timer  |

```js
console.log(job.id, job.next());
job.stop();
```

`vm.close()` stops every job registered through that VM.

## `parseSchedule(schedule, utc)`

Advanced helper used by `vm.cron()`. It validates a schedule and returns an internal parsed schedule
record. Because that return shape is not part of the stable root type surface, applications should
normally let `vm.cron()` parse and reject invalid configuration.

## `startCron`

The root exports `startCron`, but it is an internal implementation hook. Calling it directly
bypasses the VM's job registry, so `vm.close()` would not own cleanup in the normal way. It is
classified as internal and should not be used by clients.

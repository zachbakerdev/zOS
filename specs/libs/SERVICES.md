# zOS Services Library Specification

`require("services")` runs background work alongside the session, even while nobody is logged in. Apps normally get a service by including `service.lua`, as described in [APPS.md](APPS.md). System libraries use this library directly.

The key words MUST, MUST NOT, SHOULD and MAY are used as in RFC 2119.

## Methods

| Method                          | Returns                                                         |
| ------------------------------- | --------------------------------------------------------------- |
| `services.start(id, fn, ...)`   | Nothing. Runs `fn(...)` under `id`, replacing any service with that id |
| `services.stop(id)`             | Nothing. Stops the service, if it's running                     |
| `services.isRunning(id)`        | Whether a service with that id is running                       |
| `services.list()`               | The running ids, oldest first                                   |
| `services.run()`                | Doesn't return. Runs every service                              |

`services.run` belongs to the boot sequence, which runs it next to the session loop. Other code MUST NOT call it.

Starting and stopping can be done from anywhere, including from a service. A service that's stopped never runs again, and it gets no chance to tidy up.

There MUST be only one copy of this library on a computer, because it keeps the running services in a local table. A second copy couldn't see them, and anything it started would never run.

## Ids

An app's service runs under the app's id. System services use a prefix, which can't clash because `:` isn't allowed in an app id.

| Id             | Service                                     |
| -------------- | ------------------------------------------- |
| `zos:update`   | Looks for updates. See [UPDATE.md](UPDATE.md) |
| `net:receiver` | Queues incoming packets. See [NET.md](NET.md) |
| `net:worker`   | Handles packets and outgoing messages       |
| `net:renewer`  | Renews certificates                         |

## How services run

A service is a coroutine. Each one runs in turn, in the order they were started, each time an event arrives, as long as it's waiting for that event or for any event.

- **Yielding.** A service gets its turn only when the one before it yields, so a service MUST NOT work for long without yielding. While it works, the session can't respond.
- **Starting.** A new service starts with the next event. `services.start` queues one to make sure there is a next event.
- **Ctrl+T.** Services never see `terminate`. Ctrl+T belongs to whatever is on the screen.
- **Drawing.** Anything a service draws goes to a hidden window. The session's screen MUST NOT be disturbed.
- **Crashing.** A service that raises an error is logged and stopped, and doesn't affect the session or other services. It isn't restarted.
- **Finishing.** A service whose function returns is removed without any message.

Services share one set of events with the session, so a service MUST NOT discard events that others need. Queuing an event reaches every service and the session.

# lux

A service supervisor and init system in Lua.

Uses [libimsg](https://github.com/mischief/libimsg) (OpenBSD imsg) for IPC
between the daemon and control tool.

## Quick Start

### Building

```
meson setup build
ninja -C build
```

Requires: lua 5.4+, luaposix, libimsg (Lua binding)

### Creating a Service

Create `/etc/lux/services/hello.lua`:

```lua
service "hello" {
    cmd = { "/usr/bin/hello-daemon", "-f" },
    restart = true,
}
```

### Boot Sequence

When running as PID 1, luxd:

1. Mounts essential filesystems (`/proc`, `/sys`, `/dev`, `/tmp`, `/run`)
2. Sets default `PATH`
3. Loads service definitions from `/etc/lux/services/*.lua`
4. Starts all services (respecting dependencies)
5. Enters main loop (supervise, accept control commands)

## Service Definition Reference

Services are defined using a Lua DSL in files under `/etc/lux/services/`:

```lua
service "name" {
    -- fields
}
```

Multiple services can be defined in one file.

### Fields

| Field | Type | Description |
|-------|------|-------------|
| `cmd` | table | Command argv: `{ "/path/to/bin", "arg1", "arg2" }` |
| `run` | function | Inline Lua function (executed via `luxd-run` in clean interpreter) |
| `restart` | bool | Restart on exit (default: false) |
| `depends` | table | List of service names that must be ready first |
| `tty` | string | Attach stdin/stdout/stderr to this device (e.g. `"/dev/console"`) |
| `env` | table | Extra environment variables: `{ KEY = "value" }` |
| `socket` | table | Socket activation config (see below) |
| `style` | string | Socket style: `"activate"` or `"inetd"` |

### Service Types

**Long-running** — supervised, restarted on exit:

```lua
service "sshd" {
    cmd = { "/usr/sbin/sshd", "-D" },
    restart = true,
}
```

**Oneshot** — runs once, dependents wait for completion:

```lua
service "lo-setup" {
    cmd = { "/usr/sbin/net-setup", "lo" },
}
```

**Target** — milestone with no command, ready when deps are satisfied:

```lua
service "network" {
    depends = { "lo-setup", "dhclient" },
}
```

**Inline** — Lua function executed in a clean interpreter via `luxd-run`:

```lua
service "hostname" {
    run = function()
        local sys = require("lux.sys")
        sys.sethostname("myhost")
    end,
}
```

**Socket-activated (activate)** — luxd holds the socket, starts service on
first connection, passes listen fd as fd 3 with `LISTEN_FDS=1`:

```lua
service "httpd" {
    cmd = { "/usr/sbin/httpd" },
    socket = { family = "inet", type = "stream", port = 80 },
    style = "activate",
    restart = true,
}
```

**Socket-activated (inetd)** — luxd accepts connections, forks per-connection
with stdin/stdout connected to the client:

```lua
service "echo" {
    cmd = { "/bin/cat" },
    socket = { family = "inet", type = "stream", port = 7 },
    style = "inetd",
}
```

### Socket Configuration

| Field | Values |
|-------|--------|
| `family` | `"inet"`, `"unix"` |
| `type` | `"stream"` (TCP), `"dgram"` (UDP) |
| `port` | Port number (inet only) |
| `addr` | Bind address (default `"0.0.0.0"`) |
| `path` | Socket path (unix only) |
| `backlog` | Listen backlog (default 128) |

### Dependency Resolution

Services start in dependency order. A dependency is satisfied when:

- Long-running service: process has been forked
- Oneshot service: process exited with status 0
- Target: all its own dependencies are satisfied
- Socket-activated: socket is created (before service starts)

## Control Tool

```
luxctl status            # show all services
luxctl start <name>      # start a service
luxctl stop <name>       # stop a service
luxctl restart <name>    # restart a service
luxctl shutdown          # stop all services, power off
```

Options:

- `-s <path>` — control socket path (default `/run/lux.sock`)

## Architecture

### Components

```
luxd        PID 1 supervisor daemon
luxctl      Control tool (connects via Unix socket)
luxd-run    Helper: executes service run functions in clean interpreter
logd        System log daemon (socket-activated)
lux.sys     Native C module (setsid, mount, reboot, set_ctty, etc.)
lux.rpc     Shared IPC protocol (imsg message types, connect/accept/reply)
```

### Main Loop

luxd uses `poll(2)` on three fd classes simultaneously:

- **Control socket** (`/run/lux.sock`) — accepts luxctl connections
- **SIGCHLD self-pipe** — wakes on child exit for immediate reaping
- **Service listen sockets** — triggers socket activation

### Process Lifecycle

When starting a service with `cmd`:

1. `fork()`
2. `setsid()` — new session, new process group
3. Open and attach `tty` if specified (open → `TIOCSCTTY` → `dup2`)
4. Set environment variables
5. `execp(cmd[1], args)`

When starting a service with `run`:

1. `fork()`
2. `setsid()`
3. `execp("luxd-run", {service_file, service_name})`
4. luxd-run loads the file in a fresh interpreter and calls `run()`

### Shutdown

1. `luxctl shutdown` sends `MSG_SHUTDOWN` via imsg
2. luxd sends `SIGTERM` to all service process groups (`kill(-pid)`)
3. Waits up to 5 seconds for exits
4. Sends `SIGKILL` to stragglers
5. Calls `reboot(RB_POWER_OFF)` if PID 1

### IPC Protocol

Communication between luxctl and luxd uses imsg over a Unix stream socket
at `/run/lux.sock`. Message types are defined in `lux/rpc.lua`:

| Type | Direction | Payload |
|------|-----------|---------|
| START | ctl→d | service name |
| STOP | ctl→d | service name |
| RESTART | ctl→d | service name |
| STATUS | ctl→d | (empty) |
| SHUTDOWN | ctl→d | (empty) |
| ACK | d→ctl | result string |

### Native Module (lux.sys)

Exposes Linux syscalls not available in luaposix:

- `setsid()` — create new session
- `mount(source, target, fstype, flags, data)` — mount filesystem
- `umount(target)` — unmount
- `reboot(cmd)` — reboot/halt/poweroff
- `sethostname(name)` — set hostname
- `set_ctty(fd)` — make fd the controlling terminal (TIOCSCTTY)
- `setrlimit(resource, soft, hard)` — set resource limits
- `getrlimit(resource)` — get resource limits
- `prctl(option, ...)` — process control

Constants: `MS_RDONLY`, `MS_NOSUID`, `MS_NODEV`, `MS_NOEXEC`, `MS_REMOUNT`,
`RB_AUTOBOOT`, `RB_HALT_SYSTEM`, `RB_POWER_OFF`, `RLIMIT_*`, `PR_SET_NAME`, etc.

## Bundled Services

### logd

System log daemon. Reads from `/dev/log` (socket-activated) and `/dev/kmsg`.
Writes to `/var/log/messages` with timestamps and facility.severity tags.

Log rotation: every hour or 10MB, keeps `.0` through `.9`.

```lua
service "logd" {
    cmd = { "/usr/sbin/logd" },
    socket = { family = "unix", path = "/dev/log", type = "dgram" },
    style = "activate",
    restart = true,
}
```

Because `/dev/log` is created by luxd (socket activation), services can
write syslog messages immediately at boot — they queue in the kernel
socket buffer until logd starts reading.

### console

Auto-login root shell on the console:

```lua
service "console" {
    cmd = { "/bin/sh" },
    tty = "/dev/console",
    restart = true,
    env = { HOME = "/root", USER = "root", TERM = "linux" },
}
```

## Configuration

### luxd Options

```
luxd [-s sock_path] [-d services_dir]
```

| Option | Default | Description |
|--------|---------|-------------|
| `-s` | `/run/lux.sock` | Control socket path |
| `-d` | `/etc/lux/services` | Service definitions directory |

### Meson Build Options

| Option | Default | Description |
|--------|---------|-------------|
| `lua` | `lua5.4` | Lua pkg-config name |
| `lua_version` | (auto) | Lua version for module paths |
| `as_init` | `false` | Install `/sbin/init` → `luxd` symlink |

## License

ISC — Copyright 2026 Nick Owens <mischief@offblast.org>

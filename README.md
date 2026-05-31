# lux

A service supervisor and init system in Lua, using [libimsg](https://github.com/mischief/libimsg) for IPC.

## Architecture

```
luxd (PID 1)                          luxctl (control tool)
    │                                      │
    │  Unix socket: /run/lux.sock          │
    │◄─────────── imsg ──────────────────►│
    │                                      │
    ├── mount filesystems                  luxctl start sshd
    ├── run /etc/lux/boot                  luxctl stop dhclient
    ├── supervise /etc/lux/services/*.lua  luxctl status
    ├── reap orphans                       luxctl restart network
    └── shutdown on signal                 luxctl shutdown
```

## Service Definition

Services are Lua files in `/etc/lux/services/`:

```lua
-- /etc/lux/services/syslogd.lua
return {
    name = "syslogd",
    cmd = { "/usr/sbin/syslogd", "-n" },
    restart = true,
}
```

```lua
-- /etc/lux/services/dhclient.lua
return {
    name = "dhclient",
    cmd = { "/usr/sbin/dhclient", "-f", "eth0" },
    restart = true,
    depends = { "syslogd" },
    env = { INTERFACE = "eth0" },
}
```

```lua
-- /etc/lux/services/getty.lua
return {
    name = "getty",
    cmd = { "/sbin/getty", "38400", "ttyS0" },
    restart = true,
}
```

## Usage

```
luxctl status            # list all services
luxctl start <name>      # start a service
luxctl stop <name>       # stop a service
luxctl restart <name>    # restart a service
luxctl shutdown          # stop all services and halt
```

## Building

Requires: lua5.4, luaposix, libimsg

```
meson setup build
ninja -C build
ninja -C build install
```

## License

ISC — Copyright 2026 Nick Owens <mischief@offblast.org>

-- console service definition for lux
service "console" {
    cmd = { "/bin/sh" },
    tty = "/dev/console",
    restart = true,
    env = { HOME = "/root", USER = "root", TERM = "linux" },
}

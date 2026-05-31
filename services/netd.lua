-- netd service definition for lux
service "netd" {
    cmd = { "/usr/sbin/netd", "eth0" },
    restart = true,
}

-- logd service definition for lux
service "logd" {
    cmd = { "/usr/sbin/logd" },
    socket = { family = "unix", path = "/dev/log", type = "dgram" },
    style = "activate",
    restart = true,
}

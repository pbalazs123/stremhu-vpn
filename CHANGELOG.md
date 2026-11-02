# Changelog

Release notes of StremHU VPN.

## 0.1.0

The first release: a guided installer that puts an existing StremHU Source container behind a PIA WireGuard VPN.

- **Works with your setup.** Compose folders get files added beside yours; `docker run` and other tools get a new stack from the container's real settings.
- **Tests itself.** It checks the tunnel, public IP, web port and forwarded port, and cuts the tunnel to prove nothing gets out.
- **Rolls back.** A failed check or a stopped install puts the original setup back.
- **Uninstall.** One command restores the original setup. Your volumes are never touched.

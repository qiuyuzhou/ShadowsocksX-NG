# Four-way listener mode

**Status**: accepted

Replace the former loopback/host choice with one independently saved listener mode shared by the SOCKS and HTTP inbounds. The dialog uses these labels and bindings:

| Option | Binding | `ipv6_only` | HTTP proxy command host |
| --- | --- | --- | --- |
| 仅本机 | `127.0.0.1` | — | `127.0.0.1` |
| 所有 IPv4 接口 | `0.0.0.0` | — | `127.0.0.1` |
| 所有 IPv4 与 IPv6 接口 | `::` | `false` | `127.0.0.1` |
| 仅所有 IPv6 接口 | `::` | `true` | `::1` (bracketed in a URL) |

The dialog's outer row shows only the selected label; each choice includes a subdued binding-address hint. Saving commits this item alone and requests runtime application. If the agent is running, listener changes restart `sslocal`; if it is off, saving does not start it. A known external port conflict blocks saving, the current runtime's own listener is eligible for replacement by the restart, and unknown occupancy warns but does not block. The IPv6 occupancy probe must cover the selected family.

The pinned `sslocal` v1.25.0 exposes `ipv6_only` as a top-level option for listeners bound to `::`, so the two IPv6 modes set it explicitly. Include this setting in runtime identity so switching dual-stack and IPv6-only restarts listeners even though the address remains `::`. Update local health checks and system-proxy targets to use an address family accepted by the selected mode; IPv6-only uses `::1`. Verify the dual-stack and IPv6-only behavior on supported macOS versions before claiming runtime support. [Upstream configuration](https://github.com/shadowsocks/shadowsocks-rust/blob/v1.25.0/README.md), [configuration source](https://github.com/shadowsocks/shadowsocks-rust/blob/v1.25.0/crates/shadowsocks-service/src/config.rs), [listener source](https://github.com/shadowsocks/shadowsocks-rust/blob/v1.25.0/crates/shadowsocks-service/src/local/mod.rs).

The HTTP proxy environment command is local-terminal convenience, not a device-sharing feature: it uses `127.0.0.1` for the first three modes and `::1` for IPv6-only. Remove the manual advertised IPv4 address because no remaining feature consumes it. Show a no-auth, all-interfaces exposure warning in the dialog for the three non-loopback modes, without an extra confirmation.

Persistence success and runtime convergence remain separate. A saved mode is retained after restart failure; the settings view and editor handle persistence outcomes only, while the proxy status UI reports whether the agent restarted and its current state.

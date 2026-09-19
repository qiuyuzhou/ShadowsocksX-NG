# ShadowsocksX-NG domain context

## Vocabulary

- **Server configuration**: The user-visible connection data for one Shadowsocks server. It is a leaf in the configuration tree.
- **Configuration group**: A named, ordered container that may contain server configurations and nested configuration groups.
- **Manual group**: A configuration group whose membership is edited by the user.
- **Subscription**: A remote configuration source identified by a subscription URL and refreshed over time.
- **Subscription group**: The fixed configuration group owned by one subscription. Refreshing a subscription updates this group and must not change manual groups.
- **Active target**: The server configuration or configuration group currently selected for proxying.
- **Proxy mode**: The user-facing way traffic is routed through the local proxy, such as PAC, global, manual, or an external PAC configuration.
- **Legacy configuration**: The server list and preferences persisted by the frozen implementation in `Legacy/`.

## Relationships and invariants

- A configuration group may be nested to arbitrary supported depth, but its tree must remain acyclic.
- A server configuration has a stable identity independent of its display name and position.
- Activating a server selects that one server; activating a group selects the valid descendant server configurations as a set for the external proxy service.
- A subscription owns its subscription group and its refreshed members; manual groups remain user-owned.
- Legacy server configurations migrate into a separate manual group, preserving stable server identities where the legacy data provides them.
- The GUI is the user-facing manager; the Shadowsocks tunnel service is an external runtime boundary rather than part of the GUI's domain model.

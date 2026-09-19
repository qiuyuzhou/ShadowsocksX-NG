# ShadowsocksX-NG domain context

## Vocabulary

- **Configuration catalog**: The non-user-visible root of the 2.0 configuration tree. Its ordered top-level children may be server configurations or configuration groups.
- **Server configuration**: The user-visible connection data for one Shadowsocks server. It is a leaf with an opaque, persistent UUID and a source owner.
- **Configuration group**: A named, ordered container that may contain server configurations and nested configuration groups. A node has at most one parent, and group membership forms an acyclic tree.
- **Manual group**: A configuration group owned by the user. It may contain only manually owned nodes; deleting it recursively deletes its descendants, with a second confirmation when it is non-empty.
- **Subscription**: A remote configuration source with a persistent opaque UUID and a fixed subscription-group identity. Its URL is a mutable endpoint/credential reference; editing the URL keeps the source identity, while deleting and creating a subscription establishes a new source identity.
- **Subscription group**: The fixed, source-owned configuration subtree provided by one subscription. Users cannot move or structurally edit its nodes. A subscription node's user-visible name/remark is one remote-derived value from `remarks`, falling back to the server address when absent; it has no local alias or note override. Local enablement remains a separate eligibility state.
- **Active target**: The persisted server configuration or configuration group selected for proxying. When a group is active, the group UUID remains the target even when `sslocal` chooses an individual descendant server.
- **Enabled**: A local eligibility state on a server configuration or configuration group. A node is effectively enabled only when it and every group ancestor are enabled.
- **Proxy mode**: The user-facing way traffic is routed through the local proxy, such as PAC, global, manual, or an external PAC configuration.
- **HTTP proxy mode**: A local proxy mode that accepts HTTP/HTTPS proxy requests directly through the Shadowsocks runtime; it does not require a separate adapter process.
- **Legacy Privoxy adapter**: The frozen implementation's HTTP(S)-to-local-SOCKS5 bridge. It is a Legacy-only dependency and is not migrated into 2.0.
- **Listen scope**: A user-facing two-state choice of whether the locally provided proxy endpoints — the PAC HTTP endpoint and the external tunnel service's inbound listeners — bind to loopback only or to the host's network-facing address. The host-facing scope intentionally exposes an unauthenticated local proxy to other devices on the network, so users can share the PAC URL or proxy address to machines other than this one.
- **Proxy runtime**: The per-user background host process, independent of the GUI's lifetime, that hosts the locally provided proxy endpoints: it runs the external tunnel service and serves the PAC HTTP endpoint.
- **Legacy configuration**: The server list and preferences persisted by the frozen implementation in `Legacy/`.
- **Legacy import**: The user-confirmed, read-only translation of a Legacy configuration snapshot into a separate manual group in 2.0. It neither starts proxying nor alters the Legacy source.
- **Legacy handoff**: The separately confirmed transfer of proxy operation from Legacy to 2.0. It retires only positively identified Legacy runtime components while retaining Legacy data for rollback.
- **Runtime configuration file**: The derived JSON document used by the external tunnel service for the active target; it is not the user-managed server configuration or subscription document.
- **Sensitive information**: Server passwords, plugin options that contain credentials, and nonempty user-provided remote URLs, including subscription, external PAC, and custom GFW List URLs.
- **Credential exposure boundary**: This product reduces accidental disclosure and exposure to other user accounts, but does not guarantee protection against a compromised same-user process, root access, or APFS snapshots and backups; it does not promise secure erasure.
- **Credential reference**: A non-secret association from a server configuration, subscription, or remote-URL setting to its durable credential; the credential value is kept outside the configuration tree and resolved only when needed.

## Relationships and invariants

- Top-level catalog children may be server configurations or groups; there is no artificial user-visible “uncategorized” group.
- Server and group identities are opaque, persistent UUIDs independent of display name, position, or parent; IDs are not reused for another logical node.
- Each group stores an explicit child order. A node cannot be shared by multiple groups, and group edges must remain acyclic.
- Manual and subscription ownership form separate subtrees; a manual group cannot adopt subscription-owned nodes, and subscription-owned nodes cannot be moved into manual groups.
- New manual servers always receive a new UUID rather than being deduplicated by endpoint or serialized content; Legacy migration preserves an available legacy UUID.
- Effective enablement excludes a disabled group and its subtree or a disabled server leaf from activation.
- Activating a server selects that one server. Activating a group recursively expands effectively enabled server leaves in explicit child order and passes them to the external proxy service; an empty result or an invalid enabled leaf rejects activation atomically.
- The active target remains the selected node ID and is not silently replaced by a descendant chosen by `sslocal`. If it is deleted, disabled, empty, or invalid, the target is cleared and proxying stops rather than falling back silently.
- After a committed edit to the active target's subtree, the target is re-expanded immediately: a valid non-empty result updates the runtime atomically; an empty or invalid result clears the target and stops proxying without fallback.
- Manual nodes may move between the catalog root and manual groups, carrying their subtree and child order without changing identity or ownership; cross-source moves, shared parents, and cycles are rejected.
- Empty groups may persist and remain editable, but cannot be activated. Deleting a non-empty manual group recursively deletes its descendants and requires a second confirmation.
- A subscription owns its subscription group and its refreshed members; manual groups remain user-owned. Remote connection fields, membership, structure, order, and `remarks` are authoritative; only local enablement may be retained as a per-node overlay for a matched subscription identity.
- Subscription server and nested-group identities use provider-supplied stable IDs scoped to that subscription. When a remote record has no stable ID, continuity is allowed only for an exactly matching canonical record; endpoint, name, or path heuristics must not merge identities.
- Subscription-owned nodes and nested groups permit no local connection-field, name/remark, membership, parent, or order override. A matched remote node or group may retain only its local `enabled` state; new records default to enabled, and removed records lose their overlays rather than leaving tombstones.
- Each subscription refresh is a complete, validated snapshot committed atomically. A valid empty snapshot replaces the remote subtree with an empty group; transport, HTTP/authentication, decoding, schema, duplicate-ID, cycle, or record-validation failures leave the last successful snapshot, local enablement, active target, and runtime state unchanged while marking the source stale. An initial failed refresh leaves an empty group with an error state.
- Editing a subscription URL keeps the subscription, fixed group, and remote identity namespace; the last successful snapshot remains available until the new URL succeeds. To isolate a different source, delete the old subscription and create a new one. Deleting a subscription removes its source, fixed group, remote members, and local overlays after explicit confirmation; an active target is cleared and proxying stops without fallback.
- A Legacy import reads a current snapshot and commits atomically; skipping leaves an import entry available, success prevents automatic repetition, and an explicitly requested re-import creates a separate manual group.
- A unique, syntactically valid Legacy server UUID is preserved. An otherwise valid server with a missing, malformed, or duplicate UUID receives a fresh UUID; invalid records are omitted with a user-visible report, and an active target is kept only when it maps unambiguously.
- Imported mode and target preferences never start proxying or write system proxy settings. Legacy passwords, plugin options, and user-provided remote URLs move to credential references; generated configurations, caches, diagnostics, logs, and binaries do not migrate.
- A Legacy handoff is an explicit second phase, not an import side effect. It may stop only positively identified Legacy runtime jobs after confirmation and must not broadly kill processes or automatically delete Legacy data.
- The PAC HTTP endpoint and the external tunnel service's inbound listeners follow one shared listen scope, so a PAC URL or proxy address shared to another machine always points at a reachable proxy; loopback is the default scope.
- The ports of the locally provided proxy endpoints are explicit user configuration: the system never rewrites a port on its own, and a port conflict rejects proxy start with an error naming the endpoint until the user explicitly chooses a new port.
- The PAC HTTP endpoint and the external tunnel service start and stop together inside the proxy runtime: both are reachable exactly while proxying is on, and neither depends on the GUI being open. The GUI writes the system proxy configuration and gates that write on endpoint health.
- The GUI is the user-facing manager; the Shadowsocks tunnel service is an external runtime boundary rather than part of the GUI's domain model.

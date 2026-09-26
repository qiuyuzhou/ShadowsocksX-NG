# Remove manual proxy mode and external PAC

**Status**: accepted; mode-set scope superseded by ADR-0009

Remove `ProxyMode.manual` and `ProxyMode.externalPAC`, including the external PAC URL setting, Keychain reference, validation, health-check path, and related UI and presentation surfaces; retain manual catalog groups and servers, local PAC, PAC user rules, and the GFW List URL. At the time of this decision, local PAC and global SOCKS were the supported system proxy modes. ADR-0009 adds direct ACL mode while keeping these removals in force. The affected NG2 version has not shipped, so no persisted-settings migration or upgrade transition is required.

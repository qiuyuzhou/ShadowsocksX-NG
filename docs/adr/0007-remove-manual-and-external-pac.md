# Remove manual proxy mode and external PAC

**Status**: accepted

NG2 supports only local PAC and global SOCKS as system proxy modes. Remove `ProxyMode.manual` and `ProxyMode.externalPAC`, including the external PAC URL setting, Keychain reference, validation, health-check path, and related UI and presentation surfaces; retain manual catalog groups and servers, local PAC, PAC user rules, and the GFW List URL. The affected NG2 version has not shipped, so no persisted-settings migration or upgrade transition is required.

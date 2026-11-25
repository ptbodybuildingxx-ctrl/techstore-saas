# Shared SaaS launch gates
DEVELOPMENT — no paying customers or commercial authorization.
- [x] Adopt shared-project architecture and preserve original database.
- [x] Apply initial tenant registry, membership and product/stock isolation.
- [x] Test synthetic users and two synthetic tenants through database assertions; roll back fixtures.
- [ ] Test actual Auth sessions and tenant switching in browser.
- [ ] Port all ten original modules, transactional accounting, invoices, returns, loyalty, repair and inventory flows; parity and concurrency tests.
- [ ] Implement tenant-specific user/role management, file access and public storefront isolation.
- [ ] Implement commercial entitlement and verified payment integration; all write paths fail closed.
- [ ] Replace dedicated project-dependent update, backup, export and restoration workflows.
- [ ] Verify backup and restore, access revocation, performance, resource quotas, legal terms, private source and support.
- [ ] Activate king securely and publish only after all gates pass.

# Commercial launch gates

Status: DEVELOPMENT — no live commercial deployment or paying customers.

- [x] Fork development from shop 6.3.8; keep main unchanged.
- [x] Select managed single-tenant architecture with separate project and dedicated origin per business.
- [x] Remove live shop backend from the development workspace.
- [x] Implement a validated, allowlisted store UI build tool.
- [x] Draft separate control-plane schema and tenant membership RLS.
- [ ] Execute schema on dedicated control-plane project and test with operator, two stores, revoked session and anonymous actor.
- [ ] Provision two independent test shop projects from migrations; verify no common data, credentials, auth, storage or browser cache.
- [ ] Replace all remaining static project-specific references in deployment dependencies; run full builder and Node suite.
- [ ] Implement platform operator UI, audited provisioning and subscription activation.
- [ ] Bind subscription entitlement to each store's trusted server-side write boundaries; keep safe data export available on suspension.
- [ ] Implement verified payment provider webhooks with event deduplication and refunds; never trust browser payment claims.
- [ ] Test activation, expiry, renewal, cancellation, payment failure and tenant-specific backup/restore.
- [ ] Complete previous TechStore stability/security gates, including real concurrent checkout, MFA and restore.
- [ ] Establish private commercial source repository, legal license/terms, privacy policy, support and hosting costs.

Do not advertise this branch as ready to sell. Public plan prices are proposed USD amounts, not an active billing contract. Never commit real customer data, credentials, or service keys.

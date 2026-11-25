# Shared SaaS launch gates
DEVELOPMENT — no commercial authorization.
- [x] Shared-project architecture, tenant registry, role isolation and development trials.
- [x] SQL rollback fixtures for cash/credit sales, returns, currencies, supplier purchases, repair workflow, storefront pickup orders, warranty, mixed tender, historical cost reports, and paid-entitlement boundary.
- [x] SQL shared backup and release coordination, offline encrypted bundle integrity verification, offline webhook signature verification.
- [x] Synthetic 100,000-row temporary placement index query (100-row keyset page, index scan; no persistent data or concurrent users).
- [ ] Complete real-browser Auth, customer checkout, admin license/recovery UI and operational role tests; no accounts exist.
- [ ] Complete accounting and tax-specific invoicing, general ledger/reconciliation, shipping/payment integration, repair reversals and warranty parts, original module parity including Storage/loyalty.
- [ ] Confirm jurisdiction/provider eligibility; configure payment processor test environment, retrieve and reconcile actual payment/refund/dispute events, deploy trusted worker, and validate subscription renewal/expiry; live billing remains false.
- [ ] Capture actual database/Storage/config, restore and independently reconcile in isolated environment; configure automated backups, deployment and rollback worker.
- [ ] Concurrent end-to-end workload tests with representative stores/operations, monitoring, security review, resource/cost limits, privacy/legal/support.
- [ ] Activate king securely; separate authorized commercial hosting and launch approval. GitHub Pages remains offline showcase only.

## Closure batch — 2026-11-25
- [x] Integrated SQL rollback fixture (purchase batch, stock, online delivery, customer/supplier return, receipt lines, repair invoice, warranty replacement, refund, cash, gross margin and trial balance), stored at `saas/tests/sql/integrated-commerce.sql`.
- [x] Audited plan price administration; changes are blocked when live billing or any provider binding exists.
- [x] Shared recovery planning UI uses shared-shard endpoints, not a backup executor.
- [ ] Verify signup/recovery email delivery, OTP templates, CAPTCHA/rate limits and origin. Client code gated off by default.
- [ ] High-resolution Storage, freeform editor, verified custom-domain routing, coupon redemption/loyalty, jurisdiction-specific tax and consolidated statutory financial reporting remain incomplete.
- [ ] Browser print/receipt tests, actual auth, actual recovery and concurrent workload remain unverified.

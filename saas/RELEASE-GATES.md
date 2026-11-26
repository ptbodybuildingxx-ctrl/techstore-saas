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

## Closure-stage evidence
Integrated rollback SQL fixture: saas/tests/sql/integrated-commerce.sql. Management statements, coupon and media reservation migrations applied to shared development database. Real browser, printer, email delivery, actual Storage object upload/download, public high-resolution serving, private domain DNS/TLS/routing, country-specific tax and statutory accounting remain gates. No commercial authorization or paid service activation.

## Software closure batch (035–039)
- [x] Order-earned nontransferable points, reserve/release/redeem, return reversal, owner policy, buyer UI and rollback verification.
- [x] Typed responsive grid spans, per-block alignment/padding/image fit/heading, copy and cross-page move, legacy theme compatibility. No arbitrary HTML/CSS/JS or pixel-position overlay editor.
- [x] Explicit high-resolution publication authorization, service-only path resolution, bounded media worker and storefront fallback. Actual deployment and genuine Storage roundtrip remain open; publicMediaEnabled is false.
- [x] Source-bound classifications, capital/loans, documented income-tax accrual and settlement, result after recorded tax, classified balance equation and rollback verification. VAT/sales-tax treatment, jurisdiction rules, fiscal invoice numbering/legal reporting and statutory profit remain incomplete; no fabricated tax rate.
- [x] Central monitoring uses true entitlement and backup-evidence rules; bounded store-page aggregate details; no PII. Not uptime/load monitoring, nor proof of 100,000 concurrent stores.
- [ ] Real customer email, custom-domain hosting verifier/provider, public media endpoint and actual hardware print acceptance. These require operational configuration and dedicated origin; don't enable prematurely.
- [ ] Jurisdiction-specific tax/invoice requirements and full accounting reconciliation. Do not mark the software phase complete or launch approved.

## Follow-up verification (2026-11-25)
- [x] Executed the expanded `saas/tests/sql/integrated-commerce.sql` against the dedicated SaaS development database; all synthetic changes rolled back. Includes classified funding, income-tax accrual retry, loyalty earning/reservation/replay/cancellation/redemption/return deficit, operator dashboard and buyer denial.
- Exact rational FX evidence validation and explicit warnings for unresolved balances and unrecorded income tax; CI validates client behavior. The tax and public-hosting gates above remain open.

## 2026-11-26 — isolated domain build and verifier
- Storefront-only build and trusted verification orchestration added; automated tests cover missing DNS, mismatched tenant/challenge, TLS failure and activation denial.
- Real provider integration, certificates, actual ownership revalidation and deployment remain open. No commercial or paid service enabled.

# TechStore → TechStore SaaS — remaining parity
Development branch: saas/full-catalog-parity. Implementation phase only. Do not merge or apply 059–065 to production before final migration, security, integration, restore and live UI validation.
 
| Area | Implemented on branch (not validated) | Still open |
|---|---|---|
| Catalog/shop | 059 catalog editor, photos, bulk and CSV; 060 availability and search facets; 065 optional guest pickup, tracking; budget suggestions | Full-resolution media, exact category filters, guest delivery, spam protection, membership/wholesale pricing, actual customer mail and account registration, payment gateway configuration |
| POS/invoices | Exact SKU scanning, Code 39 labels, existing historical receipts | Camera/hardware scanning and label validation, invoice templates and full original visual match |
| Repair | 061 private thumbnails, intake slip, tracking and cost acceptance | Full-resolution private media, customer identity-linked approvals, dedicated task assignments, approval checkout enforcement, warranty branch inventory |
| Staff | 062 shifts, fixed monthly terms and commission snapshot, paid voucher; 064 profile/password | Payroll accrual and adjustment, fine-grained operation permissions, session/device management and MFA |
| Accounting | 063 manual bank account transfers, journal/reconciliation | Branch-level independent FIFO and treasury, direct bank payments/fees, reconciliation with bank statement, statutory tax validation |
| Professional tools | Rule-based build suggestions, existing compatibility, reviews, favorites, trade-in | Full AI assistant, encrypted server backup and restoration, complete membership tiers |
| Offline | 064 one encrypted cash-sale pending request and explicit retry | Offline reload/login, offline full catalog and multi-operation queue, device provisioning, conflict resolution and recovery |
| Design | Responsive nav, cards, editors and product details | Full original side-by-side authenticated visual review and bilingual UI |
 
Do not count the existence of a screen or function as proof of operation. Final test suite must cover both older and new workflows, cross-tenant/branch denial, historical document stability, recovery, duplicate replay, concurrent operations and production deployment compatibility. Original repository is read-only; no paid provider activation.

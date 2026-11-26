# Remaining implementation and release register (branch saas/final-operations-parity)

Baseline main includes 059–071; production release held. Draft PR #10 contains 072–077 plus recovery capture, encrypted operation queue, localization and responsive navigation. No live migration or release authorized. Do not treat a committed function as operational validation.

| Requested area | Implemented in development | Open work |
|---|---|---|
| Branch independence | 073 optional branch cash ledgers, internal transfers; 076 document-attributed receivables/payables/payroll/advances and quantities; previous branch operating reports | Location-specific FIFO allocations, exact cost transfer/return/repair consumption, independent bank/general ledger, audited opening valuation and complete branch P&L |
| Employee permissions | 067 operation restrictions, 077 catalog/stock/sales/repair read and metadata/task edit restrictions | Audit every callable RPC, complete per-role read/create/edit/cancel matrix and UI controls. Immutable financial and stock documents are intentionally never physically deleted |
| Pricing | 074 per-product member/wholesale prices, quantity minima, frozen order line prices | End-to-end invoice/replay tests; full tier administration usability |
| Payroll | 075 advances, bonuses, deductions, noncash offsets and net settlement | Reversals, partial payments, legal payroll policy, employee self-service adjustment view |
| Repairs | 072 technician assignment, task completion and approval gates | Identity-verified customer approval, evidence media, legacy migration review |
| Accounts | 070 staff TOTP/session list | Buyer/platform admin MFA and individual session revocation |
| Recovery | Private automated capture pipeline with role/schema/data exports, storage object archive, encryption and verification; example timer | Real private host and secrets, coordinated write freeze, complete managed-platform settings, isolated verified restore, off-site retention |
| Offline | Encrypted FIFO draft queue for selected request-id operations plus previous single cash sale envelope | Full offline app shell, device enrollment, encrypted read cache, multiple sales and all other mutations, dependency/conflict resolution, reauthentication after reload |
| Arabic/English | Shared locale resources and UI switch across portal, admin, workspace and storefront; static labels mapped; navigation/form headings | Dynamic status/receipt/designer labels and accessibility translation; language-switch and layout review |
| Design | Original Aurora tokens, responsive cards, mobile workspace drawer/quick navigation and bidirectional layout | Page-by-page comparison against original TechStore main f0b680ca309c8e9fac82ad365809d057a7116b99, all authenticated states, mobile/desktop, print, designer and storefront |
| Professional tools | Existing rules-based build advisor | Integrated AI assistant with approved provider and privacy boundary |

Final gates: correct existing CI SQL/UI failures and migration compatibility, implement all remaining features, test cross-store and branch isolation, finance consistency, retries/concurrency and recovery; do not apply live migrations until a verified backup and explicit approval. Never modify the original TechStore repository or enable paid providers without approval.

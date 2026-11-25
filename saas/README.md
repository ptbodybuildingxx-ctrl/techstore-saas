# TechStore SaaS — shared multi-tenant development

Architecture decision: shared Supabase project, separate store identities and tenant-scoped operational rows. The earlier dedicated-project plan remains historical in the other branch; do not run its 56 single-shop migrations on this control plane. All existing commercial features remain development-only. No new cloud projects are needed for each store.

Implemented: shared workspaces tied to the existing SaaS store registry, private tenant memberships, tenant-scoped product IDs/SKUs, stock ledger with composite foreign key and idempotent request IDs, RLS reads, authenticated server-side writes limited to owner/stock with live trial, and no implicit operational access for platform administrators. Existing control-plane states remain unchanged: a shared development store is 'provisioning', and its trial is not commercial entitlement. Owner onboarding needs a confirmed existing Auth user UUID. The UI registers shared shops; the original dedicated-project builder is historical and must not be used for shared stores.

Next: design each of the ten modules with composite tenant-scoped keys and transactional RPCs, including financial ledgers, checkout, customers, repairs, invoices/counters, role administration, Storage paths, and background jobs. Redesign client session/cache keys by store and user; never rely on the route or local storage for authorization. Replace dedicated project-based release/backup/entitlement workflows with shared versions (per-tenant exports and isolated recovery tests, plus project-wide disaster recovery). Validate all module features and two real user sessions in a browser before commercial release. Keep the original project untouched.

See multi-tenant/README.md and RELEASE-GATES.md.

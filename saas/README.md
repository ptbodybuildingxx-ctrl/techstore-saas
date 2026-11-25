# TechStore SaaS — development only

## Architecture decision
Use one isolated Supabase project per subscribed business for the first commercial version, with a separate control-plane project. Existing SQL includes a singleton workspace (id=1), store-wide counters and shared storage paths; a tenant_id column alone would not isolate these paths. Separate projects preserve the existing financial logic and avoid cross-business data access. Each business must also have its own HTTPS origin so auth, IndexedDB and service-worker caches are isolated. This is managed single-tenant SaaS, not a shared-schema multi-tenant implementation.

The current shop remains on main and its existing Supabase project. Never deploy development SQL there. This branch is still in the public repository; no private commercial source repository or payment provider is configured. No real customer data, secrets, or production project copies belong here.

## Components
- saas/control-plane/schema.sql: independent control-plane registry, subscriptions, operator/customer access boundaries.
- saas/build-store.mjs: generates a store deployment from the existing UI, requiring a distinct Supabase project and publishable key, with an explicit source-project prohibition.
- saas/store.example.json: placeholder config. Each real config stays outside Git.
- saas/tests/: tests for commercial provisioning and deployment boundaries.
- saas/RELEASE-GATES.md: launch checklist.

Subscription records are administrative metadata, not proof of payment. Billing webhooks, server-side entitlement enforcement in every store, automated project provisioning, onboarding, platform admin UI and real tenant deployment/restore tests must be completed before taking money. Do not rely on hiding buttons or browser checks for licensing.

Build a store (Node 24):
```sh
node saas/build-store.mjs /private/store-config.json /private/new-output-directory
node --test saas/tests/*.test.mjs
```
The output is only the web UI. The destination Supabase must first receive the approved base migrations and Edge functions with isolated secrets, Auth redirects, storage policies and owner bootstrap. Do not copy a production database or users to a different business. Deploy each store on a different HTTPS origin; do not use same-origin paths on shared GitHub Pages.

# Operational interface boundaries

- Root portal: role entry only; no shared data or customer directory.
- /saas/admin/: central operator session, verified by saas_admin_overview and server role checks.
- /saas/tenant/: assigned memberships, role-based workspace navigation; server RPCs and RLS remain authoritative. A failed store switch or changed membership clears the displayed workspace and signs out.
- /shop/{slug}/: public storefront, fixed shop identity, published catalog only. No administration navigation.
- Shared navigation: saas/design/workspace.mjs. Group membership controls presentation, not authorization. Do not grant database permissions based on client state.
- Deployment entry and routing: saas/deploy/portal.html and saas/deploy/worker.mjs. Deploy the allowlisted operational files, not the repository root or legacy showcase. Cloudflare must reference the exact Git commit; avoid independent Wrangler releases that overwrite it.

Commercial launch gates remain open. No additional service or permission grants in this change.

# Security

Report vulnerabilities privately to the repository owner. Do not disclose credentials, customer records, private URLs, or exploit steps in public issues.

## Scope
The cloud workspace uses Supabase Auth, active-session checks, role checks and RLS. Some legacy paths have coarser permissions than modern RPCs. The local demo is not a secure production system. Never use real customer information there.

- Keep service-role keys, OpenAI/payment/WhatsApp credentials, backup files and database exports outside Git.
- Product pictures in the public Storage bucket are intentionally public; do not upload sensitive photos. Repair evidence belongs in its protected workflow.
- Supabase MFA, leaked-password protection, off-site restore testing and independent security review remain outstanding. Do not claim security certification.
- On any suspected exposure, revoke and rotate the affected credentials, review logs, and notify affected users as appropriate.
- Existing release notes document feature-specific limitations; see docs/releases/.

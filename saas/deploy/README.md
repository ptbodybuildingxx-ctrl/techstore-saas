# Publish the development pilot only
This is not a production or commercial release. The original project must not be used. Database migrations 001–009 and the previous control-plane changes were applied only to the dedicated SaaS development database. No new credentials or customer data are required for a static build.
From a fresh checkout run:
```sh
npm run verify
node saas/deploy/build-pilot.mjs
```
Serve **dist-pilot** only on a dedicated HTTPS origin, never the repository root or the original shop's origin. Example static site settings: build command `npm run verify && node saas/deploy/build-pilot.mjs`, output directory `dist-pilot`, Node 24. Use a separate free hosting account/site only after checking billing limits; do not authorize paid infrastructure. Disable auto-deploy initially. Set response headers X-Robots-Tag: noindex, nofollow; X-Content-Type-Options: nosniff; Referrer-Policy: no-referrer; Content-Security-Policy: frame-ancestors 'none' (keep the existing per-page CSP). Noindex is not access control. Sign-in still requires authorized accounts, no public signup or real customer data is permitted for this pilot. The king account has not been created/verified. Check the site's unique origin, root links, static modules, actual authenticated role tests, and backend isolation before inviting testers. Commercial launch remains blocked by RELEASE-GATES.md. Do not enable GitHub Pages on the original shop's shared origin.

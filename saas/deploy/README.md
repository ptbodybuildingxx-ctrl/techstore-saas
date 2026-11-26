# Operational Cloudflare deployment

The existing TechStore SaaS Worker serves the operational package, not the repository root. Workers Builds uses branch main, build command `node saas/deploy/build-cloudflare.mjs`, deploy command `npx wrangler deploy --config dist-cloudflare/wrangler.json`. The generated allowlisted Worker identifies the exact commit in its response header. Root and docs pages only link to the official origin. No real login on GitHub Pages. No change to commercial release gates, credentials, or database permissions.

Run `npm run verify` and `npm run build:cloudflare` before publishing. The retired public preview and closed-pilot package are no longer deployment targets.

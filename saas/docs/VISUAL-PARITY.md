# TechStore visual parity — source comparison

Read-only reference: original `ptbodybuildingxx-ctrl/techstore` main at `f0b680ca309c8e9fac82ad365809d057a7116b99`. Reviewed `workspace.css`, `style.css`, and `modules/layout.js` against the SaaS shared stylesheet and workspace/storefront renderers. The original repository is not edited. Published tenant design settings remain authoritative.

| Reference surface | SaaS adaptation | Verification outstanding |
|---|---|---|
| Aurora palette, 20px cards and 250px sidebar | Existing tokens, adjusted workspace and shop surface dimensions | Desktop and narrow view screenshot comparison |
| Auto/mobile/desktop layout at 860px | Stored display preference, drawer and quick bar, explicit desktop scroll on narrow screens | Keyboard, orientation and responsive browser validation |
| Metric cards with colored top edges and subtle decoration | Applied to existing metric surfaces only | All metrics, long values, contrast |
| Product tiles, radial art and responsive grid | Existing catalog cards use original art dimensions, real image or explicit missing-image placeholder | Published custom list/card variants and mobile checkout |
| Arabic/English, RTL/LTR and print | Shared dictionaries, localized generated receipt labels and logical spacing | Dynamic statuses, custom editor, thermal and A4 screenshot comparison |

This is source-level implementation, not pixel parity. Capture synthetic fixtures in the final validation phase at 390, 430, 768, 1024 and 1440 CSS pixels, in both directions; compare existing admin, inventory, POS, customers, finance, repairs, store, staff, account, editor, checkout and print states. Use only fake accounts and data, no live deployment. Record differences and acceptance in the final gate.

## Component parity follow-up

The default SaaS workspace, central admin, and public shop now share the original Aurora control styling, metric typography, logical table alignment, row treatments, and responsive card spacing. The workspace navigation uses the original static SVG path artwork mapped to existing authorized SaaS groups. Published custom themes are not replaced; the navigation authorization, RPCs, and data model are unchanged. Receipt print styling is kept independent of the screen theme. Original source was read only. Browser/pixel comparison and cross-device validation remain outstanding; no test suite was run for this change.

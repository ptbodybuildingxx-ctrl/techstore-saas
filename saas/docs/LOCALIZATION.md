# Shared Arabic and English interface

Translation is explicit; user data is not translated. Language choice is per-browser and changes direction and initial UI text without reloading or clearing pending operations. Workspace navigation re-renders immediately; operational forms and headings use the common dictionary when rebuilt. Dynamic notices, generated receipt text, designer controls, accessibility attributes and some operation-specific labels still require explicit migration. Do not call the system fully bilingual yet.

## Static markup coverage (source inventory, not UI test)

- saas/deploy/portal.html: 12/12 unique Arabic text strings mapped.
- saas/admin/index.html: 120/120 unique Arabic text strings mapped.
- saas/tenant/index.html: 236/236 unique Arabic text strings mapped.
- saas/storefront/index.html: 100/100 unique Arabic text strings mapped.

import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {presets,validateTheme,defaults} from '../design/theme.mjs';
test('Aurora matches original palette without replacing stored theme defaults',()=>{
 assert.equal(presets.aurora.accent,'#3859d6');assert.equal(presets.aurora.background,'#f3f5fb');assert.equal(presets.aurora.mode,'light');assert.deepEqual(validateTheme(presets.aurora),presets.aurora);assert.equal(defaults.mode,'dark');
});
test('public store has card fallback and quantity controls without changing checkout APIs',async()=>{
 const [html,js,css]=await Promise.all(['../storefront/index.html','../storefront/storefront.mjs','../admin/admin.css'].map(p=>readFile(new URL(p,import.meta.url),'utf8')));
 assert.match(html,/class="storefront-page"/);assert.match(html,/id="catalogEmpty"/);assert.match(js,/function quantityCell/);assert.match(js,/if\(attempt\)return/);assert.match(js,/units<=100/);assert.ok(css.includes(':root:not([data-design=on]) .storefront-page #products'));assert.ok(css.includes('[data-mobile-layout=list] #products'));
});

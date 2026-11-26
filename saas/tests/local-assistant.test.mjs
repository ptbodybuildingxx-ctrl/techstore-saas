import {test} from 'node:test';
import assert from 'node:assert/strict';
import {assistantIntent,assistantPartLabel} from '../design/local-assistant.mjs';
test('recognizes bounded bilingual budgets and never infers from model numbers',()=>{
 assert.deepEqual(assistantIntent('تجميعة ألعاب بميزانية ٥٠٠ دولار','USD'),{kind:'build',budget:50000,gpu:true});
 assert.deepEqual(assistantIntent('PC build under 700.50 USD without GPU','USD'),{kind:'build',budget:70050,gpu:false});
 assert.equal(assistantIntent('PC build RTX 4090','USD').kind,'budget');
 assert.equal(assistantIntent('PC build under 500 USD','EUR').kind,'currency');
 assert.equal(assistantIntent('build for 1,500 USD','USD').kind,'budget');
 assert.equal(assistantIntent('تجميعة بميزانية ٢ مليون ليرة سورية','SYP').kind,'budget');
 assert.equal(assistantIntent('هل القطع متوافقة؟','USD').kind,'compatibility');
 assert.equal(assistantIntent('track repair','USD').kind,'tracking');
 assert.equal(assistantIntent('delivery','USD').kind,'delivery');
 assert.equal(assistantIntent('unknown request','USD').kind,'help');
 assert.throws(()=>assistantIntent('x'.repeat(241),'USD'));
 assert.equal(assistantPartLabel('socket'),'مقبس المعالج');
});

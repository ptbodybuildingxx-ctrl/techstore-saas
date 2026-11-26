import test from 'node:test';
import assert from 'node:assert/strict';
import {summarizeBranchJournal} from '../tenant/branch-finance.mjs';
const row=(account,debit,credit,branch_id='branch-a',currency='SYP')=>({branch_id,name:branch_id??'Central',currency,account,opening:'0',debit:String(debit),credit:String(credit),closing:String(BigInt(debit)-BigInt(credit))});
const report=rows=>({mode:'branch_journal_projection',opening_verified:false,rows});
test('branch management result uses exact signed integer postings, with no final profit assertion',()=>{
 const [g]=summarizeBranchJournal(report([row('cash',1000,200),row('sales_revenue',0,1000),row('cost_of_goods_services',200,0)]));
 assert.equal(g.revenue,1000n);assert.equal(g.cost,200n);assert.equal(g.resultAfterRecordedTax,800n);assert.equal(g.assets,800n);assert.equal(g.finalProfit,null);
});
test('central and branch groups and currencies cannot be combined to conceal imbalance',()=>{
 assert.throws(()=>summarizeBranchJournal(report([row('cash',100,0,'branch-a'),row('sales_revenue',0,100,null)])),/Unbalanced/);
 assert.throws(()=>summarizeBranchJournal(report([row('cash',100,0,'branch-a','SYP'),row('sales_revenue',0,100,'branch-a','USD')])),/Unbalanced/);
});
test('duplicate accounts fail closed',()=>{assert.throws(()=>summarizeBranchJournal(report([row('cash',0,0),row('cash',0,0)])),/Duplicate/)});

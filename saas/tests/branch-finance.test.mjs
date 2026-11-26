import test from 'node:test';
import assert from 'node:assert/strict';
import {summarizeBranchJournal,branchClearingTotals} from '../tenant/branch-finance.mjs';
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

test('interbranch clearing is reconciled within each currency, with no fabricated opening balances',()=>{const groups=summarizeBranchJournal(report([row('interbranch_clearing',100,0,'branch-a'),row('cash',0,100,'branch-a'),row('cash',100,0,'branch-b'),row('interbranch_clearing',0,100,'branch-b')]));assert.deepEqual(branchClearingTotals(groups),[{currency:'SYP',balance:0n,balanced:true}]);assert.ok(groups.every(x=>x.classificationResidual===0n&&x.openingVerified===false));});

test('cross-branch payroll advance offsets settle liability and receivable separately',()=>{const groups=summarizeBranchJournal(report([row('payroll_payable',100,0,'branch-a'),row('interbranch_clearing',0,100,'branch-a'),row('employee_advances',0,100,'branch-b'),row('interbranch_clearing',100,0,'branch-b')]));assert.equal(groups[0].liabilities,-100n);assert.equal(groups[1].assets,-100n);assert.equal(branchClearingTotals(groups)[0].balanced,true);assert.ok(groups.every(g=>g.resultAfterRecordedTax===0n));});

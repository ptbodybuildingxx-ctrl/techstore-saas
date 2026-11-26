// Derive management summaries from the exact attributed journal rows, never from current product prices.
const revenue=new Set(['sales_revenue','repair_revenue','sales_returns']);
const expenses=new Set(['expense_unclassified','stock_adjustment_expense','rent_expense','payroll_expense','utilities_expense','other_operating_expense']);
const assets=new Set(['cash','bank','inventory','accounts_receivable','employee_advances']);
const liabilities=new Set(['accounts_payable','loan_payable','payroll_payable','income_tax_payable','indirect_tax_payable']);
const unresolved=new Set(['funding_unclassified','stock_intake_unclassified','fx_clearing','interbranch_clearing']);
export function summarizeBranchJournal(report){
 if(report?.mode!=='branch_journal_projection'||!Array.isArray(report.rows)||report.opening_verified!==false)throw Error('Invalid projection');
 const groups=new Map(),seen=new Set();
 for(const r of report.rows){
  const key=JSON.stringify([r.branch_id,r.currency]),id=JSON.stringify([key,r.account]);
  if(seen.has(id))throw Error('Duplicate journal account');seen.add(id);
  const opening=BigInt(r.opening),debit=BigInt(r.debit),credit=BigInt(r.credit),closing=BigInt(r.closing),movement=debit-credit;
  if(debit<0n||credit<0n||opening+movement!==closing)throw Error('Invalid journal movement');
  let g=groups.get(key);if(!g){g={branch_id:r.branch_id,name:r.name,currency:r.currency,revenue:0n,cost:0n,expenses:0n,recordedTax:0n,assets:0n,liabilities:0n,capital:0n,unresolved:0n,interbranch:0n,cumulativeResult:0n,otherClosing:0n,openingCheck:0n,movementCheck:0n,closingCheck:0n};groups.set(key,g)}
  if(g.name!==r.name)throw Error('Branch name mismatch');
  const a=r.account;
  if(revenue.has(a)||a==='cost_of_goods_services'||expenses.has(a)||a==='income_tax_expense')g.cumulativeResult-=closing;
  if(a==='interbranch_clearing')g.interbranch+=closing;
  g.openingCheck+=opening;g.movementCheck+=movement;g.closingCheck+=closing;
  if(revenue.has(a))g.revenue-=movement;
  else if(a==='cost_of_goods_services')g.cost+=movement;
  else if(expenses.has(a))g.expenses+=movement;
  else if(a==='income_tax_expense')g.recordedTax+=movement;
  else if(assets.has(a))g.assets+=closing;
  else if(liabilities.has(a))g.liabilities-=closing;
  else if(a==='capital')g.capital-=closing;
  else if(unresolved.has(a))g.unresolved+=closing;
  else g.otherClosing+=closing;
 }
 return [...groups.values()].map(g=>{
  if(g.openingCheck!==0n||g.movementCheck!==0n||g.closingCheck!==0n)throw Error('Unbalanced branch journal');
  const residual=g.assets-g.liabilities-g.capital-g.cumulativeResult+g.unresolved+g.otherClosing;
  if(residual!==0n)throw Error('Unbalanced classification');
  return {...g,classificationResidual:residual,resultBeforeTax:g.revenue-g.cost-g.expenses,resultAfterRecordedTax:g.revenue-g.cost-g.expenses-g.recordedTax,finalProfit:null,openingVerified:false};
 });
}

// Internal clearing is expected to cancel only across branches of the same currency.
export function branchClearingTotals(groups){const sums=new Map();for(const g of groups)sums.set(g.currency,(sums.get(g.currency)||0n)+g.interbranch);return [...sums].map(([currency,balance])=>({currency,balance,balanced:balance===0n}))}

import {configuration} from '../admin/config.mjs';
import {createTenantApi,saleAttempt} from './api.mjs';
const api=createTenantApi(configuration),el=id=>document.getElementById(id);
const node=(tag,text)=>{const n=document.createElement(tag);n.textContent=text;return n};
let stores=[],current=null,ctx=null,selectedCurrency=null,products=[],cart=new Map(),attempt=null,stockAttempt=null,cashAttempt=null,cashCursor=null,receivableAttempt=null,returnAttempt=null,costAttempt=null,returnCursor=null,customerCursor=null,debtCursor=null,customerNames=new Map(),busy=false,productCursor=null,salesCursor=null;
const message=t=>el('message').textContent=t;
const money=(v,c=selectedCurrency)=>c?(v/100).toFixed(2)+' '+c:'—';
function button(label,fn){const b=node('button',label);b.type='button';b.addEventListener('click',()=>run(fn));return b}
function row(values){const r=document.createElement('tr');for(const v of values)r.append(node('td',String(v)));return r}
function clear(){stores=[];current=null;ctx=null;selectedCurrency=null;products=[];cart.clear();attempt=null;stockAttempt=null;cashAttempt=null;cashCursor=null;receivableAttempt=null;returnAttempt=null;costAttempt=null;el('costPending').textContent='';returnCursor=null;el('returnPending').textContent='';el('returnTitle').textContent='اختر فاتورة من سجل المبيعات';customerCursor=null;debtCursor=null;customerNames.clear();el('customerForm').reset();el('creditForm').reset();el('debtPending').textContent='';el('cashForm').reset();el('cashPending').textContent='';productCursor=null;salesCursor=null;for(const id of ['products','cart','sales','store','saleCurrency','cashBalances','cashRows','cashCurrency','cashTarget','customerRows','debtRows','scheduleRows','creditCustomer','returnRows','returnLines','marginRows','marginTotals'])el(id).replaceChildren();el('pending').textContent='';el('total').textContent='';el('dashboard').hidden=true;el('loginPanel').hidden=false;el('logout').hidden=true}
function controls(){el('costRetry').hidden=!costAttempt;el('costRetry').disabled=busy;el('returnRetry').hidden=!returnAttempt;el('returnRetry').disabled=busy;el('returnNext').disabled=busy||!returnCursor;el('debtRetry').hidden=!receivableAttempt;el('debtRetry').disabled=busy;el('creditSubmit').disabled=busy||!ctx?.can_price||!selectedCurrency||!cart.size||!el('creditCustomer').options.length||!!attempt||!!stockAttempt||!!cashAttempt||!!receivableAttempt||!!returnAttempt||!!costAttempt;el('customerNext').disabled=busy||!customerCursor;el('debtNext').disabled=busy||!debtCursor;el('store').disabled=busy||!!attempt||!!stockAttempt||!!cashAttempt||!!receivableAttempt||!!returnAttempt||!!costAttempt;el('saleCurrency').disabled=busy||!!attempt||!!stockAttempt||!!cashAttempt||!!receivableAttempt||!!returnAttempt||!!costAttempt||!ctx?.currencies.length;el('sell').disabled=busy||!ctx?.can_sell||!selectedCurrency||(!attempt&&!cart.size)||!!stockAttempt||!!cashAttempt||!!receivableAttempt||!!returnAttempt||!!costAttempt;el('sell').textContent=attempt?'إعادة محاولة نفس العملية':'تسجيل البيع النقدي';el('productNext').disabled=busy||!productCursor||!!attempt||!!stockAttempt;el('salesNext').disabled=busy||!salesCursor;el('cashNext').disabled=busy||!cashCursor;el('cashSubmit').disabled=busy||!ctx?.can_price||!ctx?.currencies.length||!!attempt||!!stockAttempt;for(const x of el('cashForm').elements)if(x.id!=='cashSubmit')x.disabled=!!cashAttempt;el('cashSubmit').textContent=cashAttempt?'إعادة محاولة الحركة نفسها':'تسجيل الحركة'}
async function run(fn,allowPending=false){if(busy)return;if((receivableAttempt||returnAttempt||costAttempt)&&!allowPending){message('توجد عملية مالية غير مؤكدة. أعد محاولة العملية نفسها أولاً.');return;}busy=true;controls();try{await fn()}catch(e){message('لم يتم تأكيد الطلب. راجع الحالة قبل أي محاولة جديدة.');if(!api.signedIn()){clear();message('انتهت الجلسة. تحقق من سجل المبيعات قبل تكرار أي عملية غير مؤكدة.')}}finally{busy=false;controls()}}
function renderCart(){el('cart').replaceChildren(...[...cart.values()].map(x=>{const tr=row([x.name,x.units,money(x.expected_price_minor)]);const td=document.createElement('td');if(!attempt)td.append(button('حذف',async()=>{cart.delete(x.product_id);renderCart()}));tr.append(td);return tr}));el('total').textContent='المجموع: '+money([...cart.values()].reduce((s,x)=>s+x.units*x.expected_price_minor,0));controls()}
async function loadProducts(after=null){products=await api.products(current.id,selectedCurrency,after,50);productCursor=products.length===50?products.at(-1).id:null;el('products').replaceChildren(...products.map(p=>{
 const tr=row([p.name,p.sku,p.quantity,p.unit_price_minor===null?'غير مسعّر':money(p.unit_price_minor)]),td=document.createElement('td');
 if(current.can_write&&!attempt&&!cashAttempt)td.append(button('تعديل المخزون',async()=>{if(stockAttempt&&stockAttempt.product!==p.id)throw Error('Pending stock operation');if(!stockAttempt){const raw=prompt('الزيادة أو النقص بالعدد الصحيح');if(raw===null)return;const delta=Number(raw);if(!Number.isSafeInteger(delta)||delta===0)throw Error('Invalid stock');stockAttempt={product:p.id,delta,id:crypto.randomUUID()}}await api.adjustStock(current.id,p.id,stockAttempt.delta,stockAttempt.id);stockAttempt=null;await loadProducts();message('تم تسجيل تعديل المخزون')}));
 if(ctx?.can_price&&selectedCurrency&&!attempt&&!stockAttempt&&!cashAttempt)td.append(button('إدخال بضاعة بتكلفة',()=>startCostIntake(p)));
 if(ctx?.can_price&&selectedCurrency&&!attempt&&!stockAttempt&&!cashAttempt)td.append(button('السعر',async()=>{const raw=prompt('السعر بعملة '+selectedCurrency+' (مثال: 125.50)');if(raw===null)return;if(!/^\d{1,7}(?:\.\d{1,2})?$/.test(raw.trim()))throw Error('Invalid price');const [whole,fraction='']=raw.trim().split('.');const price=Number(whole)*100+Number(fraction.padEnd(2,'0'));await api.setPrice(current.id,p.id,selectedCurrency,price);await loadProducts()}));
 if(ctx?.can_sell&&selectedCurrency&&p.unit_price_minor!==null&&p.quantity>0&&!attempt&&!stockAttempt)td.append(button('إضافة للسلة',async()=>{const old=cart.get(p.id);if(old&&old.expected_price_minor!==p.unit_price_minor)throw Error('Price changed');const units=(old?.units||0)+1;if(units>p.quantity||units>10000)throw Error('Insufficient stock');cart.set(p.id,{product_id:p.id,name:p.name,units,expected_price_minor:p.unit_price_minor});renderCart()}));
 tr.append(td);return tr}));controls()}
async function loadSales(before=null){if(!['owner','cashier'].includes(current.role)){el('sales').replaceChildren();salesCursor=null;return}const r=await api.sales(current.id,before,50);salesCursor=r.length===50?r.at(-1).number:null;el('sales').replaceChildren(...r.map(s=>{const tr=row([s.number,money(s.total_minor,s.currency),s.payment_mode==='credit'?'آجل':'نقدي',s.request_id]);const td=document.createElement('td');if(current.role==='owner')td.append(button('المرتجعات',()=>loadReturnLines(s)),button('مجمل الربح',()=>loadMargin(s)));tr.append(td);return tr}));controls()}
async function load(){el('costPanel').hidden=current.role!=='owner';el('marginRows').replaceChildren();el('marginTotals').replaceChildren();el('marginTitle').textContent='اختر فاتورة من سجل المبيعات';el('returnLines').replaceChildren();el('returnTitle').textContent='اختر فاتورة من سجل المبيعات';ctx=await api.context(current.id);if(!ctx.currencies.includes(selectedCurrency))selectedCurrency=ctx.currency;el('saleCurrency').replaceChildren(...ctx.currencies.map(c=>{const o=node('option',({SYP:'الليرة السورية',USD:'الدولار',EUR:'اليورو'})[c]+' / '+c);o.value=c;return o}));el('saleCurrency').value=selectedCurrency||'';el('context').textContent=current.role+' — '+(ctx.can_sell?'البيع التجريبي متاح':'البيع غير متاح')+' — '+(ctx.currencies.join(' / ')||'لم تفعّل عملة');el('settings').hidden=!ctx.can_price||ctx.currencies.length===3;el('inventory').hidden=!current.can_write;await loadProducts();await loadSales();await loadCash();await loadReceivables();await loadReturns();renderCart()}
function minor(raw){if(typeof raw!=='string'||!/^\d{1,12}(?:\.\d{1,2})?$/.test(raw.trim()))throw Error('Invalid amount');const [w,f='']=raw.trim().split('.'),n=Number(w)*100+Number(f.padEnd(2,'0'));if(!Number.isSafeInteger(n)||n<1||n>100000000000000)throw Error('Invalid amount');return n}
function cashFields(){const exchange=el('cashKind').value==='exchange';el('cashTargetLabel').hidden=!exchange;el('cashTargetAmountLabel').hidden=!exchange}
async function loadCash(before=null,beforeId=null){
 el('cashPanel').hidden=current.role!=='owner';
 if(current.role!=='owner'){el('cashBalances').replaceChildren();el('cashRows').replaceChildren();cashCursor=null;return}
 const r=await api.cashOverview(current.id,before,beforeId,50);
 const last=r.movements.at(-1);cashCursor=r.movements.length===50?{time:last.created_at,id:last.id}:null;
 el('cashBalances').replaceChildren(...r.balances.map(x=>{const b=node('div',x.currency);b.className='metric';b.append(node('strong',money(x.balance_minor,x.currency)));return b}));
 if(!cashAttempt){for(const id of ['cashCurrency','cashTarget']){const prev=el(id).value;el(id).replaceChildren(...ctx.currencies.map(c=>{const o=node('option',c);o.value=c;return o}));if(ctx.currencies.includes(prev))el(id).value=prev}}
 const names={sale:'بيع نقدي',funding:'إيداع',expense:'مصروف',exchange:'تحويل عملة',debt_payment:'تحصيل دين / دفعة أولى',return_refund:'استرداد مرتجع'};
 el('cashRows').replaceChildren(...r.movements.map(x=>row([names[x.kind],money(x.amount_minor,x.currency),x.target_currency?money(x.target_amount_minor,x.target_currency):'—',x.note,new Date(x.created_at).toISOString(),x.request_id||x.sale_id])));cashFields();controls();
}
async function loadCustomers(after=null){
 const r=await api.customers(current.id,after,50);customerCursor=r.length===50?r.at(-1).id:null;
 customerNames=new Map(r.map(x=>[x.id,x.name]));
 el('customerRows').replaceChildren(...r.map(x=>row([x.name,x.phone||'—',x.id])));
 el('creditCustomer').replaceChildren(...r.map(x=>{const o=node('option',x.name);o.value=x.id;return o}));controls()
}
async function loadDebts(after=null){
 const r=await api.debts(current.id,after,50);debtCursor=r.length===50?r.at(-1).id:null;
 el('debtRows').replaceChildren(...r.map(x=>{const tr=row([customerNames.get(x.customer_id)||x.customer_id,money(x.principal_minor,x.currency),money(x.deposit_minor,x.currency),money(x.remaining_minor,x.currency),x.installment_count]);const td=document.createElement('td');
 td.append(button('جدول الأقساط',async()=>{const schedule=await api.debtSchedule(current.id,x.id);el('scheduleRows').replaceChildren(...schedule.map(s=>row([s.number,s.due_date,money(s.amount_minor,x.currency),money(s.paid_minor,x.currency),money(s.waived_minor,x.currency)])))}));
 if(ctx?.can_price&&x.remaining_minor>0)td.append(button('تحصيل دفعة',async()=>{if(attempt||stockAttempt||cashAttempt)return;const raw=prompt('المبلغ المقبوض بعملة '+x.currency);if(raw===null)return;const amount=minor(raw);if(amount>x.remaining_minor)throw Error('Payment exceeds balance');if(!confirm('تأكيد تسجيل الدفعة؟'))return;receivableAttempt=Object.freeze({kind:'pay',store:current.id,debt:x.id,requestId:crypto.randomUUID(),currency:x.currency,amount});await submitReceivable()}));tr.append(td);return tr}));controls()
}
async function loadReceivables(){
 el('debtPanel').hidden=current.role!=='owner';
 el('scheduleRows').replaceChildren();
 if(current.role!=='owner'){for(const id of ['customerRows','debtRows','creditCustomer'])el(id).replaceChildren();customerNames.clear();customerCursor=null;debtCursor=null;return}
 await loadCustomers();await loadDebts()
}
async function submitReceivable(){
 const x=receivableAttempt;if(!x||x.store!==current.id)throw Error('Pending operation mismatch');
 el('debtPending').textContent='مرجع الطلب: '+x.requestId;controls();
 let result;
 if(x.kind==='customer')result=await api.addCustomer(x.store,x.requestId,x.name,x.phone);
 else if(x.kind==='pay')result=await api.payDebt(x.store,x.debt,x.requestId,x.currency,x.amount);
 else {result=await api.recordCredit(x.sale,x.terms);cart.clear()}
 receivableAttempt=null;el('debtPending').textContent='تم تأكيد الطلب: '+x.requestId;el('customerForm').reset();el('creditForm').reset();await load();message('تم تسجيل العملية')
}
el('customerForm').addEventListener('submit',e=>{e.preventDefault();const f=new FormData(e.currentTarget);run(async()=>{if(attempt||stockAttempt||cashAttempt||!ctx?.can_price)return;const name=String(f.get('name')).trim(),phone=String(f.get('phone')).trim();if(!name)throw Error('Invalid customer');receivableAttempt=Object.freeze({kind:'customer',store:current.id,requestId:crypto.randomUUID(),name,phone});await submitReceivable()})});
el('creditForm').addEventListener('submit',e=>{e.preventDefault();const f=new FormData(e.currentTarget);run(async()=>{if(attempt||stockAttempt||cashAttempt||!ctx?.can_price||!cart.size)return;const raw=String(f.get('deposit')).trim();const deposit=/^0(?:\.0{1,2})?$/.test(raw)?0:minor(raw);const count=Number(f.get('count')),due=String(f.get('due')),customer=String(f.get('customer'));const sale=saleAttempt(current.id,[...cart.values()],selectedCurrency),total=sale.lines.reduce((s,l)=>s+l.units*l.expected_price_minor,0);if(!customerNames.has(customer)||!Number.isInteger(count)||count<1||count>60||total-deposit<count||!/^\d{4}-\d{2}-\d{2}$/.test(due))throw Error('Invalid terms');if(!confirm('بيع آجل تجريبي بعملة '+selectedCurrency+'؟'))return;receivableAttempt=Object.freeze({kind:'credit',store:current.id,requestId:sale.requestId,sale,terms:Object.freeze({customer,deposit,count,due})});await submitReceivable()})});
el('debtRetry').addEventListener('click',()=>run(submitReceivable,true));
el('customerFirst').addEventListener('click',()=>run(async()=>{await loadCustomers();await loadDebts()}));
el('customerNext').addEventListener('click',()=>run(async()=>{if(customerCursor){await loadCustomers(customerCursor);await loadDebts()}}));
el('debtFirst').addEventListener('click',()=>run(()=>loadDebts()));
el('debtNext').addEventListener('click',()=>run(()=>debtCursor&&loadDebts(debtCursor)));
async function loadReturnLines(s){
 if(current.role!=='owner')return;
 const lines=await api.returnableLines(current.id,s.id);el('returnTitle').textContent='فاتورة رقم '+s.number;
 el('returnLines').replaceChildren(...lines.map(x=>{const tr=row([x.product_name,x.units,x.returned_units,money(x.unit_price_minor,x.currency)]),td=document.createElement('td');
 if(ctx?.can_price&&x.units>x.returned_units)td.append(button('إرجاع',async()=>{if(attempt||stockAttempt||cashAttempt||receivableAttempt)return;const raw=prompt('عدد القطع السليمة المراد إرجاعها');if(raw===null)return;const units=Number(raw);if(!Number.isSafeInteger(units)||units<1||units>x.units-x.returned_units)throw Error('Invalid quantity');const reason=prompt('سبب المرتجع');if(reason===null||!reason.trim()||reason.trim().length>300)return;if(!confirm('تأكيد إعادة القطع السليمة وتسوية الدين أو رد النقد بحسب حالة الفاتورة؟'))return;returnAttempt=Object.freeze({store:current.id,requestId:crypto.randomUUID(),sale:s.id,product:x.product_id,units,reason:reason.trim(),currency:x.currency,price:x.unit_price_minor});await submitReturn()}));tr.append(td);return tr}));controls()
}
async function loadReturns(after=null){
 el('returnPanel').hidden=current.role!=='owner';
 if(current.role!=='owner'){el('returnRows').replaceChildren();el('returnLines').replaceChildren();returnCursor=null;return}
 const r=await api.returns(current.id,after,50);returnCursor=r.length===50?r.at(-1).id:null;
 el('returnRows').replaceChildren(...r.map(x=>row([x.sale_id,x.units,money(x.total_minor,x.currency),money(x.debt_reduction_minor,x.currency),money(x.refund_minor,x.currency),x.reason])));controls()
}
async function submitReturn(){
 const x=returnAttempt;if(!x||x.store!==current.id)throw Error('Pending return mismatch');
 el('returnPending').textContent='مرجع الطلب: '+x.requestId;controls();
 const r=await api.recordReturn(x.store,x);returnAttempt=null;el('returnPending').textContent='تم تسجيل المرتجع: '+r.id;el('returnLines').replaceChildren();el('returnTitle').textContent='اختر فاتورة من سجل المبيعات';await load();message('تمت تسوية المرتجع: تخفيض الدين '+money(r.debt_reduction_minor,r.currency)+' / رد نقدي '+money(r.refund_minor,r.currency))
}
async function startCostIntake(p){
 if(attempt||stockAttempt||cashAttempt||receivableAttempt||returnAttempt||costAttempt||!ctx?.can_price||!selectedCurrency)return;
 const raw=prompt('عدد القطع الواردة');if(raw===null)return;const units=Number(raw);
 if(!Number.isSafeInteger(units)||units<1||units>1000000000)throw Error('Invalid units');
 const amount=prompt('تكلفة شراء القطعة الواحدة بعملة '+selectedCurrency+' (0 مسموح فقط للبضاعة المجانية فعلاً)');if(amount===null)return;
 const cost=/^0(?:\.0{1,2})?$/.test(amount.trim())?0:minor(amount);if(cost>100000000)throw Error('Cost out of range');
 const note=prompt('مرجع الشراء أو اسم المورد');if(note===null||!note.trim()||note.trim().length>300)return;
 if(!confirm('تسجيل دفعة المخزون بتكلفة الشراء؟ لا يتم دفع مبلغ من الصندوق تلقائياً.'))return;
 costAttempt=Object.freeze({store:current.id,product:p.id,requestId:crypto.randomUUID(),units,currency:selectedCurrency,cost,note:note.trim()});
 await submitCostIntake()
}
async function submitCostIntake(){
 const x=costAttempt;if(!x||x.store!==current.id)throw Error('Pending cost intake mismatch');
 el('costPending').textContent='مرجع الإدخال: '+x.requestId;controls();
 await api.receiveCostedStock(x.store,x);costAttempt=null;el('costPending').textContent='تم تأكيد الإدخال: '+x.requestId;await load();message('تم إدخال البضاعة وتسجيل تكلفتها')
}
async function loadMargin(s){
 const r=await api.saleMargin(current.id,s.id);
 const format=x=>x===null?'غير قابل للحساب':money(x,r.currency);
 el('marginTitle').textContent='مجمل ربح فاتورة رقم '+s.number;
 el('marginTotals').replaceChildren(...[['الإيراد بعد المرتجعات',r.net_revenue_minor],['تكلفة البضاعة',r.cost_minor],['مجمل الربح',r.gross_margin_minor]].map(([k,v])=>{const b=node('div',k);b.className='metric';b.append(node('strong',format(v)));return b}));
 el('marginRows').replaceChildren(...r.lines.map(x=>row([x.product_name,x.units,x.returned_units,format(x.net_revenue_minor),format(x.cost_minor),format(x.gross_margin_minor)])))
}
el('costRetry').addEventListener('click',()=>run(submitCostIntake,true));
el('returnRetry').addEventListener('click',()=>run(submitReturn,true));
el('returnFirst').addEventListener('click',()=>run(()=>loadReturns()));
el('returnNext').addEventListener('click',()=>run(()=>returnCursor&&loadReturns(returnCursor)));
el('cashKind').addEventListener('change',cashFields);
el('cashForm').addEventListener('submit',e=>{e.preventDefault();const f=new FormData(e.currentTarget);run(async()=>{if(attempt||stockAttempt)return;if(!cashAttempt){const kind=String(f.get('kind')),exchange=kind==='exchange';const next={requestId:crypto.randomUUID(),kind,currency:String(f.get('currency')),amount:minor(String(f.get('amount'))),note:String(f.get('note')).trim(),targetCurrency:exchange?String(f.get('targetCurrency')):null,targetAmount:exchange?minor(String(f.get('targetAmount'))):null};if(!ctx.currencies.includes(next.currency)||!next.note||(exchange&&(!ctx.currencies.includes(next.targetCurrency)||next.targetCurrency===next.currency)))throw Error('Invalid movement');if(!confirm('تأكيد تسجيل حركة نقدية تجريبية؟'))return;cashAttempt=Object.freeze(next);el('cashPending').textContent='معرف الحركة: '+next.requestId;controls()}const id=await api.recordCash(current.id,cashAttempt);cashAttempt=null;el('cashPending').textContent='تم تأكيد الحركة: '+id;e.target.reset();await loadCash();message('تم تسجيل الحركة النقدية')})});
el('cashFirst').addEventListener('click',()=>run(()=>loadCash()));
el('cashNext').addEventListener('click',()=>run(()=>cashCursor&&loadCash(cashCursor.time,cashCursor.id)));
el('login').addEventListener('submit',e=>{e.preventDefault();const f=new FormData(e.currentTarget),pass=String(f.get('password'));e.currentTarget.elements.password.value='';run(async()=>{stores=await api.signIn(String(f.get('email')),pass);el('store').replaceChildren(...stores.map(s=>{const o=node('option',s.name+' / '+s.role);o.value=s.id;return o}));current=stores[0];await load();el('dashboard').hidden=false;el('loginPanel').hidden=true;el('logout').hidden=false})});
el('store').addEventListener('change',()=>run(async()=>{if(attempt||stockAttempt||cashAttempt)return;current=stores.find(s=>s.id===el('store').value);selectedCurrency=null;customerNames.clear();for(const id of ['customerRows','debtRows','scheduleRows','creditCustomer','cashRows','cashBalances','returnRows','returnLines'])el(id).replaceChildren();cart.clear();el('products').replaceChildren();el('sales').replaceChildren();renderCart();await load()}));
el('saleCurrency').addEventListener('change',()=>run(async()=>{if(attempt||stockAttempt){el('saleCurrency').value=selectedCurrency;return}if(cart.size&&!confirm('تغيير العملة سيُفرغ السلة. متابعة؟')){el('saleCurrency').value=selectedCurrency;return}selectedCurrency=el('saleCurrency').value;cart.clear();renderCart();await loadProducts()}));
el('refresh').addEventListener('click',()=>run(async()=>{const id=current.id;stores=await api.stores();current=stores.find(s=>s.id===id);if(!current){await api.signOut();clear();throw Error('Membership changed')}await load()}));
el('currency').addEventListener('submit',e=>{e.preventDefault();const f=new FormData(e.currentTarget);run(async()=>{if(attempt||stockAttempt)return;await api.configure(current.id,String(f.get('currency')));await load()})});
el('product').addEventListener('submit',e=>{e.preventDefault();const f=new FormData(e.currentTarget);run(async()=>{if(attempt||stockAttempt)return;await api.addProduct(current.id,String(f.get('sku')),String(f.get('name')));e.target.reset();await loadProducts()})});
el('productFirst').addEventListener('click',()=>run(async()=>{if(!attempt&&!stockAttempt&&!cashAttempt)await loadProducts()}));
el('productNext').addEventListener('click',()=>run(async()=>{if(productCursor&&!attempt&&!stockAttempt)await loadProducts(productCursor)}));
el('salesFirst').addEventListener('click',()=>run(()=>loadSales()));
el('salesNext').addEventListener('click',()=>run(()=>salesCursor&&loadSales(salesCursor)));
el('sell').addEventListener('click',()=>run(async()=>{if(!attempt){if(!confirm('تسجيل بيع نقدي تجريبي فقط؟'))return;attempt=saleAttempt(current.id,[...cart.values()],selectedCurrency);el('pending').textContent='معرف العملية: '+attempt.requestId;renderCart()}const r=await api.recordSale(attempt);attempt=null;cart.clear();el('pending').textContent='تم تأكيد العملية '+r.request_id;await load();message('تم تسجيل البيع رقم '+r.number+' — '+money(r.total_minor,r.currency))}));
el('logout').addEventListener('click',()=>run(async()=>{if((attempt||stockAttempt||cashAttempt||receivableAttempt||returnAttempt||costAttempt)&&!confirm('هناك عملية غير مؤكدة. احفظ معرفها وتحقق من السجل قبل تكرارها. خروج؟'))return;try{await api.signOut()}finally{clear()}},true));
window.addEventListener('beforeunload',e=>{if(attempt||stockAttempt||cashAttempt||receivableAttempt||returnAttempt||costAttempt){e.preventDefault();e.returnValue=''}});
setInterval(()=>{if(!el('dashboard').hidden&&!api.signedIn()){clear();message('انتهت الجلسة. تحقق من السجل قبل تكرار أي عملية غير مؤكدة.')}},5000);
clear();controls();

import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import vm from 'node:vm';

const source = await fs.readFile(new URL('../customer-experience.js', import.meta.url), 'utf8');
const savedId = '11111111-1111-4111-8111-111111111111';
const home = {id:savedId,label:'<Home>',street:'123 Demo Lane',city:'Demo City',state:'CA',zip:'94500',is_default:true};
const other = {id:'22222222-2222-4222-8222-222222222222',label:'Work',street:'456 Office Road',city:'Demo City',state:'CA',zip:'94501',is_default:false};
const token = 'a'.repeat(64);
const calls = [], messages = [], formValues = {};
let refreshCount = 0;
const esc = value => String(value ?? '').replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;').replaceAll("'","&#39;");
const context=vm.createContext({
  URL,URLSearchParams,
  location:{origin:'https://bfung2.github.io'},
  window:{confirm:()=>true},
  document:{getElementById(id){return formValues[id]||null;}},
  customerEpoch:1,customerState:{addresses:[],addressEditing:null,addressBusy:false,checkoutAddressId:null,user:{id:'user-1'},orders:[],loading:false,orderSearch:'',orderFilter:'all'},
  me:{email:'customer@example.invalid',name:'Customer',phone:'555-0100',address:{street:'789 Profile Avenue',city:'Demo City',state:'CA',zip:'94502'}},
  customerRPC:async(name,args)=>{calls.push({name,args});if(name==='apex_customer_addresses')return [home,other];if(name==='apex_customer_link_order')return args.p_token===token;throw Error('Unexpected RPC '+name);},
  customerLoadOrders:async()=>{refreshCount++;},
  customerMessage:(message,error=false)=>{messages.push({message,error});},
  render(){},
  looksLikeAddress:addr=>/^\d+/.test(addr.street)&&addr.city.length>1&&addr.state.length>1&&/^\d{5}$/.test(addr.zip),
  checkAddress(){},
  esc,trackingStageLabel:()=> 'Shipped',money:n=>'$'+n
});
vm.runInContext(source,context);
const run=expression=>vm.runInContext(expression,context);

// No saved addresses: continue using the original verified customer profile.
assert.equal(run('customerPreferredShippingAddress().street'),'789 Profile Avenue');
context.customerState.addresses=[other,home];
assert.equal(run('customerPreferredShippingAddress().street'),'123 Demo Lane');
context.customerState.checkoutAddressId=other.id;
assert.equal(run('customerPreferredShippingAddress().street'),'456 Office Road');
context.customerState.checkoutAddressId='manual';
assert.equal(run('Object.keys(customerPreferredShippingAddress()).length'),0);
context.customerState.checkoutAddressId=null;

// Private receipt token parsing only accepts the Apex site or a bare 64-char token.
assert.equal(run('customerReceiptToken('+JSON.stringify(token)+')'),token);
assert.equal(run('customerReceiptToken('+JSON.stringify('https://bfung2.github.io/#/track-order?token='+token)+')'),token);
assert.equal(run('customerReceiptToken('+JSON.stringify('https://evil.example/#/track-order?token='+token)+')'),null);
assert.equal(run('customerReceiptToken("invalid")'),null);

// Order history searches only the existing customer-scoped RPC results.
context.customerState.orders=[
 {ref:'AC-PAID',items:[{name:'<script>alert(1)</script>',qty:1}],token,stage:'shipped',total:90,payment_confirmed:true},
 {ref:'AC-PENDING',items:[{name:'SSD',qty:1}],token,stage:'requested',total:50,payment_confirmed:false},
 {ref:'AC-TEST',items:[{name:'CPU',qty:1}],token,stage:'completed',total:30,payment_confirmed:false,is_test:true}
];
context.customerState.orderFilter='paid';
assert.equal(run('customerFilteredOrders().length'),1);
context.customerState.orderFilter='test';
assert.equal(run('customerFilteredOrders()[0].ref'),'AC-TEST');
context.customerState.orderFilter='all';
context.customerState.orderSearch='ssd';
assert.equal(run('customerFilteredOrders()[0].ref'),'AC-PENDING');
context.customerState.orderSearch='';
const orderMarkup=run('customerOrdersPanel()');
assert.ok(orderMarkup.includes('&lt;script&gt;'),'Order items must be HTML-escaped');
assert.ok(!orderMarkup.includes('<script>alert'),'Script markup leaked into order history');
assert.ok(orderMarkup.includes('Link a receipt from another device'));

// Address controls display escaped private account data.
const addressMarkup=run('customerAddressBookPanel()');
assert.ok(addressMarkup.includes('&lt;Home&gt;'));
assert.ok(!addressMarkup.includes('<Home>'));
assert.ok(addressMarkup.includes('Saved shipping addresses'));

// A saved address change uses the scoped RPC, not direct table access.
const values={
 addr_label:{value:'Home'},addr_street:{value:'123 Demo Lane'},addr_city:{value:'Demo City'},
 addr_state:{value:'CA'},addr_zip:{value:'94500'},addr_default:{checked:true}
};
context.saveEvent={preventDefault(){},currentTarget:{elements:{namedItem:key=>values[key]}}};
await run('customerSaveAddress(saveEvent)');
const save=calls.find(c=>c.name==='apex_customer_addresses'&&c.args.p_action==='save');
assert.ok(save,'Address save must call a server-scoped RPC');
assert.equal(save.args.p_address.street,'123 Demo Lane');
assert.equal(context.customerState.addresses.length,2);
assert.ok(messages.some(m=>m.message.includes('saved to your account')));

// Cross-device receipt linking uses the verified-email RPC and no browser storage.
context.receiptEvent={preventDefault(){},currentTarget:{elements:{namedItem:()=>({value:'https://bfung2.github.io/#/track-order?token='+token})}}};
await run('customerAttachReceipt(receiptEvent)');
assert.ok(calls.some(c=>c.name==='apex_customer_link_order'&&c.args.p_token===token));
assert.equal(refreshCount,1);
assert.ok(messages.some(m=>m.message.includes('Receipt linked')));

console.log('PASS: Phase 6 default/fallback addresses, account-scoped saves, safe receipt URLs, private order filters, HTML escaping and order refresh.');
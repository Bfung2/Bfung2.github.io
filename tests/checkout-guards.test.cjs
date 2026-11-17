// Read-only regression checks for Apex storefront purchase eligibility and cart totals.
// Run: node tests/checkout-guards.test.cjs
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const html = fs.readFileSync('index.html', 'utf8');
function extract(name, next) {
  const start = html.indexOf('function ' + name + '(');
  const end = html.indexOf('function ' + next + '(', start + 1);
  assert(start >= 0 && end > start, 'Missing function: ' + name);
  return html.slice(start, end);
}
const context = vm.createContext({S:{products:[],parts:[],settings:{taxRate:7,shippingRatePercent:2}},myCart:[],saveCart:()=>{},Number,Math,JSON,Set});
vm.runInContext(extract('apexPurchasable','apexResolveCartItem') + '\n' + extract('apexResolveCartItem','apexRefreshCart') + '\n' + extract('apexRefreshCart','addToCart') + '\n' + extract('cartTotals','catalogSearchAliases'), context);
const can = rec => vm.runInContext('apexPurchasable(' + JSON.stringify(rec) + ')', context);
const eligible = {id:'sku-1',name:'Verified part',category:'cpu',price:100,seller:'Newegg',stockStatus:'In Stock'};
assert.equal(can(eligible), true);
for(const patch of [{seller:''},{seller:'Third-party seller'},{stockStatus:''},{stockStatus:'Backordered'},{stockStatus:'Sold Out'},{active:false}]) assert.equal(can({...eligible,...patch}),false,JSON.stringify(patch));
context.S.products=[eligible];
context.myCart=[{kind:'product',id:'sku-1',qty:2,price:0,name:'tampered'}];
let totals=vm.runInContext('cartTotals()',context);
assert.equal(totals.sub,200);assert.equal(totals.tax,14);assert.equal(totals.shipping,4);assert.equal(totals.total,218);
context.myCart=[{kind:'product',id:'not-a-product',qty:1,price:1}];
assert.equal(vm.runInContext('apexResolveCartItem(myCart[0])',context),null);
context.S.products=[eligible,{...eligible,price:99}];
assert.equal(vm.runInContext('apexResolveCartItem({kind:"product",id:"sku-1",qty:1})',context),null);
console.log('PASS: eligibility, tampered cart price refresh, totals, unknown IDs and duplicate price rejection');

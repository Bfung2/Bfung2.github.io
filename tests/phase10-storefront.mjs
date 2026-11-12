import assert from "node:assert/strict";
import fs from "node:fs/promises";
import vm from "node:vm";

const html=await fs.readFile(new URL("../index.html",import.meta.url),"utf8");
const css=await fs.readFile(new URL("../storefront-ux.css",import.meta.url),"utf8");
const chunk=(a,b)=>{
 const start=html.indexOf(a),end=html.indexOf(b,start+a.length);
 assert.ok(start>=0&&end>start,"Missing storefront helper "+a);
 return html.slice(start,end);
};
for(const [,source] of html.matchAll(/<script>([\s\S]*?)<\/script>/g)){
 assert.doesNotThrow(()=>new vm.Script(source),"Inline storefront JavaScript must parse");
}

// Checkout shows line totals (including quantity) and the true subtotal,
// without changing PayPal capture or a real/test payment decision.
const checkout=chunk("function checkout(){","function orderText(");
const checkoutContext=vm.createContext({
 myCart:[{name:"Video card",price:400,qty:2},{name:"Processor",price:150,qty:1}],
 me:{name:"Test Customer",email:"test@example.invalid",phone:"555-0100"},
 checkoutPromo:{isTest:false,code:""},
 cartTotals:()=>({sub:950,shipping:20,tax:95,total:1065}),
 customerPreferredShippingAddress:()=>({street:"123 Example Road",city:"Testville",state:"CA",zip:"94500"}),
 looksLikeAddress:()=>true,
 salesHandoffNotice:()=>"",promoCheckoutField:()=>"",promoSummary:()=>"",
 esc:value=>String(value??"").replaceAll("&","&amp;").replaceAll("<","&lt;").replaceAll(">","&gt;").replaceAll('"',"&quot;"),
 money:value=>"$"+Number(value).toFixed(2)
});
vm.runInContext(checkout,checkoutContext);
const markup=vm.runInContext("checkout()",checkoutContext);
for(const expected of ["Order summary","$800.00","$150.00","$950.00","$20.00","$95.00","$1065.00","× 2",
 "checkout-order-summary","checkout-customer-form","autocomplete=\"name\"","autocomplete=\"email\"",
 "autocomplete=\"street-address\"","autocomplete=\"postal-code\"","aria-describedby=\"addrWarn\"",
 "onsubmit=\"return submitOrder(event)\"","id=\"paypalPayment\"","id=\"paypalButtons\"","Continue to PayPal"]){
 assert.ok(markup.includes(expected),"Checkout missing "+expected);
}
assert.ok(markup.indexOf("checkout-order-summary")>markup.indexOf("checkout-customer-form"),"Desktop keeps checkout form first");

// Search/input filtering batches keystrokes instead of rerendering all catalog shelves per character.
const batchSource=chunk("let storefrontFilterTimer=null;","function setProductFilter(key,val){");
const timers=new Map();let nextTimer=0,draws=0,buildOpens=0,currentRoute="/products";
const batch=vm.createContext({
 productFilters:{q:""},partFilters:{q:""},shopShelfPages:{},buildCategoryPages:{},buildMenuOpen:false,
 setTimeout:fn=>{const id=++nextTimer;timers.set(id,fn);return id;},
 clearTimeout:id=>timers.delete(id),
 route:()=>currentRoute,render:()=>draws++,toggleBuildMenu:()=>buildOpens++
});
vm.runInContext(batchSource,batch);
const call=x=>vm.runInContext(x,batch);
call("queueStorefrontFilter('products','q','g')");
call("queueStorefrontFilter('products','q','gpu')");
assert.equal(batch.productFilters.q,"gpu");
assert.equal(draws,0,"Typing should not synchronously rerender the catalog");
assert.equal(timers.size,1,"Only the latest filter render should remain queued");
for(const fn of timers.values())fn();
timers.clear();
assert.equal(draws,1);
currentRoute="/cart";
call("queueStorefrontFilter('products','q','ssd')");
for(const fn of timers.values())fn();
timers.clear();
assert.equal(draws,1,"Stale search timer must not redraw another route");
currentRoute="/build";batch.buildMenuOpen=true;
call("queueStorefrontFilter('build','q','nvidia')");
for(const fn of timers.values())fn();
assert.equal(draws,2);
assert.equal(buildOpens,1);

// Mobile Products drawer is an accessible modal panel with inert hidden content,
// Escape to close, focus restoration and body scroll lock.
const handlers={};const classes=new Map();
const classList=()=>({toggle:(name,enabled)=>classes.set(name,enabled),contains:name=>!!classes.get(name)});
const attrs={};let drawerCloseFocus=0,filterButtonFocus=0;
const closeButton={focus(){drawerCloseFocus++},getClientRects:()=>[{}],closest:()=>null};
const toggleButton={setAttribute:(k,v)=>attrs["toggle-"+k]=v,focus(){filterButtonFocus++}};
const drawer={
 parentElement:null,classList:classList(),inert:false,
 setAttribute:(k,v)=>attrs[k]=v,removeAttribute:k=>delete attrs[k],
 querySelector:()=>closeButton,querySelectorAll:()=>[closeButton],
 contains:node=>node===closeButton
};
const backdrop={parentElement:null,classList:classList()};
const sidebar={appendChild(node){node.parentElement=this;}};
const body={appendChild(node){node.parentElement=this;},classList:classList()};
drawer.parentElement=sidebar;
const doc={
 body,activeElement:closeButton,
 getElementById:id=>id==="shopFilterPanel"?drawer:null,
 querySelector:q=>q===".shop-filter-backdrop"?backdrop:q===".shop-sidebar"?sidebar:q===".shop-filter-toggle"?toggleButton:
  q===".shop-filter-drawer-head button"?closeButton:q==="dialog[open]"?null:null,
 addEventListener:(event,callback)=>{handlers[event]=callback}
};
const mobile=vm.createContext({
 document:doc,window:{matchMedia:()=>({matches:true}),addEventListener:()=>{}},
 shopFilterResizeBound:false,shopFiltersOpen:false,buildMenuOpen:false,buildPickerOpen:false,
 route:()=>"/products",setTimeout:()=>1,clearTimeout:()=>{},render:()=>{},
 productFilters:{},partFilters:{},shopShelfPages:{},buildCategoryPages:{}
});
const drawerCode=chunk("function setupShopFilterLayer(){","function setProductFilter(key,val){");
vm.runInContext(drawerCode,mobile);
vm.runInContext("setupShopFilterLayer()",mobile);
assert.equal(drawer.inert,true);
assert.equal(attrs["aria-hidden"],"true");
vm.runInContext("toggleShopFilters(true)",mobile);
assert.equal(drawer.inert,false);
assert.equal(attrs.role,"dialog");
assert.equal(attrs["aria-modal"],"true");
assert.equal(attrs["aria-hidden"],"false");
assert.equal(attrs["toggle-aria-expanded"],"true");
assert.equal(drawerCloseFocus,1);
let prevented=false;
handlers.keydown({key:"Escape",preventDefault(){prevented=true}});
assert.equal(prevented,true);
assert.equal(drawer.inert,true);
assert.equal(attrs["aria-hidden"],"true");
assert.equal(attrs["toggle-aria-expanded"],"false");
assert.equal(filterButtonFocus,1);

// Mobile CSS keeps search attached to its input, the order summary before fields,
// and dialogs scrollable without horizontal clipping.
for(const statement of [
 ".skip-to-content:focus","@media (max-width:760px)","nav.main{scroll-snap-type:x",
 ".global-search-results{position:absolute","@media (max-width:820px)",
 ".checkout-order-summary{grid-column:1;grid-row:1",
 ".checkout-customer-form{grid-column:1;grid-row:2",
 "dialog{max-height:calc(100dvh - 32px)",
 "@media (prefers-reduced-motion:reduce)"
]) assert.ok(css.includes(statement),"Missing responsive CSS rule "+statement);
for(const element of ["href=\"storefront-ux.css\"","id=\"app\" tabindex=\"-1\"","aria-label=\"Main navigation\"",
 "aria-controls=\"globalSearchResults\"","aria-current=\"page\"",
 "function syncBuildDrawerAccessibility()","function trapStorefrontPanelFocus("]){
 assert.ok(html.includes(element),"Missing UI accessibility feature "+element);
}
assert.ok(html.includes("homeMotionCleanup=null")&&html.includes("productsMotionCleanup=null"),"Detached animation cleanup required");
console.log("PASS: Phase 10 checkout arithmetic, mobile filter focus/Escape behavior, search debouncing, nav accessibility, and responsive CSS.");

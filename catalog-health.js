/* Read-only owner catalog quality dashboard. Uses only the public in-memory catalog.
   Newegg seller, stock and prices remain historical claims until independently rechecked. */
(function(){
"use strict";
const state={search:"",filter:"attention",page:1};
const PAGE_SIZE=25;
const escText=value=>String(value??"").replace(/[&<>"']/g,ch=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[ch]));
const cents=value=>{const v=Number(value);return Number.isFinite(v)?Math.round(v*100):null;};
const yes=value=>String(value||"").trim().toLowerCase();
const validSource=value=>{
 try{const u=new URL(value);return u.protocol==="https:"&&["newegg.com","www.newegg.com"].includes(u.hostname.toLowerCase())&&/\/p\/[^/]*\d[^/]*$/.test(u.pathname)?u.href:null;}catch{return null;}
};
function catalogData(data,today=new Date()){
 const byID=new Map();
 for(const section of ["products","parts"]){
  (data?.[section]||[]).forEach((p,index)=>{
   if(!p||typeof p!=="object")return;
   const id=String(p.id||"").trim(),key=id||section+":"+index;
   if(!byID.has(key))byID.set(key,{id,records:[]});
   byID.get(key).records.push({section,item:p});
  });
 }
 const now=Date.UTC(today.getUTCFullYear(),today.getUTCMonth(),today.getUTCDate());
 const rows=[];
 for(const group of byID.values()){
  const originals=group.records.map(r=>r.item);
  const pick=key=>originals.find(p=>p[key]!==undefined&&p[key]!==null&&p[key]!=="")?.[key];
  const name=String(pick("name")||"Unnamed item");
  const active=originals.some(p=>p.active!==false);
  const flags=[];
  const flag=(id,label,group)=>flags.push({id,label,group});
  const priceValues=originals.map(p=>cents(p.price));
  const price=cents(pick("price"));
  if(!group.id||name==="Unnamed item")flag("identity","Missing ID or name","critical");
  if(price==null||price<=0)flag("price","Missing or invalid Apex price","critical");
  if(new Set(priceValues).size>1)flag("price_conflict","Product / builder price differs","critical");
  const baseline=cents(pick("neweggPrice"));
  if(baseline==null||baseline<=0)flag("baseline","Missing Newegg baseline","missing");
  else if(price!=null&&price-baseline!==1500)flag("markup","Stored price is not baseline + $15","critical");
  const source=validSource(pick("sourceUrl"));
  if(!source)flag("source","Missing or invalid Newegg source URL","missing");
  if(yes(pick("seller"))!=="newegg")flag("seller",pick("seller")?"Seller not documented as direct Newegg":"Seller not documented","missing");
  const stock=yes(pick("stockStatus"));
  if(!stock)flag("stock_missing","Stock status not documented","missing");
  else if(stock!=="in stock"&&stock!=="instock")flag("stock_ineligible","Stored status is not in stock","critical");
  const verified=String(pick("verifiedDate")||"");
  const match=/^(\d{4})-(\d{2})-(\d{2})$/.exec(verified);
  const parsed=match?Date.UTC(+match[1],+match[2]-1,+match[3]):NaN;
  const roundtrip=Number.isFinite(parsed)?new Date(parsed).toISOString().slice(0,10):"";
  const days=Number.isFinite(parsed)&&roundtrip===verified?Math.round((now-parsed)/86400000):null;
  if(days===null)flag("verification_missing","Verification date missing or invalid","missing");
  else if(days<0)flag("verification_future","Verification date is in the future","critical");
  else if(days>=7)flag("verification_stale","Verified "+days+" days ago","stale");
  if(!pick("image"))flag("image","Missing product image","missing");
  if(!pick("keywords")||!Array.isArray(pick("keywords"))||!pick("keywords").length)flag("keywords","No search keywords","missing");
  if(!pick("desc")&&!pick("longDesc"))flag("description","Missing description","missing");
  rows.push({id:group.id,name,category:String(pick("category")||"Other"),active,source,
   sections:group.records.map(r=>r.section),price:price==null?null:price/100,
   baseline:baseline==null?null:baseline/100,flags,days,
   priority:flags.some(f=>f.group==="critical")?0:flags.length?1:2});
 }
 rows.sort((a,b)=>a.priority-b.priority||a.category.localeCompare(b.category)||a.name.localeCompare(b.name));
 return rows;
}
function summary(data,today){
 const rows=catalogData(data,today),active=rows.filter(r=>r.active);
 return {rows,unique:rows.length,active:active.length,
  attention:active.filter(r=>r.flags.length).length,
  critical:active.filter(r=>r.flags.some(f=>f.group==="critical")).length,
  stale:active.filter(r=>r.flags.some(f=>f.group==="stale")).length,
  missing:active.filter(r=>r.flags.some(f=>f.group==="missing")).length,
  clear:active.filter(r=>r.flags.length===0).length};
}
function selected(rows){
 const q=state.search.trim().toLowerCase();
 return rows.filter(r=>{
  if(state.filter!=="all"&&!r.active)return false;
  if(state.filter==="attention"&&!r.flags.length)return false;
  if(["critical","stale","missing"].includes(state.filter)&&!r.flags.some(f=>f.group===state.filter))return false;
  if(state.filter==="clear"&&r.flags.length)return false;
  return !q||[r.id,r.name,r.category,r.flags.map(f=>f.label).join(" ")].join(" ").toLowerCase().includes(q);
 });
}
function toCSV(rows){
 const headings=["sku","name","category","active","apex_price","stored_newegg_baseline","flags","source_url"];
 const safeCell=v=>{
  let s=String(v??"");
  if(/^[\s]*[=+\-@]/.test(s))s="'"+s; // spreadsheet formula injection protection
  return '"'+s.replace(/"/g,'""')+'"';
 };
 return [headings.join(","),...rows.map(r=>[r.id,r.name,r.category,r.active,r.price,r.baseline,r.flags.map(f=>f.id).join(";"),r.source||""].map(safeCell).join(","))].join("\r\n")+"\r\n";
}
function download(){
 if(!isOwner)return;
 const rows=selected(catalogData(S)),content=toCSV(rows);
 const blob=new Blob([content],{type:"text/csv;charset=utf-8"});
 const url=URL.createObjectURL(blob),a=document.createElement("a");
 a.href=url;a.download="apex-catalog-quality-review.csv";document.body.appendChild(a);a.click();a.remove();
 setTimeout(()=>URL.revokeObjectURL(url),1000);
}
function setFilter(v){state.filter=["attention","all","critical","stale","missing","clear"].includes(v)?v:"attention";state.page=1;render();}
function setSearch(v){state.search=String(v||"");state.page=1;render();}
function setPage(v){state.page=Math.max(1,Math.floor(Number(v)||1));render();}
function page(){
 if(!isOwner)return staff();
 const result=summary(S),rows=selected(result.rows),max=Math.max(1,Math.ceil(rows.length/PAGE_SIZE));
 state.page=Math.min(state.page,max);
 const pageRows=rows.slice((state.page-1)*PAGE_SIZE,state.page*PAGE_SIZE);
 const status=(type,label,count)=>'<button type="button" class="btn sm '+(state.filter===type?"gold":"ghost")+'" onclick="ownerCatalogHealth.setFilter(\''+type+'\')">'+escText(label)+' ('+count+')</button>';
 const metric=(title,note,num)=>'<div class="panel"><small>'+escText(title)+'</small><strong class="staff-metric">'+num+'</strong><small class="muted">'+escText(note)+'</small></div>';
 return '<div class="wrap"><div class="pagehead"><div><h2>Catalog health</h2><p>Read-only review queue for current Apex catalog data. Nothing is automatically changed or removed.</p></div><a class="btn ghost" href="#/manage">Site settings</a></div>'+
 '<div class="notice">Prices, seller, availability and verification dates shown here are <strong>stored catalog claims</strong>, not live Newegg checks. A clean row does not establish that today’s Newegg price or stock is correct. Stock quantity is not tracked here.</div>'+
 '<div class="staff-metrics">'+metric("Unique items","Across Products and Build a PC",result.unique)+metric("Active listings","Stored active flag",result.active)+metric("Needs review","Active entries with a flag",result.attention)+metric("Critical checks","Stored price, stock or ID issues",result.critical)+metric("Old verification","Seven days or more",result.stale)+metric("Incomplete evidence","Missing catalog metadata",result.missing)+'</div>'+
 '<div class="panel" style="margin-top:20px"><h3>Review queue</h3><div class="row" style="gap:8px;flex-wrap:wrap">'+
 status("attention","Needs review",result.attention)+status("critical","Critical",result.critical)+status("stale","Stale",result.stale)+status("missing","Missing data",result.missing)+status("clear","No flags",result.clear)+status("all","All items",result.unique)+
 '</div><div class="row" style="gap:12px;flex-wrap:wrap;margin:16px 0"><label for="catalogHealthSearch">Search products / issues</label><input id="catalogHealthSearch" type="search" value="'+escText(state.search)+'" oninput="ownerCatalogHealth.setSearch(this.value)" placeholder="SKU, name, category, issue"><button class="btn ghost" onclick="ownerCatalogHealth.download()">Export filtered CSV</button></div>'+
 '<p class="muted">Showing '+(rows.length?((state.page-1)*PAGE_SIZE+1):0)+'–'+Math.min(state.page*PAGE_SIZE,rows.length)+' of '+rows.length+' matching items.</p>'+
 (pageRows.length?pageRows.map(r=>'<article style="border-top:1px solid var(--line);padding:14px 0"><strong>'+escText(r.name)+'</strong><p class="muted">'+escText(r.category)+' · '+escText(r.id||"Missing ID")+' · '+escText(r.sections.join(" & "))+(r.active?"":" · Inactive")+'</p><p>Apex: '+(r.price==null?"Unknown":'$'+r.price.toFixed(2))+' · Stored Newegg baseline: '+(r.baseline==null?"Unknown":'$'+r.baseline.toFixed(2))+'</p>'+
 (r.flags.length?'<p>'+r.flags.map(f=>'<span class="staff-pill" style="margin:2px">'+escText(f.label)+'</span>').join("")+'</p>':'<p class="muted">No static catalog flags.</p>')+
 (r.source?'<a href="'+escText(r.source)+'" target="_blank" rel="noopener noreferrer">Review Newegg listing</a>':'<span class="muted">No verified source link</span>')+'</article>').join(""):'<p>No matching catalog items.</p>')+
 '<div class="row" style="justify-content:space-between;margin-top:16px"><button class="btn ghost" '+(state.page<=1?"disabled":"")+' onclick="ownerCatalogHealth.setPage('+(state.page-1)+')">Previous</button><span>Page '+state.page+' of '+max+'</span><button class="btn ghost" '+(state.page>=max?"disabled":"")+' onclick="ownerCatalogHealth.setPage('+(state.page+1)+')">Next</button></div></div></div>';
}
window.ownerCatalogHealth={page,summary,catalogData,toCSV,setFilter,setSearch,setPage,download};
})();

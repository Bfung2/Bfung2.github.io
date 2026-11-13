/* Shared Apex Computers pricing policy: sold price must cover stored Newegg cost,
   estimated shipping expense and PayPal fees while targeting a contribution margin.
   Estimates are not live supplier verification, tax advice or guaranteed net profit. */
(function(root){
  "use strict";
  const asMoneyCents=n=>Math.round((Number(n)+Number.EPSILON)*100);
  function policy(settings){
    const p=settings?.pricingPolicy||{};
    const cfg={
      margin:Number(p.targetNetMarginPercent),
      feePercent:Number(p.assumedPaymentFeePercent),
      fixed:Number(p.assumedPaymentFixedUSD),
      shippingPercent:Number(settings?.shippingRatePercent),
      shippingExpensePercent:Number(p.assumedShippingExpensePercent??settings?.shippingRatePercent),
      taxPercent:Number(settings?.taxRate??p.assumedTaxRatePercent)
    };
    if(Object.values(cfg).some(x=>!Number.isFinite(x))||
       cfg.margin<=0||cfg.margin>=100||cfg.feePercent<0||cfg.feePercent>=100||
       cfg.fixed<0||cfg.shippingPercent<0||cfg.shippingPercent>100||
       cfg.shippingExpensePercent<0||cfg.shippingExpensePercent>100||
       cfg.taxPercent<0||cfg.taxPercent>25)
      throw Error("Invalid catalog pricing settings. Check target margin, PayPal fees, shipping and tax.");
    return cfg;
  }
  function simulate(costCents,priceCents,cfg){
    const shippingCents=Math.round(priceCents*cfg.shippingPercent/100);
    const taxCents=Math.round(priceCents*cfg.taxPercent/100);
    const expenseCents=Math.round(priceCents*cfg.shippingExpensePercent/100);
    const feeCents=Math.round((priceCents+shippingCents+taxCents)*cfg.feePercent/100+cfg.fixed*100);
    const contributionCents=priceCents+shippingCents-costCents-expenseCents-feeCents;
    return {shippingCents,taxCents,expenseCents,feeCents,contributionCents,
      contributionMarginPercent:100*contributionCents/priceCents};
  }
  function quote(neweggPrice,settings){
    const cost=Number(neweggPrice);
    if(!Number.isFinite(cost)||cost<=0)throw Error("A verified Newegg purchase price is required.");
    const cfg=policy(settings), costCents=asMoneyCents(cost);
    const denominator=1+(cfg.shippingPercent-cfg.shippingExpensePercent)/100-
      cfg.feePercent/100*(1+(cfg.shippingPercent+cfg.taxPercent)/100)-cfg.margin/100;
    if(denominator<=0)throw Error("The current margin and fees cannot produce a viable selling price.");
    let priceCents=Math.max(1,Math.ceil((cost+cfg.fixed)/denominator*100));
    const passes=n=>simulate(costCents,n,cfg).contributionCents*100+1e-8>=n*cfg.margin;
    while(!passes(priceCents))priceCents++;
    while(priceCents>1&&passes(priceCents-1))priceCents--;
    const model=simulate(costCents,priceCents,cfg);
    return {price:priceCents/100,neweggCost:costCents/100,
      shipping:model.shippingCents/100,tax:model.taxCents/100,
      estimatedPayPalFee:model.feeCents/100,
      assumedShippingExpense:model.expenseCents/100,
      contribution:model.contributionCents/100,
      marginPercent:model.contributionMarginPercent};
  }
  function eligibleForSale(rec,now=new Date()){
    if(String(rec?.seller||"").trim().toLowerCase()!=="newegg")return false;
    if(String(rec?.stockStatus||"").trim().toLowerCase()!=="in stock")return false;
    try{
      const u=new URL(rec?.sourceUrl);
      if(u.protocol!=="https:"||!["www.newegg.com","newegg.com"].includes(u.hostname.toLowerCase())||!u.pathname.includes("/p/"))return false;
    }catch{return false;}
    const verified=String(rec?.verifiedDate||"");
    if(!/^\d{4}-\d{2}-\d{2}$/.test(verified))return false;
    const date=new Date(verified+"T00:00:00Z");
    if(!Number.isFinite(date.valueOf())||date.toISOString().slice(0,10)!==verified)return false;
    const today=new Date(Date.UTC(now.getUTCFullYear(),now.getUTCMonth(),now.getUTCDate()));
    const age=(today-date)/86400000;
    return age>=0&&age<7;
  }
  function applyToRecord(rec,settings,options={}){
    const cost=Number(rec?.neweggPrice);
    if(!Number.isFinite(cost)||cost<=0)return {priced:false,reason:"Missing stored Newegg cost"};
    const proposed=quote(cost,settings);
    const previous=Number(rec.price);
    const preserveHigher=options.preserveHigher!==false;
    rec.price=preserveHigher&&Number.isFinite(previous)&&previous>proposed.price?
      Math.round(previous*100)/100:proposed.price;
    rec.active=rec.active!==false&&eligibleForSale(rec,options.now);
    return {priced:true,minimumPrice:proposed.price,active:rec.active,model:proposed};
  }
  root.apexProfitPricing={policy,quote,eligibleForSale,applyToRecord};
  if(typeof module!=="undefined"&&module.exports)module.exports=root.apexProfitPricing;
})(typeof globalThis!=="undefined"?globalThis:this);

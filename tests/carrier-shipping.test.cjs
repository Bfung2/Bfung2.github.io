const test = require("node:test");
const assert = require("node:assert/strict");

test("carrier module: destination parsing, parcel validation, live quote, and fail-closed checks", async () => {
  const { destinationFromAddress, parcelForRecord, shipmentParcels, quoteActualShipping } =
    await import("../supabase/functions/_shared/carrier-shipping.mjs");
  assert.deepEqual(destinationFromAddress("123 Main St, Antioch, CA 94509"),
    { street1:"123 Main St",city:"Antioch",state:"CA",zip:"94509",country:"US" });
  assert.throws(() => destinationFromAddress("123 Main St"), /complete U.S./);
  assert.throws(() => parcelForRecord({name:"CPU"}), /weight and box dimensions/);
  const part = {id:"p1",name:"CPU",category:"CPU",shipLengthIn:10,shipWidthIn:7,shipHeightIn:5,shipWeightOz:24};
  const pcCase = {id:"p2",name:"Case",category:"Case",pcShipLengthIn:27,pcShipWidthIn:25,pcShipHeightIn:16,pcShipWeightOz:640};
  const catalog = {products:[part,pcCase],parts:[],settings:{pricingPolicy:{assumedPaymentFeePercent:4.99}}};
  assert.equal(shipmentParcels([{kind:"product",id:"p1",qty:2}],catalog).length,2);
  assert.deepEqual(shipmentParcels([{kind:"build",assembly:true,parts:[{id:"p1",category:"CPU"},{id:"p2",category:"Case"}]}],catalog)[0].parcel,
    {length:27,width:25,height:16,weight:640});
  assert.throws(()=>shipmentParcels([{kind:"build",assembly:true,parts:[{id:"p1",category:"CPU"}]}],catalog),/requires a case/);
  const env = name => ({EASYPOST_API_KEY:"demo-only",APEX_SHIP_FROM_JSON:JSON.stringify({
    name:"Apex Computers",street1:"123 Demo St",city:"Antioch",state:"CA",zip:"94509",country:"US"})})[name];
  const requested = [];
  const fetcher = async (url,init) => {
    requested.push({url,body:JSON.parse(init.body)});
    return {ok:true,json:async()=>({id:"shp_123",mode:"production",rates:[
      {id:"rate_1",carrier:"USPS",service:"Priority",currency:"USD",rate:"15.00"},
      {id:"rate_2",carrier:"UPS",service:"Ground",currency:"USD",rate:"12.00"}
    ]})};
  };
  const result=await quoteActualShipping([{kind:"product",id:"p1",qty:1}],catalog,
    {street:"123 Main St",city:"Antioch",state:"CA",zip:"94509"},{env,fetcher});
  assert.equal(result.carrierCost,12);
  assert.equal(result.charge,12.63);
  assert.equal(result.packages[0].carrier,"UPS");
  assert.equal(requested[0].body.shipment.parcel.weight,24);
  await assert.rejects(()=>quoteActualShipping([{kind:"product",id:"p1",qty:1}],catalog,
    {street:"123 Main St",city:"Antioch",state:"CA",zip:"94509"},{
      env:()=>null,fetcher
    }),/configure its carrier account/);
  await assert.rejects(()=>quoteActualShipping([{kind:"product",id:"p1",qty:1}],catalog,
    {street:"123 Main St",city:"Antioch",state:"CA",zip:"94509"},{
      env,fetcher:async()=>({ok:true,json:async()=>({mode:"test",rates:[{rate:"1.00",currency:"USD"}]})})
    }),/Only live carrier rates/);
});

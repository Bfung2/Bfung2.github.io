/* Phase 7: owner-only contribution reconciliation. Never moves funds. */
function staffEmployeeLedgerStats(id){
 const rows=(staffSales.items||[]).filter(c=>c.employee_id===id);
 const paidReal=rows.filter(c=>c.settlement_status==='paid'&&!c.is_test);
 const paidTest=rows.filter(c=>c.settlement_status==='paid'&&c.is_test);
 const voided=rows.filter(c=>c.settlement_status==='void');
 const pending=rows.filter(c=>(!c.settlement_status||c.settlement_status==='pending')&&!c.is_test);
 const cents=pending.reduce((sum,c)=>sum+(Number(c.commission_cents)||0),0);
 const missing=pending.filter(c=>c.commission_cents==null).length;
 return 'Paid: '+paidReal.length+' real, '+paidTest.length+' test · Voided: '+voided.length+' · Outstanding: '+money(cents/100)+(missing?' ('+missing+' missing amount'+(missing===1?'':'s')+')':'');
}
function staffSalesExportRows(){
 if(!isOwner)return [];
 return staffVisibleContributions(staffSales.items||[]);
}
function staffCsvCell(value){
 let str=String(value??'').replace(/[\r\n\t]/g,' ');
 // Prevent spreadsheet formula execution when opening exported employee-entered text.
 if(/^\s*[=+\-@]/.test(str))str="'"+str;
 return '"'+str.replace(/"/g,'""')+'"';
}
function staffSalesCsvText(rows){
 const header=['Type','Test sale','Status','Employee','Order or lead reference','Job kind','Job ID','Commission USD','Amount missing','Credited date','Settled date','Payment/commission note'];
 const lines=rows.map(c=>{
  const status=c.settlement_status||'pending';
  const cents=Number(c.commission_cents);
  const amount=c.commission_cents==null?'':Number.isFinite(cents)?(cents/100).toFixed(2):'';
  return [
   c.is_test?'TEST':'REAL',
   c.is_test?'Yes':'No',
   status==='paid'?'Employee paid':status==='void'?'Voided':'Outstanding',
   c.employee_name||'',
   c.reference||'',
   c.job_kind||'',
   c.job_id||'',
   amount,
   c.commission_cents==null?'Yes':'No',
   c.credited_at||'',
   c.settled_at||'',
   c.commission_note||''
  ].map(staffCsvCell).join(',');
 });
 // UTF-8 BOM enables spreadsheet apps to read employee names correctly.
 return '\uFEFF'+[header.map(staffCsvCell).join(','),...lines].join('\r\n')+'\r\n';
}
function staffSalesToolbar(){
 if(!isOwner)return '';
 const visible=staffSalesExportRows(),test=visible.filter(c=>c.is_test).length;
 return '<div class="row" style="margin:12px 0;align-items:center;gap:10px;flex-wrap:wrap">'+
  '<button class="btn ghost" type="button" onclick="staffExportSalesCsv()" '+(!visible.length?'disabled':'')+'>Export displayed contributions (CSV)</button>'+
  '<small class="muted">Owner only · '+visible.length+' matching records ('+test+' TEST). Filter by employee, status, and date before exporting. This is a record of payments, not a money transfer.</small>'+
  '</div>';
}
function staffExportSalesCsv(){
 if(!isOwner)return;
 const rows=staffSalesExportRows();
 if(!rows.length){toast('No matching contributions to export.');return;}
 const file=new Blob([staffSalesCsvText(rows)],{type:'text/csv;charset=utf-8'});
 const url=URL.createObjectURL(file);
 try{
  const a=document.createElement('a');
  a.href=url;
  a.download='apex-employee-contributions-'+new Date().toISOString().slice(0,10)+'.csv';
  document.body.appendChild(a);
  a.click();
  a.remove();
  toast('Contribution report exported. Treat it as private employee data.');
 }finally{
  setTimeout(()=>URL.revokeObjectURL(url),1000);
 }
}
function staffRefreshSalesResultRows(){
 // Refresh the list without replacing the search box on each keystroke.
 const box=document.getElementById('staffSalesResults');
 if(box)box.innerHTML=staffSalesList(staffSales.items||[]);
}

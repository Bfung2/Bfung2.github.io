export function paidOrderMessage(order: any) {
  const money = (v: unknown) => '$' + Number(v || 0).toFixed(2);
  const lines = ['PAYMENT VERIFIED — ' + String(order.ref || order.id),
    'Sales employee: ' + (order.sales_employee_name || 'Direct website order'),
    'Sales reference: ' + (order.sales_employee_code || 'Not applicable'),
    '', 'CUSTOMER', 'Name: ' + order.customer_name, 'Email: ' + order.customer_email,
    'Phone: ' + (order.customer_phone || 'Not provided'), 'Address: ' + (typeof order.shipping_address === 'object' ? Object.values(order.shipping_address || {}).filter(Boolean).join(', ') : order.shipping_address),
    '', 'ORDER'];
  for (const item of order.items || []) {
    lines.push('- ' + item.name + ' × ' + (item.qty || 1) + ' — ' + money(item.price));
    if (item.kind === 'build') {
      for (const part of item.parts || []) lines.push('    ' + part.category + ': ' + part.name + ' — ' + money(part.price));
      lines.push('    Assembly: ' + (item.assembly ? money(item.fee) : 'Parts only'));
    }
  }
  lines.push('', 'Subtotal: ' + money(order.subtotal), 'Promo discount: -' + money(order.discount_amount),
    'Shipping: ' + money(order.shipping), 'Tax: ' + money(order.tax), 'PAID TOTAL: ' + money(order.total),
    'PayPal capture: ' + (order.paypal_capture_id || 'Recorded in PayPal'), 'Customer notes: ' + (order.notes || 'None'));
  return {subject: ('PAID Apex order ' + (order.ref || order.id) + (order.sales_employee_code ? ' · ' + order.sales_employee_code : '')).replace(/[\r\n]/g, ' ').slice(0, 180), body: lines.join('\n')};
}
export function utf8Base64(value: string) {
  let binary = ''; for (const byte of new TextEncoder().encode(value)) binary += String.fromCharCode(byte);
  return btoa(binary);
}

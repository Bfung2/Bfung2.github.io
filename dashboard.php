<?php
$title = 'Dashboard';
require_once __DIR__ . '/../includes/admin-header.php';
$products = all_products(); $parts = all_parts();
$orders   = read_json('orders'); $msgs = read_json('messages');
$revenue  = 0; foreach ($orders as $o) if (($o['status'] ?? '') === 'paid') $revenue += $o['totals']['grand'];
$ready    = setting('owner_email') !== '';
?>
<h1>Dashboard</h1>

<?php if (!$ready): ?>
  <div class="notice notice-bad">No email address is set yet, so orders and enquiries have nowhere to go. <a href="settings.php">Add your email in Settings</a>.</div>
<?php endif; ?>
<?php if (setting('payment_mode') !== 'stripe'): ?>
  <div class="notice notice-info">Card payments are off. Customers can place orders and you'll invoice them. <a href="settings.php#payments">Turn on card payments</a>.</div>
<?php endif; ?>

<div class="grid" style="grid-template-columns:repeat(auto-fit,minmax(160px,1fr));margin-bottom:28px">
  <?php foreach ([
      ['Products',   count($products), 'products.php'],
      ['Build parts',count($parts),    'parts.php'],
      ['Orders',     count($orders),   'orders.php'],
      ['Messages',   count($msgs),     'messages.php'],
      ['Paid to date', money($revenue),'orders.php'],
  ] as $stat): ?>
  <a class="card" href="<?= $stat[2] ?>" style="text-decoration:none;color:inherit">
    <div class="card-body">
      <span class="mono muted"><?= e($stat[0]) ?></span>
      <strong style="font-size:1.9rem;font-family:var(--mono);line-height:1"><?= e((string)$stat[1]) ?></strong>
    </div>
  </a>
  <?php endforeach; ?>
</div>

<h2>Latest orders</h2>
<?php if (!$orders): ?>
  <div class="empty-state"><p>No orders yet. They'll show up here and in your inbox.</p></div>
<?php else: ?>
<div class="table-wrap">
  <table>
    <thead><tr><th>Ref</th><th>Customer</th><th>Status</th><th>Build?</th><th class="num">Total</th><th></th></tr></thead>
    <tbody>
    <?php foreach (array_slice($orders, 0, 8) as $o): ?>
      <tr>
        <td class="mono"><?= e($o['ref']) ?></td>
        <td><?= e($o['customer']['name']) ?><br><span class="mono muted"><?= e($o['customer']['email']) ?></span></td>
        <td><span class="tag <?= $o['status']==='paid'?'tag-rec':'' ?>"><?= e($o['status']) ?></span></td>
        <td><?= $o['totals']['assembly'] ? 'Yes — ' . money($o['totals']['assembly']) : 'Parts only' ?></td>
        <td class="num"><?= money($o['totals']['grand']) ?></td>
        <td><a href="orders.php?view=<?= e($o['id']) ?>">Open</a></td>
      </tr>
    <?php endforeach; ?>
    </tbody>
  </table>
</div>
<?php endif; ?>

<h2 style="margin-top:36px">Quick actions</h2>
<div style="display:flex;gap:10px;flex-wrap:wrap">
  <a class="btn btn-sm" href="products.php">Add a product</a>
  <a class="btn btn-sm" href="parts.php">Add a build part</a>
  <a class="btn btn-sm btn-quiet" href="settings.php">Edit site text &amp; pricing</a>
</div>

<?php require_once __DIR__ . '/../includes/admin-footer.php'; ?>

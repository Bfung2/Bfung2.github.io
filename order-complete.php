<?php
require_once __DIR__ . '/includes/config.php';
$page = ''; $title = 'Order received';

$order = get_order($_GET['order'] ?? '');
if (!$order) { include __DIR__ . '/includes/header.php'; ?>
  <section class="section"><div class="shell"><div class="empty-state"><p>We couldn't find that order.</p><a class="btn btn-sm" href="index.php">Back to the shop</a></div></div></section>
<?php include __DIR__ . '/includes/footer.php'; exit; }

/* Returning from Stripe's hosted page. */
if (!empty($_GET['paid']) && $order['status'] === 'awaiting payment') {
    $order = update_order($order['id'], [
        'status'  => 'paid',
        'payment' => array_merge($order['payment'], ['reference' => 'stripe:' . $order['id']]),
    ]);
    notify_order($order);
    cart_clear();
}

include __DIR__ . '/includes/header.php';
?>
<section class="section">
  <div class="shell" style="max-width:720px">
    <h1>Order <?= e($order['ref']) ?> received</h1>
    <p>We've emailed a copy to <strong><?= e($order['customer']['email']) ?></strong>. <?= $order['status'] === 'paid' ? 'Payment went through.' : 'We\'ll send you an invoice shortly.' ?></p>

    <div class="table-wrap" style="margin:24px 0">
      <table>
        <thead><tr><th>Item</th><th class="num">Qty</th><th class="num">Total</th></tr></thead>
        <tbody>
          <?php foreach ($order['lines'] as $l): ?>
            <tr><td><?= e($l['name']) ?></td><td class="num"><?= (int)$l['qty'] ?></td><td class="num"><?= money($l['total']) ?></td></tr>
          <?php endforeach; ?>
          <?php if ($order['totals']['assembly']): ?><tr><td>Assembly and testing</td><td class="num">1</td><td class="num"><?= money($order['totals']['assembly']) ?></td></tr><?php endif; ?>
          <tr><td colspan="2"><strong>Total</strong></td><td class="num"><strong><?= money($order['totals']['grand']) ?></strong></td></tr>
        </tbody>
      </table>
    </div>

    <p class="muted"><?= $order['totals']['assembly']
        ? 'We\'ll assemble, cable-manage and stress-test this before it ships.'
        : 'Parts will ship unassembled.' ?></p>
    <a class="btn" href="index.php">Back to the shop</a>
  </div>
</section>
<?php include __DIR__ . '/includes/footer.php'; ?>

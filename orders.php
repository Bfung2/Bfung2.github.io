<?php
$title = 'Orders';
require_once __DIR__ . '/../includes/admin-header.php';

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    check_csrf();
    if (post('action') === 'status') {
        update_order(post('id'), ['status' => post('status')]);
        flash('Order updated.');
    } elseif (post('action') === 'resend') {
        $o = get_order(post('id'));
        if ($o) { notify_order($o); flash('Order email re-sent to you and the customer.'); }
    }
    redirect('orders.php' . (post('back') ? '?view=' . urlencode(post('back')) : ''));
}

$orders = read_json('orders');
$view   = isset($_GET['view']) ? get_order($_GET['view']) : null;
$states = ['awaiting payment','paid','invoice pending','building','shipped','complete','cancelled'];

if ($view): ?>
  <p><a href="orders.php">&larr; All orders</a></p>
  <h1><?= e($view['ref']) ?></h1>
  <p class="mono muted"><?= e(date('D j M Y, g:ia', strtotime($view['at']))) ?> · <?= e($view['payment']['method']) ?></p>

  <div class="row2" style="margin:24px 0">
    <div class="panel">
      <h3>Customer</h3>
      <p style="margin:0">
        <strong><?= e($view['customer']['name']) ?></strong><br>
        <a href="mailto:<?= e($view['customer']['email']) ?>"><?= e($view['customer']['email']) ?></a><br>
        <?= e($view['customer']['phone']) ?>
      </p>
      <h3 style="margin-top:18px">Ship to</h3>
      <p class="mono" style="margin:0;font-size:.85rem">
        <?= nl2br(e($view['customer']['address'])) ?><br>
        <?= e($view['customer']['city']) ?>, <?= e($view['customer']['state']) ?> <?= e($view['customer']['zip']) ?><br>
        <?= e($view['customer']['country']) ?>
      </p>
      <?php if (!empty($view['notes'])): ?><h3 style="margin-top:18px">Notes</h3><p style="margin:0"><?= nl2br(e($view['notes'])) ?></p><?php endif; ?>
    </div>
    <div class="panel">
      <h3>Status</h3>
      <form method="post">
        <?= csrf_field() ?>
        <input type="hidden" name="action" value="status">
        <input type="hidden" name="id" value="<?= e($view['id']) ?>">
        <input type="hidden" name="back" value="<?= e($view['id']) ?>">
        <div class="field">
          <select name="status">
            <?php foreach ($states as $st): ?><option <?= $view['status'] === $st ? 'selected' : '' ?>><?= e($st) ?></option><?php endforeach; ?>
          </select>
        </div>
        <button class="btn btn-sm" type="submit">Update status</button>
      </form>
      <hr style="border:0;border-top:1px solid var(--mat-dim);margin:18px 0">
      <p style="font-size:.9rem"><?= $view['totals']['assembly']
          ? '<strong>Build it.</strong> They paid the ' . money($view['totals']['assembly']) . ' assembly fee.'
          : '<strong>Parts only.</strong> No assembly — ship loose.' ?></p>
      <form method="post">
        <?= csrf_field() ?>
        <input type="hidden" name="action" value="resend">
        <input type="hidden" name="id" value="<?= e($view['id']) ?>">
        <input type="hidden" name="back" value="<?= e($view['id']) ?>">
        <button class="btn btn-sm btn-quiet" type="submit">Re-send the order email</button>
      </form>
    </div>
  </div>

  <h3>Parts list</h3>
  <div class="table-wrap">
    <table>
      <thead><tr><th>Item</th><th class="num">Qty</th><th class="num">Each</th><th class="num">Total</th></tr></thead>
      <tbody>
        <?php foreach ($view['lines'] as $l): ?>
          <tr><td><?= e($l['name']) ?></td><td class="num"><?= (int)$l['qty'] ?></td><td class="num"><?= money($l['price']) ?></td><td class="num"><?= money($l['total']) ?></td></tr>
        <?php endforeach; ?>
        <?php foreach ([['Assembly','assembly'],['Shipping','shipping'],['Tax','tax']] as $x):
          if ($view['totals'][$x[1]] > 0): ?>
          <tr><td colspan="3"><?= $x[0] ?></td><td class="num"><?= money($view['totals'][$x[1]]) ?></td></tr>
        <?php endif; endforeach; ?>
        <tr><td colspan="3"><strong>Total</strong></td><td class="num"><strong><?= money($view['totals']['grand']) ?></strong></td></tr>
      </tbody>
    </table>
  </div>

<?php else: ?>
  <h1>Orders</h1>
  <?php if (!$orders): ?>
    <div class="empty-state"><p>No orders yet.</p></div>
  <?php else: ?>
  <div class="table-wrap">
    <table>
      <thead><tr><th>Ref</th><th>Date</th><th>Customer</th><th>Status</th><th>Build?</th><th class="num">Total</th><th></th></tr></thead>
      <tbody>
      <?php foreach ($orders as $o): ?>
        <tr>
          <td class="mono"><?= e($o['ref']) ?></td>
          <td class="mono" style="font-size:.78rem"><?= e(date('j M y', strtotime($o['at']))) ?></td>
          <td><?= e($o['customer']['name']) ?><br><span class="mono muted" style="font-size:.76rem"><?= e($o['customer']['email']) ?></span></td>
          <td><span class="tag <?= $o['status']==='paid'?'tag-rec':'' ?>"><?= e($o['status']) ?></span></td>
          <td><?= $o['totals']['assembly'] ? 'Yes' : 'No' ?></td>
          <td class="num"><?= money($o['totals']['grand']) ?></td>
          <td><a class="btn btn-sm btn-quiet" href="orders.php?view=<?= e($o['id']) ?>">Open</a></td>
        </tr>
      <?php endforeach; ?>
      </tbody>
    </table>
  </div>
  <?php endif; ?>
<?php endif; ?>
<?php require_once __DIR__ . '/../includes/admin-footer.php'; ?>

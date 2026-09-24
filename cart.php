<?php
require_once __DIR__ . '/includes/config.php';
$page = 'cart'; $title = 'Cart';

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    check_csrf();
    $a = post('action');
    if ($a === 'update') {
        foreach (($_POST['qty'] ?? []) as $key => $q) cart_set_qty($key, $q);
        $_SESSION['assembly'] = (post('assembly') === '1' && setting('offer_assembly'));
        flash('Cart updated.');
    } elseif ($a === 'remove') {
        cart_set_qty(post('key'), 0);
        flash('Item removed.');
    } elseif ($a === 'empty') {
        cart_clear();
        flash('Cart emptied.');
    }
    redirect('cart.php');
}

$t = cart_totals();
include __DIR__ . '/includes/header.php';
?>
<section class="section">
  <div class="shell">
    <h1>Your cart</h1>

    <?php if (!$t['lines']): ?>
      <div class="empty-state">
        <p>Your cart is empty.</p>
        <a class="btn btn-sm" href="products.php">Browse parts</a>
        <a class="btn btn-sm btn-quiet" href="build-pc.php">Build a PC</a>
      </div>
    <?php else: ?>
      <form method="post">
        <?= csrf_field() ?>
        <input type="hidden" name="action" value="update">
        <div class="build-layout">
          <div>
            <div class="table-wrap">
              <table>
                <thead><tr><th>Item</th><th>Type</th><th class="num">Price</th><th style="width:100px">Qty</th><th class="num">Total</th><th></th></tr></thead>
                <tbody>
                <?php foreach ($t['lines'] as $l): ?>
                  <tr>
                    <td><strong><?= e($l['name']) ?></strong></td>
                    <td><span class="tag"><?= $l['type'] === 'part' ? 'build part' : 'product' ?></span></td>
                    <td class="num"><?= money($l['price']) ?></td>
                    <td><input type="number" name="qty[<?= e($l['key']) ?>]" value="<?= (int)$l['qty'] ?>" min="0" aria-label="Quantity for <?= e($l['name']) ?>"></td>
                    <td class="num"><?= money($l['total']) ?></td>
                    <td><button class="btn btn-sm btn-quiet" type="submit" name="action" value="remove" formnovalidate onclick="this.form.key.value='<?= e($l['key']) ?>'">Remove</button></td>
                  </tr>
                <?php endforeach; ?>
                </tbody>
              </table>
            </div>
            <input type="hidden" name="key" value="">

            <?php if (setting('offer_assembly')): ?>
            <label class="checkrow" style="margin-top:18px">
              <input type="checkbox" name="assembly" value="1" <?= $t['assembly'] ? 'checked' : '' ?>>
              <span><strong>Have us assemble it — <?= money(setting('build_fee', 250)) ?></strong><br>
              <span class="muted" style="font-size:.86rem">We put it together, cable-manage it, update the BIOS and stress-test it before it goes out.</span></span>
            </label>
            <?php endif; ?>

            <div style="display:flex;gap:10px;margin-top:18px;flex-wrap:wrap">
              <button class="btn btn-quiet btn-sm" type="submit">Update cart</button>
              <button class="btn btn-quiet btn-sm" type="submit" name="action" value="empty" formnovalidate>Empty cart</button>
              <a class="btn btn-quiet btn-sm" href="products.php">Keep shopping</a>
            </div>
          </div>

          <aside>
            <div class="summary">
              <h3>Order total</h3>
              <div class="line"><span>Parts &amp; products</span><span><?= money($t['subtotal']) ?></span></div>
              <?php if ($t['assembly']): ?><div class="line"><span>Assembly</span><span><?= money($t['assembly']) ?></span></div><?php endif; ?>
              <?php if ($t['shipping']): ?><div class="line"><span>Shipping</span><span><?= money($t['shipping']) ?></span></div><?php endif; ?>
              <?php if ($t['tax']): ?><div class="line"><span>Tax (<?= e(setting('tax_rate', 0)) ?>%)</span><span><?= money($t['tax']) ?></span></div><?php endif; ?>
              <div class="grand"><span>Total</span><span><?= money($t['grand']) ?></span></div>
              <a class="btn" href="checkout.php" style="width:100%;box-sizing:border-box">Go to checkout</a>
            </div>
          </aside>
        </div>
      </form>
    <?php endif; ?>
  </div>
</section>
<?php include __DIR__ . '/includes/footer.php'; ?>

<?php
require_once __DIR__ . '/includes/config.php';
$page = 'products'; $title = 'Parts & products';

if ($_SERVER['REQUEST_METHOD'] === 'POST' && post('action') === 'add') {
    check_csrf();
    cart_add('product', post('id'), max(1, (int)post('qty', 1)));
    flash('Added to your cart.');
    redirect('products.php#p-' . urlencode(post('id')));
}

$products = all_products();
$q   = trim($_GET['q'] ?? '');
$cat = trim($_GET['cat'] ?? '');
$cats = [];
foreach ($products as $p) if (!empty($p['category'])) $cats[$p['category']] = true;
$cats = array_keys($cats); sort($cats);

$shown = array_filter($products, function ($p) use ($q, $cat) {
    if ($cat !== '' && ($p['category'] ?? '') !== $cat) return false;
    if ($q === '') return true;
    return stripos($p['name'] . ' ' . ($p['detail'] ?? ''), $q) !== false;
});

include __DIR__ . '/includes/header.php';
?>
<section class="section">
  <div class="shell">
    <div class="section-head">
      <div>
        <h1 style="margin-bottom:.2em">Parts &amp; products</h1>
        <p class="muted mono"><?= count($shown) ?> item<?= count($shown) === 1 ? '' : 's' ?></p>
      </div>
      <?php if (is_admin()): ?><a class="btn btn-sm" href="admin/products.php">Add a product</a><?php endif; ?>
    </div>

    <?php if ($products): ?>
    <form method="get" class="panel" style="margin-bottom:24px">
      <div class="row2">
        <div class="field" style="margin:0"><label for="q">Search</label><input id="q" type="text" name="q" value="<?= e($q) ?>" placeholder="Name or description"></div>
        <div class="field" style="margin:0">
          <label for="cat">Category</label>
          <select id="cat" name="cat">
            <option value="">All categories</option>
            <?php foreach ($cats as $c): ?><option value="<?= e($c) ?>" <?= $cat===$c?'selected':'' ?>><?= e($c) ?></option><?php endforeach; ?>
          </select>
        </div>
      </div>
      <div style="margin-top:14px;display:flex;gap:10px">
        <button class="btn btn-sm" type="submit">Apply</button>
        <?php if ($q !== '' || $cat !== ''): ?><a class="btn btn-sm btn-quiet" href="products.php">Clear</a><?php endif; ?>
      </div>
    </form>
    <?php endif; ?>

    <?php if (!$shown): ?>
      <div class="empty-state">
        <p><?= $products ? 'No products match that search.' : 'No products listed yet.' ?></p>
        <?php if (is_admin() && !$products): ?><a class="btn btn-sm" href="admin/products.php">Add your first product</a><?php endif; ?>
      </div>
    <?php else: ?>
      <div class="grid">
      <?php foreach ($shown as $p):
        $stock = $p['stock'] ?? '';
        $out   = ($stock !== '' && (int)$stock <= 0); ?>
        <article class="card" id="p-<?= e($p['id']) ?>">
          <?php if (!empty($p['image'])): ?>
            <div class="card-img"><img src="<?= e(img_url($p['image'])) ?>" alt="<?= e($p['name']) ?>" loading="lazy"></div>
          <?php else: ?><div class="card-img empty">no photo</div><?php endif; ?>
          <div class="card-body">
            <?php if (!empty($p['category'])): ?><span class="tag"><?= e($p['category']) ?></span><?php endif; ?>
            <h3><?= e($p['name']) ?></h3>
            <?php if (!empty($p['detail'])): ?><p><?= nl2br(e($p['detail'])) ?></p><?php endif; ?>
            <?php if ($out): ?><span class="tag tag-out">Out of stock</span><?php endif; ?>
            <div class="card-foot">
              <span class="price"><?= money($p['price']) ?></span>
              <?php if ($out): ?>
                <button class="btn btn-sm" disabled>Out of stock</button>
              <?php else: ?>
                <form method="post" style="display:flex;gap:6px;align-items:center">
                  <?= csrf_field() ?>
                  <input type="hidden" name="action" value="add">
                  <input type="hidden" name="id" value="<?= e($p['id']) ?>">
                  <input type="number" name="qty" value="1" min="1" style="width:62px;padding:7px" aria-label="Quantity">
                  <button class="btn btn-sm" type="submit">Add to cart</button>
                </form>
              <?php endif; ?>
            </div>
            <?php if (is_admin()): ?>
              <a class="mono" href="admin/products.php?edit=<?= e($p['id']) ?>">Edit this product</a>
            <?php endif; ?>
          </div>
        </article>
      <?php endforeach; ?>
      </div>
    <?php endif; ?>
  </div>
</section>
<?php include __DIR__ . '/includes/footer.php'; ?>

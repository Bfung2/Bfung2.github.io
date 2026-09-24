<?php
require_once __DIR__ . '/includes/config.php';
$page = 'home'; $title = null;
$products = array_slice(array_filter(all_products(), fn($p) => !empty($p['featured'])), 0, 4);
if (!$products) $products = array_slice(all_products(), 0, 4);
$partCount = count(all_parts());
include __DIR__ . '/includes/header.php';
?>

<section class="hero">
  <div class="shell hero-grid">
    <div>
      <h1><?= e(setting('site_name')) ?></h1>
      <p><?= e(setting('tagline')) ?></p>
      <div class="hero-actions">
        <a class="btn" href="build-pc.php">Start a build</a>
        <a class="btn btn-ghost" href="products.php">Browse parts</a>
      </div>
    </div>
    <div class="speclist">
      <div><span>Parts in stock</span><b><?= $partCount ?></b></div>
      <div><span>Assembly &amp; testing</span><b><?= setting('offer_assembly') ? money(setting('build_fee', 250)) : 'n/a' ?></b></div>
      <div><span>On-site tech visits</span><b><a href="request-tech.php" style="color:var(--amber)">Request</a></b></div>
    </div>
  </div>
</section>

<section class="section">
  <div class="shell">
    <div class="section-head">
      <h2>What we've got on the bench</h2>
      <a href="products.php">See everything</a>
    </div>

    <?php if (!$products): ?>
      <div class="empty-state">
        <p>Nothing listed yet.</p>
        <?php if (is_admin()): ?><a class="btn btn-sm" href="admin/products.php">Add your first product</a>
        <?php else: ?><p class="mono">Check back soon.</p><?php endif; ?>
      </div>
    <?php else: ?>
      <div class="grid">
        <?php foreach ($products as $p): ?>
        <article class="card">
          <?php if (!empty($p['image'])): ?>
            <div class="card-img"><img src="<?= e(img_url($p['image'])) ?>" alt="<?= e($p['name']) ?>"></div>
          <?php else: ?><div class="card-img empty">no photo</div><?php endif; ?>
          <div class="card-body">
            <h3><?= e($p['name']) ?></h3>
            <p><?= e(mb_substr((string)($p['detail'] ?? ''), 0, 110)) ?></p>
            <div class="card-foot">
              <span class="price"><?= money($p['price']) ?></span>
              <a class="btn btn-sm" href="products.php#p-<?= e($p['id']) ?>">View</a>
            </div>
          </div>
        </article>
        <?php endforeach; ?>
      </div>
    <?php endif; ?>
  </div>
</section>

<?php include __DIR__ . '/includes/footer.php'; ?>

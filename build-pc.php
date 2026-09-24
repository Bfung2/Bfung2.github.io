<?php
require_once __DIR__ . '/includes/config.php';
$page = 'build'; $title = 'Build a PC';

if ($_SERVER['REQUEST_METHOD'] === 'POST' && post('action') === 'addbuild') {
    check_csrf();
    $chosen = $_POST['part'] ?? [];
    $n = 0;
    foreach ($chosen as $id) { if ($id !== '') { cart_add('part', $id, 1); $n++; } }
    $_SESSION['assembly'] = (post('assembly') === '1' && setting('offer_assembly'));
    if ($n === 0) { flash('Pick at least one part before adding the build to your cart.'); redirect('build-pc.php'); }
    flash("Build added to your cart — $n part" . ($n === 1 ? '' : 's') . '.');
    redirect('cart.php');
}

$cats  = part_categories();
$parts = all_parts();
$byCat = [];
foreach ($parts as $p) $byCat[$p['category'] ?? 'other'][] = $p;

$order = ['cpu','motherboard','ram','gpu','storage','cooler','psu','case','other'];
include __DIR__ . '/includes/header.php';
?>
<section class="section">
  <div class="shell">
    <div class="section-head">
      <div>
        <h1 style="margin-bottom:.2em">Build a PC</h1>
        <p class="muted">Pick a processor first. Everything below it re-sorts to show what actually fits.</p>
      </div>
      <?php if (is_admin()): ?><a class="btn btn-sm" href="admin/parts.php">Manage parts</a><?php endif; ?>
    </div>

    <?php if (!$parts): ?>
      <div class="empty-state">
        <p>No parts have been added to the build list yet.</p>
        <?php if (is_admin()): ?><a class="btn btn-sm" href="admin/parts.php">Add parts</a><?php endif; ?>
      </div>
    <?php else: ?>

    <form method="post" id="build-form">
      <?= csrf_field() ?>
      <input type="hidden" name="action" value="addbuild">

      <div class="build-layout">
        <div>
          <?php foreach ($order as $key):
            if (empty($byCat[$key])) continue; ?>
            <section class="slot" data-slot="<?= e($key) ?>">
              <div class="slot-head">
                <h3><?= e($cats[$key] ?? ucfirst($key)) ?></h3>
                <button type="button" class="btn btn-sm btn-quiet js-clear" data-for="<?= e($key) ?>">Clear</button>
              </div>
              <div class="slot-body">
                <?php foreach ($byCat[$key] as $p):
                  $specbits = array_filter([
                    $p['brand'] ?? '', $p['socket'] ?? '', $p['ram_type'] ?? '',
                    !empty($p['cpu_gen']) ? $p['cpu_gen'] : '',
                    !empty($p['wattage']) ? $p['wattage'] . 'W' : '',
                    !empty($p['form_factor']) ? $p['form_factor'] : '',
                  ]);
                  $outOfStock = isset($p['stock']) && $p['stock'] !== '' && (int)$p['stock'] <= 0; ?>
                  <label class="opt<?= $outOfStock ? ' locked' : '' ?>"
                         data-id="<?= e($p['id']) ?>"
                         data-cat="<?= e($key) ?>"
                         data-brand="<?= e($p['brand'] ?? '') ?>"
                         data-socket="<?= e($p['socket'] ?? '') ?>"
                         data-ramtype="<?= e($p['ram_type'] ?? '') ?>"
                         data-gen="<?= e($p['cpu_gen'] ?? '') ?>"
                         data-tdp="<?= e($p['tdp'] ?? '') ?>"
                         data-wattage="<?= e($p['wattage'] ?? '') ?>"
                         data-form="<?= e($p['form_factor'] ?? '') ?>"
                         data-price="<?= e((float)$p['price']) ?>"
                         data-name="<?= e($p['name']) ?>">
                    <input type="radio" name="part[<?= e($key) ?>]" value="<?= e($p['id']) ?>" <?= $outOfStock ? 'disabled' : '' ?>>
                    <span>
                      <span class="o-name"><?= e($p['name']) ?></span>
                      <?php if ($specbits): ?><br><span class="o-spec"><?= e(implode(' · ', $specbits)) ?></span><?php endif; ?>
                      <?php if (!empty($p['detail'])): ?><br><span class="o-spec"><?= e(mb_substr($p['detail'], 0, 90)) ?></span><?php endif; ?>
                      <span class="fitnote"></span>
                    </span>
                    <span class="o-price"><?= money($p['price']) ?></span>
                  </label>
                <?php endforeach; ?>
              </div>
            </section>
          <?php endforeach; ?>
        </div>

        <aside>
          <div class="summary">
            <h3>Your build</h3>
            <div id="sum-lines"><p class="mono" style="color:#8f9daa">Nothing picked yet.</p></div>
            <div class="line"><span>Parts</span><span id="sum-parts">—</span></div>
            <?php if (setting('offer_assembly')): ?>
              <div class="line"><span>Assembly</span><span id="sum-asm">—</span></div>
            <?php endif; ?>
            <div class="grand"><span>Total</span><span id="sum-total">—</span></div>

            <?php if (setting('offer_assembly')): ?>
            <label class="checkrow" style="background:var(--slate-800);border-color:var(--slate-700);color:var(--mat);margin-bottom:14px">
              <input type="checkbox" name="assembly" value="1" id="asm" <?= !empty($_SESSION['assembly']) ? 'checked' : '' ?>>
              <span>
                <strong>Have us build it — <?= money(setting('build_fee', 250)) ?></strong><br>
                <span class="mono" style="color:#9fabb8">Assembled, cable-managed, BIOS updated and stress-tested before it ships. Leave this unticked and we'll send the parts loose.</span>
              </span>
            </label>
            <?php endif; ?>

            <button class="btn" type="submit" style="width:100%">Add build to cart</button>
            <p class="mono" style="color:#8f9daa;margin:12px 0 0">Estimated draw: <span id="sum-watt">—</span></p>
          </div>
        </aside>
      </div>
    </form>
    <?php endif; ?>
  </div>
</section>

<script>
  window.BUILD_FEE     = <?= (float)setting('build_fee', 250) ?>;
  window.OFFER_ASSEMBLY= <?= setting('offer_assembly') ? 'true' : 'false' ?>;
  window.CURRENCY      = <?= json_encode(setting('currency', '$')) ?>;
</script>
<script src="assets/js/build.js" defer></script>
<?php include __DIR__ . '/includes/footer.php'; ?>

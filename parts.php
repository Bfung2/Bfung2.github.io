<?php
$title = 'Build parts';
require_once __DIR__ . '/../includes/admin-header.php';

$parts = all_parts();
$cats  = part_categories();

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    check_csrf();

    if (post('action') === 'delete') {
        $parts = array_values(array_filter($parts, fn($p) => $p['id'] !== post('id')));
        write_json('parts', $parts);
        flash('Part deleted.');
        redirect('parts.php');
    }

    $id  = post('id');
    $old = $id ? find_by_id($parts, $id) : null;

    $row = [
        'id'          => $id ?: uid('pt_'),
        'category'    => array_key_exists(post('category'), $cats) ? post('category') : 'other',
        'name'        => post('name'),
        'brand'       => post('brand'),
        'price'       => (float)post('price'),
        'detail'      => post('detail'),
        'stock'       => post('stock'),
        'socket'      => post('socket'),
        'ram_type'    => post('ram_type'),
        'cpu_gen'     => post('cpu_gen'),
        'tdp'         => post('tdp'),
        'wattage'     => post('wattage'),
        'form_factor' => post('form_factor'),
        'image'       => handle_upload('image', $old['image'] ?? ''),
    ];

    if ($row['name'] === '') {
        flash('A part needs a name.');
    } else {
        if ($old) { foreach ($parts as $i => $p) if ($p['id'] === $id) $parts[$i] = $row; flash('Part saved.'); }
        else      { $parts[] = $row; flash('Part added.'); }
        write_json('parts', $parts);
    }
    redirect('parts.php');
}

$edit = isset($_GET['edit']) ? find_by_id($parts, $_GET['edit']) : null;
$v = fn($k, $d = '') => e($edit[$k] ?? $d);
?>
<h1>Build parts</h1>
<p class="muted">These feed the Build a PC page. The spec fields are what the compatibility check runs on — fill in the ones that apply and leave the rest blank.</p>

<div class="panel" style="margin-bottom:32px">
  <h2 style="font-size:1.2rem"><?= $edit ? 'Edit ' . e($edit['name']) : 'Add a part' ?></h2>
  <form method="post" enctype="multipart/form-data">
    <?= csrf_field() ?>
    <input type="hidden" name="id" value="<?= e($edit['id'] ?? '') ?>">

    <div class="row2">
      <div class="field"><label for="category">Category</label>
        <select id="category" name="category">
          <?php foreach ($cats as $k => $label): ?><option value="<?= e($k) ?>" <?= ($edit['category'] ?? '') === $k ? 'selected' : '' ?>><?= e($label) ?></option><?php endforeach; ?>
        </select>
      </div>
      <div class="field"><label for="brand">Brand</label><input id="brand" type="text" name="brand" value="<?= $v('brand') ?>" placeholder="Intel, AMD, Corsair…"></div>
    </div>

    <div class="field"><label for="name">Part name</label><input id="name" type="text" name="name" value="<?= $v('name') ?>" placeholder="Ryzen 7 7800X3D" required></div>

    <div class="row2">
      <div class="field"><label for="price">Price</label><input id="price" type="number" step="0.01" min="0" name="price" value="<?= $v('price') ?>"></div>
      <div class="field"><label for="stock">Stock count</label><input id="stock" type="number" name="stock" value="<?= $v('stock') ?>" placeholder="Blank = always available"></div>
    </div>

    <div class="field"><label for="detail">Description</label><textarea id="detail" name="detail" style="min-height:80px"><?= $v('detail') ?></textarea></div>

    <h3 style="margin-top:24px">Compatibility specs</h3>
    <p class="hint" style="margin-bottom:14px">Fill these in and the Build a PC page will automatically recommend the right boards, memory, coolers and power supplies once a customer picks a processor.</p>

    <div class="row2">
      <div class="field"><label for="socket">Socket</label>
        <input id="socket" type="text" name="socket" value="<?= $v('socket') ?>" list="sockets" placeholder="AM5, LGA1700…">
        <datalist id="sockets"><option value="AM5"><option value="AM4"><option value="LGA1700"><option value="LGA1851"><option value="LGA1200"></datalist>
        <div class="hint">Processors and motherboards: one socket. Coolers: list every socket it fits, comma separated.</div>
      </div>
      <div class="field"><label for="cpu_gen">Generation</label>
        <input id="cpu_gen" type="text" name="cpu_gen" value="<?= $v('cpu_gen') ?>" placeholder="Ryzen 7000, 14th Gen Core…">
        <div class="hint">Put the same wording on matching parts and they get flagged as a set.</div>
      </div>
    </div>

    <div class="row2">
      <div class="field"><label for="ram_type">Memory type</label>
        <select id="ram_type" name="ram_type">
          <option value="">Not applicable</option>
          <?php foreach (['DDR4','DDR5'] as $r): ?><option <?= ($edit['ram_type'] ?? '') === $r ? 'selected' : '' ?>><?= $r ?></option><?php endforeach; ?>
        </select>
        <div class="hint">Set this on motherboards and memory kits.</div>
      </div>
      <div class="field"><label for="form_factor">Form factor</label>
        <input id="form_factor" type="text" name="form_factor" value="<?= $v('form_factor') ?>" placeholder="ATX, Micro-ATX, Mini-ITX">
        <div class="hint">Boards: one size. Cases: every size it takes, comma separated.</div>
      </div>
    </div>

    <div class="row2">
      <div class="field"><label for="tdp">Power draw / cooler rating (W)</label>
        <input id="tdp" type="number" name="tdp" value="<?= $v('tdp') ?>" placeholder="e.g. 120">
        <div class="hint">On a processor this is what it pulls. On a cooler it's what it can handle.</div>
      </div>
      <div class="field"><label for="wattage">Supply output / card draw (W)</label>
        <input id="wattage" type="number" name="wattage" value="<?= $v('wattage') ?>" placeholder="e.g. 850">
        <div class="hint">On a power supply this is its output. On a graphics card it's what it draws.</div>
      </div>
    </div>

    <div class="field"><label for="image">Photo</label><input id="image" type="file" name="image" accept="image/*">
      <?php if (!empty($edit['image'])): ?><div class="hint">Currently: <?= e($edit['image']) ?></div><?php endif; ?>
    </div>

    <button class="btn" type="submit"><?= $edit ? 'Save changes' : 'Add part' ?></button>
    <?php if ($edit): ?><a class="btn btn-quiet" href="parts.php">Cancel</a><?php endif; ?>
  </form>
</div>

<h2 style="font-size:1.2rem">All parts (<?= count($parts) ?>)</h2>
<?php if (!$parts): ?>
  <div class="empty-state"><p>No parts yet. Start with a couple of processors — everything else keys off them.</p></div>
<?php else: ?>
  <?php foreach ($cats as $key => $label):
    $group = array_filter($parts, fn($p) => ($p['category'] ?? 'other') === $key);
    if (!$group) continue; ?>
    <h3 style="margin-top:26px"><?= e($label) ?></h3>
    <div class="table-wrap">
      <table>
        <thead><tr><th>Name</th><th>Specs</th><th class="num">Price</th><th class="num">Stock</th><th></th></tr></thead>
        <tbody>
        <?php foreach ($group as $p):
          $spec = array_filter([
            $p['socket'] ?? '', $p['ram_type'] ?? '', $p['cpu_gen'] ?? '', $p['form_factor'] ?? '',
            !empty($p['tdp']) ? $p['tdp'] . 'W draw/rating' : '',
            !empty($p['wattage']) ? $p['wattage'] . 'W' : '',
          ]); ?>
          <tr>
            <td><strong><?= e($p['name']) ?></strong><?= !empty($p['brand']) ? '<br><span class="mono muted">' . e($p['brand']) . '</span>' : '' ?></td>
            <td class="mono" style="font-size:.78rem"><?= $spec ? e(implode(' · ', $spec)) : '<span class="muted">no specs set</span>' ?></td>
            <td class="num"><?= money($p['price']) ?></td>
            <td class="num"><?= ($p['stock'] ?? '') === '' ? '—' : (int)$p['stock'] ?></td>
            <td style="white-space:nowrap">
              <a class="btn btn-sm btn-quiet" href="parts.php?edit=<?= e($p['id']) ?>">Edit</a>
              <form method="post" style="display:inline" onsubmit="return confirm('Delete this part?')">
                <?= csrf_field() ?>
                <input type="hidden" name="action" value="delete">
                <input type="hidden" name="id" value="<?= e($p['id']) ?>">
                <button class="btn btn-sm btn-danger" type="submit">Delete</button>
              </form>
            </td>
          </tr>
        <?php endforeach; ?>
        </tbody>
      </table>
    </div>
  <?php endforeach; ?>
<?php endif; ?>
<?php require_once __DIR__ . '/../includes/admin-footer.php'; ?>

async function catalogOpenWithSource(record) {
  if (!record?.supplierVersion) return record;
  const source = await staffRPC('apex_owner_catalog_source', {
    p_action: 'read', p_sku: record.id, p_version: record.supplierVersion
  });
  return { ...record, ...source };
}

async function catalogApplyPrivateSource(record) {
  const version = crypto.randomUUID();
  await staffRPC('apex_owner_catalog_source', {
    p_action: 'save', p_sku: record.id, p_version: version,
    p_data: { url: record.sourceUrl, cost: record.neweggPrice, extra: record.extraCostUSD }
  });
  record.supplierVersion = version;
}

function catalogPublicRecord(record) {
  if (!record.supplierVersion) return record;
  const { sourceUrl, neweggPrice, extraCostUSD, ...publicRecord } = record;
  return publicRecord;
}

function catalogOwnerKeywords(prefix, record) {
  return `<label class="field">Additional search keywords<input id="${prefix}_keywords" maxlength="300"
    placeholder="graphics card, GPU, NVIDIA upgrade" value="${esc((Array.isArray(record.keywords) ? record.keywords : []).join(', '))}"></label>`;
}

async function catalogSaveOwnerRecord(section, record, prefix) {
  const dialog = editDlg;
  const button = dialog.querySelector('[data-catalog-save]');
  if (button.disabled) return;
  button.disabled = true;
  try {
    record.keywords = [...new Set(document.getElementById(prefix + '_keywords').value.split(',')
      .map(keyword => keyword.trim()).filter(Boolean))];
    await catalogApplyPrivateSource(record);
    if (!isOwner || !staffSecurity.verified || editDlg !== dialog) return;
    upsertCatalogRecord(section, record);
    // Every public record with this ID must use the same private cost revision.
    for (const key of ['products', 'parts']) {
      S[key] = S[key].map(row => row.id === record.id ? catalogPublicRecord(row) : row);
    }
    save();
    dialog.close();
    render();
    toast(record.active ? 'Catalog entry saved.' : 'Saved inactive. Verify the supplier before listing.');
  } catch (error) {
    toast('Could not save the catalog entry. ' + error.message);
  } finally {
    button.disabled = false;
  }
}

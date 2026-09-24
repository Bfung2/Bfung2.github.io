/* Build configurator: filters and re-sorts parts around the chosen CPU. */
(function () {
  var form = document.getElementById('build-form');
  if (!form) return;

  var opts   = Array.prototype.slice.call(form.querySelectorAll('.opt'));
  var slots  = Array.prototype.slice.call(form.querySelectorAll('.slot'));
  var asm    = document.getElementById('asm');
  var money  = function (n) { return (window.CURRENCY || '$') + n.toFixed(2); };

  function norm(v) { return (v || '').toString().trim().toLowerCase(); }
  function list(v) { return norm(v).split(/[,;/]+|\s{2,}/).map(function (s) { return s.trim(); }).filter(Boolean); }
  function num(v)  { var n = parseFloat(v); return isNaN(n) ? 0 : n; }
  function d(el, k){ return el.getAttribute('data-' + k) || ''; }

  function chosen(cat) {
    var input = form.querySelector('input[name="part[' + cat + ']"]:checked');
    return input ? input.closest('.opt') : null;
  }

  /* Returns {ok:bool, note:string, rec:bool} */
  function check(el) {
    var cat = d(el, 'cat');
    var cpu = chosen('cpu');
    var mb  = chosen('motherboard');

    if (cat === 'cpu') return { ok: true, note: '', rec: false };

    if (cat === 'motherboard' && cpu) {
      var cs = norm(d(cpu, 'socket')), ms = norm(d(el, 'socket'));
      if (cs && ms) {
        if (cs !== ms) return { ok: false, note: 'Wrong socket for the ' + d(cpu, 'name') + ' (needs ' + d(cpu, 'socket') + ')', rec: false };
        return { ok: true, note: 'Socket matches your ' + d(cpu, 'name'), rec: true };
      }
    }

    if (cat === 'ram' && mb) {
      var mt = norm(d(mb, 'ramtype')), rt = norm(d(el, 'ramtype'));
      if (mt && rt) {
        if (mt !== rt) return { ok: false, note: 'Your board takes ' + d(mb, 'ramtype'), rec: false };
        return { ok: true, note: d(el, 'ramtype') + ' — fits your board', rec: true };
      }
    }

    if (cat === 'cooler' && cpu) {
      var need = norm(d(cpu, 'socket'));
      var fits = list(d(el, 'socket'));
      if (need && fits.length && fits.indexOf(need) === -1)
        return { ok: false, note: 'Not rated for ' + d(cpu, 'socket'), rec: false };
      var rating = num(d(el, 'tdp')), draw = num(d(cpu, 'tdp'));
      if (rating && draw && rating < draw)
        return { ok: false, note: 'Rated to ' + rating + 'W, your CPU pulls ' + draw + 'W', rec: false };
      if (need && fits.length) return { ok: true, note: 'Mounts on ' + d(cpu, 'socket'), rec: true };
    }

    if (cat === 'case' && mb) {
      var mf = norm(d(mb, 'form')), cf = list(d(el, 'form'));
      if (mf && cf.length) {
        if (cf.indexOf(mf) === -1) return { ok: false, note: 'Too small for a ' + d(mb, 'form') + ' board', rec: false };
        return { ok: true, note: 'Takes ' + d(mb, 'form'), rec: true };
      }
    }

    if (cat === 'psu') {
      var draw2 = estimatedDraw(), have = num(d(el, 'wattage'));
      if (have && draw2) {
        if (have < draw2) return { ok: false, note: 'Under the ~' + draw2 + 'W this build needs', rec: false };
        if (have < draw2 * 1.6) return { ok: true, note: 'Comfortable for ~' + draw2 + 'W', rec: true };
      }
    }

    /* Same-generation nudge for anything tagged with a CPU generation. */
    if (cpu && d(el, 'gen') && norm(d(el, 'gen')) === norm(d(cpu, 'gen')))
      return { ok: true, note: 'Matched to ' + d(cpu, 'gen'), rec: true };

    return { ok: true, note: '', rec: false };
  }

  function estimatedDraw() {
    var cpu = chosen('cpu'), gpu = chosen('gpu');
    var c = cpu ? num(d(cpu, 'tdp')) : 0;
    var g = gpu ? num(d(gpu, 'wattage')) : 0;
    if (!c && !g) return 0;
    return Math.round((c || 95) + g + 110);
  }

  function refresh() {
    opts.forEach(function (el) {
      var input = el.querySelector('input');
      var note  = el.querySelector('.fitnote');
      var r     = check(el);

      el.classList.toggle('chosen', input.checked);

      if (!r.ok && !input.checked) {
        el.classList.add('locked');
        el.setAttribute('data-softlock', '1');
        input.disabled = true;
      } else if (el.getAttribute('data-softlock')) {
        el.classList.remove('locked');
        el.removeAttribute('data-softlock');
        input.disabled = false;
      }

      note.innerHTML = r.note
        ? '<br><span class="tag ' + (r.ok ? 'tag-rec' : 'tag-out') + '">' + r.note + '</span>'
        : '';
      el.setAttribute('data-rec', r.rec ? '1' : '0');
    });

    /* Recommended options float to the top of their slot. */
    slots.forEach(function (slot) {
      var body = slot.querySelector('.slot-body');
      var rows = Array.prototype.slice.call(body.querySelectorAll('.opt'));
      rows.sort(function (a, b) {
        var ai = a.querySelector('input').checked ? 0 : (a.getAttribute('data-rec') === '1' ? 1 : (a.classList.contains('locked') ? 3 : 2));
        var bi = b.querySelector('input').checked ? 0 : (b.getAttribute('data-rec') === '1' ? 1 : (b.classList.contains('locked') ? 3 : 2));
        return ai - bi;
      });
      rows.forEach(function (r) { body.appendChild(r); });
    });

    summarise();
  }

  function summarise() {
    var picked = opts.filter(function (el) { return el.querySelector('input').checked; });
    var box = document.getElementById('sum-lines');
    var parts = 0;

    if (!picked.length) {
      box.innerHTML = '<p class="mono" style="color:#8f9daa">Nothing picked yet.</p>';
    } else {
      box.innerHTML = picked.map(function (el) {
        parts += num(d(el, 'price'));
        return '<div class="line"><span>' + d(el, 'name') + '</span><span>' + money(num(d(el, 'price'))) + '</span></div>';
      }).join('');
    }

    var fee = (window.OFFER_ASSEMBLY && asm && asm.checked) ? (window.BUILD_FEE || 0) : 0;
    document.getElementById('sum-parts').textContent = money(parts);
    var asmCell = document.getElementById('sum-asm');
    if (asmCell) asmCell.textContent = fee ? money(fee) : 'not included';
    document.getElementById('sum-total').textContent = money(parts + fee);

    var w = estimatedDraw();
    document.getElementById('sum-watt').textContent = w ? '~' + w + 'W' : '—';
  }

  form.addEventListener('change', refresh);

  form.querySelectorAll('.js-clear').forEach(function (btn) {
    btn.addEventListener('click', function () {
      var cat = btn.getAttribute('data-for');
      form.querySelectorAll('input[name="part[' + cat + ']"]').forEach(function (i) { i.checked = false; });
      refresh();
    });
  });

  refresh();
})();

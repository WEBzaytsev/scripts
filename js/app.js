// app.js — UI logic: navigation, form rendering, command preview, copy, localStorage.
(function () {
  'use strict';

  var LS_KEY_PREFIX = 'scripts-panel:';

  // ---- State ----

  var currentScriptId = null;
  var formValues = {};

  // ---- DOM ----

  function $(sel) { return document.querySelector(sel); }
  function $$(sel) { return Array.prototype.slice.call(document.querySelectorAll(sel)); }

  function el(tag, attrs, children) {
    var node = document.createElement(tag);
    if (attrs) {
      Object.keys(attrs).forEach(function (k) {
        if (k === 'className') node.className = attrs[k];
        else if (k === 'textContent') node.textContent = attrs[k];
        else if (k === 'innerHTML') node.innerHTML = attrs[k];
        else node.setAttribute(k, attrs[k]);
      });
    }
    if (children) {
      children.forEach(function (c) {
        if (c) node.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
      });
    }
    return node;
  }

  // ---- Sidebar ----

  function buildSidebar() {
    var nav = $('#nav');
    nav.innerHTML = '';

    CATEGORIES.forEach(function (cat) {
      var scripts = SCRIPTS.filter(function (s) { return s.category === cat.id; });
      if (!scripts.length) return;

      nav.appendChild(el('div', { className: 'nav-group' }, [
        el('div', { className: 'nav-group-label', textContent: cat.label }),
      ]));

      scripts.forEach(function (script) {
        var item = el('button', {
          className: 'nav-item',
          'data-id': script.id,
        }, [script.name]);
        item.addEventListener('click', function () { selectScript(script.id); });
        nav.appendChild(item);
      });
    });
  }

  // ---- Script Selection ----

  function selectScript(id) {
    currentScriptId = id;

    $$('.nav-item').forEach(function (btn) {
      btn.classList.toggle('active', btn.getAttribute('data-id') === id);
    });

    var script = SCRIPTS.find(function (s) { return s.id === id; });
    if (!script) return;

    // Restore or init values
    formValues = loadValues(id, script);

    renderContent(script);
    updateCommand();
    updateWarnings();
  }

  // ---- localStorage ----

  function storageKey(id) { return LS_KEY_PREFIX + id; }

  function saveValues(id, values) {
    try { localStorage.setItem(storageKey(id), JSON.stringify(values)); } catch (e) {}
  }

  function loadValues(id, script) {
    var saved = {};
    try { saved = JSON.parse(localStorage.getItem(storageKey(id)) || '{}'); } catch (e) {}

    // Build defaults from field definitions
    var defaults = {};
    (script.fields || []).forEach(function (f) {
      if (f.type === 'checkbox') defaults[f.id] = f.default !== undefined ? f.default : false;
      else if (f.type === 'radio') defaults[f.id] = f.default || (f.options && f.options[0] && f.options[0].value);
      else defaults[f.id] = f.default || '';
    });

    // Merge: defaults < saved
    return Object.assign({}, defaults, saved);
  }

  // ---- Content Rendering ----

  function renderContent(script) {
    var main = $('#main');
    main.innerHTML = '';

    // Header
    main.appendChild(el('div', { className: 'content-header' }, [
      el('h2', { className: 'script-title', textContent: script.name }),
      el('p', { className: 'script-desc', textContent: script.description }),
    ]));

    // Form
    if (script.fields && script.fields.length) {
      var form = el('div', { className: 'form' });
      script.fields.forEach(function (field) {
        form.appendChild(renderField(field));
      });
      main.appendChild(form);
    }

    // Command output
    main.appendChild(renderCommandBlock(script));

    // Warnings placeholder (updated dynamically)
    main.appendChild(el('div', { id: 'warnings-block' }));

    // Wget fallback (if applicable)
    if (hasWget(script.id)) {
      main.appendChild(renderWgetBlock(script));
    }
  }

  // ---- Field Rendering ----

  function renderField(field) {
    var wrapper = el('div', { className: 'field', 'data-field-id': field.id });

    // showIf logic — hide initially if condition not met
    if (field.showIf) {
      var condVal = formValues[field.showIf.field];
      if (condVal !== field.showIf.value) wrapper.style.display = 'none';
    }

    var labelEl = el('label', { className: 'field-label' }, [
      field.label,
      field.optional ? el('span', { className: 'field-optional', textContent: ' (необязательно)' }) : null,
    ]);

    var inputEl = createInput(field);
    wrapper.appendChild(labelEl);
    wrapper.appendChild(inputEl);

    if (field.help) {
      wrapper.appendChild(el('div', { className: 'field-help', textContent: field.help }));
    }

    return wrapper;
  }

  function createInput(field) {
    var val = formValues[field.id];

    if (field.type === 'textarea') {
      var ta = el('textarea', {
        id: 'field-' + field.id,
        placeholder: field.placeholder || '',
        rows: field.rows || 3,
        spellcheck: 'false',
        autocomplete: 'off',
        autocorrect: 'off',
        autocapitalize: 'off',
      });
      if (field.monospace) ta.className = 'monospace';
      ta.value = val || '';
      ta.addEventListener('input', function () { onFieldChange(field.id, ta.value); });
      return ta;
    }

    if (field.type === 'text' || field.type === 'number') {
      var inp = el('input', {
        id: 'field-' + field.id,
        type: field.type,
        placeholder: field.placeholder || '',
      });
      if (field.min !== undefined) inp.setAttribute('min', field.min);
      if (field.max !== undefined) inp.setAttribute('max', field.max);
      if (field.monospace) inp.className = 'monospace';
      inp.value = val || '';
      inp.addEventListener('input', function () { onFieldChange(field.id, inp.value); });
      return inp;
    }

    if (field.type === 'checkbox') {
      var lbl = el('label', { className: 'checkbox-label' });
      var cb = el('input', { type: 'checkbox', id: 'field-' + field.id });
      cb.checked = !!val;
      cb.addEventListener('change', function () { onFieldChange(field.id, cb.checked); });
      lbl.appendChild(cb);
      lbl.appendChild(document.createTextNode(' ' + field.label));
      return lbl;
    }

    if (field.type === 'radio') {
      var group = el('div', { className: 'radio-group' });
      (field.options || []).forEach(function (opt) {
        var lbl = el('label', { className: 'radio-label' });
        var rb = el('input', { type: 'radio', name: 'field-' + field.id, value: opt.value });
        rb.checked = (val === opt.value);
        rb.addEventListener('change', function () {
          if (rb.checked) onFieldChange(field.id, opt.value);
        });
        lbl.appendChild(rb);
        lbl.appendChild(document.createTextNode(' ' + opt.label));
        group.appendChild(lbl);
      });
      return group;
    }

    return el('div', {}, ['[unsupported field type: ' + field.type + ']']);
  }

  function onFieldChange(fieldId, value) {
    formValues[fieldId] = value;
    saveValues(currentScriptId, formValues);

    // showIf: toggle dependent fields
    var script = SCRIPTS.find(function (s) { return s.id === currentScriptId; });
    if (script) {
      (script.fields || []).forEach(function (f) {
        if (f.showIf && f.showIf.field === fieldId) {
          var wrapper = document.querySelector('[data-field-id="' + f.id + '"]');
          if (wrapper) wrapper.style.display = (value === f.showIf.value) ? '' : 'none';
        }
      });
    }

    updateCommand();
  }

  // ---- Command Output ----

  function renderCommandBlock(script) {
    var block = el('div', { className: 'cmd-block' });
    var label = el('div', { className: 'cmd-label' }, [
      el('span', { textContent: script.isLocalCommand ? 'Локальная команда' : 'Команда для сервера' }),
    ]);
    var wrap = el('div', { className: 'cmd-wrap' });
    var pre  = el('pre', { className: 'cmd-output', id: 'cmd-output' });
    var btn  = el('button', { className: 'copy-btn', id: 'copy-btn', textContent: 'copy' });
    btn.addEventListener('click', copyCommand);
    wrap.appendChild(pre);
    wrap.appendChild(btn);
    block.appendChild(label);
    block.appendChild(wrap);
    return block;
  }

  function renderWgetBlock(script) {
    var block = el('div', { className: 'cmd-block cmd-block--alt' });
    var label = el('div', { className: 'cmd-label' }, [
      el('span', { textContent: 'wget вариант' }),
    ]);
    var wrap = el('div', { className: 'cmd-wrap' });
    var pre  = el('pre', { className: 'cmd-output', id: 'wget-output' });
    var btn  = el('button', { className: 'copy-btn', id: 'copy-wget-btn', textContent: 'copy' });
    btn.addEventListener('click', function () { copyCommandFromEl('wget-output', 'copy-wget-btn'); });
    wrap.appendChild(pre);
    wrap.appendChild(btn);
    block.appendChild(label);
    block.appendChild(wrap);
    return block;
  }

  function warningVisible(warning) {
    if (!warning.showWhen) return true;
    var val = (formValues[warning.showWhen.field] || '').trim();
    return warning.showWhen.empty ? val === '' : val !== '';
  }

  function updateWarnings() {
    var block = document.getElementById('warnings-block');
    if (!block) return;
    block.innerHTML = '';
    var script = SCRIPTS.find(function (s) { return s.id === currentScriptId; });
    if (!script || !script.warnings || !script.warnings.length) return;

    script.warnings.forEach(function (w) {
      var text = typeof w === 'string' ? w : w.text;
      var visible = typeof w === 'string' ? true : warningVisible(w);
      if (!visible) return;
      block.appendChild(el('div', { className: 'warning-item' }, [
        el('span', { className: 'warning-icon', textContent: '!' }),
        el('span', { textContent: text }),
      ]));
    });
  }

  function updateCommand() {
    var out = document.getElementById('cmd-output');
    if (!out || !currentScriptId) return;

    var cmd = buildCommand(currentScriptId, formValues);
    var cmdBlock = out.closest('.cmd-block');
    if (!cmd) {
      if (cmdBlock) cmdBlock.style.display = 'none';
      return;
    }
    if (cmdBlock) cmdBlock.style.display = '';
    out.textContent = cmd;

    var wgetOut = document.getElementById('wget-output');
    if (wgetOut) {
      var wgetCmd = buildWgetCommand(currentScriptId, formValues);
      wgetOut.textContent = wgetCmd || '';
    }

    updateWarnings();
  }

  // ---- Copy ----

  function copyCommandFromEl(outputId, btnId) {
    var out = document.getElementById(outputId);
    var btn = document.getElementById(btnId);
    if (!out || !btn) return;
    var text = out.textContent;
    if (!text || text === '(недостаточно данных)') return;

    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(function () { flashCopied(btn); });
    } else {
      var ta = document.createElement('textarea');
      ta.value = text;
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      try { document.execCommand('copy'); flashCopied(btn); } catch (e) {}
      document.body.removeChild(ta);
    }
  }

  function copyCommand() {
    copyCommandFromEl('cmd-output', 'copy-btn');
  }

  function flashCopied(btn) {
    btn.textContent = 'copied!';
    btn.classList.add('copied');
    setTimeout(function () {
      btn.textContent = 'copy';
      btn.classList.remove('copied');
    }, 1500);
  }

  // ---- Init ----

  function init() {
    buildSidebar();

    // Select first script
    if (SCRIPTS.length) {
      selectScript(SCRIPTS[0].id);
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

}());

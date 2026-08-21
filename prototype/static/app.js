'use strict';

// ── Theme toggle ─────────────────────────────────────────────────────────────
const THEME_KEY = 'cra-theme';

function applyTheme(theme) {
  document.documentElement.setAttribute('data-theme', theme);
  const icon  = document.getElementById('theme-icon');
  const label = document.getElementById('theme-label');
  if (theme === 'light') {
    icon.textContent  = '🌙';
    label.textContent = 'Dark';
  } else {
    icon.textContent  = '☀️';
    label.textContent = 'Light';
  }
}

function initTheme() {
  const saved = localStorage.getItem(THEME_KEY) || 'light';
  applyTheme(saved);
}

document.getElementById('theme-toggle').addEventListener('click', () => {
  const current = document.documentElement.getAttribute('data-theme') || 'light';
  const next = current === 'dark' ? 'light' : 'dark';
  applyTheme(next);
  localStorage.setItem(THEME_KEY, next);
});

initTheme();

// preset_explicit: true once the operator actively changes the preset
let presetExplicit = false;
document.getElementById('preset').addEventListener('change', () => { presetExplicit = true; });

// ── Submit: single merged request ────────────────────────────────────────────
document.getElementById('submit-btn').addEventListener('click', async () => {
  // Only fields the operator actually filled in are sent: the backend treats every
  // field present in the payload as explicitly set (pipeline_v2.merge).
  const num = (id) => {
    const v = document.getElementById(id).value.trim();
    return v === '' ? null : Number(v);
  };
  const sel = (id) => document.getElementById(id).value || null;
  const form = {
    preset: document.getElementById('preset').value,
    preset_explicit: presetExplicit,
  };
  const scale = num('scale');
  if (scale !== null) form.scale = scale;
  const budget = num('budget');
  if (budget !== null) form.budget_limit_usd = budget;
  if (document.getElementById('transparency').checked) form.transparency_required = true;
  if (document.getElementById('self-managed').checked) form.self_managed_required = true;
  const renumbering = sel('renumbering');
  if (renumbering) form.pod_renumbering = renumbering;
  const expertise = sel('expertise');
  if (expertise) form.expertise = expertise;
  const body = {
    form,
    freeform_text: document.getElementById('freeform-text').value.trim() || null,
  };
  showLoading();
  try {
    const res = await fetch('/api/v2/recommend', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || `HTTP ${res.status}`);
    if (data.clarification_needed) {
      showClarification(data.question);
    } else if (data.infeasible) {
      showInfeasible(data);
    } else {
      renderResult(data);
    }
  } catch (err) {
    showError(err.message);
  }
});

// ── Render result ─────────────────────────────────────────────────────────────
const SHORT = { 'B-VXLAN': 'B1', 'N-Cloud': 'N1', 'N-Static': 'N2', 'N-Dynamic': 'N3' };

function renderResult(data) {
  document.getElementById('rec-badge').textContent = SHORT[data.recommended_name] || '';
  document.getElementById('rec-name').textContent = data.recommended_name;
  document.getElementById('rec-desc').textContent = data.description;

  const reqSection = document.getElementById('extracted-req-section');
  if (data.interpreted) {
    reqSection.style.display = '';
    renderInterpreted(data.interpreted);
  } else {
    reqSection.style.display = 'none';
  }

  renderScores(data);

  const weightBox = document.getElementById('weight-info');
  if (data.weights && data.weights.length > 0) {
    const wStr = data.weights.map((w, i) =>
      `${data.active_criteria[i]}: ${(w * 100).toFixed(0)}%`).join(' · ');
    weightBox.textContent = `Active criteria after zero-variance removal — ${wStr}`;
  } else {
    weightBox.textContent =
      'Filter-decided: only one configuration satisfies the requirements, so the ranking stage was not invoked.';
  }

  const unresolvedBox = document.getElementById('unresolved-info');
  if (data.unresolved && data.unresolved.length > 0) {
    unresolvedBox.style.display = '';
    unresolvedBox.textContent = 'Unresolved: ' + data.unresolved.join('; ');
  } else {
    unresolvedBox.style.display = 'none';
  }

  const expPanel = document.getElementById('explanation-panel');
  if (data.explanation) {
    expPanel.style.display = '';
    document.getElementById('explanation-text').textContent =
      data.explanation.replace(/\*\*/g, '');
  } else {
    expPanel.style.display = 'none';
  }

  showResultContent();
}

function renderInterpreted(x) {
  const dash = (v) => (v && v !== 'unspecified' ? v.replace(/_/g, '-') : 'Not stated');
  const chips = [
    ['Scale', x.scale != null ? `${x.scale} nodes` : 'Not stated'],
    ['Transparency', x.transparency_required ? 'Required' : 'Not stated'],
    ['Self-managed K8s', x.self_managed_required ? 'Required' : 'Not stated'],
    ['Budget limit', x.budget_limit_usd != null ? `$${x.budget_limit_usd}/mo` : 'None'],
    ['Adaptability', dash(x.pod_renumbering)],
    ['Priority', dash(x.stated_priority)],
    ['Expertise', dash(x.routing_expertise)],
  ];
  document.getElementById('extracted-req').innerHTML = chips.map(([label, val]) =>
    `<div class="req-chip"><span>${label}</span>${val}</div>`
  ).join('');
}

function renderScores(data) {
  const rows = [];
  const feasible = data.scores;
  const maxScore = Math.max(...feasible.map(s => s.phi || 0), 0.001);
  feasible.forEach((s, i) => {
    const isTop = s.config === data.recommended_name;
    if (s.phi == null) {
      rows.push(`
        <tr class="top-rank">
          <td><code>${SHORT[s.config]}</code> ${s.config} ✓</td>
          <td><span class="score-val">— (filter-decided)</span></td>
        </tr>`);
    } else {
      const pct = ((s.phi / maxScore) * 100).toFixed(0);
      rows.push(`
        <tr class="${isTop ? 'top-rank' : ''}">
          <td><code>${SHORT[s.config]}</code> ${s.config}${isTop ? ' ✓' : ''}</td>
          <td>
            <div class="score-bar-wrap">
              <div class="score-bar"><div class="score-bar-fill" style="width:${pct}%"></div></div>
              <span class="score-val">${s.phi.toFixed(3)}</span>
            </div>
          </td>
        </tr>`);
    }
  });
  Object.entries(data.eliminated || {}).forEach(([name, reason]) => {
    rows.push(`
      <tr class="eliminated">
        <td><code>${SHORT[name]}</code> ${name}</td>
        <td><span class="elim-reason"><span class="badge-elim">Eliminated</span>${reason}</span></td>
      </tr>`);
  });
  document.getElementById('scores-tbody').innerHTML = rows.join('');
}

// ── UI state helpers ──────────────────────────────────────────────────────────
function showLoading() {
  const panel = document.getElementById('results');
  panel.style.display = '';
  document.getElementById('loading').style.display = '';
  document.getElementById('result-content').style.display = 'none';
  document.getElementById('error-box').style.display = 'none';
  document.getElementById('explanation-panel').style.display = 'none';
  panel.scrollIntoView({ behavior: 'smooth', block: 'start' });
}

function showResultContent() {
  document.getElementById('loading').style.display = 'none';
  document.getElementById('result-content').style.display = '';
  document.getElementById('error-box').style.display = 'none';
}

function showBox(msg, clarify) {
  document.getElementById('loading').style.display = 'none';
  document.getElementById('result-content').style.display = 'none';
  const box = document.getElementById('error-box');
  box.style.display = '';
  box.classList.toggle('clarify', !!clarify);
  box.textContent = msg;
  document.getElementById('results').style.display = '';
}

function showError(msg) { showBox(`Error: ${msg}`, false); }

// Missing or conflicting information: NaRo asks instead of guessing (Section 4.2/4.3)
function showClarification(question) { showBox(`Clarification needed: ${question}`, true); }

// Empty feasible set: report the conflict and the relaxation options (Section 4.3)
function showInfeasible(data) {
  const lines = ['No configuration satisfies all mandatory requirements.'];
  Object.entries(data.eliminated || {}).forEach(([name, reason]) => lines.push(`• ${name}: ${reason}`));
  if (data.relaxations && data.relaxations.length) {
    lines.push('Requirement changes that would make a configuration feasible:');
    data.relaxations.forEach(r => lines.push(`• ${r}`));
  }
  showBox(lines.join('\n'), true);
}

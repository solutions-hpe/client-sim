const FLAG_ORDER = [
  'kill_switch',
  'dns_fail',
  'iperf',
  'download',
  'www_traffic',
  'ping_test',
  'ssidpw_fail',
  'auth_fail',
  'dhcp_fail',
  'port_flap',
  'assoc_fail'
];

const FAILURE_SIMS = new Set(['dns_fail', 'ssidpw_fail', 'auth_fail', 'dhcp_fail', 'port_flap', 'assoc_fail']);
const TRAFFIC_SIMS = new Set(['iperf', 'download', 'www_traffic', 'ping_test']);
const IMPACT_LABELS = {
  dns_fail: '⚠ DNS Failure',
  ssidpw_fail: '⚠ Auth Failure',
  auth_fail: '⚠ Auth Failure',
  dhcp_fail: '⚠ DHCP Failure',
  assoc_fail: '⚠ Assoc Failure',
  port_flap: '⚠ Port Flap',
  iperf: 'ℹ iPerf Traffic',
  download: 'ℹ Download Traffic',
  www_traffic: 'ℹ Web Traffic',
  ping_test: 'ℹ Ping Traffic'
};

const clients = new Map();
const rowRefs = new Map();
const tbody = document.getElementById('clients-body');
const emptyRow = document.getElementById('empty-row');
const clientCount = document.getElementById('client-count');
const wsDot = document.getElementById('ws-dot');
const wsText = document.getElementById('ws-text');
const repoDot = document.getElementById('repo-dot');
const repoText = document.getElementById('repo-text');
let socket = null;
let reconnectTimer = null;
let openControlHost = null;
let centralSiteDetailOpen = null;
let centralStatusData = {};
let availableChecks = { alerts: [], insights: [] };
let currentSettings = {
  repo_url: '',
  repo_branch: '',
  central_config: { cluster_url: '', client_id: '', customer_id: '' },
  site_mappings: {},
  monitored_checks: []
};
let centralTokenValid = null;
let centralLastSyncedTs = null;
let centralStatusInitialized = false;

// ── Tab navigation ────────────────────────────────────────────────
document.querySelectorAll('.tab').forEach((tab) => {
  tab.addEventListener('click', () => {
    document.querySelectorAll('.tab').forEach((t) => {
      t.classList.remove('active');
      t.setAttribute('aria-selected', 'false');
    });
    document.querySelectorAll('.tab-content').forEach((c) => c.classList.add('hidden'));

    tab.classList.add('active');
    tab.setAttribute('aria-selected', 'true');
    document.getElementById(`tab-${tab.dataset.tab}`).classList.remove('hidden');
  });
});

// ── Repo sync status ──────────────────────────────────────────────
function setRepoStatus(synced, error) {
  repoDot.className = `status-dot ${synced ? 'online' : 'offline'}`;
  repoText.textContent = error ? `Sync error` : synced ? 'Synced' : 'Syncing…';
  repoText.title = error || '';

  // Update setup tab status panel
  const syncState = document.getElementById('setup-sync-state');
  const syncError = document.getElementById('setup-sync-error');
  if (syncState) syncState.textContent = synced ? '✓ Synced' : error ? '✗ Failed' : 'Syncing…';
  if (syncError) syncError.textContent = error || '—';
}

// ── Setup tab — settings form ─────────────────────────────────────
const branchInput = document.getElementById('branch-input');
const saveBtn = document.getElementById('save-settings');
const settingsMsg = document.getElementById('settings-message');
const setupActiveBranch = document.getElementById('setup-active-branch');
const repoUrlInput = document.getElementById('repo-url-input');
const centralTabButton = document.querySelector('.tab[data-tab="central"]');
const setupTabButton = document.querySelector('.tab[data-tab="setup"]');
const centralOverview = document.getElementById('central-overview');
const centralSitesGrid = document.getElementById('central-sites-grid');
const centralEmpty = document.getElementById('central-empty');
const centralRefreshBtn = document.getElementById('central-refresh-btn');
const centralLastSynced = document.getElementById('central-last-synced');
const centralTokenDot = document.getElementById('central-token-dot');
const centralTokenText = document.getElementById('central-token-text');
const centralSiteDetail = document.getElementById('central-site-detail');
const centralDetailBack = document.getElementById('central-detail-back');
const centralDetailTitle = document.getElementById('central-detail-title');
const centralDetailSub = document.getElementById('central-detail-sub');
const centralSiteClients = document.getElementById('central-site-clients');
const centralSiteChecks = document.getElementById('central-site-checks');
const centralSiteHistory = document.getElementById('central-site-history');
const centralClusterUrlInput = document.getElementById('central-cluster-url');
const centralClusterUrlHint = document.getElementById('central-cluster-url-hint');
const centralAccessTokenInput = document.getElementById('central-access-token');
const centralRefreshTokenInput = document.getElementById('central-refresh-token');
const centralClientIdInput = document.getElementById('central-client-id');
const centralClientSecretInput = document.getElementById('central-client-secret');
const centralCustomerIdInput = document.getElementById('central-customer-id');
const centralTestBtn = document.getElementById('central-test-btn');
const centralTestMsg = document.getElementById('central-test-msg');
const centralClassicFields = document.getElementById('central-classic-fields');
const centralNewFields = document.getElementById('central-new-fields');
const centralClientIdBadge = document.getElementById('central-client-id-badge');
const centralClientSecretBadge = document.getElementById('central-client-secret-badge');

function getCentralApiVersion() {
  const checked = document.querySelector('input[name="central-api-version"]:checked');
  return checked ? checked.value : 'classic';
}

function applyCentralVersionUI(version) {
  const isNew = version === 'new_central';
  if (centralClassicFields) centralClassicFields.classList.toggle('hidden', isNew);
  if (centralNewFields) centralNewFields.classList.toggle('hidden', !isNew);
  if (centralClusterUrlHint) {
    centralClusterUrlHint.innerHTML = isNew
      ? 'New Central: found in <strong>Menu → API Gateway → REST API</strong>. e.g. <code>us1.api.central.arubanetworks.com</code>'
      : 'Classic: found in Central → API Gateway. e.g. <code>https://internal-apigw.central.arubanetworks.com</code>';
  }
  if (centralClientIdBadge) {
    centralClientIdBadge.textContent = isNew ? 'required' : 'optional — for auto-renewal';
    centralClientIdBadge.className = isNew ? 'token-required-badge' : 'token-optional-badge';
  }
  if (centralClientSecretBadge) {
    centralClientSecretBadge.textContent = isNew ? 'required' : 'optional — for auto-renewal';
    centralClientSecretBadge.className = isNew ? 'token-required-badge' : 'token-optional-badge';
  }
}

document.querySelectorAll('input[name="central-api-version"]').forEach((radio) => {
  radio.addEventListener('change', () => applyCentralVersionUI(getCentralApiVersion()));
});
const siteMappingsBody = document.getElementById('site-mappings-body');
const addMappingBtn = document.getElementById('add-mapping-btn');
const saveMappingsBtn = document.getElementById('save-mappings-btn');
const centralMappingsMsg = document.getElementById('central-mappings-msg');
const loadSitesBtn = document.getElementById('load-sites-btn');
const sitesLoadStatus = document.getElementById('sites-load-status');
const selectedChecksPreview = document.getElementById('selected-checks-preview');
const loadChecksBtn = document.getElementById('central-load-checks-btn');
const saveChecksBtn = document.getElementById('save-checks-btn');
const availableChecksContainer = document.getElementById('available-checks-container');
const centralChecksMsg = document.getElementById('central-checks-msg');

function mergeSettings(next = {}) {
  const merged = {
    repo_url: next.repo_url ?? currentSettings.repo_url ?? repoUrlInput?.value ?? '',
    repo_branch: next.repo_branch ?? currentSettings.repo_branch ?? '',
    central_config: {
      cluster_url: '',
      client_id: '',
      customer_id: '',
      ...(currentSettings.central_config || {}),
      ...(next.central_config || {})
    },
    site_mappings: next.site_mappings ?? currentSettings.site_mappings ?? {},
    monitored_checks: Array.isArray(next.monitored_checks)
      ? next.monitored_checks
      : (currentSettings.monitored_checks || [])
  };
  currentSettings = merged;
  return merged;
}

function setInputValueIfIdle(input, value) {
  if (input && !input.matches(':focus')) input.value = value || '';
}

function showInlineMessage(element, text, isError, timeout = 5000) {
  if (!element) return;
  clearTimeout(element._timer);
  if (!text) {
    element.textContent = '';
    element.className = 'settings-message hidden';
    return;
  }
  element.textContent = text;
  element.className = `settings-message ${isError ? 'error' : 'success'}`;
  if (timeout > 0) {
    element._timer = setTimeout(() => {
      element.className = 'settings-message hidden';
    }, timeout);
  }
}

function applySettingsToUI(s) {
  const settings = mergeSettings(s);
  if (repoUrlInput) repoUrlInput.value = settings.repo_url || repoUrlInput.value;
  if (branchInput && !branchInput.matches(':focus')) branchInput.value = settings.repo_branch || '';
  if (setupActiveBranch) setupActiveBranch.textContent = settings.repo_branch || '—';
  setInputValueIfIdle(centralClusterUrlInput, settings.central_config.cluster_url);
  setInputValueIfIdle(centralClientIdInput, settings.central_config.client_id);
  setInputValueIfIdle(centralCustomerIdInput, settings.central_config.customer_id);

  // Set API version radio + toggle UI
  const version = settings.central_config.api_version || 'classic';
  const radio = document.querySelector(`input[name="central-api-version"][value="${version}"]`);
  if (radio) radio.checked = true;
  applyCentralVersionUI(version);

  // Show "configured" hint for secrets without revealing values
  const atStatus = document.getElementById('central-access-token-status');
  const rtStatus = document.getElementById('central-refresh-token-status');
  const csStatus = document.getElementById('central-client-secret-status');
  if (atStatus) atStatus.textContent = settings.central_config.access_token_configured ? '✓ Token configured — paste new value to replace.' : 'No token saved yet.';
  if (rtStatus) rtStatus.textContent = settings.central_config.refresh_token_configured ? '✓ Refresh token configured — paste new value to replace.' : 'Optional — enables automatic renewal when the access token expires.';
  if (csStatus) csStatus.textContent = settings.central_config.client_secret_configured ? '✓ Secret configured — paste new value to replace.' : '';
  renderSiteMappingsTable();
  renderSelectedChecksPreview();
  if ((availableChecks.alerts.length || availableChecks.insights.length) && availableChecksContainer) {
    renderAvailableChecks();
  }
  renderCentralOverview();
  if (centralSiteDetailOpen) {
    renderSiteClients(centralSiteDetailOpen);
    renderSiteChecks(centralSiteDetailOpen, centralStatusData[centralSiteDetailOpen] || {});
  }
}

function showSettingsMessage(text, isError) {
  settingsMsg.textContent = text;
  settingsMsg.className = `settings-message ${isError ? 'error' : 'success'}`;
  clearTimeout(settingsMsg._timer);
  settingsMsg._timer = setTimeout(() => {
    settingsMsg.className = 'settings-message hidden';
  }, 5000);
}

saveBtn.addEventListener('click', async () => {
  const branch = branchInput.value.trim();
  if (!branch) {
    showSettingsMessage('Branch name cannot be empty.', true);
    return;
  }
  saveBtn.disabled = true;
  saveBtn.textContent = 'Saving…';
  try {
    const res = await fetch('/api/settings', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ repo_branch: branch })
    });
    const data = await res.json();
    if (!res.ok) throw new Error(data.detail || `HTTP ${res.status}`);
    showSettingsMessage(`Branch set to "${data.settings.repo_branch}" — sync started.`, false);
    applySettingsToUI(data.settings);
  } catch (err) {
    showSettingsMessage(`Error: ${err.message}`, true);
  } finally {
    saveBtn.disabled = false;
    saveBtn.textContent = 'Save & Sync';
  }
});

function normalizeFlagValue(value) {
  return String(value ?? 'off').toLowerCase() === 'on' ? 'on' : 'off';
}

function formatLastSeen(value) {
  if (!value) return '—';
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleString();
}

function impactSummary(activeSimulations = []) {
  const labels = [...new Set(activeSimulations.map((sim) => IMPACT_LABELS[sim]).filter(Boolean))];
  return labels.length ? labels.join(' · ') : '— Normal';
}

function badgeClass(simulation) {
  if (FAILURE_SIMS.has(simulation)) return 'badge badge-failure';
  if (TRAFFIC_SIMS.has(simulation)) return 'badge badge-traffic';
  return 'badge badge-neutral';
}

function setWsStatus(connected, label) {
  wsDot.className = `status-dot ${connected ? 'online' : 'offline'}`;
  wsText.textContent = label;
}

function updateClientCount() {
  clientCount.textContent = `${clients.size} client${clients.size === 1 ? '' : 's'}`;
  if (emptyRow) emptyRow.style.display = clients.size > 0 ? 'none' : '';
}

function createCell(className = '') {
  const cell = document.createElement('td');
  if (className) cell.className = className;
  return cell;
}

function ensureRow(hostname) {
  if (rowRefs.has(hostname)) {
    return rowRefs.get(hostname);
  }

  const mainRow = document.createElement('tr');
  mainRow.dataset.hostname = hostname;
  mainRow.className = 'client-row';

  const detailRow = document.createElement('tr');
  detailRow.className = 'control-row hidden';
  const detailCell = document.createElement('td');
  detailCell.colSpan = 10;
  detailRow.appendChild(detailCell);

  const statusCell = createCell('status-cell');
  const statusDot = document.createElement('span');
  statusDot.className = 'status-dot offline';
  statusCell.appendChild(statusDot);

  const hostnameCell = createCell();
  const platformCell = createCell();
  const simIdCell = createCell();
  const ssidCell = createCell();
  const activeCell = createCell('badge-cell');
  const impactCell = createCell();
  const iterationCell = createCell();
  const lastSeenCell = createCell();
  const actionsCell = createCell();

  const controlButton = document.createElement('button');
  controlButton.type = 'button';
  controlButton.className = 'btn btn-small';
  controlButton.textContent = 'Control';
  controlButton.addEventListener('click', () => toggleControlRow(hostname));
  actionsCell.appendChild(controlButton);

  [
    statusCell,
    hostnameCell,
    platformCell,
    simIdCell,
    ssidCell,
    activeCell,
    impactCell,
    iterationCell,
    lastSeenCell,
    actionsCell
  ].forEach((cell) => mainRow.appendChild(cell));

  tbody.appendChild(mainRow);
  tbody.appendChild(detailRow);

  const refs = {
    mainRow,
    detailRow,
    detailCell,
    statusDot,
    hostnameCell,
    platformCell,
    simIdCell,
    ssidCell,
    activeCell,
    impactCell,
    iterationCell,
    lastSeenCell,
    controlButton
  };

  rowRefs.set(hostname, refs);
  return refs;
}

function renderBadges(container, activeSimulations) {
  container.textContent = '';
  if (!activeSimulations || !activeSimulations.length) {
    container.textContent = '—';
    return;
  }

  activeSimulations.forEach((simulation) => {
    const badge = document.createElement('span');
    badge.className = badgeClass(simulation);
    badge.textContent = simulation;
    container.appendChild(badge);
  });
}

function upsertClient(client) {
  const existing = clients.get(client.hostname) || {};
  const merged = {
    ...existing,
    ...client,
    config: client.config || existing.config || {},
    effective_config: client.effective_config || existing.effective_config || client.config || {},
    overrides: client.overrides || existing.overrides || {},
    active_simulations: client.active_simulations || existing.active_simulations || []
  };

  clients.set(client.hostname, merged);
  const refs = ensureRow(client.hostname);

  refs.statusDot.className = `status-dot ${merged.online ? 'online' : 'offline'}`;
  refs.mainRow.classList.toggle('client-offline', !merged.online);
  refs.hostnameCell.textContent = merged.hostname || '—';
  refs.platformCell.textContent = merged.platform || '—';
  refs.simIdCell.textContent = merged.simulation_id || '—';
  refs.ssidCell.textContent = merged.connected_ssid || '—';
  renderBadges(refs.activeCell, merged.active_simulations || []);
  refs.impactCell.textContent = impactSummary(merged.active_simulations || []);
  refs.iterationCell.textContent = String(merged.iteration ?? '—');
  refs.lastSeenCell.textContent = formatLastSeen(merged.last_seen);
  refs.controlButton.textContent = openControlHost === merged.hostname ? 'Close' : 'Control';

  if (openControlHost === merged.hostname) {
    renderControlPanel(merged.hostname);
  }

  updateClientCount();
  if (centralSiteDetailOpen) {
    renderSiteClients(centralSiteDetailOpen);
  }
}

function collectPanelState(panel) {
  const state = {};
  FLAG_ORDER.forEach((flag) => {
    const input = panel.querySelector(`input[data-flag="${flag}"]`);
    state[flag] = input && input.checked ? 'on' : 'off';
  });
  return state;
}

async function sendJson(url, options = {}) {
  const response = await fetch(url, {
    headers: { 'Content-Type': 'application/json', ...(options.headers || {}) },
    ...options
  });

  if (!response.ok) {
    const errorText = await response.text();
    throw new Error(errorText || `Request failed: ${response.status}`);
  }

  const contentType = response.headers.get('content-type') || '';
  if (contentType.includes('application/json')) {
    return response.json();
  }
  return null;
}


async function requestJson(url, options = {}) {
  const response = await fetch(url, options);
  const contentType = response.headers.get('content-type') || '';
  let payload = null;
  if (contentType.includes('application/json')) {
    payload = await response.json();
  } else {
    const text = await response.text();
    payload = text ? { detail: text } : null;
  }
  if (!response.ok) {
    throw new Error(payload?.detail || payload?.message || `HTTP ${response.status}`);
  }
  return payload;
}

function formatCentralDate(value) {
  if (value == null || value === '') return '—';
  const date = new Date(value > 1e12 ? value : value * 1000);
  return Number.isNaN(date.getTime()) ? '—' : date.toLocaleString();
}

function updateCentralToolbar() {
  if (centralLastSynced) {
    centralLastSynced.textContent = centralLastSyncedTs
      ? `Last synced: ${formatCentralDate(centralLastSyncedTs / 1000)}`
      : 'Last synced: —';
  }
  if (centralTokenDot) {
    centralTokenDot.className = `status-dot ${centralTokenValid ? 'online' : 'offline'}`;
  }
  if (centralTokenText) {
    if (centralTokenValid === null) {
      centralTokenText.textContent = 'Token status unknown';
    } else {
      centralTokenText.textContent = centralTokenValid ? 'Token valid' : 'Token unavailable';
    }
  }
}

function monitoredCheckKey(check) {
  return `${check.type}:${check.id}`;
}

function currentCheckSelectionSet() {
  return new Set((currentSettings.monitored_checks || []).map(monitoredCheckKey));
}

function buildCheckBadge(label, kind) {
  const badge = document.createElement('span');
  badge.className = `check-badge ${kind}`;
  badge.textContent = label;
  return badge;
}

function buildCentralConfigPayload() {
  const version = getCentralApiVersion();
  const payload = {
    api_version: version,
    cluster_url: centralClusterUrlInput?.value.trim() || '',
    client_id: centralClientIdInput?.value.trim() || '',
  };
  if (version === 'classic') {
    payload.customer_id = centralCustomerIdInput?.value.trim() || '';
    // Only send secrets when typed — blank = keep existing
    const accessToken = centralAccessTokenInput?.value.trim();
    if (accessToken) payload.access_token = accessToken;
    const refreshToken = centralRefreshTokenInput?.value.trim();
    if (refreshToken) payload.refresh_token = refreshToken;
  }
  const secret = centralClientSecretInput?.value.trim();
  if (secret) payload.client_secret = secret;
  return payload;
}

function updateLocalCentralConfig(payload) {
  currentSettings = {
    ...currentSettings,
    central_config: {
      ...(currentSettings.central_config || {}),
      cluster_url: payload.cluster_url || '',
      client_id: payload.client_id || '',
      customer_id: payload.customer_id || '',
      // Update presence flags optimistically
      access_token_configured: payload.access_token ? true : (currentSettings.central_config?.access_token_configured || false),
      refresh_token_configured: payload.refresh_token ? true : (currentSettings.central_config?.refresh_token_configured || false),
      client_secret_configured: payload.client_secret ? true : (currentSettings.central_config?.client_secret_configured || false),
    }
  };
}

// Site mapping source lists (populated by Load Sites)
let localWsites = [];
let centralSites = [];

function buildMappingSelect(options, selected, placeholder) {
  const sel = document.createElement('select');
  sel.className = 'mapping-val form-control';
  const blank = document.createElement('option');
  blank.value = '';
  blank.textContent = placeholder;
  sel.appendChild(blank);
  options.forEach((val) => {
    const opt = document.createElement('option');
    opt.value = val;
    opt.textContent = val;
    opt.selected = val === selected;
    sel.appendChild(opt);
  });
  return sel;
}

function buildMappingInput(value, placeholder) {
  const inp = document.createElement('input');
  inp.type = 'text';
  inp.className = 'mapping-val';
  inp.value = value;
  inp.placeholder = placeholder;
  return inp;
}

function addMappingRow(wsite = '', centralSite = '') {
  if (!siteMappingsBody) return;
  const row = document.createElement('tr');

  const wsiteCell = document.createElement('td');
  wsiteCell.appendChild(
    localWsites.length
      ? buildMappingSelect(localWsites, wsite, '— select wsite —')
      : buildMappingInput(wsite, 'e.g. MIA')
  );

  const centralCell = document.createElement('td');
  centralCell.appendChild(
    centralSites.length
      ? buildMappingSelect(centralSites, centralSite, '— select Central site —')
      : buildMappingInput(centralSite, 'Central site name')
  );

  const removeCell = document.createElement('td');
  const removeBtn = document.createElement('button');
  removeBtn.type = 'button';
  removeBtn.className = 'btn btn-danger btn-small';
  removeBtn.textContent = 'Remove';
  removeBtn.addEventListener('click', () => row.remove());
  removeCell.appendChild(removeBtn);

  row.appendChild(wsiteCell);
  row.appendChild(centralCell);
  row.appendChild(removeCell);
  siteMappingsBody.appendChild(row);
}

function renderSiteMappingsTable() {
  if (!siteMappingsBody) return;
  siteMappingsBody.textContent = '';
  const entries = Object.entries(currentSettings.site_mappings || {});
  entries.forEach(([wsite, centralSite]) => addMappingRow(wsite, centralSite));
}

function renderSelectedChecksPreview() {
  if (!selectedChecksPreview) return;
  const checks = currentSettings.monitored_checks || [];
  if (!checks.length) {
    selectedChecksPreview.textContent = 'No checks selected yet.';
    return;
  }
  selectedChecksPreview.textContent = `Currently selected: ${checks.map((check) => `${check.name || check.id} (${check.type})`).join(', ')}`;
}

function renderAvailableChecks() {
  if (!availableChecksContainer) return;
  availableChecksContainer.textContent = '';
  const selection = currentCheckSelectionSet();
  const groups = [
    { key: 'alerts', title: 'Alerts' },
    { key: 'insights', title: 'AI Insights' }
  ];
  if (!availableChecks.alerts.length && !availableChecks.insights.length) {
    const empty = document.createElement('div');
    empty.className = 'form-hint';
    empty.textContent = 'No checks returned by Aruba Central.';
    availableChecksContainer.appendChild(empty);
    return;
  }
  groups.forEach(({ key, title }) => {
    const items = availableChecks[key] || [];
    if (!items.length) return;
    const group = document.createElement('div');
    group.className = 'checks-group';

    const heading = document.createElement('h3');
    heading.className = 'checks-group-title';
    heading.textContent = title;
    group.appendChild(heading);

    const list = document.createElement('div');
    list.className = 'check-checkbox-list';
    items.forEach((item) => {
      const label = document.createElement('label');
      label.className = 'check-checkbox-item';

      const input = document.createElement('input');
      input.type = 'checkbox';
      input.dataset.type = key === 'alerts' ? 'alert' : 'insight';
      input.dataset.id = item.id;
      input.dataset.name = item.name || item.id;
      input.checked = selection.has(`${input.dataset.type}:${item.id}`);

      const text = document.createElement('span');
      text.textContent = item.name || item.id;

      label.appendChild(input);
      label.appendChild(text);
      list.appendChild(label);
    });
    group.appendChild(list);
    availableChecksContainer.appendChild(group);
  });
}

function renderCentralOverview() {
  if (!centralOverview || !centralSitesGrid || !centralEmpty) return;
  updateCentralToolbar();
  centralSitesGrid.textContent = '';

  const mappings = currentSettings.site_mappings || {};
  const entries = Object.entries(mappings);
  if (!entries.length) {
    centralEmpty.textContent = 'No Aruba Central site mappings configured yet.';
    centralEmpty.classList.remove('hidden');
    return;
  }

  centralEmpty.classList.add('hidden');
  const monitoredChecks = currentSettings.monitored_checks || [];

  entries.forEach(([wsite, centralSite]) => {
    const card = document.createElement('button');
    card.type = 'button';
    card.className = 'central-site-card';
    card.addEventListener('click', () => openSiteDetail(wsite));

    const title = document.createElement('p');
    title.className = 'central-site-card-title';
    title.textContent = wsite;

    const subtitle = document.createElement('p');
    subtitle.className = 'central-site-card-sub';
    subtitle.textContent = `→ ${centralSite || 'Unmapped Central site'}`;

    const checks = document.createElement('div');
    checks.className = 'central-site-card-checks';

    const siteChecks = centralStatusData[wsite] || {};
    const okCount = monitoredChecks.filter((check) => siteChecks[check.id]?.status === 'OK').length;
    const errorCount = monitoredChecks.filter((check) => siteChecks[check.id]?.status === 'ERROR').length;
    const unknownCount = Math.max(monitoredChecks.length - okCount - errorCount, 0);

    if (!monitoredChecks.length) {
      checks.appendChild(buildCheckBadge('No checks selected', 'check-badge-unknown'));
    } else {
      checks.appendChild(buildCheckBadge(`OK ${okCount}`, 'check-badge-ok'));
      checks.appendChild(buildCheckBadge(`ERROR ${errorCount}`, 'check-badge-error'));
      checks.appendChild(buildCheckBadge(
        !Object.keys(siteChecks).length ? 'Not yet polled' : `Pending ${unknownCount}`,
        'check-badge-unknown'
      ));
    }

    card.appendChild(title);
    card.appendChild(subtitle);
    card.appendChild(checks);
    centralSitesGrid.appendChild(card);
  });
}

async function loadSiteHistory(wsite) {
  if (!centralSiteHistory) return;
  centralSiteHistory.textContent = 'Loading history…';
  try {
    const data = await requestJson(`/api/central/history?site=${encodeURIComponent(wsite)}&hours=24`);
    renderSiteHistory(data.records || []);
  } catch (error) {
    centralSiteHistory.textContent = `Could not load history: ${error.message}`;
  }
}

function renderSiteClients(wsite) {
  if (!centralSiteClients) return;
  centralSiteClients.textContent = '';
  const siteClients = [...clients.values()]
    .filter((client) => (client.config?.wsite || client.effective_config?.wsite || '') === wsite)
    .sort((a, b) => (a.hostname || '').localeCompare(b.hostname || ''));

  if (!siteClients.length) {
    const empty = document.createElement('div');
    empty.className = 'form-hint';
    empty.textContent = 'No connected or known clients for this site.';
    centralSiteClients.appendChild(empty);
    return;
  }

  siteClients.forEach((client) => {
    const row = document.createElement('div');
    row.className = 'client-mini-row';

    const dot = document.createElement('span');
    dot.className = `status-dot ${client.online ? 'online' : 'offline'}`;

    const host = document.createElement('span');
    host.className = 'client-mini-host';
    host.textContent = client.hostname || '—';

    const meta = document.createElement('span');
    meta.className = 'client-mini-sim';
    const active = (client.active_simulations || []).join(', ') || 'No active simulations';
    meta.textContent = `${client.simulation_id || '—'} · ${active}`;

    row.appendChild(dot);
    row.appendChild(host);
    row.appendChild(meta);
    centralSiteClients.appendChild(row);
  });
}

function renderSiteChecks(wsite, checkStatusMap) {
  if (!centralSiteChecks) return;
  centralSiteChecks.textContent = '';
  const monitoredChecks = currentSettings.monitored_checks || [];
  if (!monitoredChecks.length) {
    const empty = document.createElement('div');
    empty.className = 'form-hint';
    empty.textContent = 'No monitored checks configured.';
    centralSiteChecks.appendChild(empty);
    return;
  }

  monitoredChecks.forEach((check) => {
    const status = checkStatusMap[check.id] || null;
    const row = document.createElement('div');
    row.className = 'check-status-row';

    const left = document.createElement('div');
    const name = document.createElement('div');
    name.className = 'check-status-name';
    name.textContent = check.name || check.id;
    const meta = document.createElement('div');
    meta.className = 'check-status-count';
    meta.textContent = `${check.type} · ${status ? `Updated ${formatCentralDate(status.ts)}` : 'Not yet polled'}`;
    left.appendChild(name);
    left.appendChild(meta);

    const right = document.createElement('div');
    right.style.display = 'flex';
    right.style.alignItems = 'center';
    right.style.gap = '8px';
    right.appendChild(buildCheckBadge(
      status ? status.status : 'UNKNOWN',
      status?.status === 'OK' ? 'check-badge-ok' : status?.status === 'ERROR' ? 'check-badge-error' : 'check-badge-unknown'
    ));

    const count = document.createElement('span');
    count.className = 'check-status-count';
    count.textContent = status ? `Count ${status.count ?? 0}` : 'Count —';
    right.appendChild(count);

    row.appendChild(left);
    row.appendChild(right);
    centralSiteChecks.appendChild(row);
  });
}

function renderSiteHistory(records) {
  if (!centralSiteHistory) return;
  centralSiteHistory.textContent = '';
  const sorted = [...records]
    .sort((a, b) => (b.ts || 0) - (a.ts || 0))
    .slice(0, 100);

  if (!sorted.length) {
    centralSiteHistory.textContent = 'No history records in the last 24 hours.';
    return;
  }

  const table = document.createElement('table');
  table.className = 'history-table';

  const thead = document.createElement('thead');
  const headRow = document.createElement('tr');
  ['Time', 'Check', 'Status', 'Count'].forEach((label) => {
    const th = document.createElement('th');
    th.textContent = label;
    headRow.appendChild(th);
  });
  thead.appendChild(headRow);

  const tbodyEl = document.createElement('tbody');
  sorted.forEach((record) => {
    const row = document.createElement('tr');
    const values = [
      formatCentralDate(record.ts),
      record.check_name || record.check_id || '—',
      record.status || '—',
      String(record.count ?? '—')
    ];
    values.forEach((value) => {
      const td = document.createElement('td');
      td.textContent = value;
      row.appendChild(td);
    });
    tbodyEl.appendChild(row);
  });

  table.appendChild(thead);
  table.appendChild(tbodyEl);
  centralSiteHistory.appendChild(table);
}

function openSiteDetail(wsite) {
  centralSiteDetailOpen = wsite;
  if (centralOverview) centralOverview.classList.add('hidden');
  if (centralSiteDetail) centralSiteDetail.classList.remove('hidden');
  if (centralDetailTitle) centralDetailTitle.textContent = wsite;
  if (centralDetailSub) {
    centralDetailSub.textContent = `Central site: ${currentSettings.site_mappings?.[wsite] || 'Unmapped'}`;
  }
  renderSiteClients(wsite);
  renderSiteChecks(wsite, centralStatusData[wsite] || {});
  loadSiteHistory(wsite);
}

function closeSiteDetail() {
  centralSiteDetailOpen = null;
  if (centralSiteDetail) centralSiteDetail.classList.add('hidden');
  if (centralOverview) centralOverview.classList.remove('hidden');
}

function handleCentralUpdate(status, ts) {
  centralStatusData = status || {};
  centralLastSyncedTs = ts ? ts * 1000 : Date.now();
  renderCentralOverview();
  if (centralSiteDetailOpen) {
    renderSiteClients(centralSiteDetailOpen);
    renderSiteChecks(centralSiteDetailOpen, centralStatusData[centralSiteDetailOpen] || {});
    loadSiteHistory(centralSiteDetailOpen);
  }
}

async function loadSettings() {
  try {
    const settings = await requestJson('/api/settings');
    applySettingsToUI(settings || {});
  } catch (error) {
    showSettingsMessage(`Error loading settings: ${error.message}`, true);
  }
}

async function loadCentralStatus() {
  centralStatusInitialized = true;
  try {
    const data = await requestJson('/api/central/status');
    mergeSettings({
      site_mappings: data.site_mappings || {},
      monitored_checks: data.monitored_checks || []
    });
    centralTokenValid = Boolean(data.token_valid);
    handleCentralUpdate(data.status || {}, Date.now() / 1000);
    renderSelectedChecksPreview();
    renderSiteMappingsTable();
  } catch (error) {
    centralTokenValid = false;
    updateCentralToolbar();
    if (centralEmpty) {
      centralEmpty.textContent = `Could not load Central status: ${error.message}`;
      centralEmpty.classList.remove('hidden');
    }
  }
}

function buildToggle(flag, checked) {
  const wrapper = document.createElement('label');
  wrapper.className = 'toggle-item';

  const text = document.createElement('span');
  text.className = 'toggle-label';
  text.textContent = flag;

  const switchLabel = document.createElement('span');
  switchLabel.className = 'switch';

  const input = document.createElement('input');
  input.type = 'checkbox';
  input.dataset.flag = flag;
  input.checked = checked;

  const slider = document.createElement('span');
  slider.className = 'slider';

  switchLabel.appendChild(input);
  switchLabel.appendChild(slider);
  wrapper.appendChild(text);
  wrapper.appendChild(switchLabel);
  return wrapper;
}

function renderControlPanel(hostname) {
  const client = clients.get(hostname);
  const refs = rowRefs.get(hostname);
  if (!client || !refs) return;

  const baseConfig = client.effective_config || client.config || {};
  refs.detailCell.textContent = '';

  const panel = document.createElement('div');
  panel.className = 'control-panel';

  const header = document.createElement('div');
  header.className = 'control-panel-header';
  const title = document.createElement('h2');
  title.textContent = client.hostname;
  const subtitle = document.createElement('p');
  subtitle.textContent = 'Set per-client or global simulation overrides.';
  header.appendChild(title);
  header.appendChild(subtitle);

  const toggles = document.createElement('div');
  toggles.className = 'toggle-grid';
  FLAG_ORDER.forEach((flag) => {
    toggles.appendChild(buildToggle(flag, normalizeFlagValue(baseConfig[flag]) === 'on'));
  });

  const actions = document.createElement('div');
  actions.className = 'panel-actions';

  const applyButton = document.createElement('button');
  applyButton.type = 'button';
  applyButton.className = 'btn btn-primary';
  applyButton.textContent = 'Apply';
  applyButton.addEventListener('click', async () => {
    try {
      const nextState = collectPanelState(panel);
      const diff = {};
      FLAG_ORDER.forEach((flag) => {
        if (normalizeFlagValue(baseConfig[flag]) !== nextState[flag]) {
          diff[flag] = nextState[flag];
        }
      });
      if (!Object.keys(diff).length) return;
      const result = await sendJson(`/api/clients/${encodeURIComponent(hostname)}/control`, {
        method: 'POST',
        body: JSON.stringify(diff)
      });
      if (result?.client) upsertClient(result.client);
    } catch (error) {
      window.alert(`Apply failed: ${error.message}`);
    }
  });

  const clearButton = document.createElement('button');
  clearButton.type = 'button';
  clearButton.className = 'btn btn-secondary';
  clearButton.textContent = 'Clear Overrides';
  clearButton.addEventListener('click', async () => {
    try {
      const result = await sendJson(`/api/clients/${encodeURIComponent(hostname)}/control`, {
        method: 'DELETE'
      });
      if (result?.client) upsertClient(result.client);
    } catch (error) {
      window.alert(`Clear failed: ${error.message}`);
    }
  });

  const applyAllButton = document.createElement('button');
  applyAllButton.type = 'button';
  applyAllButton.className = 'btn btn-danger';
  applyAllButton.textContent = 'Apply to ALL';
  applyAllButton.addEventListener('click', async () => {
    try {
      const nextState = collectPanelState(panel);
      await sendJson('/api/clients/all/control', {
        method: 'POST',
        body: JSON.stringify(nextState)
      });
    } catch (error) {
      window.alert(`Apply to ALL failed: ${error.message}`);
    }
  });

  actions.appendChild(applyButton);
  actions.appendChild(clearButton);
  actions.appendChild(applyAllButton);

  panel.appendChild(header);
  panel.appendChild(toggles);
  panel.appendChild(actions);
  refs.detailCell.appendChild(panel);
}

function toggleControlRow(hostname) {
  if (openControlHost && openControlHost !== hostname) {
    const currentRefs = rowRefs.get(openControlHost);
    if (currentRefs) {
      currentRefs.detailRow.classList.add('hidden');
      currentRefs.mainRow.classList.remove('expanded');
      currentRefs.controlButton.textContent = 'Control';
    }
  }

  const refs = rowRefs.get(hostname);
  if (!refs) return;

  const shouldOpen = openControlHost !== hostname || refs.detailRow.classList.contains('hidden');
  refs.detailRow.classList.toggle('hidden', !shouldOpen);
  refs.mainRow.classList.toggle('expanded', shouldOpen);
  refs.controlButton.textContent = shouldOpen ? 'Close' : 'Control';
  openControlHost = shouldOpen ? hostname : null;

  if (shouldOpen) {
    renderControlPanel(hostname);
  }
}

function handleMessage(message) {
  if (message.type === 'full_state') {
    (message.clients || []).forEach((client) => upsertClient(client));
    return;
  }

  if (message.type === 'repo_status') {
    setRepoStatus(message.synced, message.error);
    return;
  }

  if (message.type === 'settings_update') {
    applySettingsToUI(message.settings);
    return;
  }

  if (message.type === 'central_update') {
    handleCentralUpdate(message.status, message.ts);
    return;
  }

  if (['status_update', 'overrides_update', 'overrides_cleared'].includes(message.type) && message.client) {
    upsertClient(message.client);
  }
}

function connectWebSocket() {
  const protocol = window.location.protocol === 'https:' ? 'wss' : 'ws';
  socket = new WebSocket(`${protocol}://${window.location.host}/ws`);
  setWsStatus(false, 'Connecting');

  socket.addEventListener('open', () => {
    if (reconnectTimer) {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }
    setWsStatus(true, 'Connected');
  });

  socket.addEventListener('message', (event) => {
    try {
      handleMessage(JSON.parse(event.data));
    } catch (error) {
      console.error('Invalid WS message', error);
    }
  });

  socket.addEventListener('close', () => {
    setWsStatus(false, 'Disconnected');
    if (!reconnectTimer) {
      reconnectTimer = window.setTimeout(() => {
        reconnectTimer = null;
        connectWebSocket();
      }, 5000);
    }
  });

  socket.addEventListener('error', () => {
    socket.close();
  });
}

async function applyGlobalOverride(overrides) {
  try {
    await sendJson('/api/clients/all/control', {
      method: 'POST',
      body: JSON.stringify(overrides)
    });
  } catch (error) {
    window.alert(`Global update failed: ${error.message}`);
  }
}

document.getElementById('kill-all').addEventListener('click', () => applyGlobalOverride({ kill_switch: 'on' }));
document.getElementById('resume-all').addEventListener('click', () => applyGlobalOverride({ kill_switch: 'off' }));

if (centralDetailBack) {
  centralDetailBack.addEventListener('click', closeSiteDetail);
}

if (centralTabButton) {
  centralTabButton.addEventListener('click', () => {
    if (!centralStatusInitialized || !Object.keys(centralStatusData).length) {
      loadCentralStatus();
    } else {
      renderCentralOverview();
    }
  });
}

if (setupTabButton) {
  setupTabButton.addEventListener('click', () => {
    if (!currentSettings.repo_url && !currentSettings.repo_branch) {
      loadSettings();
    }
  });
}

if (centralRefreshBtn) {
  centralRefreshBtn.addEventListener('click', async () => {
    const originalLabel = centralRefreshBtn.textContent;
    centralRefreshBtn.disabled = true;
    centralRefreshBtn.textContent = 'Refreshing…';
    try {
      await requestJson('/api/central/poll', { method: 'POST' });
      await loadCentralStatus();
    } catch (error) {
      if (centralLastSynced) centralLastSynced.textContent = `Refresh failed: ${error.message}`;
    } finally {
      centralRefreshBtn.disabled = false;
      centralRefreshBtn.textContent = originalLabel;
    }
  });
}

if (centralTestBtn) {
  centralTestBtn.addEventListener('click', async () => {
    const originalLabel = centralTestBtn.textContent;
    const configPayload = buildCentralConfigPayload();
    updateLocalCentralConfig(configPayload);
    centralTestBtn.disabled = true;
    centralTestBtn.textContent = 'Testing…';
    showInlineMessage(centralTestMsg, '', false, 0);
    try {
      await requestJson('/api/settings', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ central_config: configPayload })
      });
      const result = await requestJson('/api/central/test-connection', { method: 'POST' });
      centralTokenValid = true;
      updateCentralToolbar();
      showInlineMessage(centralTestMsg, result.message || 'Connected to Aruba Central successfully.', false);
      // Clear secret fields — status hints show "configured" instead
      if (centralClientSecretInput) centralClientSecretInput.value = '';
      if (centralAccessTokenInput) centralAccessTokenInput.value = '';
      if (centralRefreshTokenInput) centralRefreshTokenInput.value = '';
      // Refresh status hints
      applySettingsToUI(currentSettings);
    } catch (error) {
      centralTokenValid = false;
      updateCentralToolbar();
      showInlineMessage(centralTestMsg, `Error: ${error.message}`, true, 7000);
    } finally {
      centralTestBtn.disabled = false;
      centralTestBtn.textContent = originalLabel;
    }
  });
}

async function loadSiteMappingSources() {
  if (loadSitesBtn) { loadSitesBtn.disabled = true; loadSitesBtn.textContent = 'Loading…'; }
  if (sitesLoadStatus) sitesLoadStatus.textContent = '';
  try {
    const [wsiteData, centralData] = await Promise.all([
      requestJson('/api/local-wsites'),
      requestJson('/api/central/sites'),
    ]);
    localWsites = wsiteData.wsites || [];
    centralSites = centralData.sites || [];
    renderSiteMappingsTable();
    if (sitesLoadStatus) {
      sitesLoadStatus.textContent = `Loaded ${localWsites.length} local wsite(s), ${centralSites.length} Central site(s).`;
    }
  } catch (err) {
    if (sitesLoadStatus) sitesLoadStatus.textContent = `Error: ${err.message}`;
  } finally {
    if (loadSitesBtn) { loadSitesBtn.disabled = false; loadSitesBtn.textContent = '🔄 Load Sites'; }
  }
}

if (loadSitesBtn) {
  loadSitesBtn.addEventListener('click', loadSiteMappingSources);
}

if (addMappingBtn) {
  addMappingBtn.addEventListener('click', () => addMappingRow());
}

if (saveMappingsBtn) {
  saveMappingsBtn.addEventListener('click', async () => {
    const rows = siteMappingsBody ? [...siteMappingsBody.querySelectorAll('tr')] : [];
    const siteMappings = {};
    rows.forEach((row) => {
      const cells = row.querySelectorAll('td');
      const wsite = cells[0]?.querySelector('.mapping-val')?.value?.trim() || '';
      const centralSite = cells[1]?.querySelector('.mapping-val')?.value?.trim() || '';
      if (wsite && centralSite) siteMappings[wsite] = centralSite;
    });
    const originalLabel = saveMappingsBtn.textContent;
    saveMappingsBtn.disabled = true;
    saveMappingsBtn.textContent = 'Saving…';
    try {
      await requestJson('/api/settings', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ site_mappings: siteMappings })
      });
      applySettingsToUI({ site_mappings: siteMappings });
      showInlineMessage(centralMappingsMsg, 'Site mappings saved.', false);
      renderCentralOverview();
    } catch (error) {
      showInlineMessage(centralMappingsMsg, `Error: ${error.message}`, true, 7000);
    } finally {
      saveMappingsBtn.disabled = false;
      saveMappingsBtn.textContent = originalLabel;
    }
  });
}

if (loadChecksBtn) {
  loadChecksBtn.addEventListener('click', async () => {
    const originalLabel = loadChecksBtn.textContent;
    loadChecksBtn.disabled = true;
    loadChecksBtn.textContent = 'Loading…';
    if (availableChecksContainer) availableChecksContainer.textContent = 'Loading available checks…';
    try {
      const data = await requestJson('/api/central/available');
      availableChecks = {
        alerts: data.alerts || [],
        insights: data.insights || []
      };
      renderAvailableChecks();
      showInlineMessage(centralChecksMsg, 'Available checks loaded.', false);
    } catch (error) {
      availableChecks = { alerts: [], insights: [] };
      if (availableChecksContainer) {
        availableChecksContainer.textContent = `Unable to load checks: ${error.message}`;
      }
      showInlineMessage(centralChecksMsg, `Error: ${error.message}`, true, 7000);
    } finally {
      loadChecksBtn.disabled = false;
      loadChecksBtn.textContent = originalLabel;
    }
  });
}

if (saveChecksBtn) {
  saveChecksBtn.addEventListener('click', async () => {
    const allInputs = availableChecksContainer
      ? [...availableChecksContainer.querySelectorAll('input[type="checkbox"]')]
      : [];
    const checkedInputs = allInputs.filter((input) => input.checked);
    const monitoredChecks = allInputs.length
      ? checkedInputs.map((input) => ({
          type: input.dataset.type,
          id: input.dataset.id,
          name: input.dataset.name || input.dataset.id
        }))
      : (currentSettings.monitored_checks || []);
    const originalLabel = saveChecksBtn.textContent;
    saveChecksBtn.disabled = true;
    saveChecksBtn.textContent = 'Saving…';
    try {
      await requestJson('/api/settings', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ monitored_checks: monitoredChecks })
      });
      applySettingsToUI({ monitored_checks: monitoredChecks });
      if ((availableChecks.alerts.length || availableChecks.insights.length) && availableChecksContainer) {
        renderAvailableChecks();
      }
      showInlineMessage(centralChecksMsg, 'Monitored checks saved.', false);
    } catch (error) {
      showInlineMessage(centralChecksMsg, `Error: ${error.message}`, true, 7000);
    } finally {
      saveChecksBtn.disabled = false;
      saveChecksBtn.textContent = originalLabel;
    }
  });
}

loadSettings();
updateCentralToolbar();
connectWebSocket();

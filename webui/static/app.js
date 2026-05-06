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
const clientCount = document.getElementById('client-count');
const wsDot = document.getElementById('ws-dot');
const wsText = document.getElementById('ws-text');
let socket = null;
let reconnectTimer = null;
let openControlHost = null;

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

connectWebSocket();

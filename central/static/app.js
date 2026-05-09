let authToken = localStorage.getItem('centralAuthToken');
let currentUser = null;
const state = {
  sites: [],
  workspaces: [],
  checks: [],
  commands: []
};

document.addEventListener('DOMContentLoaded', () => {
  bindUI();
  updateAuthUI();
  showTab('dashboard');
  checkAuth().finally(() => {
    loadDashboard();
  });
});

function bindUI() {
  document.querySelectorAll('.tab').forEach((button) => {
    button.addEventListener('click', () => {
      if (button.dataset.auth === 'required' && !authToken) {
        openLoginModal();
        return;
      }
      showTab(button.dataset.tab);
    });
  });

  document.getElementById('login-button').addEventListener('click', () => {
    if (authToken) {
      logout();
      return;
    }
    openLoginModal();
  });

  document.getElementById('refresh-dashboard').addEventListener('click', loadDashboard);
  document.getElementById('refresh-sites').addEventListener('click', loadSitesTab);
  document.getElementById('refresh-workspaces').addEventListener('click', loadWorkspacesTab);
  document.getElementById('refresh-checks').addEventListener('click', loadChecksTab);
  document.getElementById('refresh-commands').addEventListener('click', loadCommandsTab);

  document.getElementById('login-close').addEventListener('click', closeLoginModal);
  document.getElementById('login-cancel').addEventListener('click', closeLoginModal);
  document.getElementById('login-modal').addEventListener('click', (event) => {
    if (event.target.id === 'login-modal') closeLoginModal();
  });
  document.getElementById('login-form').addEventListener('submit', submitLogin);

  document.getElementById('workspace-form').addEventListener('submit', createWorkspace);
  document.getElementById('check-form').addEventListener('submit', createCheck);
  document.getElementById('command-form').addEventListener('submit', createCommand);
}

async function apiFetch(url, opts = {}) {
  const options = { ...opts };
  const headers = new Headers(opts.headers || {});
  const isJsonBody = options.body && !(options.body instanceof FormData);

  if (authToken) headers.set('Authorization', `Bearer ${authToken}`);
  if (isJsonBody && !headers.has('Content-Type')) headers.set('Content-Type', 'application/json');
  if (isJsonBody && headers.get('Content-Type') === 'application/json' && typeof options.body !== 'string') {
    options.body = JSON.stringify(options.body);
  }

  options.headers = headers;
  const response = await fetch(url, options);

  if (response.status === 401) {
    clearAuth();
    updateAuthUI();
  }

  if (response.status === 204) return null;

  const contentType = response.headers.get('content-type') || '';
  const payload = contentType.includes('application/json') ? await response.json() : await response.text();

  if (!response.ok) {
    const message = typeof payload === 'string' ? payload : payload.detail || payload.message || 'Request failed';
    throw new Error(message);
  }

  return payload;
}

function showTab(tabId) {
  document.querySelectorAll('.tab').forEach((button) => {
    const active = button.dataset.tab === tabId;
    button.classList.toggle('active', active);
    button.setAttribute('aria-selected', String(active));
  });

  document.querySelectorAll('.tab-panel').forEach((panel) => {
    panel.classList.toggle('hidden', panel.id !== `tab-${tabId}`);
  });

  if (tabId === 'dashboard') loadDashboard();
  if (tabId === 'sites' && authToken) loadSitesTab();
  if (tabId === 'workspaces' && authToken) loadWorkspacesTab();
  if (tabId === 'checks' && authToken) loadChecksTab();
  if (tabId === 'commands' && authToken) loadCommandsTab();
  if (tabId === 'settings' && authToken) loadSettingsTab();
}

function showNotification(message, level = 'info') {
  const toast = document.createElement('div');
  toast.className = `toast toast-${level}`;
  toast.textContent = message;
  document.getElementById('toast-container').appendChild(toast);
  window.setTimeout(() => {
    toast.classList.add('toast-fade');
    window.setTimeout(() => toast.remove(), 250);
  }, 3500);
}

function openLoginModal() {
  document.getElementById('login-modal').classList.remove('hidden');
  document.querySelector('#login-form input[name="username"]').focus();
}

function closeLoginModal() {
  document.getElementById('login-modal').classList.add('hidden');
}

async function submitLogin(event) {
  event.preventDefault();
  const form = new FormData(event.target);
  try {
    const data = await apiFetch('/api/auth/login', {
      method: 'POST',
      body: {
        username: String(form.get('username') || '').trim(),
        password: String(form.get('password') || '')
      }
    });

    authToken = data.access_token;
    localStorage.setItem('centralAuthToken', authToken);
    closeLoginModal();
    event.target.reset();
    await checkAuth();
    showNotification('Logged in successfully.', 'success');
    loadDashboard();
  } catch (error) {
    showNotification(error.message, 'error');
  }
}

async function checkAuth() {
  if (!authToken) {
    clearAuth();
    updateAuthUI();
    return false;
  }

  try {
    currentUser = await apiFetch('/api/auth/me');
    updateAuthUI();
    return true;
  } catch (error) {
    clearAuth();
    updateAuthUI();
    return false;
  }
}

function clearAuth() {
  authToken = null;
  currentUser = null;
  localStorage.removeItem('centralAuthToken');
}

function logout() {
  clearAuth();
  updateAuthUI();
  showTab('dashboard');
  showNotification('Logged out.', 'info');
}

function updateAuthUI() {
  const loginButton = document.getElementById('login-button');
  loginButton.textContent = authToken && currentUser ? `${currentUser.username} · Logout` : 'Login';

  document.querySelectorAll('.management-tab').forEach((tab) => {
    tab.classList.toggle('hidden', !authToken || !currentUser);
  });

  const activeManagementTab = document.querySelector('.tab.active[data-auth="required"]');
  if (activeManagementTab && (!authToken || !currentUser)) {
    showTab('dashboard');
  }
}

async function loadDashboard() {
  try {
    state.sites = await apiFetch('/api/sites');
    renderSitesSummary(state.sites);
  } catch (error) {
    showNotification(`Dashboard load failed: ${error.message}`, 'error');
  }
}

function renderSitesSummary(sites) {
  const summary = document.getElementById('dashboard-summary');
  const empty = document.getElementById('dashboard-empty');
  summary.innerHTML = '';

  if (!sites.length) {
    empty.classList.remove('hidden');
    return;
  }
  empty.classList.add('hidden');

  const counts = sites.reduce((acc, site) => {
    acc[site.status] = (acc[site.status] || 0) + 1;
    return acc;
  }, {});

  const headline = document.createElement('div');
  headline.className = 'site-card site-card-summary';
  headline.innerHTML = `
    <div class="site-card-header"><h3>Summary</h3><span class="status-pill status-approved">${sites.length} total</span></div>
    <p>Approved: ${counts.approved || 0}</p>
    <p>Pending: ${counts.pending || 0}</p>
    <p>Revoked: ${counts.revoked || 0}</p>
  `;
  summary.appendChild(headline);

  sites.forEach((site) => {
    const card = document.createElement('article');
    card.className = 'site-card';
    card.innerHTML = `
      <div class="site-card-header">
        <h3>${escapeHtml(site.label || site.hostname)}</h3>
        <span class="status-pill status-${site.status}">${site.status}</span>
      </div>
      <p><strong>Hostname:</strong> ${escapeHtml(site.hostname)}</p>
      <p><strong>Workspace:</strong> ${site.workspace_id || '—'}</p>
      <p><strong>Last Seen:</strong> ${formatDate(site.last_seen)}</p>
      <p><strong>Registered:</strong> ${formatDate(site.created_at)}</p>
    `;
    summary.appendChild(card);
  });
}

async function loadSitesTab() {
  try {
    state.sites = await apiFetch('/api/sites');
    const body = document.getElementById('sites-table-body');
    body.innerHTML = '';

    state.sites.forEach((site) => {
      const row = document.createElement('tr');
      row.innerHTML = `
        <td>${escapeHtml(site.hostname)}</td>
        <td>${escapeHtml(site.label || '—')}</td>
        <td><span class="status-pill status-${site.status}">${site.status}</span></td>
        <td>${formatDate(site.last_seen)}</td>
        <td>${formatDate(site.created_at)}</td>
        <td class="actions-cell">
          <button class="btn btn-secondary btn-small" data-action="approve" data-id="${site.id}">Approve</button>
          <button class="btn btn-secondary btn-small" data-action="revoke" data-id="${site.id}">Revoke</button>
          <button class="btn btn-danger btn-small" data-action="delete" data-id="${site.id}">Delete</button>
        </td>
      `;
      body.appendChild(row);
    });

    body.querySelectorAll('button').forEach((button) => button.addEventListener('click', handleSiteAction));
  } catch (error) {
    showNotification(`Sites load failed: ${error.message}`, 'error');
  }
}

async function handleSiteAction(event) {
  const { action, id } = event.currentTarget.dataset;
  try {
    if (action === 'approve') {
      const result = await apiFetch(`/api/sites/${id}/approve`, { method: 'POST' });
      showNotification(`Site approved. API key: ${result.api_key}`, 'success');
    } else if (action === 'revoke') {
      await apiFetch(`/api/sites/${id}/revoke`, { method: 'POST' });
      showNotification('Site revoked.', 'info');
    } else if (action === 'delete') {
      await apiFetch(`/api/sites/${id}`, { method: 'DELETE' });
      showNotification('Site deleted.', 'info');
    }
    await loadSitesTab();
    loadDashboard();
  } catch (error) {
    showNotification(error.message, 'error');
  }
}

async function loadWorkspacesTab() {
  try {
    state.workspaces = await apiFetch('/api/workspaces');
    renderWorkspaceList();
    populateWorkspaceSelects();
  } catch (error) {
    showNotification(`Workspaces load failed: ${error.message}`, 'error');
  }
}

function renderWorkspaceList() {
  const container = document.getElementById('workspace-list');
  container.innerHTML = '';

  if (!state.workspaces.length) {
    container.innerHTML = '<div class="card empty-card">No workspaces created yet.</div>';
    return;
  }

  state.workspaces.forEach((workspace) => {
    const card = document.createElement('article');
    card.className = 'card workspace-card';
    card.innerHTML = `
      <div class="card-header card-header-inline">
        <span class="card-title">${escapeHtml(workspace.name)}</span>
        <span class="status-pill status-${workspace.ownership === 'remote' ? 'pending' : 'approved'}">${workspace.ownership}</span>
      </div>
      <div class="card-body">
        <p><strong>Aruba Workspace ID:</strong> ${escapeHtml(workspace.aruba_workspace_id || '—')}</p>
        <p><strong>Central Polling:</strong> ${workspace.central_poll_enabled ? 'Enabled' : 'Disabled'}</p>
        <p><strong>Created:</strong> ${formatDate(workspace.created_at)}</p>
        <button class="btn btn-danger btn-small" data-workspace-delete="${workspace.id}">Delete</button>
      </div>
    `;
    container.appendChild(card);
  });

  container.querySelectorAll('[data-workspace-delete]').forEach((button) => {
    button.addEventListener('click', async (event) => {
      try {
        await apiFetch(`/api/workspaces/${event.currentTarget.dataset.workspaceDelete}`, { method: 'DELETE' });
        showNotification('Workspace deleted.', 'info');
        await loadWorkspacesTab();
      } catch (error) {
        showNotification(error.message, 'error');
      }
    });
  });
}

function populateWorkspaceSelects() {
  const select = document.getElementById('check-workspace');
  select.innerHTML = '';
  state.workspaces.forEach((workspace) => {
    const option = document.createElement('option');
    option.value = workspace.id;
    option.textContent = workspace.name;
    select.appendChild(option);
  });
}

async function createWorkspace(event) {
  event.preventDefault();
  const form = new FormData(event.target);
  try {
    await apiFetch('/api/workspaces', {
      method: 'POST',
      body: {
        name: String(form.get('name') || '').trim(),
        aruba_workspace_id: String(form.get('aruba_workspace_id') || '').trim() || null,
        ownership: String(form.get('ownership') || 'local'),
        aruba_config: {},
        notification_config: {},
        central_poll_enabled: form.get('central_poll_enabled') === 'on'
      }
    });
    event.target.reset();
    showNotification('Workspace created.', 'success');
    await loadWorkspacesTab();
  } catch (error) {
    showNotification(error.message, 'error');
  }
}

async function loadChecksTab() {
  try {
    const [checks, workspaces] = await Promise.all([
      apiFetch('/api/checks'),
      apiFetch('/api/workspaces')
    ]);
    state.checks = checks;
    state.workspaces = workspaces;
    populateWorkspaceSelects();

    const lookup = Object.fromEntries(workspaces.map((workspace) => [workspace.id, workspace.name]));
    const body = document.getElementById('checks-table-body');
    body.innerHTML = '';
    checks.forEach((check) => {
      const row = document.createElement('tr');
      row.innerHTML = `
        <td>${escapeHtml(check.check_name)}</td>
        <td>${escapeHtml(check.check_type)}</td>
        <td><span class="status-pill status-${statusToClass(check.status)}">${check.status}</span></td>
        <td>${escapeHtml(lookup[check.workspace_id] || check.workspace_id)}</td>
        <td><button class="btn btn-danger btn-small" data-check-delete="${check.id}">Delete</button></td>
      `;
      body.appendChild(row);
    });

    body.querySelectorAll('[data-check-delete]').forEach((button) => {
      button.addEventListener('click', async (event) => {
        try {
          await apiFetch(`/api/checks/${event.currentTarget.dataset.checkDelete}`, { method: 'DELETE' });
          showNotification('Check deleted.', 'info');
          await loadChecksTab();
        } catch (error) {
          showNotification(error.message, 'error');
        }
      });
    });
  } catch (error) {
    showNotification(`Checks load failed: ${error.message}`, 'error');
  }
}

async function createCheck(event) {
  event.preventDefault();
  const form = new FormData(event.target);
  try {
    await apiFetch('/api/checks', {
      method: 'POST',
      body: {
        workspace_id: String(form.get('workspace_id')),
        check_name: String(form.get('check_name') || '').trim(),
        check_type: String(form.get('check_type') || 'alert'),
        timeout_minutes: Number(form.get('timeout_minutes') || 60),
        status: 'unknown'
      }
    });
    event.target.reset();
    showNotification('Check created.', 'success');
    await loadChecksTab();
  } catch (error) {
    showNotification(error.message, 'error');
  }
}

async function loadCommandsTab() {
  try {
    state.commands = await apiFetch('/api/commands');
    const body = document.getElementById('commands-table-body');
    body.innerHTML = '';

    state.commands.forEach((command) => {
      const row = document.createElement('tr');
      row.innerHTML = `
        <td>${escapeHtml(command.target)}</td>
        <td>${escapeHtml(command.type)}</td>
        <td><span class="status-pill status-${statusToClass(command.status)}">${command.status}</span></td>
        <td>${formatDate(command.created_at)}</td>
        <td><button class="btn btn-danger btn-small" data-command-delete="${command.id}">Delete</button></td>
      `;
      body.appendChild(row);
    });

    body.querySelectorAll('[data-command-delete]').forEach((button) => {
      button.addEventListener('click', async (event) => {
        try {
          await apiFetch(`/api/commands/${event.currentTarget.dataset.commandDelete}`, { method: 'DELETE' });
          showNotification('Command deleted.', 'info');
          await loadCommandsTab();
        } catch (error) {
          showNotification(error.message, 'error');
        }
      });
    });
  } catch (error) {
    showNotification(`Commands load failed: ${error.message}`, 'error');
  }
}

async function createCommand(event) {
  event.preventDefault();
  const form = new FormData(event.target);
  try {
    const payload = JSON.parse(String(form.get('payload') || '{}'));
    await apiFetch('/api/commands', {
      method: 'POST',
      body: {
        target: String(form.get('target') || '').trim(),
        type: String(form.get('type') || '').trim(),
        site_id: String(form.get('site_id') || '').trim() || null,
        workspace_id: String(form.get('workspace_id') || '').trim() || null,
        payload
      }
    });
    showNotification('Command queued.', 'success');
    await loadCommandsTab();
  } catch (error) {
    showNotification(`Command creation failed: ${error.message}`, 'error');
  }
}

function loadSettingsTab() {
  const card = document.getElementById('settings-card');
  card.innerHTML = `
    <div class="card-header"><span class="card-title">Session</span></div>
    <div class="card-body">
      <p><strong>User:</strong> ${escapeHtml(currentUser?.username || 'Not logged in')}</p>
      <p><strong>Token Stored:</strong> ${authToken ? 'Yes' : 'No'}</p>
      <button id="logout-inline" class="btn btn-secondary" type="button">Logout</button>
    </div>
  `;
  document.getElementById('logout-inline').addEventListener('click', logout);
}

function formatDate(value) {
  if (!value) return '—';
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? value : date.toLocaleString();
}

function statusToClass(status) {
  if (status === 'green' || status === 'approved' || status === 'executed') return 'approved';
  if (status === 'waiting' || status === 'pending' || status === 'queued' || status === 'delivered' || status === 'unknown') return 'pending';
  return 'revoked';
}

function escapeHtml(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

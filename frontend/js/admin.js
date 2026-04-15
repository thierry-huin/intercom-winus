const API = window.IntercomAPI;

let users = [];
let groups = [];
let permissions = [];
let groupPermissions = [];

// ======================== INIT ========================

document.addEventListener('DOMContentLoaded', () => {
  if (!API.getToken() || API.getUser()?.role !== 'admin') {
    window.location.href = 'index.html';
    return;
  }

  loadUsers();
  loadGroups();
  loadPermissions();

  // Tab switching
  document.querySelectorAll('.tab').forEach((tab) => {
    tab.addEventListener('click', () => switchTab(tab.dataset.tab));
  });

  document.getElementById('addUserBtn').addEventListener('click', showAddUserModal);
  document.getElementById('addGroupBtn').addEventListener('click', showAddGroupModal);
  document.getElementById('userForm').addEventListener('submit', saveUser);
  document.getElementById('groupForm').addEventListener('submit', saveGroup);
  document.getElementById('savePermsBtn').addEventListener('click', savePermissions);
  document.getElementById('permGroupFilter').addEventListener('change', renderPermissionMatrix);
  document.getElementById('logoutBtn').addEventListener('click', () => {
    API.logout();
    window.location.href = 'index.html';
  });
});

function switchTab(tabName) {
  document.querySelectorAll('.tab').forEach((t) => t.classList.remove('active'));
  document.querySelectorAll('.tab-content').forEach((t) => t.classList.remove('active'));
  document.querySelector(`.tab[data-tab="${tabName}"]`).classList.add('active');
  document.getElementById(`${tabName}-tab`).classList.add('active');

  if (tabName === 'permissions') {
    renderPermissionMatrix();
  }
}

// ======================== USERS ========================

async function loadUsers() {
  users = await API.get('/api/admin/users');
  renderUsers();
}

function renderUsers() {
  const tbody = document.querySelector('#usersTable tbody');
  tbody.innerHTML = users
    .map(
      (u) => `
    <tr>
      <td>${u.id}</td>
      <td>${u.username}</td>
      <td>${u.display_name}</td>
      <td>${u.role}</td>
      <td>${u.room_id || '-'}</td>
      <td>
        <button class="btn btn-sm btn-primary" onclick="editUser(${u.id})">Editar</button>
        <button class="btn btn-sm btn-danger" onclick="deleteUser(${u.id})">Eliminar</button>
      </td>
    </tr>`
    )
    .join('');
}

function showAddUserModal() {
  document.getElementById('userModalTitle').textContent = 'Nuevo Usuario';
  document.getElementById('userId').value = '';
  document.getElementById('userUsername').value = '';
  document.getElementById('userUsername').disabled = false;
  document.getElementById('userPassword').value = '';
  document.getElementById('userPassword').required = true;
  document.getElementById('userDisplayName').value = '';
  document.getElementById('userRole').value = 'user';
  openModal('userModal');
}

function editUser(id) {
  const u = users.find((x) => x.id === id);
  if (!u) return;

  document.getElementById('userModalTitle').textContent = 'Editar Usuario';
  document.getElementById('userId').value = u.id;
  document.getElementById('userUsername').value = u.username;
  document.getElementById('userUsername').disabled = true;
  document.getElementById('userPassword').value = '';
  document.getElementById('userPassword').required = false;
  document.getElementById('userDisplayName').value = u.display_name;
  document.getElementById('userRole').value = u.role;
  openModal('userModal');
}

async function saveUser(e) {
  e.preventDefault();
  const id = document.getElementById('userId').value;
  const data = {
    username: document.getElementById('userUsername').value,
    password: document.getElementById('userPassword').value,
    display_name: document.getElementById('userDisplayName').value,
    role: document.getElementById('userRole').value,
  };

  try {
    if (id) {
      await API.put(`/api/admin/users/${id}`, data);
    } else {
      await API.post('/api/admin/users', data);
    }
    closeModal('userModal');
    loadUsers();
  } catch (err) {
    alert(err.message);
  }
}

async function deleteUser(id) {
  const u = users.find((x) => x.id === id);
  if (!confirm(`¿Eliminar usuario "${u.display_name}"?`)) return;

  await API.delete(`/api/admin/users/${id}`);
  loadUsers();
  loadPermissions();
}

// ======================== GROUPS ========================

async function loadGroups() {
  groups = await API.get('/api/admin/groups');
  renderGroups();
}

function renderGroups() {
  const container = document.getElementById('groupsList');
  if (groups.length === 0) {
    container.innerHTML = '<p style="color:var(--text-light)">No hay grupos creados.</p>';
    return;
  }

  container.innerHTML = groups
    .map(
      (g) => `
    <div class="group-card">
      <div class="group-info">
        <h3>${g.name}</h3>
        <div class="members">
          Miembros: ${g.members.map((m) => m.display_name).join(', ') || 'Ninguno'}
        </div>
      </div>
      <div class="group-actions">
        <button class="btn btn-sm btn-primary" onclick="editGroup(${g.id})">Editar</button>
        <button class="btn btn-sm btn-danger" onclick="deleteGroup(${g.id})">Eliminar</button>
      </div>
    </div>`
    )
    .join('');
}

function showAddGroupModal() {
  document.getElementById('groupModalTitle').textContent = 'Nuevo Grupo';
  document.getElementById('groupId').value = '';
  document.getElementById('groupName').value = '';
  renderGroupMemberCheckboxes([]);
  openModal('groupModal');
}

function editGroup(id) {
  const g = groups.find((x) => x.id === id);
  if (!g) return;

  document.getElementById('groupModalTitle').textContent = 'Editar Grupo';
  document.getElementById('groupId').value = g.id;
  document.getElementById('groupName').value = g.name;
  renderGroupMemberCheckboxes(g.members.map((m) => m.id));
  openModal('groupModal');
}

function renderGroupMemberCheckboxes(selectedIds) {
  const container = document.getElementById('groupMembersCheckboxes');
  const nonAdminUsers = users.filter((u) => u.role !== 'admin');
  container.innerHTML = nonAdminUsers
    .map(
      (u) => `
    <label>
      <input type="checkbox" value="${u.id}" ${selectedIds.includes(u.id) ? 'checked' : ''}>
      ${u.display_name} (${u.username})
    </label>`
    )
    .join('');
}

async function saveGroup(e) {
  e.preventDefault();
  const id = document.getElementById('groupId').value;
  const name = document.getElementById('groupName').value;
  const checkboxes = document.querySelectorAll('#groupMembersCheckboxes input:checked');
  const member_ids = Array.from(checkboxes).map((cb) => parseInt(cb.value));

  try {
    let groupId;
    if (id) {
      await API.put(`/api/admin/groups/${id}`, { name, member_ids });
      groupId = parseInt(id);
    } else {
      const created = await API.post('/api/admin/groups', { name, member_ids });
      groupId = created.id;
    }

    // Auto-grant group talk permission for all members (talk + listen by default)
    if (member_ids.length > 0) {
      const grpPerms = member_ids.map((uid) => ({
        from_user_id: uid,
        to_group_id: groupId,
        can_talk: true,
      }));
      await API.post('/api/admin/group-permissions/bulk', { permissions: grpPerms });
    }

    closeModal('groupModal');
    loadGroups();
    loadPermissions(); // Refresh permission matrix
  } catch (err) {
    alert(err.message);
  }
}

async function deleteGroup(id) {
  const g = groups.find((x) => x.id === id);
  if (!confirm(`¿Eliminar grupo "${g.name}"?`)) return;

  await API.delete(`/api/admin/groups/${id}`);
  loadGroups();
}

// ======================== PERMISSIONS ========================

async function loadPermissions() {
  permissions = await API.get('/api/admin/permissions');
  groupPermissions = await API.get('/api/admin/group-permissions');
}

function renderPermissionMatrix() {
  const container = document.getElementById('permMatrix');
  const allNonAdmin = users.filter((u) => u.role !== 'admin');

  // Update group filter dropdown
  const filterSelect = document.getElementById('permGroupFilter');
  const currentFilter = filterSelect.value;
  const existingOptions = filterSelect.querySelectorAll('option[value]:not([value=""])');
  const existingGroupIds = new Set(Array.from(existingOptions).map(o => o.value));
  const currentGroupIds = new Set(groups.map(g => String(g.id)));
  // Only rebuild options if groups changed
  if (existingGroupIds.size !== currentGroupIds.size || ![...existingGroupIds].every(id => currentGroupIds.has(id))) {
    filterSelect.innerHTML = '<option value="">Todos los usuarios</option>' +
      groups.map(g => `<option value="${g.id}">${g.name}</option>`).join('');
    filterSelect.value = currentFilter;
  }

  // Apply group filter
  let nonAdminUsers;
  const filterGroupId = parseInt(filterSelect.value);
  if (filterGroupId) {
    const group = groups.find(g => g.id === filterGroupId);
    const memberIds = new Set(group ? group.members.map(m => m.id) : []);
    nonAdminUsers = allNonAdmin.filter(u => memberIds.has(u.id));
  } else {
    nonAdminUsers = allNonAdmin;
  }

  // Sort alphabetically by display_name (same order for rows AND columns)
  nonAdminUsers.sort((a, b) => a.display_name.localeCompare(b.display_name));

  if (nonAdminUsers.length === 0) {
    container.innerHTML = '<p style="color:var(--text-light)">No hay usuarios para mostrar.</p>';
    return;
  }

  let html = '<table><thead><tr><th>De \\ A</th>';

  // Column headers: users (same sorted order)
  for (const u of nonAdminUsers) {
    html += `<th title="${u.username}">${u.display_name}</th>`;
  }

  // Column headers: groups
  for (const g of groups) {
    html += `<th title="Grupo: ${g.name}" style="background:#e8f0fe">${g.name}</th>`;
  }

  html += '</tr></thead><tbody>';

  // Rows (same sorted order)
  for (const fromUser of nonAdminUsers) {
    html += `<tr><td><strong>${fromUser.display_name}</strong></td>`;

    // User-to-user permissions
    for (const toUser of nonAdminUsers) {
      if (fromUser.id === toUser.id) {
        html += '<td class="self-cell">&mdash;</td>';
      } else {
        const perm = permissions.find(
          (p) => p.from_user_id === fromUser.id && p.to_user_id === toUser.id
        );
        const checked = perm && perm.can_talk ? 'checked' : '';
        html += `<td><input type="checkbox" data-from="${fromUser.id}" data-to="${toUser.id}" data-type="user" ${checked}></td>`;
      }
    }

    // User-to-group permissions
    for (const g of groups) {
      const perm = groupPermissions.find(
        (p) => p.from_user_id === fromUser.id && p.to_group_id === g.id
      );
      const checked = perm && perm.can_talk ? 'checked' : '';
      html += `<td style="background:#f8faff"><input type="checkbox" data-from="${fromUser.id}" data-to="${g.id}" data-type="group" ${checked}></td>`;
    }

    html += '</tr>';
  }

  html += '</tbody></table>';
  container.innerHTML = html;
}

async function savePermissions() {
  const userPerms = [];
  const grpPerms = [];

  document.querySelectorAll('#permMatrix input[type="checkbox"]').forEach((cb) => {
    const fromId = parseInt(cb.dataset.from);
    const toId = parseInt(cb.dataset.to);
    const type = cb.dataset.type;

    if (type === 'user') {
      userPerms.push({ from_user_id: fromId, to_user_id: toId, can_talk: cb.checked });
    } else if (type === 'group') {
      grpPerms.push({ from_user_id: fromId, to_group_id: toId, can_talk: cb.checked });
    }
  });

  try {
    await API.post('/api/admin/permissions/bulk', { permissions: userPerms });
    await API.post('/api/admin/group-permissions/bulk', { permissions: grpPerms });
    alert('Permisos guardados');
    loadPermissions();
  } catch (err) {
    alert('Error: ' + err.message);
  }
}

// ======================== MODALS ========================

function openModal(id) {
  document.getElementById(id).classList.add('active');
}

function closeModal(id) {
  document.getElementById(id).classList.remove('active');
}

// Expose to inline onclick handlers
window.editUser = editUser;
window.deleteUser = deleteUser;
window.editGroup = editGroup;
window.deleteGroup = deleteGroup;
window.closeModal = closeModal;

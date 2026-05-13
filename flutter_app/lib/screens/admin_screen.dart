import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../services/api_service.dart';
import '../platform/platform_utils.dart';
import '../theme/app_theme.dart';

const _presetColors = [
  '#F44336', '#E91E63', '#9C27B0', '#673AB7',
  '#3F51B5', '#2196F3', '#00BCD4', '#009688',
  '#4CAF50', '#FF9800', '#FF5722', '#795548',
];

Color _hexToColor(String hex) {
  final h = hex.replaceAll('#', '');
  return Color(int.parse('FF$h', radix: 16));
}

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

enum UserSortMode { alphabetical, byColor, byGroup }

class _AdminScreenState extends State<AdminScreen> with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  List<dynamic> _users = [];
  List<dynamic> _groups = [];
  List<dynamic> _permissions = [];
  List<dynamic> _groupPermissions = [];
  Set<int> _onlineUserIds = {};
  UserSortMode _userSort = UserSortMode.alphabetical;
  String _userFilter = '';
  int? _permGroupFilter;

  // Server config state
  List<String> _announcedIps = [];
  final _turnHostCtrl = TextEditingController();
  final _turnPortCtrl = TextEditingController(text: '3478');
  final _turnUserCtrl = TextEditingController();
  final _turnPassCtrl = TextEditingController();
  final _publicDomainCtrl = TextEditingController();
  final _newIpCtrl = TextEditingController();
  bool _configLoading = false;
  bool _configSaving = false;
  // Last infra-sync error reported by the backend (empty = no error). The
  // backend persists this in `server_config.last_sync_error`; we display
  // it as a dismissable banner above the Settings tab.
  String _lastSyncError = '';

  ApiService get api => context.read<AuthProvider>().api;

  bool _isFullAdmin = true; // default, updated in didChangeDependencies
  bool _tabInitialized = false;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 6, vsync: this); // placeholder
    _tabCtrl.addListener(_onTabChanged);
    _loadAll();
    _loadServerConfig();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_tabInitialized) {
      _tabInitialized = true;
      final role = context.read<AuthProvider>().user?['role'];
      _isFullAdmin = role == 'admin';
      final tabCount = _isFullAdmin ? 6 : 4;
      if (_tabCtrl.length != tabCount) {
        _tabCtrl.removeListener(_onTabChanged);
        _tabCtrl.dispose();
        _tabCtrl = TabController(length: tabCount, vsync: this);
        _tabCtrl.addListener(_onTabChanged);
      }
    }
  }

  List<dynamic> _bridgeStatus = [];
  Timer? _bridgeRefreshTimer;

  void _onTabChanged() {
    // Auto-refresh bridge status when Bridges tab is selected
    // Bridges is tab 5 for admin, tab 3 for superuser
    final bridgesIdx = _isFullAdmin ? 5 : 3;
    if (_tabCtrl.index == bridgesIdx) {
      _loadBridgeStatus();
      _bridgeRefreshTimer?.cancel();
      _bridgeRefreshTimer = Timer.periodic(const Duration(seconds: 5), (_) => _loadBridgeStatus());
    } else {
      _bridgeRefreshTimer?.cancel();
    }
  }

  Future<void> _loadBridgeStatus() async {
    try {
      final status = await api.getBridgeStatus();
      if (mounted) setState(() => _bridgeStatus = status);
    } catch (_) {}
  }

  @override
  void dispose() {
    _bridgeRefreshTimer?.cancel();
    _tabCtrl.dispose();
    _turnHostCtrl.dispose();
    _turnPortCtrl.dispose();
    _turnUserCtrl.dispose();
    _turnPassCtrl.dispose();
    _publicDomainCtrl.dispose();
    _newIpCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadServerConfig() async {
    setState(() => _configLoading = true);
    try {
      final cfg = await api.getServerConfig();
      setState(() {
        _announcedIps = (cfg['announced_ips'] as String? ?? '')
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        _turnHostCtrl.text = cfg['turn_host'] ?? '';
        _turnPortCtrl.text = cfg['turn_port'] ?? '3478';
        _turnUserCtrl.text = cfg['turn_user'] ?? 'intercom';
        _turnPassCtrl.text = cfg['turn_password'] ?? '';
        _publicDomainCtrl.text = cfg['public_domain'] ?? '';
        _lastSyncError = (cfg['last_sync_error'] as String? ?? '').trim();
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error loading config: $e')));
    } finally {
      setState(() => _configLoading = false);
    }
  }

  Future<void> _saveServerConfig() async {
    setState(() => _configSaving = true);
    try {
      final result = await api.updateServerConfig({
        'announced_ips': _announcedIps.join(','),
        'turn_host': _turnHostCtrl.text.trim(),
        'turn_port': _turnPortCtrl.text.trim(),
        'turn_user': _turnUserCtrl.text.trim(),
        'turn_password': _turnPassCtrl.text,
        'public_domain': _publicDomainCtrl.text.trim(),
      });
      // Backend returns `sync: { coturn: 'queued'|'skipped', nginx: ... }`.
      // Build a human-friendly summary for the SnackBar.
      final sync = result['sync'] as Map<String, dynamic>?;
      final coturn = sync?['coturn'] ?? 'skipped';
      final nginx = sync?['nginx'] ?? 'skipped';
      final parts = <String>[];
      if (coturn == 'queued') parts.add('coturn');
      if (nginx == 'queued') parts.add('nginx');
      final tail = parts.isEmpty
          ? 'No infra changes were needed.'
          : 'Recreating: ${parts.join(', ')}.';
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Configuration saved. $tail'),
          backgroundColor: Colors.green,
        ),
      );
      // Refresh after a short delay so the user sees the new
      // last_sync_error if the background sync failed.
      Future<void>.delayed(const Duration(seconds: 4), () {
        if (mounted) _loadServerConfig();
      });
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      setState(() => _configSaving = false);
    }
  }

  Future<void> _dismissSyncError() async {
    try {
      await api.clearServerConfigSyncError();
      if (mounted) setState(() => _lastSyncError = '');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not clear: $e')),
      );
    }
  }

  Future<void> _loadAll() async {
    try {
      final results = await Future.wait([
        api.getUsers(),
        api.getGroups(),
        api.getPermissions(),
        api.getGroupPermissions(),
        api.getOnlineUserIds(),
      ]);
      setState(() {
        _users = results[0] as List;
        _groups = results[1] as List;
        _permissions = results[2] as List;
        _groupPermissions = results[3] as List;
        _onlineUserIds = (results[4] as List<int>).toSet();
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  // ======================== USERS TAB ========================

  List<dynamic> get _sortedNonAdminUsers =>
      _sortedUsers.where((u) => u['role'] != 'admin').toList();

  List<dynamic> get _sortedUsers {
    final list = List<dynamic>.from(_users);
    switch (_userSort) {
      case UserSortMode.alphabetical:
        list.sort((a, b) => ((a['display_name'] ?? a['username']) as String)
            .toLowerCase()
            .compareTo(((b['display_name'] ?? b['username']) as String).toLowerCase()));
        break;
      case UserSortMode.byColor:
        list.sort((a, b) {
          final ca = a['color'] as String? ?? '';
          final cb = b['color'] as String? ?? '';
          if (ca == cb) {
            return ((a['display_name'] ?? a['username']) as String)
                .toLowerCase()
                .compareTo(((b['display_name'] ?? b['username']) as String).toLowerCase());
          }
          if (ca.isEmpty) return 1;
          if (cb.isEmpty) return -1;
          return ca.compareTo(cb);
        });
        break;
      case UserSortMode.byGroup:
        // Sorting is handled in the rendering code (one user can appear in
        // several groups), so here we just default to alphabetical.
        list.sort((a, b) => ((a['display_name'] ?? a['username']) as String)
            .toLowerCase()
            .compareTo(((b['display_name'] ?? b['username']) as String).toLowerCase()));
        break;
    }
    return list;
  }

  /// Build a synthetic flat list of (groupName, user) entries used by the
  /// "Sort by group" mode. A user that belongs to N groups appears N times,
  /// once under each group header. Users with no group are placed under a
  /// trailing `(No group)` section so they don't get lost.
  List<_UserGroupEntry> _entriesByGroup(List<dynamic> users) {
    final groupedByName = <String, List<dynamic>>{};
    final orphans = <dynamic>[];
    for (final u in users) {
      final groups = (u['groups'] as List?) ?? const [];
      if (groups.isEmpty) {
        orphans.add(u);
      } else {
        for (final g in groups) {
          final name = (g['name'] ?? '').toString();
          groupedByName.putIfAbsent(name, () => <dynamic>[]).add(u);
        }
      }
    }
    final entries = <_UserGroupEntry>[];
    final sortedGroupNames = groupedByName.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    for (final gn in sortedGroupNames) {
      final list = groupedByName[gn]!
        ..sort((a, b) => ((a['display_name'] ?? a['username']) as String)
            .toLowerCase()
            .compareTo(((b['display_name'] ?? b['username']) as String).toLowerCase()));
      entries.add(_UserGroupEntry.header(gn, list.length));
      for (final u in list) {
        entries.add(_UserGroupEntry.user(u));
      }
    }
    if (orphans.isNotEmpty) {
      orphans.sort((a, b) => ((a['display_name'] ?? a['username']) as String)
          .toLowerCase()
          .compareTo(((b['display_name'] ?? b['username']) as String).toLowerCase()));
      entries.add(_UserGroupEntry.header('(No group)', orphans.length));
      for (final u in orphans) {
        entries.add(_UserGroupEntry.user(u));
      }
    }
    return entries;
  }

  Widget _buildUsersTab() {
    final filter = _userFilter.toLowerCase();
    final filteredUsers = _sortedUsers.where((u) {
      if (filter.isEmpty) return true;
      final name = ((u['display_name'] ?? '') as String).toLowerCase();
      final uname = ((u['username'] ?? '') as String).toLowerCase();
      return name.contains(filter) || uname.contains(filter);
    }).toList();

    return Column(
      children: [
        // Sticky toolbar
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: Row(
            children: [
              // Search field
              Expanded(
                child: SizedBox(
                  height: 38,
                  child: TextField(
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'Search...',
                      hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade500),
                      prefixIcon: const Icon(Icons.search, size: 18),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      suffixIcon: _userFilter.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.close, size: 16),
                              onPressed: () => setState(() => _userFilter = ''),
                            )
                          : null,
                    ),
                    onChanged: (v) => setState(() => _userFilter = v),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Sort buttons
              Container(
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.border),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _sortButton(Icons.sort_by_alpha, 'A-Z', UserSortMode.alphabetical),
                    Container(width: 1, height: 28, color: AppColors.border),
                    _sortButton(Icons.color_lens, 'Color', UserSortMode.byColor),
                    if (isWeb) ...[
                      Container(width: 1, height: 28, color: AppColors.border),
                      _sortButton(Icons.folder_outlined, 'Group', UserSortMode.byGroup),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Add user button (compact)
              SizedBox(
                height: 38,
                child: ElevatedButton.icon(
                  onPressed: _showCreateUserDialog,
                  icon: const Icon(Icons.person_add, size: 16),
                  label: const Text('Add', style: TextStyle(fontSize: 13)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
            ],
          ),
        ),
        // Compact user list — alphabetical/byColor uses a flat list, byGroup
        // (web-only) interleaves group headers and may repeat a user across
        // their groups.
        Expanded(
          child: _userSort == UserSortMode.byGroup && isWeb
              ? _buildUsersByGroup(filteredUsers)
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                  itemCount: filteredUsers.length,
                  itemBuilder: (context, i) =>
                      _buildUserRow(filteredUsers[i], i.isEven),
                ),
        ),
      ],
    );
  }

  // Fixed column widths so every row aligns vertically across the list.
  static const double _kColAvatarW = 38;       // avatar slot
  static const double _kColPrimaryW = 160;     // display_name (≈18 chars)
  static const double _kColLoginIdW = 130;     // username used for login (≈15 chars)
  static const double _kColFullNameW = 180;    // first + last name (≈20 chars)
  static const double _kColRoleW = 88;         // role badge column
  static const double _kColActionsWWeb = 220;  // 5 icon buttons
  static const double _kColActionsWNative = 132; // 3 icon buttons

  /// Render the user row used by both the flat list and the byGroup view.
  /// Responsive: when the row is wide enough (≥ 700 px) we render the
  /// fixed-column layout; on narrow screens (phones) we collapse to a
  /// two-line compact card so everything stays readable.
  /// The primary label uses `first_name` when set, falling back to
  /// `display_name`.
  Widget _buildUserRow(Map<String, dynamic> u, bool zebraEven, {String? hintGroup}) {
    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth < 700) {
        return _buildUserRowCompact(u, zebraEven);
      }
      return _buildUserRowWide(u, zebraEven, hintGroup: hintGroup);
    });
  }

  /// Narrow-screen layout (phones): two-line card so display name, login id,
  /// real name and the action icons all fit comfortably without horizontal
  /// scroll.
  Widget _buildUserRowCompact(Map<String, dynamic> u, bool zebraEven) {
    final isAdmin = u['role'] == 'admin';
    final userColor = u['color'] != null ? _hexToColor(u['color']) : null;
    final isOnline = _onlineUserIds.contains(u['id']);
    final firstName = (u['first_name'] as String?)?.trim() ?? '';
    final lastName = (u['last_name'] as String?)?.trim() ?? '';
    final displayName = (u['display_name'] as String?)?.trim() ?? '';
    final username = (u['username'] as String?) ?? '';
    final primary = displayName.isNotEmpty ? displayName : username;
    final fullName = ('$firstName $lastName').trim();

    return Container(
      margin: const EdgeInsets.only(bottom: 2),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: zebraEven ? AppColors.surface : AppColors.backgroundAlt,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Line 1: avatar + display name + role + edit/delete/kick
          Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 32, height: 32,
                    decoration: BoxDecoration(
                      color: (userColor ?? Colors.blue.shade600)
                          .withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      isAdmin ? Icons.admin_panel_settings : Icons.person,
                      color: userColor ??
                          (isAdmin ? Colors.orange.shade600 : Colors.blue.shade400),
                      size: 18,
                    ),
                  ),
                  if (isOnline)
                    Positioned(
                      right: -1, bottom: -1,
                      child: Container(
                        width: 11, height: 11,
                        decoration: BoxDecoration(
                          color: Colors.green,
                          shape: BoxShape.circle,
                          border: Border.all(color: AppColors.surface, width: 2),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  primary,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: isAdmin
                      ? Colors.orange.withValues(alpha: 0.15)
                      : Colors.blue.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  u['role'] ?? 'user',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: isAdmin
                        ? Colors.orange.shade300
                        : Colors.blue.shade300,
                  ),
                ),
              ),
              if (isOnline)
                _compactIcon(Icons.power_settings_new, Colors.orange.shade400,
                    'Disconnect',
                    () => _kickUser(u['id'], u['display_name'] ?? u['username'])),
              _compactIcon(Icons.edit, Colors.blue.shade400, 'Edit',
                  () => _showEditUserDialog(u)),
              _compactIcon(Icons.delete, Colors.red.shade400, 'Delete',
                  () => _deleteUser(u['id'])),
            ],
          ),
          // Line 2: User Id (monospace) + full real name
          Padding(
            padding: const EdgeInsets.only(left: 42, top: 2),
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    username,
                    style: TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      color: Colors.grey.shade400,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (fullName.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      '• $fullName',
                      style: TextStyle(
                          fontSize: 12, color: Colors.grey.shade500),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Wide-screen layout (web/tablet): everything in one row with fixed-width
  /// columns so rows align vertically.
  Widget _buildUserRowWide(Map<String, dynamic> u, bool zebraEven,
      {String? hintGroup}) {
    final isAdmin = u['role'] == 'admin';
    final userColor = u['color'] != null ? _hexToColor(u['color']) : null;
    final isOnline = _onlineUserIds.contains(u['id']);
    final groups = (u['groups'] as List?) ?? const [];
    final firstName = (u['first_name'] as String?)?.trim() ?? '';
    final lastName = (u['last_name'] as String?)?.trim() ?? '';
    final displayName = (u['display_name'] as String?)?.trim() ?? '';
    final username = (u['username'] as String?) ?? '';
    final primary = displayName.isNotEmpty ? displayName : username;
    final fullName = ('$firstName $lastName').trim();

    return Container(
      height: 44,
      margin: const EdgeInsets.only(bottom: 2),
      decoration: BoxDecoration(
        color: zebraEven ? AppColors.surface : AppColors.backgroundAlt,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          // ---- Avatar column ----
          SizedBox(
            width: _kColAvatarW,
            child: Center(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    width: 28, height: 28,
                    decoration: BoxDecoration(
                      color: (userColor ?? Colors.blue.shade600).withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      isAdmin ? Icons.admin_panel_settings : Icons.person,
                      color: userColor ??
                          (isAdmin ? Colors.orange.shade600 : Colors.blue.shade400),
                      size: 16,
                    ),
                  ),
                  if (isOnline)
                    Positioned(
                      right: -2, bottom: -2,
                      child: Container(
                        width: 12, height: 12,
                        decoration: BoxDecoration(
                          color: Colors.green,
                          shape: BoxShape.circle,
                          border: Border.all(color: AppColors.surface, width: 2),
                          boxShadow: [
                            BoxShadow(
                                color: Colors.green.withValues(alpha: 0.5),
                                blurRadius: 4),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          // ---- Display name column ----
          SizedBox(
            width: _kColPrimaryW,
            child: Text(
              primary,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // ---- User Id column — login username (used to authenticate) ----
          SizedBox(
            width: _kColLoginIdW,
            child: Text(
              username,
              style: TextStyle(
                fontSize: 13,
                fontFamily: 'monospace',
                color: Colors.grey.shade400,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // ---- Real name column — first_name + last_name ----
          SizedBox(
            width: _kColFullNameW,
            child: Text(
              fullName,
              style: TextStyle(fontSize: 14, color: Colors.grey.shade500),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // ---- Role column ----
          SizedBox(
            width: _kColRoleW,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: isAdmin
                      ? Colors.orange.withValues(alpha: 0.15)
                      : Colors.blue.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  u['role'] ?? 'user',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: isAdmin
                        ? Colors.orange.shade300
                        : Colors.blue.shade300,
                  ),
                ),
              ),
            ),
          ),
          // ---- Actions column (fixed width so chips line up everywhere) ----
          SizedBox(
            width: isWeb ? _kColActionsWWeb : _kColActionsWNative,
            child: Row(
              children: [
                if (isWeb)
                  _compactIcon(Icons.group_add, Colors.purple.shade300,
                      'Manage groups', () => _showGroupPickerSheet(u)),
                if (isWeb)
                  _compactIcon(Icons.share, Colors.teal.shade300,
                      'Send invite', () => _showShareSheet(u)),
                _compactIcon(
                  Icons.power_settings_new,
                  isOnline ? Colors.orange.shade400 : Colors.grey.shade700,
                  isOnline ? 'Disconnect' : 'Offline',
                  isOnline
                      ? () => _kickUser(
                          u['id'], u['display_name'] ?? u['username'])
                      : () {},
                ),
                _compactIcon(Icons.edit, Colors.blue.shade400, 'Edit',
                    () => _showEditUserDialog(u)),
                _compactIcon(Icons.delete, Colors.red.shade400, 'Delete',
                    () => _deleteUser(u['id'])),
              ],
            ),
          ),
          // ---- Group chips (web only): take whatever space is left ----
          if (isWeb)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: ClipRect(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: groups.map<Widget>((g) {
                        final isHint =
                            hintGroup != null && g['name'] == hintGroup;
                        return Container(
                          margin: const EdgeInsets.only(right: 4),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: isHint
                                ? Colors.teal.withValues(alpha: 0.25)
                                : Colors.grey.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: isHint
                                  ? Colors.teal.shade400
                                  : Colors.grey.withValues(alpha: 0.25),
                              width: 0.5,
                            ),
                          ),
                          child: Text(
                            g['name'] ?? '',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: isHint
                                  ? Colors.teal.shade200
                                  : Colors.grey.shade400,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ),
            )
          else
            const Spacer(),
        ],
      ),
    );
  }

  /// Render the byGroup list — inserts a section header for every group and
  /// repeats a user under every group they belong to.
  Widget _buildUsersByGroup(List<dynamic> users) {
    final entries = _entriesByGroup(users);
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      itemCount: entries.length,
      itemBuilder: (context, i) {
        final e = entries[i];
        if (e.isHeader) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
            child: Row(
              children: [
                Icon(Icons.folder_open, size: 16, color: Colors.teal.shade300),
                const SizedBox(width: 6),
                Text(
                  '${e.groupName}  (${e.count})',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Colors.teal.shade200,
                    letterSpacing: 0.4,
                  ),
                ),
              ],
            ),
          );
        }
        // Find the most recent header to highlight chip in the row.
        String? hint;
        for (int j = i - 1; j >= 0; j--) {
          if (entries[j].isHeader) {
            hint = entries[j].groupName;
            break;
          }
        }
        return _buildUserRow(
            e.user!, i.isEven, hintGroup: hint == '(No group)' ? null : hint);
      },
    );
  }

  /// BottomSheet with a CheckboxListTile per group; toggling instantly
  /// calls the addGroupMember/removeGroupMember endpoints and refreshes the
  /// local copy. Web-only.
  Future<void> _showGroupPickerSheet(Map<String, dynamic> user) async {
    if (_groups.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('No groups defined yet'),
      ));
      return;
    }
    final memberOf = <int>{
      for (final g in (user['groups'] as List? ?? const []))
        (g['id'] as num).toInt(),
    };
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setSt) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 40,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: AppColors.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Text(
                  'Manage groups for ${user['display_name'] ?? user['username']}',
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 360),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: _groups.length,
                    itemBuilder: (_, i) {
                      final g = _groups[i];
                      final gid = g['id'] as int;
                      final checked = memberOf.contains(gid);
                      return CheckboxListTile(
                        dense: true,
                        title: Text(g['name'] ?? ''),
                        value: checked,
                        onChanged: (v) async {
                          try {
                            if (v == true) {
                              await api.addGroupMember(gid, user['id']);
                              memberOf.add(gid);
                            } else {
                              await api.removeGroupMember(gid, user['id']);
                              memberOf.remove(gid);
                            }
                            setSt(() {});
                            // Refresh master state so chips update behind
                            // the sheet too.
                            _loadAll();
                          } catch (e) {
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Error: $e')),
                              );
                            }
                          }
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          );
        });
      },
    );
  }

  /// Compose the boilerplate text that ships with every invite.
  String _buildInviteText(Map<String, dynamic> user) {
    final base = api.baseUrl;
    final name = user['display_name'] ?? user['username'] ?? 'there';
    return 'Hi $name,\n\n'
        "You've been added to Winus Intercom.\n"
        'Server: $base\n'
        'Username: ${user['username']}\n'
        'Download (Android): $base/intercom.apk\n';
  }

  /// BottomSheet that lets the admin send the invite by email, WhatsApp or
  /// just copy the text to the clipboard. Web-only.
  Future<void> _showShareSheet(Map<String, dynamic> user) async {
    final email = (user['email'] as String?)?.trim() ?? '';
    final phone = (user['phone'] as String?)?.trim() ?? '';
    final body = _buildInviteText(user);
    final subject = 'Winus Intercom invitation';

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: AppColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Text(
              'Send invite to ${user['display_name'] ?? user['username']}',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: const Icon(Icons.email_outlined, color: Colors.amber),
              title: const Text('Send by email'),
              subtitle: Text(email.isEmpty ? '(no email on file)' : email,
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 12)),
              enabled: email.isNotEmpty,
              onTap: email.isEmpty
                  ? null
                  : () {
                      final url = 'mailto:${Uri.encodeComponent(email)}'
                          '?subject=${Uri.encodeQueryComponent(subject)}'
                          '&body=${Uri.encodeQueryComponent(body)}';
                      platformOpenUrl(url);
                      Navigator.pop(ctx);
                    },
            ),
            ListTile(
              leading: const Icon(Icons.chat, color: Colors.green),
              title: const Text('Send via WhatsApp'),
              subtitle: Text(phone.isEmpty ? '(no phone on file)' : phone,
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 12)),
              enabled: phone.isNotEmpty,
              onTap: phone.isEmpty
                  ? null
                  : () {
                      // wa.me requires digits only (no +/spaces).
                      final cleaned = phone.replaceAll(RegExp(r'[^0-9]'), '');
                      final url = 'https://wa.me/$cleaned'
                          '?text=${Uri.encodeQueryComponent(body)}';
                      platformOpenUrl(url);
                      Navigator.pop(ctx);
                    },
            ),
            ListTile(
              leading: const Icon(Icons.copy, color: Colors.blueAccent),
              title: const Text('Copy invite text'),
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: body));
                if (context.mounted) {
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('Invite copied to clipboard'),
                  ));
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _compactIcon(IconData icon, Color color, String tooltip, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, size: 22, color: color),
        ),
      ),
    );
  }

  Widget _sortButton(IconData icon, String label, UserSortMode mode) {
    final active = _userSort == mode;
    return InkWell(
      onTap: () => setState(() => _userSort = mode),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: active ? Colors.blue.shade50 : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: active ? Colors.blue.shade700 : Colors.grey.shade500),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(
              fontSize: 11,
              fontWeight: active ? FontWeight.bold : FontWeight.normal,
              color: active ? Colors.blue.shade700 : Colors.grey.shade600,
            )),
          ],
        ),
      ),
    );
  }

  Widget _buildColorPicker(String selectedColor, void Function(String) onSelect) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Color', style: TextStyle(fontSize: 12, color: Colors.grey)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _presetColors.map((hex) {
            final isSelected = selectedColor == hex;
            return GestureDetector(
              onTap: () => onSelect(hex),
              child: Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: _hexToColor(hex),
                  shape: BoxShape.circle,
                  border: isSelected
                      ? Border.all(color: Colors.black87, width: 3)
                      : Border.all(color: Colors.grey.shade300, width: 1),
                ),
                child: isSelected
                    ? const Icon(Icons.check, size: 16, color: Colors.white)
                    : null,
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  Future<void> _showCreateUserDialog() async {
    final nameCtrl = TextEditingController();
    final userCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    final firstCtrl = TextEditingController();
    final lastCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    String selectedColor = '#2196F3';
    String selectedRole = 'user';

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('New User'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Display name')),
                TextField(controller: userCtrl, decoration: const InputDecoration(labelText: 'Username')),
                TextField(controller: passCtrl, decoration: const InputDecoration(labelText: 'Password'), obscureText: true),
                if (isWeb) ...[
                  const SizedBox(height: 8),
                  TextField(controller: firstCtrl, decoration: const InputDecoration(labelText: 'First name (optional)')),
                  TextField(controller: lastCtrl, decoration: const InputDecoration(labelText: 'Last name (optional)')),
                  TextField(
                    controller: emailCtrl,
                    decoration: const InputDecoration(labelText: 'Email (optional)'),
                    keyboardType: TextInputType.emailAddress,
                  ),
                  TextField(
                    controller: phoneCtrl,
                    decoration: const InputDecoration(
                        labelText: 'Phone (optional, for WhatsApp invite)'),
                    keyboardType: TextInputType.phone,
                  ),
                ],
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: selectedRole,
                  decoration: const InputDecoration(labelText: 'Role'),
                  items: const [
                    DropdownMenuItem(value: 'user', child: Text('User')),
                    DropdownMenuItem(value: 'admin', child: Text('Admin')),
                    DropdownMenuItem(value: 'superuser', child: Text('Super User (Bridge)')),
                    DropdownMenuItem(value: 'bridge', child: Text('Bridge')),
                  ],
                  onChanged: (v) => setDialogState(() => selectedRole = v!),
                ),
                const SizedBox(height: 12),
                _buildColorPicker(selectedColor, (hex) => setDialogState(() => selectedColor = hex)),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Create')),
          ],
        ),
      ),
    );

    if (result == true) {
      final body = <String, dynamic>{
        'display_name': nameCtrl.text,
        'username': userCtrl.text,
        'password': passCtrl.text,
        'role': selectedRole,
        'color': selectedColor,
      };
      if (isWeb) {
        body['first_name'] = firstCtrl.text;
        body['last_name'] = lastCtrl.text;
        body['email'] = emailCtrl.text;
        body['phone'] = phoneCtrl.text;
      }
      await api.createUser(body);
      _loadAll();
    }
  }

  Future<void> _showEditUserDialog(Map<String, dynamic> user) async {
    final nameCtrl = TextEditingController(text: user['display_name']);
    final passCtrl = TextEditingController();
    final firstCtrl = TextEditingController(text: user['first_name'] ?? '');
    final lastCtrl = TextEditingController(text: user['last_name'] ?? '');
    final emailCtrl = TextEditingController(text: user['email'] ?? '');
    final phoneCtrl = TextEditingController(text: user['phone'] ?? '');
    final usernameCtrl = TextEditingController(text: user['username'] ?? '');
    String selectedColor = user['color'] ?? '#2196F3';
    String selectedRole = user['role'] ?? 'user';
    final isSuperadmin = context.read<AuthProvider>().user?['role'] == 'superadmin';

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('Editar ${user['username']}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Username (User Id): read-only for everyone except the
                // hidden superadmin (Winus), who can rename it.
                TextField(
                  enabled: isSuperadmin,
                  controller: usernameCtrl,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                  decoration: InputDecoration(
                    labelText: isSuperadmin
                        ? 'User Id (login — superadmin can rename)'
                        : 'User Id (login — cannot be changed)',
                  ),
                ),
                if (isSuperadmin)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: const Icon(Icons.tag, size: 16),
                      label: Text(
                          'Change numeric ID (current: ${user['id']})',
                          style: const TextStyle(fontSize: 12)),
                      onPressed: () => _showChangeIdDialog(user),
                    ),
                  ),
                const SizedBox(height: 6),
                TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Display name')),
                TextField(
                  controller: passCtrl,
                  decoration: const InputDecoration(labelText: 'Password (empty = no change)'),
                  obscureText: true,
                ),
                if (isWeb) ...[
                  const SizedBox(height: 8),
                  TextField(controller: firstCtrl, decoration: const InputDecoration(labelText: 'First name (optional)')),
                  TextField(controller: lastCtrl, decoration: const InputDecoration(labelText: 'Last name (optional)')),
                  TextField(
                    controller: emailCtrl,
                    decoration: const InputDecoration(labelText: 'Email (optional)'),
                    keyboardType: TextInputType.emailAddress,
                  ),
                  TextField(
                    controller: phoneCtrl,
                    decoration: const InputDecoration(
                        labelText: 'Phone (optional, for WhatsApp invite)'),
                    keyboardType: TextInputType.phone,
                  ),
                ],
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: selectedRole,
                  decoration: const InputDecoration(labelText: 'Role'),
                  items: const [
                    DropdownMenuItem(value: 'user', child: Text('User')),
                    DropdownMenuItem(value: 'admin', child: Text('Admin')),
                    DropdownMenuItem(value: 'superuser', child: Text('Super User (Bridge)')),
                    DropdownMenuItem(value: 'bridge', child: Text('Bridge')),
                  ],
                  onChanged: (v) => setDialogState(() => selectedRole = v!),
                ),
                const SizedBox(height: 12),
                _buildColorPicker(selectedColor, (hex) => setDialogState(() => selectedColor = hex)),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
          ],
        ),
      ),
    );

    if (result == true) {
      final data = <String, dynamic>{
        'display_name': nameCtrl.text,
        'role': selectedRole,
        'color': selectedColor,
      };
      if (passCtrl.text.isNotEmpty) data['password'] = passCtrl.text;
      if (isWeb) {
        data['first_name'] = firstCtrl.text;
        data['last_name'] = lastCtrl.text;
        data['email'] = emailCtrl.text;
        data['phone'] = phoneCtrl.text;
      }
      try {
        await api.updateUser(user['id'], data);
        // Superadmin: if username changed, push it through the dedicated
        // endpoint after the regular update so other admins see the change.
        if (isSuperadmin) {
          final newUsername = usernameCtrl.text.trim();
          if (newUsername.isNotEmpty &&
              newUsername != (user['username'] ?? '')) {
            await api.updateUserUsername(user['id'], newUsername);
          }
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Error: $e')));
        }
      }
      _loadAll();
    }
  }

  /// Show a confirmation dialog to change the numeric id of a user.
  /// Superadmin only — calls the dedicated /change-id endpoint that
  /// cascades the new id through every FK-reference table on the server.
  Future<void> _showChangeIdDialog(Map<String, dynamic> user) async {
    final ctrl = TextEditingController(text: '${user['id']}');
    final newId = await showDialog<int?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Change numeric ID of ${user['username']}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This will rewrite the user id and cascade it through '
              'permissions, group memberships and device tokens. Use with care.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'New numeric ID'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(
                ctx, int.tryParse(ctrl.text.trim())),
            child: const Text('Change'),
          ),
        ],
      ),
    );
    if (newId == null) return;
    try {
      await api.changeUserId(user['id'] as int, newId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('ID changed to $newId')),
        );
      }
      _loadAll();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Future<void> _kickUser(int id, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Disconnect $name?'),
        content: const Text('This will force-close the user\'s connection.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (ok == true) {
      try {
        await api.kickUser(id);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$name disconnected')));
        _loadAll();
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
  }

  Future<void> _deleteUser(int id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete user?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await api.deleteUser(id);
      _loadAll();
    }
  }

  // ======================== GROUPS TAB ========================

  Widget _buildGroupsTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _showCreateGroupDialog,
            icon: const Icon(Icons.group_add),
            label: const Text('New Group'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue.shade700,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ),
        const SizedBox(height: 16),
        ..._groups.map((g) {
          final members = g['members'] as List? ?? [];
          return Card(
            elevation: 1,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            margin: const EdgeInsets.only(bottom: 8),
            child: ExpansionTile(
              leading: CircleAvatar(
                backgroundColor: Colors.teal.shade50,
                child: Icon(Icons.group, color: Colors.teal.shade600, size: 20),
              ),
              title: Text(g['name'], style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text('${members.length} members',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: Icon(Icons.person_add, size: 20, color: Colors.green.shade400),
                    tooltip: 'Add member',
                    onPressed: () => _showAddMemberDialog(g),
                  ),
                  IconButton(
                    icon: Icon(Icons.edit, size: 20, color: Colors.blue.shade400),
                    tooltip: 'Edit group',
                    onPressed: () => _showEditGroupDialog(g),
                  ),
                  IconButton(
                    icon: Icon(Icons.delete, size: 20, color: Colors.red.shade300),
                    tooltip: 'Delete group',
                    onPressed: () => _deleteGroup(g['id']),
                  ),
                ],
              ),
              children: members.map<Widget>((m) => ListTile(
                    leading: Icon(Icons.person_outline, size: 18, color: Colors.grey.shade500),
                    title: Text(m['display_name'] ?? 'User ${m['id']}'),
                    trailing: IconButton(
                      icon: const Icon(Icons.remove_circle, color: Colors.red, size: 20),
                      onPressed: () async {
                        await api.removeGroupMember(g['id'], m['id']);
                        _loadAll();
                      },
                    ),
                  )).toList(),
            ),
          );
        }),
      ],
    );
  }

  Future<void> _showCreateGroupDialog() async {
    final nameCtrl = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Group'),
        content: TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Create')),
        ],
      ),
    );
    if (result == true) {
      await api.createGroup({'name': nameCtrl.text});
      _loadAll();
    }
  }

  Future<void> _showEditGroupDialog(Map<String, dynamic> group) async {
    final nameCtrl = TextEditingController(text: group['name']);

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Edit group'),
        content: TextField(
          controller: nameCtrl,
          decoration: const InputDecoration(labelText: 'Group name'),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );

    if (result == true && nameCtrl.text.isNotEmpty) {
      await api.updateGroup(group['id'], {'name': nameCtrl.text});
      _loadAll();
    }
  }

  Future<void> _showAddMemberDialog(Map<String, dynamic> group) async {
    final members = (group['members'] as List? ?? []).map((m) => m['id']).toSet();
    final available = _users.where((u) => !members.contains(u['id'])).toList();

    if (available.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Todos los usuarios ya son members')));
      return;
    }

    final userId = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Add to ${group['name']}'),
        children: available
            .map((u) => SimpleDialogOption(
                  onPressed: () => Navigator.pop(ctx, u['id']),
                  child: Text(u['display_name'] ?? u['username']),
                ))
            .toList(),
      ),
    );

    if (userId != null) {
      // Backend now handles the bidirectional permission matrix and the
      // group_permissions row in a single transaction. The frontend just
      // adds the membership and refreshes.
      await api.addGroupMember(group['id'], userId);
      _loadAll();
    }
  }

  Future<void> _deleteGroup(int id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete group?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await api.deleteGroup(id);
      _loadAll();
    }
  }

  // ======================== PERMISSIONS TAB ========================

  Widget _buildPermissionsTab() {
    final allNonAdmin = _sortedNonAdminUsers;
    // Apply group filter
    final List<dynamic> nonAdminUsers;
    if (_permGroupFilter != null) {
      final group = _groups.firstWhere((g) => g['id'] == _permGroupFilter, orElse: () => null);
      if (group != null) {
        final memberIds = (group['members'] as List? ?? []).map((m) => m['id']).toSet();
        nonAdminUsers = allNonAdmin.where((u) => memberIds.contains(u['id'])).toList();
      } else {
        nonAdminUsers = allNonAdmin;
        _permGroupFilter = null;
      }
    } else {
      nonAdminUsers = allNonAdmin;
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Sort + filter controls
        Row(
          children: [
            // Group filter
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<int?>(
                    value: _permGroupFilter,
                    isExpanded: true,
                    icon: Icon(Icons.filter_list, color: _permGroupFilter != null ? Colors.blue.shade700 : Colors.grey),
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
                    hint: const Text('All users', style: TextStyle(fontSize: 13)),
                    items: [
                      const DropdownMenuItem<int?>(value: null, child: Text('All users')),
                      ..._groups.map((g) => DropdownMenuItem<int?>(value: g['id'], child: Text(g['name']))),
                    ],
                    onChanged: (val) => setState(() => _permGroupFilter = val),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Sort buttons
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _sortButton(Icons.sort_by_alpha, 'A-Z', UserSortMode.alphabetical),
                  Container(width: 1, height: 30, color: Colors.grey.shade300),
                  _sortButton(Icons.color_lens, 'Color', UserSortMode.byColor),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        // User → User matrix
        Row(
          children: [
            Icon(Icons.mic, size: 20, color: Colors.blue.shade700),
            const SizedBox(width: 8),
            const Text('Who can TALK to whom',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        Text('Row → Column: check = row user can talk to column user',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
        const SizedBox(height: 12),
        if (nonAdminUsers.length < 2)
          _emptyCard('At least 2 users required')
        else
          _buildMatrix(
            rowItems: nonAdminUsers,
            colItems: nonAdminUsers,
            rowLabel: (u) => u['display_name'] ?? u['username'],
            colLabel: (u) => u['display_name'] ?? u['username'],
            isChecked: (from, to) => _permissions.any(
              (p) => p['from_user_id'] == from['id'] && p['to_user_id'] == to['id'] && p['can_talk'] == 1,
            ),
            onToggle: (from, to, val) async {
              await api.setPermission(from['id'], to['id'], val);
              _loadAll();
            },
            isSame: (a, b) => a['id'] == b['id'],
          ),

        const SizedBox(height: 28),

        // User → Group matrix
        Row(
          children: [
            Icon(Icons.campaign, size: 20, color: Colors.teal.shade700),
            const SizedBox(width: 8),
            const Text('Who can TALK to group',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ],
        ),
        Text('Row → Column: check = user can talk to group (and listen)',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
        const SizedBox(height: 12),
        if (nonAdminUsers.isEmpty || _groups.isEmpty)
          _emptyCard('Users and groups required')
        else
          _buildMatrix(
            rowItems: nonAdminUsers,
            colItems: _groups,
            rowLabel: (u) => u['display_name'] ?? u['username'],
            colLabel: (g) => g['name'],
            isChecked: (user, group) => _groupPermissions.any(
              (p) => p['from_user_id'] == user['id'] && p['to_group_id'] == group['id'] && p['can_talk'] == 1,
            ),
            onToggle: (user, group, val) async {
              await api.setGroupPermission(user['id'], group['id'], val);
              _loadAll();
            },
          ),
      ],
    );
  }

  // Dante Controller style colors
  static const _danteBackground = Color(0xFF1A1A2E);
  static const _danteSurface = Color(0xFF16213E);
  static const _danteHeader = Color(0xFF0F3460);
  static const _danteBorder = Color(0xFF233554);
  static const _danteTeal = Color(0xFF00B8A9);
  static const _danteTealDark = Color(0xFF008C7E);
  static const _danteTextDim = Color(0xFF6B7B8D);
  static const _danteTextLight = Color(0xFFAABBCC);

  Widget _buildMatrix({
    required List<dynamic> rowItems,
    required List<dynamic> colItems,
    required String Function(dynamic) rowLabel,
    required String Function(dynamic) colLabel,
    required bool Function(dynamic row, dynamic col) isChecked,
    required Future<void> Function(dynamic row, dynamic col, bool newVal) onToggle,
    bool Function(dynamic a, dynamic b)? isSame,
  }) {
    return _DanteMatrix(
      rowItems: rowItems,
      colItems: colItems,
      rowLabel: rowLabel,
      colLabel: colLabel,
      isChecked: isChecked,
      onToggle: onToggle,
      isSame: isSame,
    );
  }

  Widget _emptyCard(String text) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _danteBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _danteBorder),
      ),
      child: Text(text, style: const TextStyle(color: _danteTextDim), textAlign: TextAlign.center),
    );
  }

  // ======================== BRIDGES TAB ========================

  Widget _buildBridgesTab() {
    if (_bridgeStatus.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.cable, size: 48, color: Colors.grey.shade600),
            const SizedBox(height: 16),
            Text('No bridge users configured', style: TextStyle(color: Colors.grey.shade500)),
            const SizedBox(height: 8),
            Text('Create users with role "Bridge" in the Users tab',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _loadBridgeStatus,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Refresh'),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadBridgeStatus,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _bridgeStatus.length,
        itemBuilder: (context, i) {
          final b = _bridgeStatus[i];
          final online = b['online'] == true;
          final hasProducer = b['hasProducer'] == true;
          final producerPaused = b['producerPaused'] == true;
          final consumerCount = b['consumerCount'] as int? ?? 0;
          final hasSend = b['hasSendTransport'] == true;
          final hasRecv = b['hasRecvTransport'] == true;
          final pttTargets = (b['pttTargets'] as List?) ?? [];
          final isTalking = pttTargets.isNotEmpty;

          return Card(
            color: AppColors.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            margin: const EdgeInsets.only(bottom: 10),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Header row: name + LED + kick
                  Row(
                    children: [
                      // Big online LED
                      Container(
                        width: 18, height: 18,
                        decoration: BoxDecoration(
                          color: online ? Colors.green : Colors.grey.shade700,
                          shape: BoxShape.circle,
                          boxShadow: online
                              ? [BoxShadow(color: Colors.green.withValues(alpha: 0.6), blurRadius: 8, spreadRadius: 1)]
                              : null,
                        ),
                      ),
                      const SizedBox(width: 12),
                      // Name
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(b['display_name'] ?? b['username'],
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                            Text(b['username'] ?? '',
                                style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                          ],
                        ),
                      ),
                      // Status badge
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: online
                              ? (isTalking ? Colors.teal.withValues(alpha: 0.2) : Colors.green.withValues(alpha: 0.15))
                              : Colors.grey.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          online ? (isTalking ? 'TALKING' : 'ONLINE') : 'OFFLINE',
                          style: TextStyle(
                            fontSize: 11, fontWeight: FontWeight.bold,
                            color: online
                                ? (isTalking ? Colors.teal.shade300 : Colors.green.shade300)
                                : Colors.grey.shade500,
                          ),
                        ),
                      ),
                      if (online) ...[
                        const SizedBox(width: 8),
                        IconButton(
                          icon: Icon(Icons.power_settings_new, color: Colors.orange.shade400, size: 20),
                          tooltip: 'Disconnect bridge',
                          onPressed: () => _kickUser(b['id'], b['display_name'] ?? b['username']),
                        ),
                      ],
                    ],
                  ),
                  if (online) ...[
                    const SizedBox(height: 12),
                    // Transport + media indicators
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        _bridgeChip('SEND', hasSend, Icons.upload),
                        _bridgeChip('RECV', hasRecv, Icons.download),
                        _bridgeChip('PRODUCER', hasProducer, Icons.mic,
                            detail: hasProducer ? (producerPaused ? 'paused' : 'active') : null,
                            active2: hasProducer && !producerPaused),
                        _bridgeChip('CONSUMERS', consumerCount > 0, Icons.headphones,
                            detail: '$consumerCount'),
                      ],
                    ),
                    if (pttTargets.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      // PTT targets
                      ...pttTargets.map((t) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Row(
                          children: [
                            Icon(
                              t['type'] == 'group' ? Icons.group : Icons.person,
                              size: 16, color: Colors.teal.shade300,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${t['name']}',
                              style: const TextStyle(fontSize: 13),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '(${t['listeners']} listener${(t['listeners'] as int) != 1 ? 's' : ''})',
                              style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                            ),
                          ],
                        ),
                      )),
                    ],
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _bridgeChip(String label, bool active, IconData icon, {String? detail, bool? active2}) {
    final isActive = active2 ?? active;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isActive ? Colors.teal.withValues(alpha: 0.15) : AppColors.backgroundAlt,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isActive ? Colors.teal.withValues(alpha: 0.4) : AppColors.border,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: isActive ? Colors.teal.shade300 : Colors.grey.shade600),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(
            fontSize: 10, fontWeight: FontWeight.bold,
            color: isActive ? Colors.teal.shade200 : Colors.grey.shade500,
          )),
          if (detail != null) ...[
            const SizedBox(width: 4),
            Text(detail, style: TextStyle(
              fontSize: 10, color: isActive ? Colors.teal.shade400 : Colors.grey.shade600,
            )),
          ],
        ],
      ),
    );
  }

  // ======================== BUILD ========================

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: AppColors.backgroundAlt,
        foregroundColor: AppColors.textPrimary,
        title: const Row(
          children: [
            Icon(Icons.admin_panel_settings, size: 22),
            SizedBox(width: 8),
            Text('Administration'),
          ],
        ),
        bottom: TabBar(
          controller: _tabCtrl,
          indicatorColor: Colors.white,
          indicatorWeight: 3,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          isScrollable: true,
          tabs: [
            const Tab(icon: Icon(Icons.person, size: 18), text: 'Users'),
            const Tab(icon: Icon(Icons.group, size: 18), text: 'Groups'),
            const Tab(icon: Icon(Icons.security, size: 18), text: 'Permissions'),
            if (_isFullAdmin) const Tab(icon: Icon(Icons.settings, size: 18), text: 'Settings'),
            if (_isFullAdmin) const Tab(icon: Icon(Icons.download, size: 18), text: 'Downloads'),
            const Tab(icon: Icon(Icons.cable, size: 18), text: 'Bridges'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabCtrl,
        children: [
          _buildUsersTab(),
          _buildGroupsTab(),
          _buildPermissionsTab(),
          if (_isFullAdmin) _buildSettingsTab(),
          if (_isFullAdmin) _buildDownloadsTab(),
          _buildBridgesTab(),
        ],
      ),
    );
  }

  // ======================== SETTINGS TAB ========================

  Widget _buildSettingsTab() {
    if (_configLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // ---- Last sync error banner (only when present) ----
        if (_lastSyncError.isNotEmpty) _syncErrorBanner(),
        // ---- Announced IPs ----
        _settingsSection(
          icon: Icons.router,
          title: 'WebRTC Announced IPs',
          subtitle: 'ICE candidates sent to clients. Add all IPs clients may use to reach this server.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_announcedIps.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text('No IPs configured', style: TextStyle(color: Colors.grey.shade400, fontSize: 13)),
                ),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: _announcedIps.map((ip) => Chip(
                  label: Text(ip, style: const TextStyle(fontSize: 13)),
                  deleteIcon: const Icon(Icons.close, size: 16),
                  onDeleted: () => setState(() => _announcedIps.remove(ip)),
                  backgroundColor: Colors.blue.shade50,
                  side: BorderSide(color: Colors.blue.shade200),
                )).toList(),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _newIpCtrl,
                      decoration: InputDecoration(
                        hintText: 'e.g. 88.12.80.169 or 10.0.0.21',
                        hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade400),
                        isDense: true,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                      onSubmitted: (_) => _addIp(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _addIp,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue.shade700,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('Add'),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Tip: public IP (for internet), WireGuard IP (for VPN), LAN IP (for local network)',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // ---- TURN Server ----
        _settingsSection(
          icon: Icons.swap_horiz,
          title: 'TURN Server',
          subtitle: 'Relay server for clients behind strict NAT. Leave Turn Host empty to use the first announced IP.',
          child: Column(
            children: [
              _settingsField(
                controller: _turnHostCtrl,
                label: 'TURN Host',
                hint: 'Leave empty to use first announced IP',
              ),
              const SizedBox(height: 10),
              _settingsField(
                controller: _turnPortCtrl,
                label: 'TURN Port',
                hint: '3478',
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 10),
              _settingsField(
                controller: _turnUserCtrl,
                label: 'TURN Username',
                hint: 'intercom',
              ),
              const SizedBox(height: 10),
              _settingsField(
                controller: _turnPassCtrl,
                label: 'TURN Password',
                hint: '••••••••',
                obscureText: true,
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // ---- Public domain ----
        _settingsSection(
          icon: Icons.language,
          title: 'Public Domain (TLS)',
          subtitle:
              'Optional DNS name to embed in the self-signed certificate '
              '(e.g. winus.overon.es). Saving rebuilds the cert and recreates nginx.',
          child: _settingsField(
            controller: _publicDomainCtrl,
            label: 'Public domain',
            hint: 'leave empty if you only use IPs',
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            'Saving rewrites .env (EXTERNAL_IP / LOCAL_IP / MEDIASOUP_ANNOUNCED_IPS) '
            'and recreates the coturn / nginx containers automatically.',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _configSaving ? null : _saveServerConfig,
            icon: _configSaving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save),
            label: Text(_configSaving ? 'Saving...' : 'Save Configuration'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green.shade600,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ),
        const SizedBox(height: 24),
        // ---- Backup / Restore ----
        _settingsSection(
          icon: Icons.backup,
          title: 'Backup & Restore',
          subtitle: 'Export or import full configuration (users, groups, permissions)',
          child: Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _exportConfig,
                  icon: const Icon(Icons.download, size: 18),
                  label: const Text('Export'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _importConfig,
                  icon: const Icon(Icons.upload, size: 18),
                  label: const Text('Import'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _exportConfig() async {
    final nameCtrl = TextEditingController(
      text: 'winus-config-${DateTime.now().toString().substring(0, 10)}',
    );
    final filename = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Export Configuration'),
        content: TextField(
          controller: nameCtrl,
          decoration: const InputDecoration(
            labelText: 'Filename',
            suffixText: '.txt',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, nameCtrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (filename == null || filename.isEmpty) return;

    try {
      final data = await api.exportConfig();
      final jsonStr = const JsonEncoder.withIndent('  ').convert(data);
      final finalName = filename.endsWith('.txt') ? filename : '$filename.txt';

      if (isWeb) {
        // Web: trigger browser download
        platformDownloadFile(finalName, jsonStr);
        await Clipboard.setData(ClipboardData(text: jsonStr));
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Downloaded $finalName'), backgroundColor: Colors.green),
          );
        }
      } else {
        // Native: save to Downloads folder
        final path = await platformSaveTextFile(finalName, jsonStr);
        if (mounted) {
          if (path != null) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Saved to $path'), backgroundColor: Colors.green, duration: const Duration(seconds: 4)),
            );
          } else {
            // Fallback: copy to clipboard
            await Clipboard.setData(ClipboardData(text: jsonStr));
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Could not save file. Copied to clipboard instead.'), backgroundColor: Colors.orange),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Export error: $e')));
    }
  }

  Future<void> _importConfig() async {
    String? jsonText;

    if (!isWeb) {
      // Native: ask for filename in Downloads folder
      final pathCtrl = TextEditingController(text: '/sdcard/Download/winus-config-');
      final path = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Import Configuration'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Enter the path to the .txt config file:', style: TextStyle(fontSize: 13)),
              const SizedBox(height: 12),
              TextField(
                controller: pathCtrl,
                style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  labelText: 'File path',
                  hintText: '/sdcard/Download/winus-config-2025-05-05.txt',
                  border: OutlineInputBorder(),
                ),
                autofocus: true,
              ),
              const SizedBox(height: 12),
              TextButton.icon(
                icon: const Icon(Icons.content_paste, size: 16),
                label: const Text('Or paste from clipboard'),
                onPressed: () async {
                  final clip = await Clipboard.getData(Clipboard.kTextPlain);
                  if (clip?.text != null && clip!.text!.isNotEmpty) {
                    Navigator.pop(ctx, '__clipboard__');
                  }
                },
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, pathCtrl.text.trim()),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
              child: const Text('Import'),
            ),
          ],
        ),
      );
      if (path == null || path.isEmpty) return;

      if (path == '__clipboard__') {
        final clip = await Clipboard.getData(Clipboard.kTextPlain);
        jsonText = clip?.text;
      } else {
        jsonText = await platformReadTextFile(path);
        if (jsonText == null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('File not found: $path')),
          );
          return;
        }
      }
    } else {
      // Web: paste textarea (existing behavior)
      final ctrl = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Import Configuration'),
          content: SizedBox(
            width: 400, height: 300,
            child: TextField(
              controller: ctrl,
              maxLines: null,
              expands: true,
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
              decoration: const InputDecoration(
                hintText: 'Paste the exported .txt content here...',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
              child: const Text('Import (replaces all data)'),
            ),
          ],
        ),
      );
      if (ok != true || ctrl.text.isEmpty) return;
      jsonText = ctrl.text;
    }

    if (jsonText == null || jsonText.isEmpty) return;
    try {
      final data = jsonDecode(jsonText) as Map<String, dynamic>;
      final result = await api.importConfig(data);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Imported: ${result['users']} users, ${result['groups']} groups'), backgroundColor: Colors.green),
        );
        _loadAll();
        _loadServerConfig();
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Import error: $e')));
    }
  }

  void _addIp() {
    final ip = _newIpCtrl.text.trim();
    if (ip.isNotEmpty && !_announcedIps.contains(ip)) {
      setState(() {
        _announcedIps.add(ip);
        _newIpCtrl.clear();
      });
    }
  }

  Widget _settingsSection({
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: Colors.blue.shade700),
                const SizedBox(width: 8),
                Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 4),
            Text(subtitle, style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }

  /// Banner shown above the Settings tab when the backend's last
  /// infra-sync (writeEnv / regenerateCerts / docker compose up) failed.
  /// Lets the operator see what went wrong without having to dig through
  /// docker logs and dismiss the warning once acknowledged.
  Widget _syncErrorBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.shade900.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.red.shade400.withValues(alpha: 0.6)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, color: Colors.red.shade300, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Last infra-sync failed',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Colors.red.shade200,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  _lastSyncError,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.red.shade100,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            color: Colors.red.shade200,
            tooltip: 'Dismiss',
            onPressed: _dismissSyncError,
          ),
        ],
      ),
    );
  }

  Widget _settingsField({
    required TextEditingController controller,
    required String label,
    String hint = '',
    bool obscureText = false,
    TextInputType? keyboardType,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade400),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
    );
  }

  // ======================== DOWNLOADS TAB ========================

  Widget _buildDownloadsTab() {
    final baseUrl = getServerBaseUrl();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // APK
        _downloadCard(
          icon: Icons.android,
          iconColor: Colors.green.shade600,
          title: 'Android App (APK)',
          subtitle: 'Winus Intercom for Android devices',
          url: '$baseUrl/intercom.apk',
          instructions: 'Open this link on the Android device.\n'
              'Allow "Install from unknown sources" if prompted.',
        ),
        const SizedBox(height: 16),
        // Certificate
        _downloadCard(
          icon: Icons.lock,
          iconColor: Colors.orange.shade600,
          title: 'SSL Certificate (iOS)',
          subtitle: 'Required for iPhone / iPad',
          url: '$baseUrl/cert.pem',
          instructions:
              '1. Open this link in Safari on the iOS device\n'
              '2. Allow the profile download\n'
              '3. Settings → General → VPN & Device Management → Install profile\n'
              '4. Settings → General → About → Certificate Trust Settings → Enable full trust\n'
              '5. Then open $baseUrl in Safari or Chrome',
        ),
        const SizedBox(height: 16),
        // Bridge
        _downloadCard(
          icon: Icons.cable,
          iconColor: Colors.blue.shade600,
          title: 'Tie-Line Bridge',
          subtitle: 'Audio bridge for multi-channel devices (Dante, MADI...)',
          url: '',
          instructions:
              'The bridge runs on the server machine:\n'
              '  cd tie-line-bridge && python3 bridge_gui.py\n\n'
              'Or headless:\n'
              '  python3 bridge.py --config config.json\n\n'
              'Requirements: Python 3.10+, libopus, sounddevice',
        ),
        const SizedBox(height: 16),
        // Server info
        Card(
          elevation: 1,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.info_outline, size: 20, color: Colors.grey.shade600),
                    const SizedBox(width: 8),
                    Text('Server Info', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey.shade700)),
                  ],
                ),
                const SizedBox(height: 12),
                _infoRow('Web URL', baseUrl),
                _infoRow('Ports needed', '8443/TCP, 10000-10200/UDP, 3478/UDP+TCP'),
                _infoRow('Audio', 'mediasoup (Opus 48kHz)'),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _downloadCard({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required String url,
    required String instructions,
  }) {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: iconColor.withValues(alpha: 0.1),
                  child: Icon(icon, color: iconColor, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                      Text(subtitle, style: TextStyle(color: Colors.grey.shade500, fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),
            if (url.isNotEmpty) ...[
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.grey.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: SelectableText(
                        url,
                        style: TextStyle(fontSize: 12, color: Colors.blue.shade700, fontFamily: 'monospace'),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy, size: 16),
                      tooltip: 'Copy URL',
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: url));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('URL copied'), duration: Duration(seconds: 1)),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                instructions,
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700, height: 1.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
          ),
          Expanded(
            child: SelectableText(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }
}

/// Lightweight value object used by the byGroup view: every entry is either
/// a section header (`isHeader=true`) or a user under that header.
class _UserGroupEntry {
  final bool isHeader;
  final String groupName;
  final int count;
  final Map<String, dynamic>? user;

  _UserGroupEntry.header(this.groupName, this.count)
      : isHeader = true,
        user = null;
  _UserGroupEntry.user(Map<String, dynamic> u)
      : isHeader = false,
        groupName = '',
        count = 0,
        user = u;
}

/// Dante Controller style matrix with crosshair hover highlight.
class _DanteMatrix extends StatefulWidget {
  final List<dynamic> rowItems;
  final List<dynamic> colItems;
  final String Function(dynamic) rowLabel;
  final String Function(dynamic) colLabel;
  final bool Function(dynamic row, dynamic col) isChecked;
  final Future<void> Function(dynamic row, dynamic col, bool newVal) onToggle;
  final bool Function(dynamic a, dynamic b)? isSame;

  const _DanteMatrix({
    required this.rowItems,
    required this.colItems,
    required this.rowLabel,
    required this.colLabel,
    required this.isChecked,
    required this.onToggle,
    this.isSame,
  });

  @override
  State<_DanteMatrix> createState() => _DanteMatrixState();
}

class _DanteMatrixState extends State<_DanteMatrix> {
  static const _bg = Color(0xFF1A1A2E);
  static const _surface = Color(0xFF16213E);
  static const _border = Color(0xFF233554);
  static const _teal = Color(0xFF00B8A9);
  static const _tealDark = Color(0xFF008C7E);
  static const _textLight = Color(0xFFAABBCC);
  static const _highlight = Color(0xFF1E3A5F); // crosshair row/col highlight

  int _hoverRow = -1;
  int _hoverCol = -1;

  static const double cellSize = 34;
  static const double labelWidth = 110;
  static const double headerHeight = 90;

  @override
  Widget build(BuildContext context) {
    final rowItems = widget.rowItems;
    final colItems = widget.colItems;

    return MouseRegion(
      onExit: (_) => setState(() { _hoverRow = -1; _hoverCol = -1; }),
      child: Container(
        decoration: BoxDecoration(
          color: _bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _border, width: 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          height: headerHeight + (rowItems.length * cellSize) + 2,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: labelWidth + (colItems.length * cellSize) + 2,
              child: CustomScrollView(
                slivers: [
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: _MatrixHeaderDelegate(
                      height: headerHeight,
                      labelWidth: labelWidth,
                      cellSize: cellSize,
                      colItems: colItems,
                      colLabel: widget.colLabel,
                      highlightCol: _hoverCol,
                    ),
                  ),
                  SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, idx) => _buildRow(idx),
                      childCount: rowItems.length,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRow(int idx) {
    final row = widget.rowItems[idx];
    final isHoverRow = idx == _hoverRow;
    final baseBg = idx.isEven ? _bg : _surface;
    final rowBg = isHoverRow ? _highlight : baseBg;

    return Container(
      decoration: BoxDecoration(
        color: rowBg,
        border: Border(bottom: BorderSide(color: _border.withValues(alpha: 0.5), width: 0.5)),
      ),
      child: Row(
        children: [
          // Row label
          Container(
            width: labelWidth,
            height: cellSize,
            padding: const EdgeInsets.only(left: 10),
            decoration: BoxDecoration(
              color: isHoverRow ? _highlight : null,
              border: const Border(right: BorderSide(color: _border, width: 1)),
            ),
            alignment: Alignment.centerLeft,
            child: Text(
              widget.rowLabel(row),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: isHoverRow ? Colors.white : _textLight,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // Cells
          ...List.generate(widget.colItems.length, (colIdx) {
            final col = widget.colItems[colIdx];
            final same = widget.isSame != null && widget.isSame!(row, col);
            final isHoverCol = colIdx == _hoverCol;
            final isCrosshair = isHoverRow || isHoverCol;

            if (same) {
              return MouseRegion(
                onEnter: (_) => setState(() { _hoverRow = idx; _hoverCol = colIdx; }),
                child: Container(
                  width: cellSize,
                  height: cellSize,
                  decoration: BoxDecoration(
                    color: isCrosshair ? _highlight : const Color(0xFF0D1520),
                    border: Border(right: BorderSide(color: _border.withValues(alpha: 0.3), width: 0.5)),
                  ),
                ),
              );
            }

            final checked = widget.isChecked(row, col);
            final cellBg = isCrosshair ? _highlight : null;
            final rowName = widget.rowLabel(row);
            final colName = widget.colLabel(col);
            final tooltipText = '$rowName → $colName';

            return Tooltip(
              message: tooltipText,
              waitDuration: const Duration(milliseconds: 300),
              textStyle: const TextStyle(fontSize: 12, color: Colors.white),
              decoration: BoxDecoration(
                color: const Color(0xDD1A1A2E),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: _teal, width: 0.5),
              ),
              child: MouseRegion(
                onEnter: (_) => setState(() { _hoverRow = idx; _hoverCol = colIdx; }),
                child: GestureDetector(
                  onTap: () => widget.onToggle(row, col, !checked),
                  child: Container(
                  width: cellSize,
                  height: cellSize,
                  decoration: BoxDecoration(
                    color: cellBg,
                    border: Border(right: BorderSide(color: _border.withValues(alpha: 0.3), width: 0.5)),
                  ),
                  child: Center(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: 22,
                      height: 22,
                      decoration: BoxDecoration(
                        color: checked ? _teal : Colors.transparent,
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(
                          color: checked ? _tealDark : _border,
                          width: checked ? 1.5 : 1,
                        ),
                        boxShadow: checked
                            ? [BoxShadow(color: _teal.withValues(alpha: 0.4), blurRadius: 4)]
                            : null,
                      ),
                    ),
                  ),
                  ),
                ),
              ),
            );
          }),
        ],
      ),
    );
  }
}

/// Sticky header delegate for the permissions matrix column names — Dante style.
class _MatrixHeaderDelegate extends SliverPersistentHeaderDelegate {
  final double height;
  final double labelWidth;
  final double cellSize;
  final List<dynamic> colItems;
  final String Function(dynamic) colLabel;

  static const _headerBg = Color(0xFF0F3460);
  static const _headerBorder = Color(0xFF233554);
  static const _headerText = Color(0xFF8BA4BD);
  static const _headerHighlight = Color(0xFF1E3A5F);

  final int highlightCol;

  _MatrixHeaderDelegate({
    required this.height,
    required this.labelWidth,
    required this.cellSize,
    required this.colItems,
    required this.colLabel,
    this.highlightCol = -1,
  });

  @override
  double get maxExtent => height;
  @override
  double get minExtent => height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      color: _headerBg,
      child: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Container(
                  width: labelWidth,
                  decoration: const BoxDecoration(
                    border: Border(right: BorderSide(color: _headerBorder, width: 1)),
                  ),
                ),
                ...List.generate(colItems.length, (i) {
                  final col = colItems[i];
                  final isHighlighted = i == highlightCol;
                  return Container(
                    width: cellSize,
                    color: isHighlighted ? _headerHighlight : null,
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: RotatedBox(
                        quarterTurns: 3,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Text(
                            colLabel(col),
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: isHighlighted ? Colors.white : _headerText,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
          const Divider(height: 1, color: _headerBorder),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _MatrixHeaderDelegate oldDelegate) => true;
}

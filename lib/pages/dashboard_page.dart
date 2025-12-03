import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import '../models/project_data.dart';
import '../widgets/data_view_tab.dart';
import '../widgets/matching_result_tab.dart';
import '../utils/excel_exporter.dart';
import '../utils/lock_manager.dart';
import '../providers/user_provider.dart';
import 'login_page.dart';

class DashboardPage extends ConsumerStatefulWidget {
  const DashboardPage({super.key});

  @override
  ConsumerState<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends ConsumerState<DashboardPage> with WidgetsBindingObserver {
  Map<String, List<ProjectData>> _groupedProjects = {};
  ProjectData? _selectedProject;
  bool _isLoading = false;
  String _currentRootPath = '';
  
  bool _isReadOnly = false; // ロック制御用フラグ

  final List<ProjectData> _undoStack = [];
  final List<ProjectData> _redoStack = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _releaseCurrentProjectLock();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      _releaseCurrentProjectLock();
    }
  }

  // --- ロック管理 ---

  Future<void> _releaseCurrentProjectLock() async {
    if (_selectedProject != null && !_isReadOnly) {
      await LockManager.releaseLock(_selectedProject!.filePath);
    }
  }

  Future<void> _trySelectProject(ProjectData proj) async {
    if (_selectedProject?.filePath == proj.filePath) return;

    await _releaseCurrentProjectLock();

    setState(() => _isLoading = true);

    final lockInfo = await LockManager.checkLock(proj.filePath);
    final currentUser = ref.read(userProvider);
    bool allowWrite = true;

    if (lockInfo != null) {
      // 自分がロックしている場合はOK、他人なら警告
      if (lockInfo.user != currentUser && mounted) {
        final result = await showDialog<String>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            title: const Text('編集中のプロジェクトです'),
            content: Text(
              'このプロジェクトは現在、作業中です。\n\n'
              '担当者: ${lockInfo.user}\n'
              '開始: ${DateFormat('MM/dd HH:mm').format(lockInfo.timestamp)}\n\n'
              '操作を選択してください。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, 'cancel'),
                child: const Text('キャンセル'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, 'readonly'),
                child: const Text('読み取り専用で開く'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => Navigator.pop(context, 'force'),
                child: const Text('強制解除して編集'),
              ),
            ],
          ),
        );

        if (result == 'cancel' || result == null) {
          setState(() => _isLoading = false);
          return;
        } else if (result == 'readonly') {
          allowWrite = false;
        }
      }
    }

    if (allowWrite) {
      await LockManager.acquireLock(proj.filePath, currentUser);
    }

    setState(() {
      _selectedProject = proj;
      _isReadOnly = !allowWrite;
      _undoStack.clear();
      _redoStack.clear();
      _isLoading = false;
    });
  }

  // --- 状態更新 ---

  void _updateProjectState(ProjectData newProject) {
    if (_isReadOnly) return;
    if (_selectedProject != null) {
      _undoStack.add(_selectedProject!);
      if (_undoStack.length > 20) _undoStack.removeAt(0);
    }
    _redoStack.clear();
    setState(() {
      _selectedProject = newProject;
    });
  }

  void _undo() {
    if (_undoStack.isEmpty || _isReadOnly) return;
    final prev = _undoStack.removeLast();
    if (_selectedProject != null) _redoStack.add(_selectedProject!);
    setState(() => _selectedProject = prev);
  }

  void _redo() {
    if (_redoStack.isEmpty || _isReadOnly) return;
    final next = _redoStack.removeLast();
    if (_selectedProject != null) _undoStack.add(_selectedProject!);
    setState(() => _selectedProject = next);
  }

  // --- 読み込み ---

  Future<void> _pickFolderAndLoad() async {
    String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
    if (selectedDirectory == null) return;
    await _loadProjectsFromDirectory(selectedDirectory);
  }

  Future<void> _reloadCurrentFolder() async {
    if (_currentRootPath.isEmpty) return;
    await _loadProjectsFromDirectory(_currentRootPath);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('リストを更新しました'), duration: Duration(seconds: 1)),
      );
    }
  }

  Future<void> _loadProjectsFromDirectory(String directoryPath) async {
    await _releaseCurrentProjectLock();
    
    setState(() {
      _isLoading = true;
      _currentRootPath = directoryPath;
      _groupedProjects.clear();
      _undoStack.clear();
      _redoStack.clear();
      _selectedProject = null;
      _isReadOnly = false;
    });

    try {
      final dir = Directory(directoryPath);
      if (!await dir.exists()) throw Exception('ディレクトリが存在しません');

      final List<FileSystemEntity> entities = await dir.list(recursive: true).toList();
      final List<ProjectData> loadedProjects = [];

      for (var entity in entities) {
        if (entity is File && p.extension(entity.path).toLowerCase() == '.json') {
          try {
            final data = await ProjectData.fromFile(entity);
            if (data.nifudaDataRaw.isNotEmpty && data.productListDataRaw.isNotEmpty) {
              loadedProjects.add(data);
            }
          } catch (e) {
            debugPrint('Error parsing ${entity.path}: $e');
          }
        }
      }

      final Map<String, List<ProjectData>> grouped = {};
      for (var proj in loadedProjects) {
        final dateKey = proj.shippingDate != null 
            ? DateFormat('yyyy/MM/dd').format(proj.shippingDate!) 
            : '未設定';
        if (!grouped.containsKey(dateKey)) grouped[dateKey] = [];
        grouped[dateKey]!.add(proj);
      }

      final sortedKeys = grouped.keys.toList()..sort((a, b) {
        if (a == '未設定') return -1;
        if (b == '未設定') return 1;
        return b.compareTo(a);
      });

      final Map<String, List<ProjectData>> sortedGrouped = {
        for (var key in sortedKeys) key: grouped[key]!
      };

      for (var key in sortedGrouped.keys) {
        sortedGrouped[key]!.sort((a, b) => b.lastModified.compareTo(a.lastModified));
      }

      setState(() {
        _groupedProjects = sortedGrouped;
      });

    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('エラー: $e')));
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // --- アクション (保存) ---

  Future<void> _saveToFile(ProjectData project, {bool isPlCompletion = false}) async {
    if (_isReadOnly) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('読み取り専用のため保存できません'), backgroundColor: Colors.orange),
      );
      return;
    }

    final currentUser = ref.read(userProvider);
    ProjectData updatedProject = project.copyWith(lastUpdatedBy: currentUser);

    if (isPlCompletion) {
      updatedProject = updatedProject.copyWith(
        status: 'P/L,S/M作成完了',
        plCreatedBy: currentUser,
        plCreatedAt: DateTime.now(),
      );
    }

    try {
      final file = File(updatedProject.filePath);
      final jsonString = jsonEncode(updatedProject.toJson());
      await file.writeAsString(jsonString);
      _updateProjectState(updatedProject);
    } catch (e) {
      throw e;
    }
  }

  Future<void> _runPlSmCreation() async {
    if (_selectedProject == null) return;
    try {
      await _saveToFile(_selectedProject!, isPlCompletion: true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('P/L, S/M 作成完了として保存しました')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存エラー: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _overwriteSave() async {
    if (_selectedProject == null) return;
    try {
      await _saveToFile(_selectedProject!);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('上書き保存しました')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存エラー: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _updateShippingDate() async {
    if (_selectedProject == null || _isReadOnly) return;

    final initialDate = _selectedProject!.shippingDate ?? DateTime.now();
    final pickedDate = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      helpText: '出荷日を選択',
    );

    if (pickedDate == null) return;

    final projectWithDate = _selectedProject!.copyWith(shippingDate: pickedDate);

    try {
      await _saveToFile(projectWithDate);
      await _loadProjectsFromDirectory(_currentRootPath); // リスト更新のためリロード
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('出荷日を ${DateFormat('yyyy/MM/dd').format(pickedDate)} に設定しました')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存エラー: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _exportExcel() async {
    if (_selectedProject == null) return;
    String? selectedDirectory = await FilePicker.platform.getDirectoryPath(dialogTitle: 'Excel出力先を選択');
    if (selectedDirectory == null) return;

    try {
      final path = await ExcelExporter.export(_selectedProject!, selectedDirectory);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Excelを出力しました: $path')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Excel出力エラー: $e'), backgroundColor: Colors.red));
      }
    }
  }

  void _logout() {
    _releaseCurrentProjectLock();
    ref.read(userProvider.notifier).logout();
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const LoginPage()));
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = ref.watch(userProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('荷札照合データ管理'),
        backgroundColor: Colors.indigo[700],
        foregroundColor: Colors.white,
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Text('担当: $currentUser', style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
          IconButton(icon: const Icon(Icons.logout), onPressed: _logout, tooltip: 'ログアウト'),
          const VerticalDivider(width: 20, color: Colors.white24, indent: 10, endIndent: 10),
          IconButton(icon: const Icon(Icons.undo), onPressed: (!_isReadOnly && _undoStack.isNotEmpty) ? _undo : null),
          IconButton(icon: const Icon(Icons.redo), onPressed: (!_isReadOnly && _redoStack.isNotEmpty) ? _redo : null),
          const SizedBox(width: 16),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: (_isLoading || _currentRootPath.isEmpty) ? null : _reloadCurrentFolder,
            tooltip: 'データを更新',
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.folder_open),
            onPressed: _isLoading ? null : _pickFolderAndLoad,
            tooltip: 'データフォルダを選択',
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: Row(
        children: [
          // 左ペイン
          SizedBox(
            width: 300,
            child: Container(
              color: Colors.grey[100],
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    color: Colors.indigo[50],
                    width: double.infinity,
                    child: Text(
                      _currentRootPath.isEmpty ? 'フォルダ未選択' : '監視中: ${p.basename(_currentRootPath)}',
                      style: TextStyle(color: Colors.indigo[900], fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: _isLoading 
                      ? const Center(child: CircularProgressIndicator())
                      : _groupedProjects.isEmpty
                        ? const Center(child: Text('データが見つかりません'))
                        : ListView.builder(
                            itemCount: _groupedProjects.length,
                            itemBuilder: (context, index) {
                              final dateKey = _groupedProjects.keys.elementAt(index);
                              final projects = _groupedProjects[dateKey]!;
                              return ExpansionTile(
                                title: Text(dateKey, style: const TextStyle(fontWeight: FontWeight.bold)),
                                initiallyExpanded: index == 0,
                                shape: const Border(),
                                children: projects.map((proj) {
                                  final isSelected = _selectedProject?.filePath == proj.filePath;
                                  return ListTile(
                                    title: Text(proj.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                                    subtitle: Text(
                                      'Case: ${proj.currentCaseNumber} / 更新: ${DateFormat('MM/dd HH:mm').format(proj.lastModified)}',
                                      style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                                    ),
                                    selected: isSelected,
                                    selectedTileColor: Colors.indigo[100],
                                    onTap: () => _trySelectProject(proj),
                                  );
                                }).toList(),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
          const VerticalDivider(width: 1, thickness: 1),
          // 右ペイン
          Expanded(
            child: _selectedProject == null
                ? const Center(child: Text('左側のリストからプロジェクトを選択してください', style: TextStyle(color: Colors.grey)))
                : SelectionArea(
                    child: Column(
                      children: [
                        if (_isReadOnly)
                          Container(
                            width: double.infinity,
                            color: Colors.orange[100],
                            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
                            child: Row(
                              children: const [
                                Icon(Icons.lock, size: 16, color: Colors.deepOrange),
                                SizedBox(width: 8),
                                Text('読み取り専用モード（他ユーザーが作業中）', style: TextStyle(color: Colors.deepOrange, fontWeight: FontWeight.bold)),
                              ],
                            ),
                          ),
                        _buildActionHeader(),
                        _buildProjectInfoFooter(_selectedProject!),
                        const Divider(height: 1),
                        Expanded(child: _ProjectDetailView(
                          project: _selectedProject!,
                          onNifudaChanged: (newRows) {
                            if (_isReadOnly) return;
                            final newProject = _selectedProject!.copyWith(
                              nifudaDataRaw: [_selectedProject!.nifudaHeader, ...newRows],
                            );
                            _updateProjectState(newProject);
                          },
                          onProductChanged: (newRows) {
                            if (_isReadOnly) return;
                            final newProject = _selectedProject!.copyWith(
                              productListDataRaw: [_selectedProject!.productHeader, ...newRows],
                            );
                            _updateProjectState(newProject);
                          },
                        )),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildProjectInfoFooter(ProjectData proj) {
    return Container(
      width: double.infinity,
      color: Colors.grey[50],
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Wrap(
        spacing: 16,
        children: [
          if (proj.lastUpdatedBy != null)
            Text('最終更新: ${proj.lastUpdatedBy} (${DateFormat('MM/dd HH:mm').format(proj.lastModified)})', style: TextStyle(fontSize: 11, color: Colors.grey[700])),
          if (proj.plCreatedBy != null)
            Text('P/L作成: ${proj.plCreatedBy} (${DateFormat('MM/dd HH:mm').format(proj.plCreatedAt!)})', style: TextStyle(fontSize: 11, color: Colors.green[800], fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildActionHeader() {
    final status = _selectedProject!.status;
    final isProcessDone = status == 'P/L,S/M作成完了';
    final isInspectionDone = status == '現場検品完了';
    final shippingDateStr = _selectedProject!.shippingDate != null
        ? DateFormat('yyyy/MM/dd').format(_selectedProject!.shippingDate!)
        : '出荷日未定';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: Colors.white,
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: isProcessDone ? Colors.green[100] : (isInspectionDone ? Colors.orange[100] : Colors.grey[200]),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: isProcessDone ? Colors.green : (isInspectionDone ? Colors.orange : Colors.grey)),
            ),
            child: Row(
              children: [
                Icon(isProcessDone ? Icons.check_circle : Icons.info, size: 18, color: isProcessDone ? Colors.green[800] : Colors.orange[800]),
                const SizedBox(width: 8),
                Text(status, style: TextStyle(fontWeight: FontWeight.bold, color: isProcessDone ? Colors.green[900] : Colors.orange[900])),
              ],
            ),
          ),
          const SizedBox(width: 16),
          OutlinedButton.icon(
            onPressed: _isReadOnly ? null : _updateShippingDate,
            icon: const Icon(Icons.calendar_today, size: 18),
            label: Text(shippingDateStr),
            style: OutlinedButton.styleFrom(foregroundColor: _selectedProject!.shippingDate != null ? Colors.indigo : Colors.grey[700]),
          ),
          const Spacer(),
          ElevatedButton.icon(
            // 完了済み または 読み取り専用なら押せない
            onPressed: (isProcessDone || _isReadOnly) ? null : _runPlSmCreation,
            icon: const Icon(Icons.settings_applications),
            label: const Text('P/L, S/M 作成完了'),
            style: ElevatedButton.styleFrom(
              backgroundColor: isProcessDone ? Colors.green[600] : Colors.blue[600],
              foregroundColor: Colors.white,
              disabledBackgroundColor: Colors.green[100],
              disabledForegroundColor: Colors.green[800],
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: _isReadOnly ? null : _overwriteSave,
            icon: const Icon(Icons.save),
            label: const Text('上書き保存'),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: _exportExcel,
            icon: const Icon(Icons.table_view),
            label: const Text('Excel出力'),
          ),
        ],
      ),
    );
  }
}

class _ProjectDetailView extends StatelessWidget {
  final ProjectData project;
  final Function(List<List<String>>) onNifudaChanged;
  final Function(List<List<String>>) onProductChanged;

  const _ProjectDetailView({required this.project, required this.onNifudaChanged, required this.onProductChanged});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          Container(
            color: Colors.white,
            child: TabBar(
              labelColor: Colors.indigo,
              unselectedLabelColor: Colors.grey,
              indicatorColor: Colors.indigo,
              tabs: [
                Tab(text: '荷札リスト (${project.nifudaRows.length}件)'),
                Tab(text: '製品リスト (${project.productRows.length}件)'),
                const Tab(text: '照合結果プレビュー'),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              physics: const NeverScrollableScrollPhysics(),
              children: [
                DataViewTab(
                  headers: project.nifudaHeader,
                  rows: project.nifudaRows,
                  filterColumnIndex: project.nifudaHeader.indexOf('Case No.'),
                  filterValue: project.currentCaseNumber,
                  onRowsChanged: onNifudaChanged,
                ),
                DataViewTab(
                  headers: project.productHeader,
                  rows: project.productRows,
                  onRowsChanged: onProductChanged,
                ),
                MatchingResultTab(project: project),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
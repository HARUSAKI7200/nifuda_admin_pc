import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; 
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart'; 
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
  
  bool _isReadOnly = false;

  final List<ProjectData> _undoStack = [];
  final List<ProjectData> _redoStack = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _autoLoadLastDirectory();
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

  Future<void> _autoLoadLastDirectory() async {
    final prefs = await SharedPreferences.getInstance();
    final lastPath = prefs.getString('last_project_dir');
    
    if (lastPath != null && lastPath.isNotEmpty) {
      final dir = Directory(lastPath);
      if (await dir.exists()) {
        await _loadProjectsFromDirectory(lastPath);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('前回のフォルダを自動読み込みしました')),
          );
        }
      }
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

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_project_dir', directoryPath);

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
            : '出荷日未設定';
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

  Future<void> _saveToFile(ProjectData project, {bool isPlCompletion = false, bool isPlCreationStart = false}) async {
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
    } else if (isPlCreationStart) {
      // 作成開始時はステータスのみ変更
      updatedProject = updatedProject.copyWith(
        status: 'P/L,S/M作成中',
        lastUpdatedBy: currentUser, // 更新者も更新
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

  // ★ 追加: P/L, S/M 作成開始処理
  Future<void> _startPlSmCreation() async {
    if (_selectedProject == null || _isReadOnly) return;

    try {
      // 1. ステータスを「P/L,S/M作成中」に変更して保存
      await _saveToFile(_selectedProject!, isPlCreationStart: true);

      // 2. 作成に使用するファイルを選択 (Excel/Word等)
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        dialogTitle: '作成に使用するファイルを選択してください (Excel, Word等)',
        type: FileType.any, 
      );

      if (result != null && result.files.single.path != null) {
        final filePath = result.files.single.path!;
        
        // 3. 選択されたファイルをOS標準のアプリで開く
        if (Platform.isWindows) {
           await Process.run('explorer', [filePath]); 
        } else if (Platform.isMacOS) {
           await Process.run('open', [filePath]);
        }
        
        if (mounted) {
           ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('ファイルを開きました: ${p.basename(filePath)}')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('エラーが発生しました: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _runPlSmCreation() async {
    if (_selectedProject == null || _isReadOnly) return;

    // 完了確認ダイアログ
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('完了確認'),
        content: const Text('ステータスを「P/L,S/M作成完了」に変更しますか？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('キャンセル')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('完了とする')),
        ],
      ),
    );

    if (confirm != true) return;

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
      await _loadProjectsFromDirectory(_currentRootPath);
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

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
          if (_selectedProject != null && !_isReadOnly) _overwriteSave();
        },
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true): () {
          if (_undoStack.isNotEmpty && !_isReadOnly) _undo();
        },
        const SingleActivator(LogicalKeyboardKey.keyY, control: true): () {
          if (_redoStack.isNotEmpty && !_isReadOnly) _redo();
        },
        const SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true): () {
          if (_redoStack.isNotEmpty && !_isReadOnly) _redo();
        },
        const SingleActivator(LogicalKeyboardKey.keyR, control: true): () {
          if (_currentRootPath.isNotEmpty && !_isLoading) _reloadCurrentFolder();
        },
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
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
              IconButton(icon: const Icon(Icons.undo), onPressed: (!_isReadOnly && _undoStack.isNotEmpty) ? _undo : null, tooltip: '元に戻す (Ctrl+Z)'),
              IconButton(icon: const Icon(Icons.redo), onPressed: (!_isReadOnly && _redoStack.isNotEmpty) ? _redo : null, tooltip: 'やり直し (Ctrl+Y)'),
              const SizedBox(width: 16),
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: (_isLoading || _currentRootPath.isEmpty) ? null : _reloadCurrentFolder,
                tooltip: 'データを更新 (Ctrl+R)',
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
        ),
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

  // ★ 修正: ボタン切り替えロジック
  Widget _buildActionHeader() {
    final status = _selectedProject!.status;
    final isProcessDone = status == 'P/L,S/M作成完了';
    final isCreating = status == 'P/L,S/M作成中';
    final isInspectionDone = status == '現場検品完了'; // またはその他の状態
    
    final shippingDateStr = _selectedProject!.shippingDate != null
        ? DateFormat('yyyy/MM/dd').format(_selectedProject!.shippingDate!)
        : '出荷日未定';

    // ステータス表示色
    Color statusBg = Colors.grey[200]!;
    Color statusFg = Colors.grey[900]!;
    IconData statusIcon = Icons.info;

    if (isProcessDone) {
      statusBg = Colors.green[100]!;
      statusFg = Colors.green[900]!;
      statusIcon = Icons.check_circle;
    } else if (isCreating) {
      statusBg = Colors.blue[100]!;
      statusFg = Colors.blue[900]!;
      statusIcon = Icons.edit_document;
    } else if (isInspectionDone) {
      statusBg = Colors.orange[100]!;
      statusFg = Colors.orange[900]!;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: Colors.white,
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: statusBg,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: statusFg.withOpacity(0.5)),
            ),
            child: Row(
              children: [
                Icon(statusIcon, size: 18, color: statusFg),
                const SizedBox(width: 8),
                Text(status, style: TextStyle(fontWeight: FontWeight.bold, color: statusFg)),
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

          // ★ ボタンの切り替え
          if (isProcessDone)
             ElevatedButton.icon(
              onPressed: null,
              icon: const Icon(Icons.check),
              label: const Text('P/L, S/M 作成完了'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green[600],
                disabledBackgroundColor: Colors.green[100],
                disabledForegroundColor: Colors.green[800],
              ),
            )
          else if (isCreating)
            ElevatedButton.icon(
              onPressed: _isReadOnly ? null : _runPlSmCreation,
              icon: const Icon(Icons.save_alt),
              label: const Text('P/L, S/M 作成完了'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.orange[700],
                foregroundColor: Colors.white,
              ),
            )
          else
            ElevatedButton.icon(
              onPressed: _isReadOnly ? null : _startPlSmCreation,
              icon: const Icon(Icons.play_arrow),
              label: const Text('P/L, S/M 作成開始'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue[600],
                foregroundColor: Colors.white,
              ),
            ),

          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: _isReadOnly ? null : _overwriteSave,
            icon: const Icon(Icons.save),
            label: const Text('上書き保存 (Ctrl+S)'),
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

class _ProjectDetailView extends StatefulWidget {
  final ProjectData project;
  final Function(List<List<String>>) onNifudaChanged;
  final Function(List<List<String>>) onProductChanged;

  const _ProjectDetailView({
    required this.project,
    required this.onNifudaChanged,
    required this.onProductChanged,
  });

  @override
  State<_ProjectDetailView> createState() => _ProjectDetailViewState();
}

class _ProjectDetailViewState extends State<_ProjectDetailView> {
  String? _selectedCaseNumber;

  @override
  void initState() {
    super.initState();
    _initSelectedCase();
  }

  @override
  void didUpdateWidget(covariant _ProjectDetailView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.project.filePath != widget.project.filePath) {
      _initSelectedCase();
    }
  }

  void _initSelectedCase() {
    final cases = widget.project.availableCaseNumbers;
    if (cases.contains(widget.project.currentCaseNumber)) {
      _selectedCaseNumber = widget.project.currentCaseNumber;
    } else if (cases.isNotEmpty) {
      _selectedCaseNumber = cases.first;
    } else {
      _selectedCaseNumber = null; 
    }
  }

  @override
  Widget build(BuildContext context) {
    final nifudaHeader = widget.project.nifudaHeader;
    final caseIndex = nifudaHeader.indexOf('Case No.');
    
    final caseItems = widget.project.availableCaseNumbers.map((c) {
      return DropdownMenuItem(value: c, child: Text(c));
    }).toList();

    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          Container(
            color: Colors.white,
            child: Row(
              children: [
                Expanded(
                  child: TabBar(
                    labelColor: Colors.indigo,
                    unselectedLabelColor: Colors.grey,
                    indicatorColor: Colors.indigo,
                    tabs: [
                      Tab(text: '荷札リスト (${widget.project.nifudaRows.length}件)'),
                      Tab(text: '製品リスト (${widget.project.productRows.length}件)'),
                      const Tab(text: '照合結果プレビュー'),
                    ],
                  ),
                ),
              ],
            ),
          ),
          
          Expanded(
            child: TabBarView(
              physics: const NeverScrollableScrollPhysics(),
              children: [
                // --- 1. 荷札リストタブ (Case選択機能付き) ---
                Column(
                  children: [
                    if (caseItems.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        color: Colors.grey[50],
                        child: Row(
                          children: [
                            const Icon(Icons.filter_list, size: 20, color: Colors.indigo),
                            const SizedBox(width: 8),
                            const Text('表示するCase No.: ', style: TextStyle(fontWeight: FontWeight.bold)),
                            const SizedBox(width: 8),
                            DropdownButton<String>(
                              value: _selectedCaseNumber,
                              items: caseItems,
                              onChanged: (val) {
                                if (val != null) {
                                  setState(() {
                                    _selectedCaseNumber = val;
                                  });
                                }
                              },
                              underline: Container(height: 1, color: Colors.indigo),
                              style: const TextStyle(color: Colors.indigo, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                    
                    Expanded(
                      child: DataViewTab(
                        headers: widget.project.nifudaHeader,
                        rows: widget.project.nifudaRows,
                        // 選択されたCaseでフィルタリング
                        filterColumnIndex: caseIndex,
                        filterValue: _selectedCaseNumber,
                        onRowsChanged: widget.onNifudaChanged,
                      ),
                    ),
                  ],
                ),

                // --- 2. 製品リストタブ ---
                DataViewTab(
                  headers: widget.project.productHeader,
                  rows: widget.project.productRows,
                  onRowsChanged: widget.onProductChanged,
                ),

                // --- 3. 照合結果タブ ---
                MatchingResultTab(project: widget.project),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
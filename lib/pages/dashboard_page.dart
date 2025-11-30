import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import '../models/project_data.dart';
import '../widgets/data_view_tab.dart';
import '../widgets/matching_result_tab.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  // 日付文字列(yyyy-MM-dd) -> プロジェクトリスト
  Map<String, List<ProjectData>> _groupedProjects = {};
  ProjectData? _selectedProject;
  bool _isLoading = false;
  String _currentRootPath = '';

  Future<void> _pickFolderAndLoad() async {
    String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
    if (selectedDirectory == null) return;

    setState(() {
      _isLoading = true;
      _currentRootPath = selectedDirectory;
      _selectedProject = null;
      _groupedProjects.clear();
    });

    try {
      final dir = Directory(selectedDirectory);
      // 再帰的にファイルを探索
      // Note: ファイル数が多い場合はisolateを使うなどの最適化が必要ですが、
      // ここではシンプルに実装します。
      final List<FileSystemEntity> entities = await dir.list(recursive: true).toList();
      
      final List<ProjectData> loadedProjects = [];

      for (var entity in entities) {
        if (entity is File && p.extension(entity.path).toLowerCase() == '.json') {
          // ファイル名がプロジェクトコードっぽいか、またはSAVESフォルダ内かなどのチェックも可能
          // ここではすべてのJSONを試行する
          try {
            final data = await ProjectData.fromFile(entity);
            // 必須項目が入っているか簡易チェック
            if (data.nifudaDataRaw.isNotEmpty && data.productListDataRaw.isNotEmpty) {
              loadedProjects.add(data);
            }
          } catch (e) {
            // JSONの形式が違うファイルなどはスキップ
            debugPrint('Error parsing ${entity.path}: $e');
          }
        }
      }

      // 日付でグループ化
      final Map<String, List<ProjectData>> grouped = {};
      for (var proj in loadedProjects) {
        final dateKey = DateFormat('yyyy-MM-dd').format(proj.lastModified);
        if (!grouped.containsKey(dateKey)) {
          grouped[dateKey] = [];
        }
        grouped[dateKey]!.add(proj);
      }

      // 日付の降順ソート
      final sortedKeys = grouped.keys.toList()..sort((a, b) => b.compareTo(a));
      final Map<String, List<ProjectData>> sortedGrouped = {
        for (var key in sortedKeys) key: grouped[key]!
      };

      // 各日付内のプロジェクトも時刻順(新しい順)にソート
      for (var key in sortedGrouped.keys) {
        sortedGrouped[key]!.sort((a, b) => b.lastModified.compareTo(a.lastModified));
      }

      setState(() {
        _groupedProjects = sortedGrouped;
      });

    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('フォルダ読み込みエラー: $e')),
        );
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('荷札照合データ管理'),
        backgroundColor: Colors.indigo[700],
        foregroundColor: Colors.white,
        actions: [
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
          // 左ペイン: プロジェクト選択
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
                                  final isSelected = _selectedProject == proj;
                                  return ListTile(
                                    title: Text(proj.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                                    subtitle: Text(
                                      '${DateFormat('HH:mm').format(proj.lastModified)} / Case: ${proj.currentCaseNumber}',
                                      style: TextStyle(fontSize: 12, color: Colors.grey[700]),
                                    ),
                                    selected: isSelected,
                                    selectedTileColor: Colors.indigo[100],
                                    onTap: () {
                                      setState(() {
                                        _selectedProject = proj;
                                      });
                                    },
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
          
          // 右ペイン: 詳細表示
          Expanded(
            child: _selectedProject == null
                ? const Center(child: Text('左側のリストからプロジェクトを選択してください', style: TextStyle(color: Colors.grey)))
                : _ProjectDetailView(project: _selectedProject!),
          ),
        ],
      ),
    );
  }
}

class _ProjectDetailView extends StatelessWidget {
  final ProjectData project;

  const _ProjectDetailView({required this.project});

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
              physics: const NeverScrollableScrollPhysics(), // マウス操作用にスワイプ無効化
              children: [
                // 1. 荷札リスト
                DataViewTab(
                  headers: project.nifudaHeader,
                  rows: project.nifudaRows,
                  filterColumnIndex: project.nifudaHeader.indexOf('Case No.'),
                  filterValue: project.currentCaseNumber,
                ),
                // 2. 製品リスト
                DataViewTab(
                  headers: project.productHeader,
                  rows: project.productRows,
                ),
                // 3. 照合結果
                MatchingResultTab(project: project),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
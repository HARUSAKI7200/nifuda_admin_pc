// lib/pages/directory_image_picker_page.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import '../widgets/custom_snackbar.dart';

// ★ 修正：JSONファイルピッカーとしても機能するように修正
class DirectoryImagePickerPage extends StatefulWidget {
  final String rootDirectoryPath;
  // ★ 追加: オプションのパラメータ
  final String title;
  final List<String>? fileExtensionFilter; // e.g., ['.json'] or ['.jpg', '.png']
  final bool showDirectoriesFirst;
  final bool returnOnlyFilePath; // trueの場合、選択したらすぐにPathを返す

  // ★ 修正: コンストラクタを修正
  const DirectoryImagePickerPage({
    super.key,
    required this.rootDirectoryPath,
    this.title = "日付を選択", // デフォルトタイトル
    this.fileExtensionFilter,
    this.showDirectoriesFirst = true,
    this.returnOnlyFilePath = false,
  });

  @override
  State<DirectoryImagePickerPage> createState() => _DirectoryImagePickerPageState();
}

class _DirectoryImagePickerPageState extends State<DirectoryImagePickerPage> {
  late Directory _currentDirectory;
  List<FileSystemEntity> _entities = [];
  String _currentTitle = "";

  final Set<String> _selectedImagePaths = {};
  bool _isLoading = true;
  String _currentPathDisplay = ""; // ★ 追加：現在のパスを表示するための変数

  @override
  void initState() {
    super.initState();
    _currentDirectory = Directory(widget.rootDirectoryPath);
    _currentTitle = widget.title;
    _requestPermissionAndLoad();
  }

  Future<void> _requestPermissionAndLoad() async {
    var status = await Permission.storage.status;
    if (!status.isGranted) status = await Permission.storage.request();
    if (!status.isGranted) status = await Permission.manageExternalStorage.request();

    if (!status.isGranted) {
      if (mounted) {
        showCustomSnackBar(context, 'ストレージ権限がありません。', isError: true);
        Navigator.pop(context);
      }
      return;
    }
    _loadEntitiesInDir(_currentDirectory);
  }

  Future<void> _loadEntitiesInDir(Directory dir) async {
    setState(() {
      _isLoading = true;
      _currentDirectory = dir;
      // パス表示をルートからの相対パスに
      _currentPathDisplay = p.relative(dir.path, from: widget.rootDirectoryPath);
      if (_currentPathDisplay == '.') _currentPathDisplay = '';
    });

    try {
      List<FileSystemEntity> entities = await dir.list().toList();
      List<Directory> dirs = [];
      List<File> files = [];

      for (var entity in entities) {
        if (entity is Directory) {
          dirs.add(entity);
        } else if (entity is File) {
          if (widget.fileExtensionFilter != null) {
            // ファイルフィルターが指定されている場合
            final extension = p.extension(entity.path).toLowerCase();
            if (widget.fileExtensionFilter!.contains(extension)) {
              files.add(entity);
            }
          } else {
            // デフォルト (画像ピッカー)
            final extension = p.extension(entity.path).toLowerCase();
            if (['.jpg', '.jpeg', '.png'].contains(extension)) {
              files.add(entity);
            }
          }
        }
      }

      // 並び替え (ディレクトリ優先、名前順)
      dirs.sort((a, b) => b.path.compareTo(a.path)); // 降順 (新しい日付が上)
      files.sort((a, b) => b.path.compareTo(a.path)); // 降順

      setState(() {
        if (widget.showDirectoriesFirst) {
          _entities = [...dirs, ...files];
        } else {
          _entities = [...dirs, ...files]..sort((a, b) => b.path.compareTo(a.path));
        }
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) showCustomSnackBar(context, 'フォルダの読み込みに失敗: $e', isError: true);
      setState(() => _isLoading = false);
    }
  }

  // ディレクトリタップ時の動作
  void _onDirectoryTap(Directory dir) {
    setState(() {
      _currentTitle = p.basename(dir.path);
    });
    _loadEntitiesInDir(dir);
  }

  // ファイルタップ時の動作 (JSONピッカー用)
  void _onFileTap(File file) {
    if (widget.returnOnlyFilePath) {
      Navigator.pop(context, {'filePath': file.path});
    } else {
      // 画像選択ロジック (既存)
      _toggleSelection(file.path);
    }
  }
  
  // 画像選択のトグル (既存)
  void _toggleSelection(String path) {
    setState(() {
      if (_selectedImagePaths.contains(path)) {
        _selectedImagePaths.remove(path);
      } else {
        _selectedImagePaths.add(path);
      }
    });
  }

  // 戻るボタンの動作
  Future<bool> _onWillPop() async {
    if (_currentDirectory.path == widget.rootDirectoryPath) {
      return true; // ルートディレクトリなら閉じる
    } else {
      _loadEntitiesInDir(_currentDirectory.parent); // 親ディレクトリに戻る
      setState(() {
        _currentTitle = p.basename(_currentDirectory.parent.path);
        if (_currentDirectory.parent.path == widget.rootDirectoryPath) {
          _currentTitle = widget.title;
        }
      });
      return false; // ダイアログは閉じない
    }
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: _onWillPop,
      child: Scaffold(
        appBar: AppBar(
          title: Text("$_currentTitle ($_currentPathDisplay)", style: const TextStyle(fontSize: 16)),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () async {
              if (await _onWillPop()) {
                Navigator.pop(context);
              }
            },
          ),
          actions: [
            // ★ 追加: 更新ボタン
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'リストを更新',
              onPressed: () {
                _loadEntitiesInDir(_currentDirectory);
                showCustomSnackBar(context, 'リストを更新しました', durationSeconds: 1);
              },
            ),
            // JSONピッカーモードでは完了ボタンは不要
            if (!widget.returnOnlyFilePath)
              IconButton(
                icon: Icon(Icons.check, color: _selectedImagePaths.isNotEmpty ? Colors.white : Colors.grey),
                onPressed: _selectedImagePaths.isNotEmpty
                    ? () => Navigator.pop(context, _selectedImagePaths.toList())
                    : null,
              ),
          ],
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _entities.isEmpty
                ? Center(child: Text("このフォルダは空です。 (${_currentPathDisplay})"))
                // ★ 修正: fileExtensionFilter がある場合は ListView、ない場合は GridView
                : (widget.fileExtensionFilter != null)
                    ? _buildFileListView()
                    : _buildImageGridView(),
      ),
    );
  }

  Widget _buildFileListView() {
    return ListView.builder(
      itemCount: _entities.length,
      itemBuilder: (context, index) {
        final entity = _entities[index];
        if (entity is Directory) {
          return _buildDirectoryTile(entity, _onDirectoryTap);
        } else if (entity is File) {
          return _buildFileTile(entity, _onFileTap);
        }
        return const SizedBox.shrink();
      },
    );
  }

  Widget _buildImageGridView() {
    // GridView表示用にFileのみを抽出
    final imageFiles = _entities.whereType<File>().toList();
    // GridViewの前にDirectoryをリスト表示
    final directories = _entities.whereType<Directory>().toList();

    if (imageFiles.isEmpty && directories.isEmpty) {
        return Center(child: Text("このフォルダは空です。 (${_currentPathDisplay})"));
    }
    
    return Column(
      children: [
        if(directories.isNotEmpty)
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: directories.length,
            itemBuilder: (context, index) => _buildDirectoryTile(directories[index], _onDirectoryTap),
          ),
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.all(4.0),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 4.0,
              mainAxisSpacing: 4.0,
            ),
            itemCount: imageFiles.length,
            itemBuilder: (context, index) {
              final file = imageFiles[index];
              return _buildImageTile(file, _toggleSelection);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildDirectoryTile(Directory dir, Function(Directory) onTap) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
      child: ListTile(
        leading: const Icon(Icons.folder, size: 40, color: Colors.orange),
        title: Text(p.basename(dir.path)),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => onTap(dir),
      ),
    );
  }
  
  Widget _buildFileTile(File file, Function(File) onTap) {
    final isSelected = _selectedImagePaths.contains(file.path); // (流用)
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
      color: isSelected ? Colors.blue.shade100 : null,
      child: ListTile(
        leading: const Icon(Icons.description, size: 40, color: Colors.blueGrey),
        title: Text(p.basename(file.path)),
        trailing: widget.returnOnlyFilePath ? const Icon(Icons.chevron_right) : null,
        onTap: () => onTap(file),
      ),
    );
  }

  Widget _buildImageTile(File file, Function(String) onTap) {
    final isSelected = _selectedImagePaths.contains(file.path);
    return GestureDetector(
      onTap: () => onTap(file.path),
      child: GridTile(
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.file(file, fit: BoxFit.cover),
            if (isSelected)
              Container(
                color: Colors.black.withOpacity(0.5),
                child: const Icon(Icons.check_circle, color: Colors.white, size: 40),
              ),
          ],
        ),
      ),
    );
  }
}
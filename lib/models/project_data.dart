import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;

class ProjectData {
  final String title;
  final String projectFolderPath;
  final String currentCaseNumber;
  final DateTime lastModified;
  final String filePath;
  
  // 生のリストデータ (ヘッダー含む)
  final List<List<String>> nifudaDataRaw;
  final List<List<String>> productListDataRaw;

  ProjectData({
    required this.title,
    required this.projectFolderPath,
    required this.currentCaseNumber,
    required this.lastModified,
    required this.filePath,
    required this.nifudaDataRaw,
    required this.productListDataRaw,
  });

  /// JSONファイルからインスタンスを生成
  static Future<ProjectData> fromFile(File file) async {
    final content = await file.readAsString();
    final Map<String, dynamic> json = jsonDecode(content);

    // データのキャスト処理
    List<List<String>> convertToList(dynamic list) {
      if (list is List) {
        return list.map((row) {
          if (row is List) {
            return row.map((cell) => cell.toString()).toList();
          }
          return <String>[];
        }).toList();
      }
      return [];
    }

    final nifuda = convertToList(json['nifudaData']);
    final product = convertToList(json['productListKariData']);
    final modified = await file.lastModified();

    return ProjectData(
      title: json['projectTitle']?.toString() ?? '名称未設定',
      projectFolderPath: json['projectFolderPath']?.toString() ?? '',
      currentCaseNumber: json['currentCaseNumber']?.toString() ?? '#1',
      lastModified: modified,
      filePath: file.path,
      nifudaDataRaw: nifuda,
      productListDataRaw: product,
    );
  }

  // --- ヘルパーメソッド ---

  // 荷札データのヘッダー
  List<String> get nifudaHeader => nifudaDataRaw.isNotEmpty ? nifudaDataRaw.first : [];
  
  // 荷札データの中身（ヘッダー除く）
  List<List<String>> get nifudaRows => nifudaDataRaw.length > 1 ? nifudaDataRaw.sublist(1) : [];

  // 製品リストのヘッダー
  List<String> get productHeader => productListDataRaw.isNotEmpty ? productListDataRaw.first : [];
  
  // 製品リストの中身（ヘッダー除く）
  List<List<String>> get productRows => productListDataRaw.length > 1 ? productListDataRaw.sublist(1) : [];

  // 照合用：荷札データをMapのリストに変換 (Case Noでフィルタリング)
  List<Map<String, String>> getNifudaMapListForMatching(String targetCase) {
    if (nifudaDataRaw.isEmpty) return [];
    
    final header = nifudaHeader;
    // ヘッダー内の 'Case No.' のインデックスを探す
    final caseIndex = header.indexOf('Case No.');
    
    return nifudaRows.where((row) {
      if (caseIndex >= 0 && caseIndex < row.length) {
        return row[caseIndex] == targetCase;
      }
      return false;
    }).map((row) {
      final Map<String, String> map = {};
      for (int i = 0; i < header.length; i++) {
        map[header[i]] = i < row.length ? row[i] : '';
      }
      return map;
    }).toList();
  }

  // 照合用：製品リストデータをMapのリストに変換
  List<Map<String, String>> getProductMapListForMatching() {
    if (productListDataRaw.isEmpty) return [];
    
    final header = productHeader;
    return productRows.map((row) {
      final Map<String, String> map = {};
      for (int i = 0; i < header.length; i++) {
        map[header[i]] = i < row.length ? row[i] : '';
      }
      return map;
    }).toList();
  }
}
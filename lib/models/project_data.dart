import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

class ProjectData {
  final String title;
  final String projectFolderPath;
  final String currentCaseNumber;
  final DateTime lastModified;
  final String filePath;
  final String status;
  final DateTime? shippingDate;
  
  // 担当者情報
  final String? lastUpdatedBy;
  final String? plCreatedBy;
  final DateTime? plCreatedAt;

  // 内部的にはフラットなリストとして保持し続ける（UI表示・Excel出力用）
  final List<List<String>> nifudaDataRaw;
  final List<List<String>> productListDataRaw;

  ProjectData({
    required this.title,
    required this.projectFolderPath,
    required this.currentCaseNumber,
    required this.lastModified,
    required this.filePath,
    required this.status,
    this.shippingDate,
    this.lastUpdatedBy,
    this.plCreatedBy,
    this.plCreatedAt,
    required this.nifudaDataRaw,
    required this.productListDataRaw,
  });

  // ★ 追加: データに含まれる全てのCase No.を取得してソートして返す
  List<String> get availableCaseNumbers {
    if (nifudaDataRaw.isEmpty) return [];
    
    final header = nifudaHeader;
    final caseIndex = header.indexOf('Case No.');
    
    if (caseIndex == -1) return []; // Case No.列がない場合

    final cases = <String>{};
    // データ行（1行目以降）からCase No.を収集
    for (var i = 1; i < nifudaDataRaw.length; i++) {
      final row = nifudaDataRaw[i];
      if (row.length > caseIndex) {
        final val = row[caseIndex];
        if (val.isNotEmpty) {
          cases.add(val);
        }
      }
    }
    
    // ソート処理 (#1, #2, #10 のように数値順になるよう配慮)
    final sorted = cases.toList();
    sorted.sort((a, b) {
      final int? numA = int.tryParse(a.replaceAll(RegExp(r'[^0-9]'), ''));
      final int? numB = int.tryParse(b.replaceAll(RegExp(r'[^0-9]'), ''));
      if (numA != null && numB != null) {
        return numA.compareTo(numB);
      }
      return a.compareTo(b);
    });
    
    return sorted;
  }

  /// ファイルからプロジェクトデータを読み込む
  static Future<ProjectData> fromFile(File file) async {
    final content = await file.readAsString();
    final Map<String, dynamic> json = jsonDecode(content);

    List<List<String>> nifuda = [];
    List<List<String>> product = [];

    // --- データの復元ロジック ---
    if (json.containsKey('cases')) {
      // ★ 新フォーマット
      
      if (json['nifudaHeader'] != null) {
        nifuda.add(List<String>.from(json['nifudaHeader']));
      } else {
        nifuda.add(['製番', '項目番号', '品名', '形式', '個数', '図書番号', '摘要', '手配コード', 'Case No.']);
      }

      if (json['productListHeader'] != null) {
        product.add(List<String>.from(json['productListHeader']));
      } else {
        product.add(['ORDER No.', 'ITEM OF SPARE', '品名記号', '形格', '製品コード番号', '注文数', '記事', '備考', '照合済Case']);
      }

      final Map<String, dynamic> cases = json['cases'];
      final sortedKeys = cases.keys.toList()..sort((a, b) {
        final int? numA = int.tryParse(a.replaceAll('#', ''));
        final int? numB = int.tryParse(b.replaceAll('#', ''));
        if (numA != null && numB != null) {
          return numA.compareTo(numB);
        }
        return a.compareTo(b);
      });

      for (var key in sortedKeys) {
        final caseData = cases[key];
        if (caseData is Map) {
          if (caseData['nifuda'] != null) {
            for (var row in caseData['nifuda']) {
              nifuda.add(List<String>.from(row));
            }
          }
          if (caseData['products'] != null) {
            for (var row in caseData['products']) {
              product.add(List<String>.from(row));
            }
          }
        }
      }

    } else {
      // ★ 旧フォーマット
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
      nifuda = convertToList(json['nifudaData']);
      product = convertToList(json['productListKariData']);
    }

    // --- メタデータの読み込み ---
    final modified = await file.lastModified();
    final status = json['status']?.toString() ?? '現場検品完了';

    DateTime? shippingDate;
    if (json['shippingDate'] != null) {
      try {
        shippingDate = DateTime.parse(json['shippingDate']);
      } catch (e) {}
    }

    DateTime? plCreatedAt;
    if (json['plCreatedAt'] != null) {
      try {
        plCreatedAt = DateTime.parse(json['plCreatedAt']);
      } catch (e) {}
    }

    return ProjectData(
      title: json['projectTitle']?.toString() ?? '名称未設定',
      projectFolderPath: json['projectFolderPath']?.toString() ?? '',
      currentCaseNumber: json['currentCaseNumber']?.toString() ?? '#1',
      lastModified: modified,
      filePath: file.path,
      status: status,
      shippingDate: shippingDate,
      lastUpdatedBy: json['lastUpdatedBy']?.toString(),
      plCreatedBy: json['plCreatedBy']?.toString(),
      plCreatedAt: plCreatedAt,
      nifudaDataRaw: nifuda,
      productListDataRaw: product,
    );
  }

  /// プロジェクトデータをJSON形式に変換
  Map<String, dynamic> toJson() {
    Map<String, dynamic> casesMap = {};

    // 1. 荷札データのグループ化
    if (nifudaDataRaw.length > 1) {
      final header = nifudaDataRaw.first;
      final caseColIndex = header.indexOf('Case No.');

      for (int i = 1; i < nifudaDataRaw.length; i++) {
        final row = nifudaDataRaw[i];
        String caseNo = 'Unknown';
        if (caseColIndex != -1 && row.length > caseColIndex) {
          caseNo = row[caseColIndex];
        }
        if (caseNo.isEmpty) caseNo = 'Unknown';

        if (!casesMap.containsKey(caseNo)) {
          casesMap[caseNo] = {'nifuda': [], 'products': []};
        }
        casesMap[caseNo]!['nifuda'].add(row);
      }
    }

    // 2. 製品リストデータのグループ化
    if (productListDataRaw.length > 1) {
      final header = productListDataRaw.first;
      final matchColIndex = header.indexOf('照合済Case');

      for (int i = 1; i < productListDataRaw.length; i++) {
        final row = productListDataRaw[i];
        String matchedCase = '';
        if (matchColIndex != -1 && row.length > matchColIndex) {
          matchedCase = row[matchColIndex];
        } else if (row.length > 8) {
           matchedCase = row[8];
        }

        String groupKey = matchedCase.isNotEmpty ? matchedCase : 'Unmatched';

        if (!casesMap.containsKey(groupKey)) {
          casesMap[groupKey] = {'nifuda': [], 'products': []};
        }
        casesMap[groupKey]!['products'].add(row);
      }
    }

    return {
      'projectTitle': title,
      'projectFolderPath': projectFolderPath,
      'currentCaseNumber': currentCaseNumber,
      'status': status,
      'shippingDate': shippingDate?.toIso8601String(),
      'lastUpdatedBy': lastUpdatedBy,
      'plCreatedBy': plCreatedBy,
      'plCreatedAt': plCreatedAt?.toIso8601String(),
      'nifudaHeader': nifudaDataRaw.isNotEmpty ? nifudaDataRaw.first : [],
      'productListHeader': productListDataRaw.isNotEmpty ? productListDataRaw.first : [],
      'cases': casesMap,
    };
  }

  ProjectData copyWith({
    String? status, 
    String? filePath,
    DateTime? shippingDate,
    String? lastUpdatedBy,
    String? plCreatedBy,
    DateTime? plCreatedAt,
    List<List<String>>? nifudaDataRaw,
    List<List<String>>? productListDataRaw,
  }) {
    return ProjectData(
      title: title,
      projectFolderPath: projectFolderPath,
      currentCaseNumber: currentCaseNumber,
      lastModified: DateTime.now(),
      filePath: filePath ?? this.filePath,
      status: status ?? this.status,
      shippingDate: shippingDate ?? this.shippingDate,
      lastUpdatedBy: lastUpdatedBy ?? this.lastUpdatedBy,
      plCreatedBy: plCreatedBy ?? this.plCreatedBy,
      plCreatedAt: plCreatedAt ?? this.plCreatedAt,
      nifudaDataRaw: nifudaDataRaw ?? List.from(this.nifudaDataRaw.map((e) => List<String>.from(e))),
      productListDataRaw: productListDataRaw ?? List.from(this.productListDataRaw.map((e) => List<String>.from(e))),
    );
  }

  // --- Helpers ---
  List<String> get nifudaHeader => nifudaDataRaw.isNotEmpty ? nifudaDataRaw.first : [];
  List<List<String>> get nifudaRows => nifudaDataRaw.length > 1 ? nifudaDataRaw.sublist(1) : [];
  List<String> get productHeader => productListDataRaw.isNotEmpty ? productListDataRaw.first : [];
  List<List<String>> get productRows => productListDataRaw.length > 1 ? productListDataRaw.sublist(1) : [];

  List<Map<String, String>> getNifudaMapListForMatching(String targetCase) {
    if (nifudaDataRaw.isEmpty) return [];
    final header = nifudaHeader;
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
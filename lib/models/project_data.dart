import 'dart:convert';
import 'dart:io';

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

  static Future<ProjectData> fromFile(File file) async {
    final content = await file.readAsString();
    final Map<String, dynamic> json = jsonDecode(content);

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

  Map<String, dynamic> toJson() {
    return {
      'projectTitle': title,
      'projectFolderPath': projectFolderPath,
      'currentCaseNumber': currentCaseNumber,
      'status': status,
      'shippingDate': shippingDate?.toIso8601String(),
      'lastUpdatedBy': lastUpdatedBy,
      'plCreatedBy': plCreatedBy,
      'plCreatedAt': plCreatedAt?.toIso8601String(),
      'nifudaData': nifudaDataRaw,
      'productListKariData': productListDataRaw,
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
import 'dart:io';
import 'package:excel/excel.dart';
import 'package:path/path.dart' as p;
import '../models/project_data.dart';

class ExcelExporter {
  /// プロジェクトデータをExcelとして保存
  static Future<String> export(ProjectData project, String directoryPath) async {
    var excel = Excel.createExcel();
    
    // シート1: 荷札リスト
    _addSheet(excel, '荷札リスト', project.nifudaHeader, project.nifudaRows);
    
    // シート2: 製品リスト
    _addSheet(excel, '製品リスト', project.productHeader, project.productRows);

    // デフォルトの "Sheet1" を削除
    if (excel.sheets.containsKey('Sheet1')) {
      excel.delete('Sheet1');
    }

    // ファイル保存
    final fileName = '${project.title}_Export.xlsx';
    final filePath = p.join(directoryPath, fileName);
    final fileBytes = excel.save();

    if (fileBytes != null) {
      File(filePath)
        ..createSync(recursive: true)
        ..writeAsBytesSync(fileBytes);
    }

    return filePath;
  }

  static void _addSheet(Excel excel, String sheetName, List<String> header, List<List<String>> rows) {
    Sheet sheet = excel[sheetName];
    
    // ヘッダー書き込み
    sheet.appendRow(header.map((e) => TextCellValue(e)).toList());
    
    // データ書き込み
    for (var row in rows) {
      sheet.appendRow(row.map((e) => TextCellValue(e)).toList());
    }
  }
}
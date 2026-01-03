import 'package:flutter/material.dart';
import '../models/project_data.dart';
import '../utils/product_matcher.dart';

class MatchingResultTab extends StatefulWidget {
  final ProjectData project;

  const MatchingResultTab({super.key, required this.project});

  @override
  State<MatchingResultTab> createState() => _MatchingResultTabState();
}

class _MatchingResultTabState extends State<MatchingResultTab> {
  bool _isLoading = true;
  Map<String, dynamic>? _matchingResult;
  final ProductMatcher _matcher = ProductMatcher();

  @override
  void initState() {
    super.initState();
    _runMatching();
  }

  @override
  void didUpdateWidget(covariant MatchingResultTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.project.filePath != widget.project.filePath) {
      _runMatching();
    }
  }

  Future<void> _runMatching() async {
    setState(() => _isLoading = true);

    // UI更新用に少し待機
    await Future.delayed(const Duration(milliseconds: 100)); 

    // ★ 修正箇所: ここでProjectDataに追加した「安全な取得メソッド」を使用する
    // これにより、列の順番が変わっていても、正しいキー（'製番'など）が入ったMapが渡される
    final nifudaMap = widget.project.getNifudaMapListForMatching(widget.project.currentCaseNumber);
    final productMap = widget.project.getProductMapListForMatching();

    final result = await _matcher.match(
      nifudaMap,
      productMap,
      pattern: 'T社（製番・項目番号）', 
      currentCaseNumber: widget.project.currentCaseNumber,
    );

    if (mounted) {
      setState(() {
        _matchingResult = result;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_matchingResult == null) {
      return const Center(child: Text('照合に失敗しました'));
    }

    final matched = (_matchingResult!['matched'] as List).cast<Map<String, dynamic>>();
    final unmatched = (_matchingResult!['unmatched'] as List).cast<Map<String, dynamic>>();
    
    final allRows = [...unmatched, ...matched];

    if (allRows.isEmpty) {
      return const Center(child: Text('照合対象データがありません'));
    }

    // 表示用カラム定義（照合結果画面で表示したい項目）
    const displayFields = ['製番', '項目番号', '品名', '形式', '個数', '図書番号', '手配コード', '記事'];
    const displayFieldsMap = {
      '製番': 'ORDER No.',
      '項目番号': 'ITEM OF SPARE',
      '品名': '品名記号',
      '形式': '形格',
      '個数': '注文数',
      '図書番号': '製品コード番号',
      '手配コード': '製品コード番号',
      '記事': '記事',
    };

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Text(
            '照合結果 (Case: ${widget.project.currentCaseNumber}) - 一致:${matched.length}件 / 不一致・未検出:${unmatched.length}件',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
        ),
        Expanded(
          child: Scrollbar(
            thumbVisibility: true,
            trackVisibility: true,
            child: SingleChildScrollView(
              scrollDirection: Axis.vertical,
              child: Scrollbar(
                thumbVisibility: true,
                trackVisibility: true,
                notificationPredicate: (n) => n.depth == 1,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    headingRowColor: MaterialStateProperty.all(Colors.indigo[50]),
                    columns: [
                      const DataColumn(label: Text('項目')),
                      const DataColumn(label: Text('結果')),
                      ...displayFields.map((f) => DataColumn(label: Text(f))),
                    ],
                    rows: allRows.expand((row) {
                      final status = row['照合ステータス'] as String;
                      final nifuda = row['nifuda'] as Map? ?? {};
                      final product = row['product'] as Map? ?? {};
                      final mismatchFields = (row['不一致項目リスト'] as List?)?.cast<String>() ?? [];
                      
                      final isMatched = status.contains('一致') || status.contains('再');
                      final isError = !isMatched;
                      
                      Color baseColor = isMatched ? Colors.white : Colors.red[50]!;
                      if (status.contains('スキップ')) baseColor = Colors.yellow[50]!;

                      // 荷札行
                      final nifudaRow = DataRow(
                        color: MaterialStateProperty.all(baseColor),
                        cells: [
                          const DataCell(Text('荷札', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.indigo))),
                          DataCell(Text(status, style: TextStyle(fontWeight: FontWeight.bold, color: isError ? Colors.red : Colors.green))),
                          ...displayFields.map((field) {
                            final val = nifuda[field]?.toString() ?? '---';
                            return DataCell(Text(val));
                          }),
                        ],
                      );

                      // 製品行
                      final productRow = DataRow(
                        color: MaterialStateProperty.all(baseColor),
                        cells: [
                          const DataCell(Text('リスト', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.teal))),
                          DataCell(Text(row['詳細']?.toString() ?? '', style: const TextStyle(fontSize: 11))),
                          ...displayFields.map((field) {
                            final pField = displayFieldsMap[field];
                            String val = '---';
                            if (pField != null) {
                              // 特殊対応
                              if (field == '品名') {
                                final h = product['品名記号']?.toString() ?? '';
                                final k = product['記事']?.toString() ?? '';
                                val = h.isNotEmpty ? h : k;
                              } else {
                                val = product[pField]?.toString() ?? '';
                              }
                            }
                            
                            // 不一致ハイライト
                            bool isMismatch = mismatchFields.any((m) => m.contains(field));
                            return DataCell(
                              Container(
                                color: isMismatch ? Colors.red[100] : null,
                                padding: const EdgeInsets.symmetric(horizontal: 4),
                                alignment: Alignment.centerLeft,
                                width: double.infinity,
                                height: double.infinity,
                                child: Text(val, style: TextStyle(
                                  color: isMismatch ? Colors.red[900] : Colors.black87,
                                  fontWeight: isMismatch ? FontWeight.bold : FontWeight.normal
                                )),
                              )
                            );
                          }),
                        ],
                      );

                      return [nifudaRow, productRow];
                    }).toList(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
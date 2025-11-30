import 'package:flutter/material.dart';

class DataViewTab extends StatelessWidget {
  final List<String> headers;
  final List<List<String>> rows;
  final int? filterColumnIndex;
  final String? filterValue;

  const DataViewTab({
    super.key,
    required this.headers,
    required this.rows,
    this.filterColumnIndex,
    this.filterValue,
  });

  @override
  Widget build(BuildContext context) {
    if (headers.isEmpty) {
      return const Center(child: Text('データがありません'));
    }

    // フィルタリング処理
    final displayRows = (filterColumnIndex != null && filterValue != null && filterColumnIndex! >= 0)
        ? rows.where((row) => row.length > filterColumnIndex! && row[filterColumnIndex!] == filterValue).toList()
        : rows;

    if (displayRows.isEmpty) {
      return const Center(child: Text('表示対象のデータがありません'));
    }

    return Scrollbar(
      thumbVisibility: true,
      trackVisibility: true,
      child: SingleChildScrollView(
        scrollDirection: Axis.vertical,
        child: Scrollbar(
          thumbVisibility: true,
          trackVisibility: true,
          notificationPredicate: (notification) => notification.depth == 1,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowColor: MaterialStateProperty.all(Colors.grey[200]),
              columns: headers.map((h) => DataColumn(
                label: Text(h, style: const TextStyle(fontWeight: FontWeight.bold)),
              )).toList(),
              rows: displayRows.asMap().entries.map((entry) {
                final index = entry.key;
                final row = entry.value;
                final isAlternate = index % 2 == 1;
                return DataRow(
                  color: MaterialStateProperty.resolveWith<Color?>((Set<MaterialState> states) {
                    if (states.contains(MaterialState.selected)) {
                      return Theme.of(context).colorScheme.primary.withOpacity(0.08);
                    }
                    return isAlternate ? Colors.grey[50] : null;
                  }),
                  cells: row.map((cell) => DataCell(Text(cell))).toList(),
                );
              }).toList(),
            ),
          ),
        ),
      ),
    );
  }
}
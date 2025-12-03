import 'package:flutter/material.dart';

class DataViewTab extends StatefulWidget {
  final List<String> headers;
  final List<List<String>> rows;
  final int? filterColumnIndex;
  final String? filterValue;
  final Function(List<List<String>> newRows)? onRowsChanged;

  const DataViewTab({
    super.key,
    required this.headers,
    required this.rows,
    this.filterColumnIndex,
    this.filterValue,
    this.onRowsChanged,
  });

  @override
  State<DataViewTab> createState() => _DataViewTabState();
}

class _DataViewTabState extends State<DataViewTab> {
  final TextEditingController _searchController = TextEditingController();
  String _searchText = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() => _searchText = _searchController.text);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _showEditDialog(int originalRowIndex, int cellIndex, String currentValue) async {
    // 編集コールバックが無い（読み取り専用）場合は何もしない
    if (widget.onRowsChanged == null) return;

    final controller = TextEditingController(text: currentValue);
    final newValue = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${widget.headers[cellIndex]} の編集'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('キャンセル')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text), child: const Text('保存')),
        ],
      ),
    );

    if (newValue != null && newValue != currentValue) {
      _updateData(originalRowIndex, cellIndex, newValue);
    }
  }

  void _updateData(int originalRowIndex, int cellIndex, String newValue) {
    if (widget.onRowsChanged == null) return;
    final newRows = widget.rows.map((row) => List<String>.from(row)).toList();
    if (originalRowIndex < newRows.length && cellIndex < newRows[originalRowIndex].length) {
      newRows[originalRowIndex][cellIndex] = newValue;
      widget.onRowsChanged!(newRows);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.headers.isEmpty) return const Center(child: Text('データがありません'));

    var filteredRowsEntries = widget.rows.asMap().entries.toList();

    if (widget.filterColumnIndex != null && widget.filterValue != null && widget.filterColumnIndex! >= 0) {
      filteredRowsEntries = filteredRowsEntries.where((entry) {
        final row = entry.value;
        return row.length > widget.filterColumnIndex! && row[widget.filterColumnIndex!] == widget.filterValue;
      }).toList();
    }

    if (_searchText.isNotEmpty) {
      filteredRowsEntries = filteredRowsEntries.where((entry) {
        return entry.value.any((cell) => cell.contains(_searchText));
      }).toList();
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              labelText: '検索',
              hintText: '製番、品名などを入力...',
              prefixIcon: const Icon(Icons.search),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              suffixIcon: _searchText.isNotEmpty ? IconButton(icon: const Icon(Icons.clear), onPressed: () => _searchController.clear()) : null,
            ),
          ),
        ),
        Expanded(
          child: filteredRowsEntries.isEmpty
              ? const Center(child: Text('表示対象のデータがありません'))
              : Scrollbar(
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
                          showCheckboxColumn: false,
                          columns: widget.headers.map((h) => DataColumn(label: Text(h, style: const TextStyle(fontWeight: FontWeight.bold)))).toList(),
                          rows: filteredRowsEntries.asMap().entries.map((entry) {
                            final displayIndex = entry.key;
                            final originalEntry = entry.value;
                            final originalIndex = originalEntry.key;
                            final row = originalEntry.value;
                            final isAlternate = displayIndex % 2 == 1;
                            
                            return DataRow(
                              color: MaterialStateProperty.resolveWith<Color?>((states) => isAlternate ? Colors.grey[50] : null),
                              cells: row.asMap().entries.map((cellEntry) {
                                final cellIndex = cellEntry.key;
                                final cellValue = cellEntry.value;
                                return DataCell(
                                  InkWell(
                                    onDoubleTap: widget.onRowsChanged != null ? () => _showEditDialog(originalIndex, cellIndex, cellValue) : null,
                                    child: Container(
                                      constraints: const BoxConstraints(minHeight: 40, minWidth: 50),
                                      alignment: Alignment.centerLeft,
                                      padding: const EdgeInsets.symmetric(horizontal: 4),
                                      child: Text(cellValue),
                                    ),
                                  ),
                                );
                              }).toList(),
                            );
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
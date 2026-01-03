import 'package:flutter/foundation.dart';

class ProductMatcher {
  
  Future<Map<String, dynamic>> match(
    List<Map<String, String>> nifudaMapList,
    List<Map<String, String>> productMapList, {
    String pattern = 'T社（製番・項目番号）',
    required String currentCaseNumber,
  }) async {
    debugPrint('=== [ProductMatcher] 照合開始 (パターン: $pattern, Case: $currentCaseNumber) ===');
    debugPrint('荷札 (対象Case): ${nifudaMapList.length}件, 製品リスト (全体): ${productMapList.length}件');
    
    // パターンに応じて呼び出すロジックを分岐
    switch (pattern) {
      case 'T社（製番・項目番号）':
        return await _matchForTCompany(nifudaMapList, productMapList, currentCaseNumber);
      case '汎用（図書番号優先）':
        return await _matchGeneralPurpose(nifudaMapList, productMapList, currentCaseNumber);
      default:
        return await _matchForTCompany(nifudaMapList, productMapList, currentCaseNumber);
    }
  }

  // ★★★ 照合処理 T社（製番・項目番号） - ロジック主体を「製品リスト」に変更 ★★★
  Future<Map<String, dynamic>> _matchForTCompany(
      List<Map<String, String>> nifudaMapList, // (現Case No.でフィルタリング済み)
      List<Map<String, String>> productMapList, // (全データ)
      String currentCaseNumber,
      ) async {
    
    // --- 1. 荷札データをMapに変換 ---
    // (現Case No.の荷札のみが nifudaMapList として渡される前提)
    final nifudaMap = <String, Map<String, String>>{};
    for (final nifuda in nifudaMapList) {
      final key = _normalize(nifuda['製番']) + '-' + _normalize(nifuda['項目番号']);
      // 重複キーの場合は警告（通常、同一Case内では重複しない想定）
      if (nifudaMap.containsKey(key)) {
         debugPrint('Warning: Duplicate nifuda key found in Case $currentCaseNumber: $key');
      }
      nifudaMap[key] = nifuda;
    }
    
    // --- 2. 製品リストを主体にループして照合 ---
    final matched = <Map<String, dynamic>>[];
    final unmatched = <Map<String, dynamic>>[];

    for (final productItem in productMapList) {
      
      // 製品リストの照合キー
      final productKey = _normalize(productItem['ORDER No.']) + '-' + _normalize(productItem['ITEM OF SPARE']);
      
      // 対応する荷札をMapから探す
      final Map<String, String>? potentialNifuda = nifudaMap[productKey];

      // --- 3a. 荷札が見つからなかった場合 ---
      if (potentialNifuda == null) {
        // (荷札未検出)
        // ただし、この製品が「他のCase」で「照合済み」の場合は、アンマッチとして表示する必要はない
        final matchedCase = productItem['照合済Case'];
        if (matchedCase == null || matchedCase.isEmpty) {
          // 他のCaseでも未照合の場合のみ「荷札未検出」としてリストアップ
          unmatched.add({
            'nifuda': {}, // 荷札データなし
            'product': productItem,
            '照合ステータス': '荷札未検出',
            '詳細': '対応する荷札 (Case: $currentCaseNumber) が見つかりませんでした。',
            '不一致項目リスト': [],
          });
        }
        continue; // 次の製品へ
      }

      // --- 3b. 荷札が見つかった場合 ---
      
      // この荷札キーは処理済みとしてMapから削除 (ループ後に残った荷札が「製品未検出」となる)
      nifudaMap.remove(productKey);

      // 製品が「他のCase」で照合済みの場合
      final matchedCase = productItem['照合済Case'];
      if (matchedCase != null && matchedCase.isNotEmpty) {
          // 現Case No. と一致する場合 (＝再照合)
          if (matchedCase == currentCaseNumber) {
             matched.add({
                'nifuda': potentialNifuda,
                'product': productItem,
                '照合ステータス': '照合成功 (再)',
                '詳細': 'このCaseで既に照合済みです。',
                '不一致項目リスト': [],
             });
          } 
          // 他の Case No. と一致する場合
          else {
             unmatched.add({
                'nifuda': potentialNifuda,
                'product': productItem,
                '照合ステータス': '重複照合スキップ',
                '詳細': 'この製品は既に「$matchedCase」で照合済みです。',
                '不一致項目リスト': [],
             });
          }
          continue; // 次の製品へ
      }


      // --- 4. 詳細比較 (7項目) ---
      // (製品がどのCaseとも未照合で、現Caseの荷札が見つかった場合)
      final mismatchFields = <String>[];

      // 1. 製番/ORDER No. (キーなので一致しているはずだが念のため)
      if (!_compareString(potentialNifuda['製番'], productItem['ORDER No.'])) {
        mismatchFields.add('製番/ORDER No.');
      }
      
      // 2. 項目番号/ITEM OF SPARE (キーなので一致しているはずだが念のため)
      if (!_compareString(potentialNifuda['項目番号'], productItem['ITEM OF SPARE'])) {
        mismatchFields.add('項目番号/ITEM OF SPARE');
      }

      // 3. 品名 vs (品名記号 OR 記事)
      final nifudaHinmei = potentialNifuda['品名'];
      final productHinmeiKigou = productItem['品名記号'];
      final productKiji = productItem['記事']; // '記事'列
      
      if (!(_compareString(nifudaHinmei, productHinmeiKigou) || _compareString(nifudaHinmei, productKiji))) {
        mismatchFields.add('品名/(品名記号or記事)');
      }
      
      // 4. 形式 vs 形格
      if (!_compareString(potentialNifuda['形式'], productItem['形格'])) {
        mismatchFields.add('形式/形格');
      }
      
      // 5. 個数 vs 注文数
      if (!_compareString(potentialNifuda['個数'], productItem['注文数'])) {
        mismatchFields.add('個数/注文数');
      }
      
      // 6. 図書番号 vs 製品コード番号
      if (!_compareString(potentialNifuda['図書番号'], productItem['製品コード番号'])) {
        mismatchFields.add('図書番号/製品コード番号');
      }
      
      // 7. 手配コード vs 製品コード番号
      if (!_compareString(potentialNifuda['手配コード'], productItem['製品コード番号'])) {
        mismatchFields.add('手配コード/製品コード番号');
      }
      // --- 詳細比較ここまで ---

      if (mismatchFields.isEmpty) {
        // 照合成功
        matched.add({
          'nifuda': potentialNifuda,
          'product': productItem,
          '照合ステータス': '一致',
          '詳細': '全ての項目が一致しました',
          '不一致項目リスト': [],
        });
        
      } else {
        // 項目不一致
        unmatched.add({
          'nifuda': potentialNifuda,
          'product': productItem,
          '照合ステータス': '不一致',
          '詳細': '${mismatchFields.join("、")}が不一致です',
          '不一致項目リスト': mismatchFields,
        });
      }
    } // --- 製品リストのループ終了 ---

    // --- 5. 製品リスト未検出の荷札を追加 ---
    // (ループが終わり、nifudaMapに残っている荷札 = 対応する製品がなかった荷札)
    for (final remainingNifuda in nifudaMap.values) {
       unmatched.add({
          'nifuda': remainingNifuda,
          'product': {}, // 製品データなし
          '照合ステータス': '製品リスト未検出',
          '詳細': 'この荷札に対応する製品リスト項目が見つかりませんでした。',
          '不一致項目リスト': [],
       });
    }

    debugPrint('照合完了: 一致 ${matched.length}, 不一致/未検出 ${unmatched.length}');
    return {
      'matched': matched,
      'unmatched': unmatched,
      'missing': [], // 'unmatched' に統合済み
      'currentCaseNumber': currentCaseNumber,
    };
  }

  // 照合処理 汎用（図書番号優先）
  Future<Map<String, dynamic>> _matchGeneralPurpose(
      List<Map<String, String>> nifudaMapList, 
      List<Map<String, String>> productMapList,
      String currentCaseNumber,
      ) async {
    // ★ 汎用ロジック（現在はT社と同じものを流用）
    // TODO: 将来的に汎用ロジックをここに実装
    return _matchForTCompany(nifudaMapList, productMapList, currentCaseNumber);
  }


  // 共通のヘルパー関数
  String _normalize(String? s) {
    if (s == null) return '';
    return s.trim().toUpperCase().replaceAll(RegExp(r'[-_ ]'), '');
  }

  bool _compareString(String? s1, String? s2) {
    return _normalize(s1) == _normalize(s2);
  }
}
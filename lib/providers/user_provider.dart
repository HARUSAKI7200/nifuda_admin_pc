import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class UserNotifier extends StateNotifier<String> {
  UserNotifier() : super('');

  static const _keyUserList = 'saved_user_list';
  static const _keyCurrentUser = 'login_user_name';

  /// 最後にログインしていたユーザーを読み込む
  Future<void> loadLastLoginUser() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getString(_keyCurrentUser) ?? '';
  }

  /// 保存されているユーザーリストを取得
  Future<List<String>> getSavedUsers() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_keyUserList) ?? [];
  }

  /// 新規ユーザーを追加して保存
  Future<void> addUser(String name) async {
    final prefs = await SharedPreferences.getInstance();
    final users = prefs.getStringList(_keyUserList) ?? [];
    
    if (!users.contains(name)) {
      users.add(name);
      await prefs.setStringList(_keyUserList, users);
    }
  }

  /// ユーザーを削除
  Future<void> deleteUser(String name) async {
    final prefs = await SharedPreferences.getInstance();
    final users = prefs.getStringList(_keyUserList) ?? [];
    
    users.remove(name);
    await prefs.setStringList(_keyUserList, users);
    
    // もし削除したユーザーでログイン中ならログアウト状態にする
    if (state == name) {
      logout();
    }
  }

  /// ログイン（現在のユーザーとして設定）
  Future<void> login(String name) async {
    final prefs = await SharedPreferences.getInstance();
    
    // 現在のユーザーとして保存
    await prefs.setString(_keyCurrentUser, name);
    state = name;

    // リストになければ追加（念のため）
    await addUser(name);
  }

  /// ログアウト
  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyCurrentUser);
    state = '';
  }
}

final userProvider = StateNotifierProvider<UserNotifier, String>((ref) {
  return UserNotifier();
});
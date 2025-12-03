import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class UserNotifier extends StateNotifier<String> {
  UserNotifier() : super('');

  Future<void> loadUser() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getString('login_user_name') ?? '';
  }

  Future<void> login(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('login_user_name', name);
    state = name;
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('login_user_name');
    state = '';
  }
}

final userProvider = StateNotifierProvider<UserNotifier, String>((ref) {
  return UserNotifier();
});
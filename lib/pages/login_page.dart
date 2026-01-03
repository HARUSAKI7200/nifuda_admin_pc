import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/user_provider.dart';
import 'dashboard_page.dart';

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  List<String> _savedUsers = [];
  bool _isLoading = true;
  bool _isEditing = false; // 削除モードフラグ

  @override
  void initState() {
    super.initState();
    _checkAutoLoginAndLoadUsers();
  }

  Future<void> _checkAutoLoginAndLoadUsers() async {
    final notifier = ref.read(userProvider.notifier);
    
    // 1. 保存されたユーザーリストを取得
    final users = await notifier.getSavedUsers();
    
    // 2. 最後のログインユーザーを確認
    await notifier.loadLastLoginUser();
    final currentUser = ref.read(userProvider);

    if (currentUser.isNotEmpty && mounted) {
      // 既にログイン状態（前回終了時）ならダッシュボードへ
      _navigateToDashboard();
    } else {
      // ユーザー選択画面を表示
      setState(() {
        _savedUsers = users;
        _isLoading = false;
      });
    }
  }

  Future<void> _loadUsers() async {
    final users = await ref.read(userProvider.notifier).getSavedUsers();
    setState(() {
      _savedUsers = users;
    });
  }

  // ログイン処理
  void _login(String name) async {
    await ref.read(userProvider.notifier).login(name);
    if (mounted) {
      _navigateToDashboard();
    }
  }

  void _navigateToDashboard() {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const DashboardPage()),
    );
  }

  // アカウント作成ダイアログ
  void _showCreateAccountDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('アカウント作成'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '氏名',
            hintText: '例: 山田 太郎',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isNotEmpty) {
                // 重複チェック
                if (_savedUsers.contains(name)) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('その名前は既に登録されています')),
                  );
                  return;
                }
                
                await ref.read(userProvider.notifier).addUser(name);
                await _loadUsers(); // リスト再読み込み
                if (context.mounted) Navigator.pop(context);
                
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('アカウント「$name」を作成しました')),
                  );
                }
              }
            },
            child: const Text('作成'),
          ),
        ],
      ),
    );
  }

  // アカウント削除
  void _deleteAccount(String name) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('アカウント削除'),
        content: Text('「$name」を削除しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('削除'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await ref.read(userProvider.notifier).deleteUser(name);
      await _loadUsers();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      backgroundColor: Colors.indigo[50],
      appBar: AppBar(
        title: const Text('ユーザーログイン'),
        backgroundColor: Colors.indigo,
        foregroundColor: Colors.white,
        actions: [
          if (_savedUsers.isNotEmpty)
            IconButton(
              icon: Icon(_isEditing ? Icons.check : Icons.edit),
              tooltip: _isEditing ? '編集完了' : 'リスト編集',
              onPressed: () {
                setState(() {
                  _isEditing = !_isEditing;
                });
              },
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 500),
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.lock_person, size: 80, color: Colors.indigo),
              const SizedBox(height: 32),
              
              Text(
                _savedUsers.isEmpty ? 'アカウントを作成してください' : 'アカウントを選択',
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.black87),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),

              // ユーザーリスト
              if (_savedUsers.isNotEmpty)
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _savedUsers.length,
                    separatorBuilder: (context, index) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final user = _savedUsers[index];
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: Colors.indigo[100],
                          foregroundColor: Colors.indigo,
                          child: Text(user.isNotEmpty ? user[0] : '?'),
                        ),
                        title: Text(user, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
                        trailing: _isEditing
                            ? IconButton(
                                icon: const Icon(Icons.delete, color: Colors.red),
                                onPressed: () => _deleteAccount(user),
                              )
                            : const Icon(Icons.arrow_forward_ios, size: 16, color: Colors.grey),
                        onTap: _isEditing ? null : () => _login(user),
                      );
                    },
                  ),
                ),

              const SizedBox(height: 24),

              // アカウント作成ボタン
              OutlinedButton.icon(
                onPressed: _showCreateAccountDialog,
                icon: const Icon(Icons.add),
                label: const Text('新しいアカウントを作成'),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: Colors.white,
                  side: const BorderSide(color: Colors.indigo),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
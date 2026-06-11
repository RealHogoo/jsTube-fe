import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import 'http_client.dart';

void main() {
  runApp(const JsTubeApp());
}

class AppConfig {
  static const apiBase =
      String.fromEnvironment('MEDIA_API_BASE', defaultValue: '');
  static const adminBase = String.fromEnvironment('ADMIN_BASE_URL',
      defaultValue: 'http://localhost:8081');
  static const webhardBase = String.fromEnvironment('WEBHARD_BASE_URL',
      defaultValue: 'http://localhost:8083');
  static const apkDownloadUrl = String.fromEnvironment('APK_DOWNLOAD_URL',
      defaultValue: '/downloads/jstube-tv.apk');

  static String apiUrl(String path) {
    if (path.startsWith('http')) return path;
    if (apiBase.isEmpty) return path;
    return '${apiBase.replaceAll(RegExp(r'/$'), '')}$path';
  }
}

class AuthSession extends ChangeNotifier {
  AuthSession._();

  static final instance = AuthSession._();

  String _token = '';
  String _refreshToken = '';
  String _userId = '';
  bool _isAdmin = false;
  bool _cookieAuthenticated = false;
  Map<String, bool> _permissions = const {};

  String get token => _token;
  String get userId => _userId;
  bool get isAuthenticated => _token.isNotEmpty || _cookieAuthenticated;
  bool get canWrite => _isAdmin || (_permissions['write'] ?? false);

  Map<String, String> get authHeaders =>
      _token.isEmpty ? const {} : {'Authorization': 'Bearer $_token'};

  void updateFromLogin(Map<String, dynamic> data, {bool notify = true}) {
    final user = data['user'] is Map<String, dynamic>
        ? data['user'] as Map<String, dynamic>
        : const <String, dynamic>{};
    _token = '${data['token'] ?? ''}'.trim();
    _refreshToken = '${data['refresh_token'] ?? ''}'.trim();
    _cookieAuthenticated = false;
    _userId = '${user['user_id'] ?? ''}'.trim();
    _isAdmin = user['super_admin'] == true ||
        ((user['roles'] as List?) ?? const [])
            .map((item) => '$item')
            .any((role) => role == 'ROLE_ADMIN' || role == 'ROLE_SUPER_ADMIN');
    if (notify) notifyListeners();
  }

  void updateFromMe(Map<String, dynamic> data) {
    _userId = '${data['user_id'] ?? _userId}'.trim();
    _isAdmin = data['is_admin'] == true;
    _cookieAuthenticated = _userId.isNotEmpty;
    final rawPermissions = data['permissions'];
    if (rawPermissions is Map) {
      _permissions = rawPermissions.map(
          (key, value) => MapEntry('$key', value == true || '$value' == 'true'));
    }
    notifyListeners();
  }

  void clear() {
    _token = '';
    _refreshToken = '';
    _userId = '';
    _isAdmin = false;
    _cookieAuthenticated = false;
    _permissions = const {};
    notifyListeners();
  }
}

class AuthRepository {
  final http.Client _client;

  AuthRepository([http.Client? client])
      : _client = client ?? createAppHttpClient();

  Future<void> login(String userId, String password) async {
    final response = await _client.post(
      Uri.parse(AppConfig.adminBase.replaceAll(RegExp(r'/$'), '') + '/login.json'),
      headers: const {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'user_id': userId, 'user_pw': password}),
    );
    final decoded = response.body.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(response.body) as Map<String, dynamic>;
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        decoded['ok'] != true) {
      throw ApiException(
          decoded['message']?.toString() ?? '로그인에 실패했습니다.',
          response.statusCode);
    }
    final data = decoded['data'];
    if (data is! Map<String, dynamic> || '${data['token'] ?? ''}'.isEmpty) {
      throw ApiException('로그인 토큰을 받을 수 없습니다.', response.statusCode);
    }
    AuthSession.instance.updateFromLogin(data, notify: false);
    try {
      final me = await ApiClient().getJson('/api/me/');
      AuthSession.instance.updateFromMe(me);
    } catch (_) {
      AuthSession.instance.clear();
      rethrow;
    }
  }

  Future<bool> restoreSession() async {
    try {
      final me = await ApiClient().getJson('/api/me/');
      AuthSession.instance.updateFromMe(me);
      return true;
    } catch (_) {
      return false;
    }
  }
}

class JsTubeApp extends StatelessWidget {
  const JsTubeApp({super.key});

  @override
  Widget build(BuildContext context) {
    final tvMode = Uri.base.queryParameters['karaoke_tv'] == '1';
    return MaterialApp(
      title: 'jsTube',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xff2563eb), brightness: Brightness.light),
        fontFamily: 'NotoSansKR',
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xfffacc15), brightness: Brightness.dark),
      ),
      themeMode: tvMode ? ThemeMode.dark : ThemeMode.system,
      home: AuthGate(child: tvMode ? const KaraokeTvScreen() : const MediaShell()),
    );
  }
}

class ApiClient {
  final http.Client _client;

  ApiClient([http.Client? client]) : _client = client ?? createAppHttpClient();

  Future<Map<String, dynamic>> getJson(String path,
      [Map<String, String>? query]) async {
    final uri =
        Uri.parse(AppConfig.apiUrl(path)).replace(queryParameters: query);
    final response = await _client.get(uri, headers: {
      'Accept': 'application/json',
      ...AuthSession.instance.authHeaders,
    });
    return _decode(response);
  }

  Future<Map<String, dynamic>> postJson(String path, [Object? body]) async {
    final response = await _client.post(
      Uri.parse(AppConfig.apiUrl(path)),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        ...AuthSession.instance.authHeaders,
      },
      body: body == null ? null : jsonEncode(body),
    );
    return _decode(response);
  }

  Map<String, dynamic> _decode(http.Response response) {
    final decoded = _decodeJsonObject(response);
    if (response.statusCode == 401 || response.statusCode == 403) {
      if (response.statusCode == 401) AuthSession.instance.clear();
      throw ApiException(
          decoded['message']?.toString() ?? '로그인이 필요합니다.', response.statusCode);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiException(
          decoded['message']?.toString() ?? 'HTTP ${response.statusCode}',
          response.statusCode);
    }
    if (decoded['ok'] == false) {
      throw ApiException(
          decoded['message']?.toString() ?? '요청에 실패했습니다.', response.statusCode);
    }
    final data = decoded['data'];
    return data is Map<String, dynamic> ? data : decoded;
  }

  Map<String, dynamic> _decodeJsonObject(http.Response response) {
    if (response.body.isEmpty) {
      return <String, dynamic>{};
    }
    try {
      final decoded = jsonDecode(response.body);
      return decoded is Map<String, dynamic>
          ? decoded
          : <String, dynamic>{'message': '${response.statusCode}'};
    } catch (_) {
      final body = response.body.trim();
      return <String, dynamic>{
        'message': body.isEmpty
            ? 'HTTP ${response.statusCode}'
            : body.substring(0, body.length > 160 ? 160 : body.length),
      };
    }
  }
}

class AuthGate extends StatefulWidget {
  final Widget child;

  const AuthGate({super.key, required this.child});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  final auth = AuthRepository();
  var checking = true;

  @override
  void initState() {
    super.initState();
    unawaited(_restoreSession());
  }

  Future<void> _restoreSession() async {
    await auth.restoreSession();
    if (mounted) {
      setState(() => checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (checking) {
      return const Scaffold(
        backgroundColor: Color(0xfff3efe5),
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return widget.child;
  }
}

class ApiException implements Exception {
  final String message;
  final int statusCode;

  ApiException(this.message, this.statusCode);

  @override
  String toString() => message;
}

class MediaItem {
  final int id;
  final String title;
  final String fileName;
  final String kind;
  final String thumbnailUrl;
  final String contentUrl;
  final String karaokeNumber;
  final List<String> tags;
  final int fileSize;

  MediaItem({
    required this.id,
    required this.title,
    required this.fileName,
    required this.kind,
    required this.thumbnailUrl,
    required this.contentUrl,
    required this.karaokeNumber,
    required this.tags,
    required this.fileSize,
  });

  factory MediaItem.fromJson(Map<String, dynamic> json) {
    final tags = <String>[
      ...((json['tags'] as List?) ?? const []).map((item) => item.toString()),
      ...((json['webhard_tags'] as List?) ?? const [])
          .map((item) => item.toString()),
    ];
    return MediaItem(
      id: int.tryParse('${json['webhard_file_id'] ?? 0}') ?? 0,
      title:
          '${json['title'] ?? json['display_name'] ?? json['file_name'] ?? 'Untitled'}',
      fileName: '${json['file_name'] ?? ''}',
      kind: '${json['content_kind'] ?? ''}',
      thumbnailUrl: _absoluteUrl('${json['thumbnail_url'] ?? ''}'),
      contentUrl: _absoluteUrl('${json['content_url'] ?? ''}'),
      karaokeNumber: _karaokeNumber(json, tags),
      tags: tags,
      fileSize: int.tryParse('${json['file_size'] ?? 0}') ?? 0,
    );
  }

  static String _absoluteUrl(String url) {
    if (url.isEmpty) {
      return url;
    }
    final absolute = url.startsWith('http') || AppConfig.apiBase.isEmpty
        ? url
        : AppConfig.apiUrl(url);
    return _authenticatedFileUrl(absolute);
  }

  static String _authenticatedFileUrl(String url) {
    if (!url.contains('-file/')) return url;
    final token = AuthSession.instance.token;
    if (token.isEmpty) return url;
    final uri = Uri.parse(url);
    return uri
        .replace(queryParameters: {
          ...uri.queryParameters,
          'access_token': token,
        })
        .toString();
  }

  static String _karaokeNumber(Map<String, dynamic> json, List<String> tags) {
    final existing = '${json['karaoke_number'] ?? ''}'.trim();
    if (existing.isNotEmpty) return existing;
    for (final tag in tags) {
      final ky =
          RegExp(r'KY\.?([0-9]{3,7})', caseSensitive: false).firstMatch(tag);
      if (ky != null) return 'KY.${ky.group(1)}';
      if (RegExp(r'^[0-9]{3,7}$').hasMatch(tag)) return 'KY.$tag';
    }
    final text =
        '${json['title'] ?? ''} ${json['display_name'] ?? ''} ${json['file_name'] ?? ''}';
    final match =
        RegExp(r'KY\.?([0-9]{3,7})', caseSensitive: false).firstMatch(text);
    return match == null ? '' : 'KY.${match.group(1)}';
  }
}

class MediaRepository {
  final ApiClient api;

  MediaRepository(this.api);

  Future<MediaListResult> list(
      {required String kind,
      String query = '',
      int offset = 0,
      int limit = 30}) async {
    final data = await api.getJson('/api/media/', {
      'content_kind': kind,
      'q': query,
      'offset': '$offset',
      'limit': '$limit',
      'sort': 'recent',
      if (offset == 0) 'include_counts': 'true',
    });
    final items = ((data['items'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(MediaItem.fromJson)
        .toList();
    final counts = (data['counts'] as Map?)?.map(
            (key, value) => MapEntry('$key', int.tryParse('$value') ?? 0)) ??
        const <String, int>{};
    return MediaListResult(
        items: items, hasMore: data['has_more'] == true, counts: counts);
  }

  Future<void> sync() async {
    await api.postJson('/api/sync/');
  }
}

class MediaListResult {
  final List<MediaItem> items;
  final bool hasMore;
  final Map<String, int> counts;

  MediaListResult(
      {required this.items, required this.hasMore, required this.counts});
}

class MediaShell extends StatefulWidget {
  const MediaShell({super.key});

  @override
  State<MediaShell> createState() => _MediaShellState();
}

class _MediaShellState extends State<MediaShell> {
  late final MediaRepository repo = MediaRepository(ApiClient());
  var kind = 'IMAGE';
  var query = '';
  var offset = 0;
  var hasMore = false;
  var loading = false;
  var message = '';
  var authRequired = false;
  var counts = <String, int>{};
  final items = <MediaItem>[];
  final queryController = TextEditingController();
  final scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    scrollController.addListener(_onScroll);
    _load(reset: true);
  }

  @override
  void dispose() {
    scrollController.dispose();
    queryController.dispose();
    super.dispose();
  }

  Future<void> _load({required bool reset}) async {
    if (loading) return;
    setState(() {
      loading = true;
      message = '';
      authRequired = false;
      if (reset) {
        offset = 0;
        hasMore = false;
        items.clear();
      }
    });
    try {
      final result = await repo.list(kind: kind, query: query, offset: offset);
      setState(() {
        authRequired = false;
        items.addAll(result.items);
        offset = items.length;
        hasMore = result.hasMore;
        if (result.counts.isNotEmpty) counts = result.counts;
        message = items.isEmpty ? '표시할 자료가 없습니다.' : '';
      });
    } catch (error) {
      setState(() {
        authRequired = error is ApiException &&
            (error.statusCode == 401 || error.statusCode == 403);
        message = authRequired ? '' : error.toString();
      });
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _sync() async {
    setState(() {
      loading = true;
      message = '웹하드 동기화 중입니다.';
    });
    try {
      await repo.sync();
      await _load(reset: true);
    } catch (error) {
      setState(() => message = error.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _logout() async {
    setState(() {
      loading = true;
      message = '';
    });
    try {
      await ApiClient().postJson('/api/logout/');
    } catch (_) {
      // Local session cleanup still matters if the server-side logout already expired.
    } finally {
      AuthSession.instance.clear();
      if (mounted) {
        setState(() {
          loading = false;
          authRequired = true;
          items.clear();
          offset = 0;
          hasMore = false;
        });
      }
    }
  }

  void _onScroll() {
    if (!hasMore || loading) return;
    if (scrollController.position.extentAfter < 500) _load(reset: false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xfff3efe5),
      appBar: AppBar(
        title: const Text('jsTube 미디어'),
        actions: [
          TextButton.icon(
              onPressed: _downloadApk,
              icon: const Icon(Icons.tv),
              label: const Text('TV 앱 다운로드')),
          if (AuthSession.instance.canWrite)
            TextButton(onPressed: _sync, child: const Text('웹하드 동기화')),
          TextButton(
              onPressed: () => _openExternal(AppConfig.webhardBase),
              child: const Text('웹하드')),
          AnimatedBuilder(
            animation: AuthSession.instance,
            builder: (context, _) => TextButton(
              onPressed:
                  AuthSession.instance.isAuthenticated ? _logout : _openAdminLogin,
              child:
                  Text(AuthSession.instance.isAuthenticated ? '로그아웃' : '로그인'),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          CustomScrollView(
            controller: scrollController,
            slivers: [
              SliverToBoxAdapter(
                  child: _Header(
                      kind: kind,
                      queryController: queryController,
                      onSearch: _search)),
              SliverToBoxAdapter(
                  child: _Tabs(
                      kind: kind, counts: counts, onChanged: _changeKind)),
              if (message.isNotEmpty)
                SliverToBoxAdapter(
                    child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(message))),
              if (authRequired)
                SliverToBoxAdapter(
                    child: _AuthRequiredPanel(onOpenAdmin: _openAdminLogin)),
              SliverPadding(
                padding: const EdgeInsets.all(18),
                sliver: SliverGrid.builder(
                  itemCount: items.length,
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 280,
                    mainAxisExtent: 265,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 16,
                  ),
                  itemBuilder: (context, index) =>
                      MediaCard(item: items[index]),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 80)),
            ],
          ),
          if (loading) const LoadingLayer(),
        ],
      ),
    );
  }

  void _search() {
    query = queryController.text.trim();
    _load(reset: true);
  }

  void _changeKind(String value) {
    setState(() {
      kind = value;
      query = '';
      queryController.clear();
    });
    _load(reset: true);
  }

  Future<void> _downloadApk() async {
    await _openExternal(AppConfig.apkDownloadUrl);
  }

  Future<void> _openAdminLogin() async {
    final adminBase = AppConfig.adminBase.replaceAll(RegExp(r'/$'), '');
    final loginUri = Uri.parse('$adminBase/service-login-page.do').replace(
      queryParameters: {
        'service_nm': 'jsTube',
        'return_url': Uri.base.toString(),
      },
    );
    await _openExternal(loginUri.toString(), sameWindow: true);
  }

  Future<void> _openExternal(String url, {bool sameWindow = false}) async {
    final uri = Uri.parse(url);
    final targetUri = uri.hasScheme ? uri : Uri.base.resolveUri(uri);
    if (await canLaunchUrl(targetUri)) {
      await launchUrl(
        targetUri,
        mode: LaunchMode.externalApplication,
        webOnlyWindowName: sameWindow ? '_self' : null,
      );
      return;
    }
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('링크를 열 수 없습니다: $targetUri')));
    }
  }
}

class _AuthRequiredPanel extends StatelessWidget {
  final VoidCallback onOpenAdmin;

  const _AuthRequiredPanel({required this.onOpenAdmin});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Card(
        elevation: 0,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Icon(Icons.admin_panel_settings_outlined),
              const SizedBox(width: 12),
              const Expanded(child: Text('어드민 로그인 후 jsTube 목록을 볼 수 있습니다.')),
              FilledButton.icon(
                onPressed: onOpenAdmin,
                icon: const Icon(Icons.open_in_new),
                label: const Text('어드민에서 로그인'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final String kind;
  final TextEditingController queryController;
  final VoidCallback onSearch;

  const _Header(
      {required this.kind,
      required this.queryController,
      required this.onSearch});

  @override
  Widget build(BuildContext context) {
    final title = switch (kind) {
      'IMAGE' => '이미지 보기',
      'VIDEO' => '영상 보기',
      _ => '노래방 보기',
    };
    return Container(
      margin: const EdgeInsets.all(18),
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
            colors: [Color(0xff1e293b), Color(0xff334155)]),
        borderRadius: BorderRadius.circular(26),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: Theme.of(context)
                  .textTheme
                  .headlineMedium
                  ?.copyWith(color: Colors.white, fontWeight: FontWeight.w800)),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: queryController,
                  onSubmitted: (_) => onSearch(),
                  decoration: const InputDecoration(
                    filled: true,
                    fillColor: Colors.white,
                    hintText: '제목, 파일명, 태그 검색',
                    prefixIcon: Icon(Icons.search),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(onPressed: onSearch, child: const Text('검색')),
            ],
          ),
        ],
      ),
    );
  }
}

class _Tabs extends StatelessWidget {
  final String kind;
  final Map<String, int> counts;
  final ValueChanged<String> onChanged;

  const _Tabs(
      {required this.kind, required this.counts, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final tabs = [
      ('IMAGE', '이미지', counts['image'] ?? 0),
      ('VIDEO', '영상', counts['video'] ?? 0),
      ('KARAOKE', '노래방', counts['karaoke'] ?? 0),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Wrap(
        spacing: 10,
        children: [
          for (final tab in tabs)
            ChoiceChip(
              label: Text('${tab.$2} ${tab.$3}'),
              selected: kind == tab.$1,
              onSelected: (_) => onChanged(tab.$1),
            ),
        ],
      ),
    );
  }
}

class MediaCard extends StatelessWidget {
  final MediaItem item;

  const MediaCard({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      color: Colors.white,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => MediaDetailScreen(item: item))),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                width: double.infinity,
                color: const Color(0xffdbeafe),
                child: item.thumbnailUrl.isEmpty
                    ? Icon(item.kind == 'IMAGE' ? Icons.image : Icons.movie,
                        size: 58, color: const Color(0xff64748b))
                    : Image.network(item.thumbnailUrl,
                        headers: AuthSession.instance.authHeaders,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            const Icon(Icons.broken_image, size: 54)),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (item.karaokeNumber.isNotEmpty)
                    Text(item.karaokeNumber,
                        style: const TextStyle(
                            color: Color(0xff2563eb),
                            fontWeight: FontWeight.bold)),
                  Text(item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                  const SizedBox(height: 6),
                  Text(item.tags.take(3).join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Color(0xff64748b))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class MediaDetailScreen extends StatelessWidget {
  final MediaItem item;

  const MediaDetailScreen({super.key, required this.item});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(item.title)),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          if (item.kind == 'VIDEO')
            VideoPanel(url: item.contentUrl, poster: item.thumbnailUrl)
          else
            Image.network(item.contentUrl,
                headers: AuthSession.instance.authHeaders, fit: BoxFit.contain),
          const SizedBox(height: 16),
          Text(item.title,
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(item.fileName),
          const SizedBox(height: 8),
          Wrap(
              spacing: 8,
              children:
                  item.tags.map((tag) => Chip(label: Text(tag))).toList()),
        ],
      ),
    );
  }
}

class KaraokeTvScreen extends StatefulWidget {
  const KaraokeTvScreen({super.key});

  @override
  State<KaraokeTvScreen> createState() => _KaraokeTvScreenState();
}

class _KaraokeTvScreenState extends State<KaraokeTvScreen> {
  late final MediaRepository repo = MediaRepository(ApiClient());
  final focusNode = FocusNode();
  final queue = <MediaItem>[];
  var items = <MediaItem>[];
  var selectedIndex = 0;
  var page = 0;
  var number = '';
  var message = '';
  var lastKey = '-';
  var loading = false;
  MediaItem? current;

  static const pageSize = 4;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => focusNode.requestFocus());
    _load();
  }

  @override
  void dispose() {
    focusNode.dispose();
    super.dispose();
  }

  Future<void> _load([String query = '']) async {
    setState(() {
      loading = true;
      message = '곡 목록을 불러오는 중입니다.';
    });
    try {
      final result = await repo.list(kind: 'KARAOKE', query: query, limit: 80);
      setState(() {
        items = result.items;
        selectedIndex = 0;
        page = 0;
        message = items.isEmpty ? '검색 결과가 없습니다.' : '';
      });
    } catch (error) {
      setState(() => message = error.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final start = page * pageSize;
    final visible = items.skip(start).take(pageSize).toList();
    final selected =
        items.isEmpty ? null : items[selectedIndex.clamp(0, items.length - 1)];
    return KeyboardListener(
      focusNode: focusNode,
      autofocus: true,
      onKeyEvent: _handleKey,
      child: Scaffold(
        backgroundColor: const Color(0xff0f172a),
        body: SafeArea(
          minimum: const EdgeInsets.all(30),
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _TvNowPlaying(current: current, queue: queue),
                  const SizedBox(height: 18),
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(
                            flex: 5,
                            child: _TvSongList(
                                items: visible,
                                pageStart: start,
                                selectedIndex: selectedIndex,
                                onPlay: _play,
                                onReserve: _reserve)),
                        const SizedBox(width: 18),
                        Expanded(
                            flex: 4,
                            child: _TvControlPanel(
                                number: number,
                                selected: selected,
                                message: message,
                                onSearch: _searchNumber,
                                onClear: () => setState(() => number = ''),
                                onPlay: selected == null
                                    ? null
                                    : () => _play(selected),
                                onReserve: selected == null
                                    ? null
                                    : () => _reserve(selected))),
                      ],
                    ),
                  ),
                ],
              ),
              Positioned(
                  right: 0,
                  top: 0,
                  child: _KeyDebug(
                      lastKey: lastKey, count: items.length, page: page + 1)),
              if (loading) const LoadingLayer(dark: true),
            ],
          ),
        ),
      ),
    );
  }

  void _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    setState(() => lastKey = event.logicalKey.keyLabel.isEmpty
        ? event.logicalKey.debugName ?? '-'
        : event.logicalKey.keyLabel);
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) return _move(1);
    if (key == LogicalKeyboardKey.arrowUp) return _move(-1);
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.select) {
      if (items.isNotEmpty) _play(items[selectedIndex]);
      return;
    }
    if (key == LogicalKeyboardKey.backspace) {
      if (number.isNotEmpty) {
        setState(() => number = number.substring(0, number.length - 1));
      }
      return;
    }
    if (key == LogicalKeyboardKey.escape) {
      setState(() => number = '');
      _load();
      return;
    }
    if (key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.mediaTrackNext) return _movePage(1);
    if (key == LogicalKeyboardKey.pageUp ||
        key == LogicalKeyboardKey.mediaTrackPrevious) return _movePage(-1);
    final digit = _digitFromKey(key);
    if (digit != null) {
      final nextNumber = '$number$digit';
      setState(() =>
          number = nextNumber.substring(0, nextNumber.length.clamp(0, 7)));
      return;
    }
  }

  String? _digitFromKey(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.digit0 || key == LogicalKeyboardKey.numpad0) {
      return '0';
    }
    if (key == LogicalKeyboardKey.digit1 || key == LogicalKeyboardKey.numpad1) {
      return '1';
    }
    if (key == LogicalKeyboardKey.digit2 || key == LogicalKeyboardKey.numpad2) {
      return '2';
    }
    if (key == LogicalKeyboardKey.digit3 || key == LogicalKeyboardKey.numpad3) {
      return '3';
    }
    if (key == LogicalKeyboardKey.digit4 || key == LogicalKeyboardKey.numpad4) {
      return '4';
    }
    if (key == LogicalKeyboardKey.digit5 || key == LogicalKeyboardKey.numpad5) {
      return '5';
    }
    if (key == LogicalKeyboardKey.digit6 || key == LogicalKeyboardKey.numpad6) {
      return '6';
    }
    if (key == LogicalKeyboardKey.digit7 || key == LogicalKeyboardKey.numpad7) {
      return '7';
    }
    if (key == LogicalKeyboardKey.digit8 || key == LogicalKeyboardKey.numpad8) {
      return '8';
    }
    if (key == LogicalKeyboardKey.digit9 || key == LogicalKeyboardKey.numpad9) {
      return '9';
    }
    return null;
  }

  void _move(int delta) {
    if (items.isEmpty) return;
    setState(() {
      selectedIndex = (selectedIndex + delta).clamp(0, items.length - 1);
      page = selectedIndex ~/ pageSize;
    });
  }

  void _movePage(int delta) {
    if (items.isEmpty) return;
    final pageCount = (items.length / pageSize).ceil();
    setState(() {
      page = (page + delta).clamp(0, pageCount - 1);
      selectedIndex = (page * pageSize).clamp(0, items.length - 1);
    });
  }

  void _play(MediaItem item) {
    setState(() {
      current = item;
      message = '${item.title} 재생 중';
    });
  }

  void _reserve(MediaItem item) {
    if (queue.any((entry) => entry.id == item.id)) return;
    setState(() {
      queue.add(item);
      message = '${item.title} 예약됨';
    });
  }

  void _searchNumber() {
    if (number.isEmpty) return;
    _load(number);
  }
}

class _TvNowPlaying extends StatelessWidget {
  final MediaItem? current;
  final List<MediaItem> queue;

  const _TvNowPlaying({required this.current, required this.queue});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
          color: const Color(0xff111827),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: const Color(0xff374151))),
      child: Row(
        children: [
          Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('현재곡',
                  style: TextStyle(
                      color: Color(0xfffde68a),
                      fontSize: 24,
                      fontWeight: FontWeight.bold)),
              Text(current?.title ?? '곡을 선택하세요',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 38,
                      fontWeight: FontWeight.w900,
                      color: Colors.white)),
              const SizedBox(height: 8),
              Text('다음곡: ${queue.isNotEmpty ? queue.first.title : '-'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(fontSize: 22, color: Color(0xffcbd5e1))),
              Text('다다음곡: ${queue.length > 1 ? queue[1].title : '-'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:
                      const TextStyle(fontSize: 22, color: Color(0xffcbd5e1))),
            ]),
          ),
          SizedBox(
              width: 360,
              height: 200,
              child: current == null
                  ? const Center(
                      child: Icon(Icons.music_note,
                          color: Colors.white54, size: 80))
                  : VideoPanel(
                      url: current!.contentUrl, poster: current!.thumbnailUrl)),
        ],
      ),
    );
  }
}

class _TvSongList extends StatelessWidget {
  final List<MediaItem> items;
  final int pageStart;
  final int selectedIndex;
  final ValueChanged<MediaItem> onPlay;
  final ValueChanged<MediaItem> onReserve;

  const _TvSongList(
      {required this.items,
      required this.pageStart,
      required this.selectedIndex,
      required this.onPlay,
      required this.onReserve});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
          color: const Color(0xff1f2937),
          borderRadius: BorderRadius.circular(28)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('곡 목록',
            style: TextStyle(
                fontSize: 30,
                color: Colors.white,
                fontWeight: FontWeight.w900)),
        const SizedBox(height: 12),
        Expanded(
          child: Column(children: [
            for (var i = 0; i < items.length; i++)
              Expanded(
                  child: _TvSongTile(
                      item: items[i],
                      index: pageStart + i,
                      active: pageStart + i == selectedIndex,
                      onPlay: () => onPlay(items[i]),
                      onReserve: () => onReserve(items[i]))),
          ]),
        ),
      ]),
    );
  }
}

class _TvSongTile extends StatelessWidget {
  final MediaItem item;
  final int index;
  final bool active;
  final VoidCallback onPlay;
  final VoidCallback onReserve;

  const _TvSongTile(
      {required this.item,
      required this.index,
      required this.active,
      required this.onPlay,
      required this.onReserve});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      margin: const EdgeInsets.symmetric(vertical: 7),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: active ? const Color(0xfffacc15) : const Color(0xff111827),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: active ? const Color(0xfffff7ad) : const Color(0xff374151),
            width: active ? 4 : 1),
      ),
      child: Row(children: [
        Container(
            width: 76,
            height: 76,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color:
                    active ? const Color(0xff111827) : const Color(0xff312e81),
                borderRadius: BorderRadius.circular(18)),
            child: Text(
                item.karaokeNumber.isEmpty
                    ? '${index + 1}'
                    : item.karaokeNumber.replaceFirst('KY.', ''),
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 24))),
        const SizedBox(width: 18),
        Expanded(
            child: Text(item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: active ? const Color(0xff111827) : Colors.white,
                    fontSize: 25,
                    fontWeight: FontWeight.w900))),
        FilledButton(onPressed: onPlay, child: const Text('재생')),
        const SizedBox(width: 8),
        OutlinedButton(onPressed: onReserve, child: const Text('예약')),
      ]),
    );
  }
}

class _TvControlPanel extends StatelessWidget {
  final String number;
  final MediaItem? selected;
  final String message;
  final VoidCallback onSearch;
  final VoidCallback onClear;
  final VoidCallback? onPlay;
  final VoidCallback? onReserve;

  const _TvControlPanel(
      {required this.number,
      required this.selected,
      required this.message,
      required this.onSearch,
      required this.onClear,
      required this.onPlay,
      required this.onReserve});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
          color: const Color(0xff111827),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: const Color(0xff334155))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('숫자키 입력',
            style: TextStyle(
                fontSize: 30,
                color: Color(0xfffde68a),
                fontWeight: FontWeight.w900)),
        Container(
            margin: const EdgeInsets.symmetric(vertical: 14),
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
                color: const Color(0xff0f172a),
                borderRadius: BorderRadius.circular(18)),
            child: Text(number.isEmpty ? '리모컨 숫자키를 누르세요' : number,
                style: const TextStyle(
                    fontSize: 34,
                    color: Colors.white,
                    fontWeight: FontWeight.bold))),
        Row(children: [
          Expanded(
              child: FilledButton(
                  onPressed: onSearch, child: const Text('번호 검색'))),
          const SizedBox(width: 10),
          Expanded(
              child:
                  OutlinedButton(onPressed: onClear, child: const Text('지움')))
        ]),
        const SizedBox(height: 20),
        Text('선택곡',
            style: Theme.of(context)
                .textTheme
                .titleLarge
                ?.copyWith(color: Colors.white70)),
        Text(selected?.title ?? '-',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                fontSize: 30,
                color: Colors.white,
                fontWeight: FontWeight.w900)),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
              child: FilledButton(onPressed: onPlay, child: const Text('재생'))),
          const SizedBox(width: 10),
          Expanded(
              child:
                  OutlinedButton(onPressed: onReserve, child: const Text('예약')))
        ]),
        const Spacer(),
        Text(message,
            style: const TextStyle(color: Color(0xffcbd5e1), fontSize: 20)),
        const SizedBox(height: 12),
        const Text('▲▼ 곡 이동 · Enter 재생 · 숫자키 검색 · Backspace 삭제',
            style: TextStyle(color: Color(0xff94a3b8), fontSize: 18)),
      ]),
    );
  }
}

class _KeyDebug extends StatelessWidget {
  final String lastKey;
  final int count;
  final int page;

  const _KeyDebug(
      {required this.lastKey, required this.count, required this.page});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.55),
          borderRadius: BorderRadius.circular(14)),
      child: Text('key: $lastKey · $count곡 · $page쪽',
          style: const TextStyle(color: Colors.white70)),
    );
  }
}

class VideoPanel extends StatefulWidget {
  final String url;
  final String poster;

  const VideoPanel({super.key, required this.url, required this.poster});

  @override
  State<VideoPanel> createState() => _VideoPanelState();
}

class _VideoPanelState extends State<VideoPanel> {
  VideoPlayerController? controller;
  Future<void>? initialize;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant VideoPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) _load();
  }

  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }

  void _load() {
    controller?.dispose();
    if (widget.url.isEmpty) return;
    controller = VideoPlayerController.networkUrl(Uri.parse(widget.url),
        httpHeaders: AuthSession.instance.authHeaders);
    initialize = controller!.initialize().then((_) {
      controller!.setLooping(false);
      controller!.play();
    });
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (widget.url.isEmpty || controller == null) {
      return const ColoredBox(
          color: Colors.black12,
          child: Center(child: Icon(Icons.play_circle, size: 80)));
    }
    return FutureBuilder<void>(
      future: initialize,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const ColoredBox(
              color: Colors.black,
              child: Center(child: CircularProgressIndicator()));
        }
        return Stack(
          alignment: Alignment.bottomCenter,
          children: [
            AspectRatio(
                aspectRatio: controller!.value.aspectRatio,
                child: VideoPlayer(controller!)),
            VideoProgressIndicator(controller!, allowScrubbing: true),
            Positioned.fill(
                child: Material(
                    color: Colors.transparent,
                    child: InkWell(
                        onTap: () => setState(() => controller!.value.isPlaying
                            ? controller!.pause()
                            : controller!.play())))),
          ],
        );
      },
    );
  }
}

class LoadingLayer extends StatelessWidget {
  final bool dark;

  const LoadingLayer({super.key, this.dark = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: (dark ? Colors.black : Colors.white).withOpacity(0.55),
      child: const Center(child: CircularProgressIndicator()),
    );
  }
}

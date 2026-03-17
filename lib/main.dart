import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:intl/intl.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  WakelockPlus.enable();
  
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    print('Flutter错误: ${details.exception}');
  };
  
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => PlayerProvider()),
        ChangeNotifierProvider(create: (_) => FavoritesProvider()),
        ChangeNotifierProvider(create: (_) => MusicProvider()),
        ChangeNotifierProvider(create: (_) => ThumbnailProvider()),
      ],
      child: MaterialApp(
        title: '相册播放器 Pro',
        theme: ThemeData(
          primarySwatch: Colors.blue,
          brightness: Brightness.dark,
          useMaterial3: true,
        ),
        home: const HomeScreen(),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}

enum MediaType { image, video }
enum TransitionEffect { fade, slide, scale, rotate, blur }
enum SortType { timeNewest, timeOldest, folder, dateGroup }

class MediaFile {
  final String path;
  final MediaType type;
  final String name;
  final int? duration;
  final int lastModified;

  MediaFile({
    required this.path,
    required this.type,
    required this.name,
    this.duration,
    required this.lastModified,
  });

  File get file => File(path);
  bool get isImage => type == MediaType.image;
  bool get isVideo => type == MediaType.video;
  String get folderPath => path.substring(0, path.lastIndexOf('/'));
  String get folderName {
    final folder = folderPath;
    return folder.substring(folder.lastIndexOf('/') + 1);
  }
  DateTime get modifiedDate => DateTime.fromMillisecondsSinceEpoch(lastModified);
  
  String get dateGroupLabel {
    final now = DateTime.now();
    final fileDate = modifiedDate;
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final fileDay = DateTime(fileDate.year, fileDate.month, fileDate.day);
    
    if (fileDay == today) return '今天';
    if (fileDay == yesterday) return '昨天';
    if (fileDay.isAfter(today.subtract(const Duration(days: 7)))) return '本周';
    if (fileDay.isAfter(today.subtract(const Duration(days: 30)))) return '本月';
    if (fileDate.year == now.year) return '${fileDate.month}月';
    return '${fileDate.year}年';
  }
  
  Map<String, dynamic> toMap() {
    return {
      'path': path,
      'type': type == MediaType.image ? 'image' : 'video',
      'name': name,
      'duration': duration,
      'lastModified': lastModified,
    };
  }
  
  factory MediaFile.fromMap(Map<String, dynamic> map) {
    return MediaFile(
      path: map['path'],
      type: map['type'] == 'image' ? MediaType.image : MediaType.video,
      name: map['name'],
      duration: map['duration'],
      lastModified: map['lastModified'],
    );
  }
}

class MediaDatabase {
  static Database? _database;
  
  static Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }
  
  static Future<Database> _initDatabase() async {
    final documentsDirectory = await getApplicationDocumentsDirectory();
    final dbPath = path.join(documentsDirectory.path, 'media_cache.db');
    
    return await openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE media_files (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT UNIQUE,
            type TEXT,
            name TEXT,
            duration INTEGER,
            lastModified INTEGER,
            scanTime INTEGER
          )
        ''');
        await db.execute('CREATE INDEX idx_path ON media_files(path)');
        await db.execute('CREATE INDEX idx_scanTime ON media_files(scanTime)');
      },
    );
  }
  
  static Future<void> saveMediaFiles(List<MediaFile> files) async {
    final db = await database;
    final batch = db.batch();
    final scanTime = DateTime.now().millisecondsSinceEpoch;
    
    batch.delete('media_files');
    for (var file in files) {
      final map = file.toMap();
      map['scanTime'] = scanTime;
      batch.insert('media_files', map);
    }
    await batch.commit(noResult: true);
    print('已保存 ${files.length} 个文件到数据库');
  }
  
  static Future<List<MediaFile>> loadMediaFiles() async {
    final db = await database;
    final List<Map<String, dynamic>> maps = await db.query('media_files', orderBy: 'lastModified DESC');
    print('从数据库加载了 ${maps.length} 个文件');
    return List.generate(maps.length, (i) => MediaFile.fromMap(maps[i]));
  }
  
  static Future<bool> hasCachedFiles() async {
    final db = await database;
    final result = await db.rawQuery('SELECT COUNT(*) as count FROM media_files');
    final count = Sqflite.firstIntValue(result) ?? 0;
    return count > 0;
  }
  
  static Future<DateTime?> getCacheTime() async {
    final db = await database;
    final result = await db.rawQuery('SELECT MAX(scanTime) as time FROM media_files');
    final time = Sqflite.firstIntValue(result);
    if (time != null) return DateTime.fromMillisecondsSinceEpoch(time);
    return null;
  }
  
  static Future<void> clearCache() async {
    final db = await database;
    await db.delete('media_files');
    print('已清除缓存');
  }
}

class ThumbnailProvider with ChangeNotifier {
  String _searchQuery = '';
  Set<String> _selectedFiles = {};
  bool _isSelectionMode = false;
  Set<String> _selectedFolders = {};
  bool _showFolderFilter = false;
  
  String get searchQuery => _searchQuery;
  Set<String> get selectedFiles => _selectedFiles;
  bool get isSelectionMode => _isSelectionMode;
  Set<String> get selectedFolders => _selectedFolders;
  bool get showFolderFilter => _showFolderFilter;
  
  void setSearchQuery(String query) {
    _searchQuery = query;
    notifyListeners();
  }
  
  void toggleSelection(String filePath) {
    if (_selectedFiles.contains(filePath)) {
      _selectedFiles.remove(filePath);
    } else {
      _selectedFiles.add(filePath);
    }
    notifyListeners();
  }
  
  void toggleSelectionMode() {
    _isSelectionMode = !_isSelectionMode;
    if (!_isSelectionMode) _selectedFiles.clear();
    notifyListeners();
  }
  
  void selectAll(List<MediaFile> files) {
    _selectedFiles = files.map((f) => f.path).toSet();
    notifyListeners();
  }
  
  void clearSelection() {
    _selectedFiles.clear();
    _isSelectionMode = false;
    notifyListeners();
  }
  
  void toggleFolder(String folder) {
    if (_selectedFolders.contains(folder)) {
      _selectedFolders.remove(folder);
    } else {
      _selectedFolders.add(folder);
    }
    notifyListeners();
  }
  
  void toggleFolderFilter() {
    _showFolderFilter = !_showFolderFilter;
    notifyListeners();
  }
  
  void clearFolderFilter() {
    _selectedFolders.clear();
    notifyListeners();
  }
  
  List<MediaFile> filterFiles(List<MediaFile> files) {
    var filtered = files;
    if (_searchQuery.isNotEmpty) {
      filtered = filtered.where((file) => file.name.toLowerCase().contains(_searchQuery.toLowerCase())).toList();
    }
    if (_selectedFolders.isNotEmpty) {
      filtered = filtered.where((file) => _selectedFolders.contains(file.folderPath)).toList();
    }
    return filtered;
  }
}

class FavoritesProvider with ChangeNotifier {
  Set<String> _favorites = {};
  SharedPreferences? _prefs;
  Set<String> get favorites => _favorites;

  FavoritesProvider() {
    _loadFavorites();
  }

  Future<void> _loadFavorites() async {
    _prefs = await SharedPreferences.getInstance();
    final saved = _prefs?.getStringList('favorites') ?? [];
    _favorites = saved.toSet();
    notifyListeners();
  }

  bool isFavorite(String path) => _favorites.contains(path);

  Future<void> toggleFavorite(String path) async {
    if (_favorites.contains(path)) {
      _favorites.remove(path);
    } else {
      _favorites.add(path);
    }
    await _prefs?.setStringList('favorites', _favorites.toList());
    notifyListeners();
  }
  
  Future<void> addMultipleFavorites(Set<String> paths) async {
    _favorites.addAll(paths);
    await _prefs?.setStringList('favorites', _favorites.toList());
    notifyListeners();
  }

  List<MediaFile> filterFavorites(List<MediaFile> allFiles) {
    return allFiles.where((file) => _favorites.contains(file.path)).toList();
  }
}

class MusicProvider with ChangeNotifier {
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isMusicEnabled = false;
  String? _currentMusicPath;
  bool get isMusicEnabled => _isMusicEnabled;
  String? get currentMusicPath => _currentMusicPath;

  MusicProvider() {
    _audioPlayer.setReleaseMode(ReleaseMode.loop);
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _isMusicEnabled = prefs.getBool('music_enabled') ?? false;
    _currentMusicPath = prefs.getString('current_music');
    if (_isMusicEnabled && _currentMusicPath != null) {
      await playMusic(_currentMusicPath!);
    }
  }

  Future<void> toggleMusic() async {
    _isMusicEnabled = !_isMusicEnabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('music_enabled', _isMusicEnabled);
    if (_isMusicEnabled && _currentMusicPath != null) {
      await playMusic(_currentMusicPath!);
    } else {
      await _audioPlayer.pause();
    }
    notifyListeners();
  }

  Future<void> playMusic(String musicPath) async {
    try {
      _currentMusicPath = musicPath;
      await _audioPlayer.play(DeviceFileSource(musicPath));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('current_music', musicPath);
      notifyListeners();
    } catch (e) {
      print('播放音乐失败: $e');
    }
  }

  Future<void> stopMusic() async {
    await _audioPlayer.stop();
    _isMusicEnabled = false;
    notifyListeners();
  }

  Future<void> selectMusicFile() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.audio, allowMultiple: false);
      if (result != null && result.files.single.path != null) {
        final musicPath = result.files.single.path!;
        _currentMusicPath = musicPath;
        if (_isMusicEnabled) await playMusic(musicPath);
      }
    } catch (e) {
      print('选择音乐文件失败: $e');
    }
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }
}

class MediaScanner {
  static const imageExts = [
    'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp',
    'heic', 'heif', 'tiff', 'tif', 'svg', 'ico',
    'jfif', 'pjpeg', 'pjp', 'avif',
  ];
  
  static const videoExts = ['mp4', 'avi', 'mov', 'mkv', '3gp', 'webm', 'flv'];
  
  static const skipDirs = [
    'Android', '.thumbnails', 'thumbnails', 'cache', '.cache',
    'temp', '.temp', 'system', '.system', 'data', 'obb',
  ];
  
  int _scannedCount = 0;
  int _foundCount = 0;
  final Function(int, String)? onProgress;
  bool _shouldStop = false;
  
  MediaScanner({this.onProgress});
  
  void stop() {
    _shouldStop = true;
  }
  
  Future<List<MediaFile>> scanDirectory(String dirPath) async {
    final mediaFiles = <MediaFile>[];
    final directory = Directory(dirPath);
    
    if (!await directory.exists()) {
      print('目录不存在: $dirPath');
      return mediaFiles;
    }
    
    _scannedCount = 0;
    _foundCount = 0;
    _shouldStop = false;
    
    try {
      await _scanRecursively(directory, mediaFiles, 0);
      print('扫描完成，共找到 ${mediaFiles.length} 个媒体文件');
    } catch (e, stackTrace) {
      print('扫描错误: $e');
      print('堆栈: $stackTrace');
    }
    
    return mediaFiles;
  }
  
  Future<List<MediaFile>> scanAllImages() async {
    print('========== 开始扫描整个设备 ==========');
    print('开始时间: ${DateTime.now()}');
    
    final allMediaFiles = <MediaFile>[];
    final rootPath = '/storage/emulated/0';
    final rootDir = Directory(rootPath);
    
    if (!await rootDir.exists()) {
      print('根目录不存在');
      return allMediaFiles;
    }
    
    _scannedCount = 0;
    _foundCount = 0;
    _shouldStop = false;
    
    try {
      await _scanInBatchesOptimized(rootDir, allMediaFiles);
      
      print('========== 扫描完成 ==========');
      print('扫描的文件总数: $_scannedCount');
      print('找到的媒体文件: ${allMediaFiles.length}');
      print('完成时间: ${DateTime.now()}');
      
    } catch (e, stackTrace) {
      print('扫描失败: $e');
      print('堆栈: $stackTrace');
    }
    
    final uniqueFiles = <String, MediaFile>{};
    for (var file in allMediaFiles) {
      uniqueFiles[file.path] = file;
    }
    
    final result = uniqueFiles.values.toList();
    
    if (result.length != allMediaFiles.length) {
      print('去重: ${allMediaFiles.length} → ${result.length}');
    }
    
    try {
      result.sort((a, b) => b.lastModified.compareTo(a.lastModified));
    } catch (e) {
      print('排序失败: $e');
    }
    
    return result;
  }
  
  Future<void> _scanInBatchesOptimized(Directory rootDir, List<MediaFile> result) async {
    final queue = <Directory>[rootDir];
    int processedDirs = 0;
    int skippedDirs = 0;
    int errorDirs = 0;
    
    final startTime = DateTime.now();
    print('开始批量扫描...');
    
    while (queue.isNotEmpty && !_shouldStop) {
      final currentDir = queue.removeAt(0);
      final dirName = path.basename(currentDir.path);
      
      if (_shouldSkipDirectory(dirName)) {
        skippedDirs++;
        continue;
      }
      
      processedDirs++;
      
      if (processedDirs % 50 == 0) {
        final elapsed = DateTime.now().difference(startTime);
        print('进度: 已处理 $processedDirs 个目录, 找到 ${result.length} 个文件');
        onProgress?.call(result.length, currentDir.path);
      }
      
      try {
        final entities = await currentDir.list().toList().timeout(
          const Duration(seconds: 60),
          onTimeout: () {
            print('列出目录超时: ${currentDir.path}');
            return [];
          },
        );
        
        for (var i = 0; i < entities.length && !_shouldStop; i++) {
          final entity = entities[i];
          
          try {
            if (entity is Directory) {
              queue.add(entity);
            } else if (entity is File) {
              _scannedCount++;
              
              if (_scannedCount % 200 == 0) {
                onProgress?.call(result.length, currentDir.path);
                await Future.delayed(const Duration(microseconds: 100));
              }
              
              final mediaFile = await _processFileFast(entity);
              if (mediaFile != null) {
                result.add(mediaFile);
                _foundCount++;
              }
            }
          } catch (e) {
            continue;
          }
        }
        
        if (processedDirs % 100 == 0) {
          await Future.delayed(const Duration(milliseconds: 5));
        }
        
      } catch (e) {
        errorDirs++;
        continue;
      }
    }
    
    final totalTime = DateTime.now().difference(startTime);
    print('扫描统计: 目录=$processedDirs, 文件=$_scannedCount, 媒体=$_foundCount');
  }
  
  Future<void> _scanRecursively(Directory folder, List<MediaFile> result, int depth) async {
    if (depth > 10 || _shouldStop) return;
    
    try {
      final entities = await folder.list().toList().timeout(
        const Duration(seconds: 60),
        onTimeout: () => [],
      );
      
      for (var entity in entities) {
        if (_shouldStop) break;
        
        try {
          if (entity is Directory) {
            final dirName = path.basename(entity.path);
            if (!_shouldSkipDirectory(dirName)) {
              await _scanRecursively(entity, result, depth + 1);
            }
          } else if (entity is File) {
            _scannedCount++;
            
            if (_scannedCount % 200 == 0) {
              onProgress?.call(result.length, folder.path);
              await Future.delayed(const Duration(microseconds: 100));
            }
            
            final mediaFile = await _processFileFast(entity);
            if (mediaFile != null) {
              result.add(mediaFile);
            }
          }
        } catch (e) {
          continue;
        }
      }
    } catch (e) {
      // 忽略错误继续
    }
  }
  
  bool _shouldSkipDirectory(String dirName) {
    if (dirName.startsWith('.')) return true;
    
    final lowerName = dirName.toLowerCase();
    for (var skipDir in skipDirs) {
      if (lowerName == skipDir.toLowerCase()) return true;
    }
    
    return false;
  }
  
  Future<MediaFile?> _processFileFast(File file) async {
    try {
      final ext = path.extension(file.path).toLowerCase().replaceAll('.', '');
      if (ext.isEmpty) return null;
      
      final fileName = path.basename(file.path);
      
      try {
        final fileSize = await file.length().timeout(
          const Duration(milliseconds: 100),
          onTimeout: () => 0,
        );
        if (fileSize < 1024) return null;
      } catch (e) {
        return null;
      }
      
      int lastModified;
      try {
        final stat = await file.stat().timeout(
          const Duration(milliseconds: 100),
          onTimeout: () => throw TimeoutException('timeout'),
        );
        lastModified = stat.modified.millisecondsSinceEpoch;
      } catch (e) {
        lastModified = DateTime.now().millisecondsSinceEpoch;
      }
      
      if (imageExts.contains(ext)) {
        return MediaFile(
          path: file.path,
          type: MediaType.image,
          name: fileName,
          lastModified: lastModified,
        );
      } else if (videoExts.contains(ext)) {
        return MediaFile(
          path: file.path,
          type: MediaType.video,
          name: fileName,
          duration: 60,
          lastModified: lastModified,
        );
      }
    } catch (e) {
      return null;
    }
    return null;
  }
}  
      
class PlayerProvider with ChangeNotifier {
  List<MediaFile> _mediaFiles = [];
  int _currentIndex = 0;
  bool _isPlaying = false;
  bool _isLoading = false;
  int _imageDuration = 5;
  Timer? _timer;
  int _scannedCount = 0;
  String _currentScanPath = '';
  TransitionEffect _transitionEffect = TransitionEffect.fade;
  bool _showOnlyFavorites = false;
  SortType _sortType = SortType.timeNewest;
  bool _hasAutoLoaded = false;
  
  List<MediaFile> get mediaFiles => _mediaFiles;
  MediaFile? get currentMedia => _mediaFiles.isEmpty ? null : _mediaFiles[_currentIndex];
  bool get isPlaying => _isPlaying;
  bool get isLoading => _isLoading;
  int get imageDuration => _imageDuration;
  int get currentIndex => _currentIndex;
  int get totalCount => _mediaFiles.length;
  int get scannedCount => _scannedCount;
  String get currentScanPath => _currentScanPath;
  TransitionEffect get transitionEffect => _transitionEffect;
  bool get showOnlyFavorites => _showOnlyFavorites;
  SortType get sortType => _sortType;
  bool get hasAutoLoaded => _hasAutoLoaded;
  
  PlayerProvider() {
    _loadSettings();
    _autoLoadCachedFiles();
  }
  
  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _imageDuration = prefs.getInt('image_duration') ?? 5;
    final effectIndex = prefs.getInt('transition_effect') ?? 0;
    _transitionEffect = TransitionEffect.values[effectIndex];
    final sortIndex = prefs.getInt('sort_type') ?? 0;
    _sortType = SortType.values[sortIndex];
    notifyListeners();
  }
  
  Future<void> _autoLoadCachedFiles() async {
    if (_hasAutoLoaded) return;
    try {
      print('=== 检查缓存 ===');
      final hasCache = await MediaDatabase.hasCachedFiles();
      if (hasCache) {
        print('发现缓存，正在加载...');
        _isLoading = true;
        notifyListeners();
        _mediaFiles = await MediaDatabase.loadMediaFiles();
        if (_mediaFiles.isNotEmpty) {
          print('从缓存加载了 ${_mediaFiles.length} 个文件');
          _hasAutoLoaded = true;
          _isLoading = false;
          notifyListeners();
          await Future.delayed(const Duration(seconds: 1));
          if (_mediaFiles.isNotEmpty) play();
        } else {
          _isLoading = false;
          notifyListeners();
        }
      } else {
        print('没有缓存数据');
      }
    } catch (e) {
      print('加载缓存失败: $e');
      _isLoading = false;
      notifyListeners();
    }
  }
  
  Future<void> loadCachedFiles() async {
    try {
      _isLoading = true;
      notifyListeners();
      _mediaFiles = await MediaDatabase.loadMediaFiles();
      _currentIndex = 0;
      _hasAutoLoaded = true;
      _isLoading = false;
      notifyListeners();
      if (_mediaFiles.isNotEmpty) play();
    } catch (e) {
      print('加载缓存失败: $e');
      _isLoading = false;
      notifyListeners();
    }
  }
  
  Future<void> loadDirectory(String dirPath) async {
    _isLoading = true;
    _scannedCount = 0;
    _currentScanPath = dirPath;
    notifyListeners();
    try {
      final scanner = MediaScanner(
        onProgress: (count, currentPath) {
          _scannedCount = count;
          _currentScanPath = currentPath;
          notifyListeners();
        },
      );
      _mediaFiles = await scanner.scanDirectory(dirPath);
      _currentIndex = 0;
      _hasAutoLoaded = true;
      if (_mediaFiles.isNotEmpty) {
        await MediaDatabase.saveMediaFiles(_mediaFiles);
        print('已保存 ${_mediaFiles.length} 个文件到缓存');
        play();
      }
    } catch (e) {
      print('加载失败: $e');
    } finally {
      _isLoading = false;
      _currentScanPath = '';
      notifyListeners();
    }
  }
  
  Future<void> loadAllImages() async {
    _isLoading = true;
    _scannedCount = 0;
    _currentScanPath = '准备扫描整个设备...';
    notifyListeners();
    await Future.delayed(const Duration(milliseconds: 500));
    try {
      print('========== 开始扫描整个设备 ==========');
      print('开始时间: ${DateTime.now()}');
      final scanner = MediaScanner(
        onProgress: (count, currentPath) {
          _scannedCount = count;
          _currentScanPath = currentPath;
          if (count % 100 == 0) print('进度: 已找到 $count 个媒体文件');
          notifyListeners();
        },
      );
      _mediaFiles = await scanner.scanAllImages().timeout(
        const Duration(minutes: 60),
        onTimeout: () {
          print('扫描超时（60分钟），返回已扫描的文件');
          return <MediaFile>[];
        },
      );
      _currentIndex = 0;
      _hasAutoLoaded = true;
      print('========== 扫描完成 ==========');
      print('完成时间: ${DateTime.now()}');
      print('总共找到: ${_mediaFiles.length} 个媒体文件');
      if (_mediaFiles.isNotEmpty) {
        print('正在保存到缓存...');
        try {
          await MediaDatabase.saveMediaFiles(_mediaFiles);
          print('✓ 已保存到缓存');
        } catch (e) {
          print('✗ 保存缓存失败: $e');
        }
        play();
      } else {
        print('未找到任何媒体文件');
      }
    } catch (e, stackTrace) {
      print('========== 扫描失败 ==========');
      print('错误: $e');
      print('堆栈: $stackTrace');
      _mediaFiles = [];
    } finally {
      _isLoading = false;
      _currentScanPath = '';
      notifyListeners();
    }
  }
  
  Future<void> rescan() async {
    await MediaDatabase.clearCache();
    _hasAutoLoaded = false;
    await loadAllImages();
  }
  
  List<MediaFile> getSortedFiles() {
    final files = List<MediaFile>.from(_mediaFiles);
    switch (_sortType) {
      case SortType.timeNewest:
        files.sort((a, b) => b.lastModified.compareTo(a.lastModified));
        break;
      case SortType.timeOldest:
        files.sort((a, b) => a.lastModified.compareTo(b.lastModified));
        break;
      case SortType.folder:
        files.sort((a, b) {
          final folderCompare = a.folderPath.compareTo(b.folderPath);
          if (folderCompare != 0) return folderCompare;
          return b.lastModified.compareTo(a.lastModified);
        });
        break;
      case SortType.dateGroup:
        files.sort((a, b) => b.lastModified.compareTo(a.lastModified));
        break;
    }
    return files;
  }
  
  Map<String, List<MediaFile>> getFilesByFolder() {
    final Map<String, List<MediaFile>> folderMap = {};
    for (var file in _mediaFiles) {
      final folder = file.folderPath;
      if (!folderMap.containsKey(folder)) folderMap[folder] = [];
      folderMap[folder]!.add(file);
    }
    folderMap.forEach((key, value) {
      value.sort((a, b) => b.lastModified.compareTo(a.lastModified));
    });
    return folderMap;
  }
  
  Map<String, List<MediaFile>> getFilesByDateGroup() {
    final Map<String, List<MediaFile>> dateMap = {};
    for (var file in _mediaFiles) {
      final group = file.dateGroupLabel;
      if (!dateMap.containsKey(group)) dateMap[group] = [];
      dateMap[group]!.add(file);
    }
    dateMap.forEach((key, value) {
      value.sort((a, b) => b.lastModified.compareTo(a.lastModified));
    });
    return dateMap;
  }
  
  Set<String> getAllFolders() => _mediaFiles.map((f) => f.folderPath).toSet();
  
  Future<void> setSortType(SortType type) async {
    _sortType = type;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('sort_type', type.index);
    notifyListeners();
  }
  
  void toggleFavoritesFilter(Set<String> favorites) {
    _showOnlyFavorites = !_showOnlyFavorites;
    notifyListeners();
  }
  
  List<MediaFile> getDisplayFiles(Set<String> favorites) {
    if (_showOnlyFavorites) {
      return _mediaFiles.where((file) => favorites.contains(file.path)).toList();
    }
    return _mediaFiles;
  }
  
  void play() {
    if (_mediaFiles.isEmpty) return;
    _isPlaying = true;
    notifyListeners();
    _scheduleNext();
  }
  
  void pause() {
    _isPlaying = false;
    _timer?.cancel();
    notifyListeners();
  }
  
  void playNext() {
    if (_mediaFiles.isEmpty) return;
    _timer?.cancel();
    _currentIndex = (_currentIndex + 1) % _mediaFiles.length;
    notifyListeners();
    _scheduleNext();
  }
  
  void playPrevious() {
    if (_mediaFiles.isEmpty) return;
    _timer?.cancel();
    _currentIndex = _currentIndex > 0 ? _currentIndex - 1 : _mediaFiles.length - 1;
    notifyListeners();
    _scheduleNext();
  }
  
  void jumpToIndex(int index) {
    if (index >= 0 && index < _mediaFiles.length) {
      _timer?.cancel();
      _currentIndex = index;
      notifyListeners();
      if (_isPlaying) _scheduleNext();
    }
  }
  
  void _scheduleNext() {
    if (!_isPlaying || currentMedia == null) return;
    _timer?.cancel();
    if (currentMedia!.isImage) {
      _timer = Timer(Duration(seconds: _imageDuration), () {
        if (_isPlaying) playNext();
      });
    }
  }
  
  void onVideoEnded() {
    if (_isPlaying) playNext();
  }
  
  Future<void> setImageDuration(int seconds) async {
    _imageDuration = seconds;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('image_duration', seconds);
    notifyListeners();
  }
  
  Future<void> setTransitionEffect(TransitionEffect effect) async {
    _transitionEffect = effect;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('transition_effect', effect.index);
    notifyListeners();
  }
  
  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  VideoPlayerController? _videoController;
  MediaFile? _currentDisplayedMedia;
  bool _showThumbnails = false;
  final TransformationController _transformationController = TransformationController();
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
  }

  @override
  void dispose() {
    _videoController?.dispose();
    _transformationController.dispose();
    _searchController.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  Future<void> _selectFolder() async {
    try {
      String? dir = await FilePicker.platform.getDirectoryPath();
      if (dir != null && mounted) {
        await context.read<PlayerProvider>().loadDirectory(dir);
      }
    } catch (e) {
      if (mounted) _showSnackBar('选择文件夹失败: $e', Colors.red);
    }
  }
  
  Future<void> _scanAllImages() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('扫描整个设备'),
        content: const Text('这将扫描平板上所有文件夹中的图片和视频。\n\n扫描可能需要5-15分钟，扫描结果会自动保存。\n\n确定要继续吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('开始扫描')),
        ],
      ),
    );
    if (confirm == true && mounted) {
      try {
        await context.read<PlayerProvider>().loadAllImages();
      } catch (e) {
        if (mounted) _showSnackBar('扫描失败: $e', Colors.red);
      }
    }
  }
  
  void _showSnackBar(String message, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: color, duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Consumer4<PlayerProvider, FavoritesProvider, MusicProvider, ThumbnailProvider>(
        builder: (context, player, favorites, music, thumbnail, child) {
          if (player.isLoading) return _buildLoadingScreen(player);
          if (player.mediaFiles.isEmpty) return _buildWelcomeScreen(player);
          return Stack(
            children: [
              Center(child: _buildMediaDisplay(player)),
              if (_showThumbnails) _buildThumbnailGrid(player, favorites, thumbnail),
              Positioned(bottom: 0, left: 0, right: 0, child: _buildControls(player, favorites, music)),
              Positioned(top: 16, right: 16, child: _buildFavoriteButton(player, favorites)),
              Positioned(top: 16, right: 80, child: _buildShareButton(player)),
              Positioned(top: 16, left: 16, child: _buildThumbnailToggle()),
            ],
          );
        },
      ),
    );
  }

  Widget _buildLoadingScreen(PlayerProvider player) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(width: 100, height: 100, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 8)),
          const SizedBox(height: 40),
          const Text('正在扫描文件...', style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
            decoration: BoxDecoration(
              color: Colors.blue.withOpacity(0.2),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.blue, width: 2),
            ),
            child: Column(
              children: [
                const Icon(Icons.photo_library, color: Colors.blue, size: 48),
                const SizedBox(height: 12),
                Text('已找到: ${player.scannedCount} 个文件', style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            margin: const EdgeInsets.symmetric(horizontal: 40),
            decoration: BoxDecoration(color: Colors.black.withOpacity(0.5), borderRadius: BorderRadius.circular(12)),
            child: Column(
              children: [
                const Text('当前位置:', style: TextStyle(color: Colors.white70, fontSize: 14)),
                const SizedBox(height: 4),
                Text(player.currentScanPath, style: const TextStyle(color: Colors.white, fontSize: 12), textAlign: TextAlign.center, maxLines: 3, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          const SizedBox(height: 40),
          Container(
            padding: const EdgeInsets.all(16),
            margin: const EdgeInsets.symmetric(horizontal: 40),
            decoration: BoxDecoration(
              color: Colors.orange.withOpacity(0.2),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.orange),
            ),
            child: const Column(
              children: [
                Icon(Icons.info_outline, color: Colors.orange, size: 32),
                SizedBox(height: 8),
                Text('扫描可能需要5-15分钟', style: TextStyle(color: Colors.orange, fontSize: 16, fontWeight: FontWeight.bold)),
                SizedBox(height: 4),
                Text('请保持应用在前台运行', style: TextStyle(color: Colors.white70, fontSize: 14)),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.green.withOpacity(0.2),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.green),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle, color: Colors.green, size: 20),
                SizedBox(width: 8),
                Text('扫描结果会自动保存', style: TextStyle(color: Colors.green, fontSize: 14)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWelcomeScreen(PlayerProvider player) {
    if (player.hasAutoLoaded && player.mediaFiles.isNotEmpty) {
      return const SizedBox.shrink();
    }
    return FutureBuilder<bool>(
      future: MediaDatabase.hasCachedFiles(),
      builder: (context, snapshot) {
        final hasCache = snapshot.data ?? false;
        return Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.photo_library_outlined, size: 100, color: Colors.white54),
                const SizedBox(height: 32),
                const Text('欢迎使用相册播放器 Pro', style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                const Text('功能强大的照片和视频播放器', style: TextStyle(color: Colors.white70, fontSize: 16)),
                if (hasCache)
                  FutureBuilder<DateTime?>(
                    future: MediaDatabase.getCacheTime(),
                    builder: (context, snapshot) {
                      if (snapshot.hasData && snapshot.data != null) {
                        final cacheTime = snapshot.data!;
                        final diff = DateTime.now().difference(cacheTime);
                        String timeAgo;
                        if (diff.inDays > 0) {
                          timeAgo = '${diff.inDays}天前';
                        } else if (diff.inHours > 0) {
                          timeAgo = '${diff.inHours}小时前';
                        } else {
                          timeAgo = '${diff.inMinutes}分钟前';
                        }
                        return Padding(
                          padding: const EdgeInsets.only(top: 24),
                          child: Container(
                            padding: const EdgeInsets.all(20),
                            margin: const EdgeInsets.symmetric(horizontal: 40),
                            decoration: BoxDecoration(
                              color: Colors.green.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: Colors.green, width: 2),
                            ),
                            child: Column(
                              children: [
                                const Icon(Icons.check_circle, color: Colors.green, size: 48),
                                const SizedBox(height: 12),
                                const Text('发现缓存数据', style: TextStyle(color: Colors.green, fontSize: 20, fontWeight: FontWeight.bold)),
                                const SizedBox(height: 8),
                                Text('上次扫描: $timeAgo', style: const TextStyle(color: Colors.white70, fontSize: 16)),
                                const SizedBox(height: 4),
                                const Text('应用启动时会自动加载', style: TextStyle(color: Colors.white54, fontSize: 14)),
                              ],
                            ),
                          ),
                        );
                      }
                      return const SizedBox.shrink();
                    },
                  ),
                const SizedBox(height: 48),
                ElevatedButton.icon(
                  onPressed: _selectFolder,
                  icon: const Icon(Icons.folder_open, size: 32),
                  label: const Text('选择文件夹', style: TextStyle(fontSize: 20)),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 24),
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                  ),
                ),
                const SizedBox(height: 20),
                if (hasCache)
                  ElevatedButton.icon(
                    onPressed: () async => await context.read<PlayerProvider>().loadCachedFiles(),
                    icon: const Icon(Icons.history, size: 32),
                    label: const Text('立即加载缓存', style: TextStyle(fontSize: 20)),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 24),
                      backgroundColor: Colors.purple,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                    ),
                  ),
                if (hasCache) const SizedBox(height: 20),
                ElevatedButton.icon(
                  onPressed: _scanAllImages,
                  icon: const Icon(Icons.search, size: 32),
                  label: Text(hasCache ? '重新扫描设备' : '扫描整个设备', style: const TextStyle(fontSize: 20)),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 24),
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                  ),
                ),
                const SizedBox(height: 24),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.blue.withOpacity(0.3)),
                    ),
                    child: Column(
                      children: [
                        const Icon(Icons.info_outline, color: Colors.blue, size: 24),
                        const SizedBox(height: 8),
                        Text(
                          hasCache ? '提示：退出应用后，下次启动会自动加载上次扫描的图片' : '提示：扫描整个设备可能需要5-15分钟，扫描结果会自动保存',
                          style: const TextStyle(color: Colors.white70, fontSize: 14),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
  Widget _buildMediaDisplay(PlayerProvider player) {
    final media = player.currentMedia!;
    Widget mediaWidget = media.isImage ? _buildImageViewer(media) : _buildVideoPlayer(media, player);
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 800),
      switchInCurve: Curves.easeInOut,
      switchOutCurve: Curves.easeInOut,
      transitionBuilder: (Widget child, Animation<double> animation) {
        switch (player.transitionEffect) {
          case TransitionEffect.fade:
            return FadeTransition(opacity: animation, child: child);
          case TransitionEffect.slide:
            return SlideTransition(position: Tween<Offset>(begin: const Offset(1.0, 0.0), end: Offset.zero).animate(animation), child: child);
          case TransitionEffect.scale:
            return ScaleTransition(scale: animation, child: child);
          case TransitionEffect.rotate:
            return RotationTransition(turns: animation, child: FadeTransition(opacity: animation, child: child));
          case TransitionEffect.blur:
            return FadeTransition(opacity: animation, child: child);
        }
      },
      child: mediaWidget,
    );
  }

  Widget _buildImageViewer(MediaFile media) {
    return Image.file(
      media.file,
      key: ValueKey(media.path),
      fit: BoxFit.contain,
      errorBuilder: (context, error, stackTrace) {
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.broken_image, color: Colors.red, size: 64),
            const SizedBox(height: 16),
            Text('无法加载图片\n${media.name}', style: const TextStyle(color: Colors.white70, fontSize: 14), textAlign: TextAlign.center),
          ],
        );
      },
    );
  }

  Widget _buildVideoPlayer(MediaFile media, PlayerProvider player) {
    if (_currentDisplayedMedia != media) {
      _currentDisplayedMedia = media;
      _initializeVideo(media, player);
    }
    return _videoController != null && _videoController!.value.isInitialized
        ? AspectRatio(key: ValueKey(media.path), aspectRatio: _videoController!.value.aspectRatio, child: VideoPlayer(_videoController!))
        : const Column(mainAxisAlignment: MainAxisAlignment.center, children: [CircularProgressIndicator(color: Colors.white), SizedBox(height: 16), Text('加载视频中...', style: TextStyle(color: Colors.white))]);
  }
  
  Future<void> _initializeVideo(MediaFile media, PlayerProvider player) async {
    try {
      await _videoController?.dispose();
      _videoController = VideoPlayerController.file(media.file);
      await _videoController!.initialize();
      if (mounted) {
        setState(() {});
        if (player.isPlaying) await _videoController!.play();
      }
      _videoController!.addListener(() {
        if (_videoController!.value.position >= _videoController!.value.duration) player.onVideoEnded();
      });
    } catch (e) {
      print('视频初始化失败: ${media.path}, 错误: $e');
    }
  }

  Widget _buildThumbnailGrid(PlayerProvider player, FavoritesProvider favorites, ThumbnailProvider thumbnail) {
    return Container(
      color: Colors.black.withOpacity(0.95),
      child: Column(
        children: [
          _buildThumbnailHeader(player, favorites, thumbnail),
          if (thumbnail.showFolderFilter) _buildFolderFilter(player, thumbnail),
          Expanded(child: _buildThumbnailContent(player, favorites, thumbnail)),
          if (thumbnail.isSelectionMode) _buildSelectionToolbar(player, favorites, thumbnail),
        ],
      ),
    );
  }

  Widget _buildThumbnailHeader(PlayerProvider player, FavoritesProvider favorites, ThumbnailProvider thumbnail) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: Colors.black.withOpacity(0.9), border: const Border(bottom: BorderSide(color: Colors.white24, width: 1))),
      child: Column(
        children: [
          Row(
            children: [
              if (thumbnail.isSelectionMode)
                IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: () => thumbnail.clearSelection())
              else
                const Text('缩略图', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
              if (thumbnail.isSelectionMode) Text('已选择 ${thumbnail.selectedFiles.length}', style: const TextStyle(color: Colors.white, fontSize: 18)),
              const Spacer(),
              if (!thumbnail.isSelectionMode) ...[
                IconButton(icon: Icon(thumbnail.showFolderFilter ? Icons.filter_list : Icons.filter_list_off, color: Colors.white70, size: 20), onPressed: () => thumbnail.toggleFolderFilter(), tooltip: '文件夹筛选'),
                IconButton(icon: const Icon(Icons.checklist, color: Colors.white70, size: 20), onPressed: () => thumbnail.toggleSelectionMode(), tooltip: '批量选择'),
                IconButton(icon: const Icon(Icons.zoom_out_map, color: Colors.white70, size: 20), onPressed: () => _transformationController.value = Matrix4.identity(), tooltip: '重置缩放'),
              ],
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 24),
                onPressed: () {
                  setState(() {
                    _showThumbnails = false;
                    _transformationController.value = Matrix4.identity();
                  });
                  thumbnail.clearSelection();
                  thumbnail.setSearchQuery('');
                },
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _searchController,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: '搜索文件名...',
              hintStyle: const TextStyle(color: Colors.white54),
              prefixIcon: const Icon(Icons.search, color: Colors.white70),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(icon: const Icon(Icons.clear, color: Colors.white70), onPressed: () {
                      _searchController.clear();
                      thumbnail.setSearchQuery('');
                    })
                  : null,
              filled: true,
              fillColor: Colors.white.withOpacity(0.1),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(25), borderSide: BorderSide.none),
              contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            ),
            onChanged: (value) => thumbnail.setSearchQuery(value),
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                const Icon(Icons.sort, color: Colors.white70, size: 18),
                const SizedBox(width: 8),
                _buildSortButton(player, SortType.timeNewest, '最新', Icons.access_time),
                const SizedBox(width: 6),
                _buildSortButton(player, SortType.timeOldest, '最旧', Icons.history),
                const SizedBox(width: 6),
                _buildSortButton(player, SortType.folder, '文件夹', Icons.folder),
                const SizedBox(width: 6),
                _buildSortButton(player, SortType.dateGroup, '日期', Icons.calendar_today),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSortButton(PlayerProvider player, SortType type, String label, IconData icon) {
    final isSelected = player.sortType == type;
    return GestureDetector(
      onTap: () => player.setSortType(type),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? Colors.blue : Colors.white.withOpacity(0.1),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: isSelected ? Colors.blue : Colors.white24, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: isSelected ? Colors.white : Colors.white70, size: 14),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(color: isSelected ? Colors.white : Colors.white70, fontSize: 12, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
          ],
        ),
      ),
    );
  }

  Widget _buildFolderFilter(PlayerProvider player, ThumbnailProvider thumbnail) {
    final folders = player.getAllFolders().toList()..sort();
    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(color: Colors.blue.withOpacity(0.1), border: const Border(bottom: BorderSide(color: Colors.blue, width: 1))),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: folders.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: const Text('全部'),
                selected: thumbnail.selectedFolders.isEmpty,
                onSelected: (_) => thumbnail.clearFolderFilter(),
                selectedColor: Colors.blue,
                backgroundColor: Colors.white.withOpacity(0.1),
              ),
            );
          }
          final folder = folders[index - 1];
          final folderName = folder.substring(folder.lastIndexOf('/') + 1);
          final isSelected = thumbnail.selectedFolders.contains(folder);
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              label: Text(folderName),
              selected: isSelected,
              onSelected: (_) => thumbnail.toggleFolder(folder),
              selectedColor: Colors.blue,
              backgroundColor: Colors.white.withOpacity(0.1),
            ),
          );
        },
      ),
    );
  }

  Widget _buildThumbnailContent(PlayerProvider player, FavoritesProvider favorites, ThumbnailProvider thumbnail) {
    var files = thumbnail.filterFiles(player.mediaFiles);
    if (files.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off, size: 64, color: Colors.white54),
            SizedBox(height: 16),
            Text('没有找到匹配的文件', style: TextStyle(color: Colors.white70, fontSize: 16)),
          ],
        ),
      );
    }
    switch (player.sortType) {
      case SortType.folder:
        return _buildFolderGroupedGrid(files, player, favorites, thumbnail);
      case SortType.dateGroup:
        return _buildDateGroupedGrid(files, player, favorites, thumbnail);
      default:
        return _buildTimeBasedGrid(files, player, favorites, thumbnail);
    }
  }

  Widget _buildTimeBasedGrid(List<MediaFile> files, PlayerProvider player, FavoritesProvider favorites, ThumbnailProvider thumbnail) {
    final sortedFiles = List<MediaFile>.from(files);
    if (player.sortType == SortType.timeNewest) {
      sortedFiles.sort((a, b) => b.lastModified.compareTo(a.lastModified));
    } else {
      sortedFiles.sort((a, b) => a.lastModified.compareTo(b.lastModified));
    }
    return InteractiveViewer(
      transformationController: _transformationController,
      minScale: 0.5,
      maxScale: 4.0,
      boundaryMargin: const EdgeInsets.all(double.infinity),
      child: GridView.builder(
        padding: const EdgeInsets.all(8),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, crossAxisSpacing: 8, mainAxisSpacing: 8, childAspectRatio: 1.0),
        itemCount: sortedFiles.length,
        itemBuilder: (context, index) {
          final media = sortedFiles[index];
          final originalIndex = player.mediaFiles.indexOf(media);
          final isCurrent = originalIndex == player.currentIndex;
          final isFavorite = favorites.isFavorite(media.path);
          final isSelected = thumbnail.selectedFiles.contains(media.path);
          return _buildThumbnailItem(media, originalIndex, isCurrent, isFavorite, isSelected, player, thumbnail);
        },
      ),
    );
  }

  Widget _buildFolderGroupedGrid(List<MediaFile> files, PlayerProvider player, FavoritesProvider favorites, ThumbnailProvider thumbnail) {
    final folderMap = <String, List<MediaFile>>{};
    for (var file in files) {
      final folder = file.folderPath;
      if (!folderMap.containsKey(folder)) folderMap[folder] = [];
      folderMap[folder]!.add(file);
    }
    folderMap.forEach((key, value) {
      value.sort((a, b) => b.lastModified.compareTo(a.lastModified));
    });
    final folders = folderMap.keys.toList()..sort();
    return InteractiveViewer(
      transformationController: _transformationController,
      minScale: 0.5,
      maxScale: 4.0,
      boundaryMargin: const EdgeInsets.all(double.infinity),
      child: ListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: folders.length,
        itemBuilder: (context, folderIndex) {
          final folder = folders[folderIndex];
          final folderFiles = folderMap[folder]!;
          final folderName = folder.substring(folder.lastIndexOf('/') + 1);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                margin: EdgeInsets.only(top: folderIndex == 0 ? 0 : 16, bottom: 8),
                decoration: BoxDecoration(color: Colors.blue.withOpacity(0.2), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.blue.withOpacity(0.5))),
                child: Row(
                  children: [
                    const Icon(Icons.folder, color: Colors.blue, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(folderName, style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold), maxLines: 1, overflow: TextOverflow.ellipsis),
                          Text(folder, style: const TextStyle(color: Colors.white54, fontSize: 10), maxLines: 1, overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: Colors.blue, borderRadius: BorderRadius.circular(10)),
                      child: Text('${folderFiles.length}', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, crossAxisSpacing: 8, mainAxisSpacing: 8, childAspectRatio: 1.0),
                itemCount: folderFiles.length,
                itemBuilder: (context, index) {
                  final media = folderFiles[index];
                  final originalIndex = player.mediaFiles.indexOf(media);
                  final isCurrent = originalIndex == player.currentIndex;
                  final isFavorite = favorites.isFavorite(media.path);
                  final isSelected = thumbnail.selectedFiles.contains(media.path);
                  return _buildThumbnailItem(media, originalIndex, isCurrent, isFavorite, isSelected, player, thumbnail);
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildDateGroupedGrid(List<MediaFile> files, PlayerProvider player, FavoritesProvider favorites, ThumbnailProvider thumbnail) {
    final dateMap = <String, List<MediaFile>>{};
    for (var file in files) {
      final group = file.dateGroupLabel;
      if (!dateMap.containsKey(group)) dateMap[group] = [];
      dateMap[group]!.add(file);
    }
    dateMap.forEach((key, value) {
      value.sort((a, b) => b.lastModified.compareTo(a.lastModified));
    });
    final groups = ['今天', '昨天', '本周', '本月'];
    final sortedGroups = dateMap.keys.toList()..sort((a, b) {
      final aIndex = groups.indexOf(a);
      final bIndex = groups.indexOf(b);
      if (aIndex != -1 && bIndex != -1) return aIndex.compareTo(bIndex);
      if (aIndex != -1) return -1;
      if (bIndex != -1) return 1;
      return b.compareTo(a);
    });
    return InteractiveViewer(
      transformationController: _transformationController,
      minScale: 0.5,
      maxScale: 4.0,
      boundaryMargin: const EdgeInsets.all(double.infinity),
      child: ListView.builder(
        padding: const EdgeInsets.all(8),
        itemCount: sortedGroups.length,
        itemBuilder: (context, groupIndex) {
          final group = sortedGroups[groupIndex];
          final groupFiles = dateMap[group]!;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                margin: EdgeInsets.only(top: groupIndex == 0 ? 0 : 16, bottom: 8),
                decoration: BoxDecoration(color: Colors.green.withOpacity(0.2), borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.green.withOpacity(0.5))),
                child: Row(
                  children: [
                    const Icon(Icons.calendar_today, color: Colors.green, size: 18),
                    const SizedBox(width: 8),
                    Text(group, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(color: Colors.green, borderRadius: BorderRadius.circular(10)),
                      child: Text('${groupFiles.length}', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
              ),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, crossAxisSpacing: 8, mainAxisSpacing: 8, childAspectRatio: 1.0),
                itemCount: groupFiles.length,
                itemBuilder: (context, index) {
                  final media = groupFiles[index];
                  final originalIndex = player.mediaFiles.indexOf(media);
                  final isCurrent = originalIndex == player.currentIndex;
                  final isFavorite = favorites.isFavorite(media.path);
                  final isSelected = thumbnail.selectedFiles.contains(media.path);
                  return _buildThumbnailItem(media, originalIndex, isCurrent, isFavorite, isSelected, player, thumbnail);
                },
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildThumbnailItem(MediaFile media, int originalIndex, bool isCurrent, bool isFavorite, bool isSelected, PlayerProvider player, ThumbnailProvider thumbnail) {
    return GestureDetector(
      onTap: () {
        if (thumbnail.isSelectionMode) {
          thumbnail.toggleSelection(media.path);
        } else {
          player.jumpToIndex(originalIndex);
          setState(() {
            _showThumbnails = false;
            _transformationController.value = Matrix4.identity();
          });
        }
      },
      onLongPress: () {
        if (!thumbnail.isSelectionMode) {
          thumbnail.toggleSelectionMode();
          thumbnail.toggleSelection(media.path);
        }
      },
      child: Stack(
        fit: StackFit.expand,
        children: [
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: isSelected ? Colors.green : isCurrent ? Colors.blue : Colors.transparent, width: isSelected ? 4 : 3),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: media.isImage
                  ? Image.file(media.file, fit: BoxFit.cover, errorBuilder: (context, error, stackTrace) => Container(color: Colors.grey[900], child: const Icon(Icons.broken_image, color: Colors.grey, size: 32)))
                  : Container(color: Colors.grey[800], child: const Icon(Icons.play_circle_outline, color: Colors.white, size: 40)),
            ),
          ),
          if (thumbnail.isSelectionMode)
            Positioned(
              top: 4,
              left: 4,
              child: Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: isSelected ? Colors.green : Colors.black.withOpacity(0.6),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 2),
                ),
                child: isSelected ? const Icon(Icons.check, color: Colors.white, size: 16) : null,
              ),
            ),
          if (!thumbnail.isSelectionMode && isFavorite)
            Positioned(
              top: 4,
              right: 4,
              child: Container(padding: const EdgeInsets.all(4), decoration: BoxDecoration(color: Colors.black.withOpacity(0.7), shape: BoxShape.circle), child: const Icon(Icons.favorite, color: Colors.red, size: 12)),
            ),
          if (isCurrent && !thumbnail.isSelectionMode)
            Positioned(
              bottom: 4,
              left: 4,
              right: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(color: Colors.blue, borderRadius: BorderRadius.circular(8)),
                child: const Text('播放中', style: TextStyle(color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSelectionToolbar(PlayerProvider player, FavoritesProvider favorites, ThumbnailProvider thumbnail) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Colors.black.withOpacity(0.9), border: const Border(top: BorderSide(color: Colors.white24, width: 1))),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          ElevatedButton.icon(
            onPressed: () {
              final files = thumbnail.filterFiles(player.mediaFiles);
              thumbnail.selectAll(files);
            },
            icon: const Icon(Icons.select_all, size: 20),
            label: const Text('全选'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue, padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12)),
          ),
          ElevatedButton.icon(
            onPressed: thumbnail.selectedFiles.isEmpty
                ? null
                : () async {
                    await favorites.addMultipleFavorites(thumbnail.selectedFiles);
                    _showSnackBar('已添加 ${thumbnail.selectedFiles.length} 个到收藏', Colors.green);
                    thumbnail.clearSelection();
                  },
            icon: const Icon(Icons.favorite, size: 20),
            label: Text('收藏 (${thumbnail.selectedFiles.length})'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12)),
          ),
          ElevatedButton.icon(
            onPressed: thumbnail.selectedFiles.isEmpty
                ? null
                : () async {
                    try {
                      final files = thumbnail.selectedFiles.map((p) => XFile(p)).toList();
                      await Share.shareXFiles(files, text: '分享 ${files.length} 个文件');
                    } catch (e) {
                      _showSnackBar('分享失败: $e', Colors.red);
                    }
                  },
            icon: const Icon(Icons.share, size: 20),
            label: Text('分享 (${thumbnail.selectedFiles.length})'),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green, padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12)),
          ),
        ],
      ),
    );
  }

  Widget _buildFavoriteButton(PlayerProvider player, FavoritesProvider favorites) {
    if (player.currentMedia == null) return const SizedBox.shrink();
    final isFavorite = favorites.isFavorite(player.currentMedia!.path);
    return Container(
      decoration: BoxDecoration(color: Colors.black.withOpacity(0.6), shape: BoxShape.circle),
      child: IconButton(
        icon: Icon(isFavorite ? Icons.favorite : Icons.favorite_border, color: isFavorite ? Colors.red : Colors.white, size: 32),
        onPressed: () async {
          await favorites.toggleFavorite(player.currentMedia!.path);
          _showSnackBar(isFavorite ? '已取消收藏' : '已添加到收藏', isFavorite ? Colors.grey : Colors.red);
        },
      ),
    );
  }

  Widget _buildShareButton(PlayerProvider player) {
    if (player.currentMedia == null) return const SizedBox.shrink();
    return Container(
      decoration: BoxDecoration(color: Colors.black.withOpacity(0.6), shape: BoxShape.circle),
      child: IconButton(
        icon: const Icon(Icons.share, color: Colors.white, size: 32),
        onPressed: () async {
          try {
            final media = player.currentMedia!;
            await Share.shareXFiles([XFile(media.path)], text: '分享: ${media.name}');
          } catch (e) {
            _showSnackBar('分享失败: $e', Colors.red);
          }
        },
      ),
    );
  }

  Widget _buildThumbnailToggle() {
    return Container(
      decoration: BoxDecoration(color: Colors.black.withOpacity(0.6), shape: BoxShape.circle),
      child: IconButton(
        icon: Icon(_showThumbnails ? Icons.grid_off : Icons.grid_on, color: Colors.white, size: 32),
        onPressed: () => setState(() => _showThumbnails = !_showThumbnails),
      ),
    );
  }

  Widget _buildControls(PlayerProvider player, FavoritesProvider favorites, MusicProvider music) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.bottomCenter, end: Alignment.topCenter, colors: [Colors.black.withOpacity(0.8), Colors.transparent])),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(icon: const Icon(Icons.skip_previous, size: 36), color: Colors.white, onPressed: player.playPrevious),
          const SizedBox(width: 24),
          Container(
            decoration: BoxDecoration(color: Colors.white.withOpacity(0.2), shape: BoxShape.circle),
            child: IconButton(icon: Icon(player.isPlaying ? Icons.pause : Icons.play_arrow, size: 48), color: Colors.white, onPressed: () => player.isPlaying ? player.pause() : player.play()),
          ),
          const SizedBox(width: 24),
          IconButton(icon: const Icon(Icons.skip_next, size: 36), color: Colors.white, onPressed: player.playNext),
          const Spacer(),
          IconButton(icon: Icon(music.isMusicEnabled ? Icons.music_note : Icons.music_off, color: music.isMusicEnabled ? Colors.green : Colors.white, size: 28), onPressed: () => music.toggleMusic()),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(color: Colors.black.withOpacity(0.5), borderRadius: BorderRadius.circular(16)),
            child: Text('${player.currentIndex + 1} / ${player.totalCount}', style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 16),
          IconButton(icon: const Icon(Icons.settings, size: 28), color: Colors.white, onPressed: () => _showSettings(player, favorites, music)),
        ],
      ),
    );
  }

  void _showSettings(PlayerProvider player, FavoritesProvider favorites, MusicProvider music) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('设置'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.timer),
                title: const Text('图片显示时长'),
                trailing: DropdownButton<int>(
                  value: player.imageDuration,
                  items: [3, 5, 10, 15, 30, 60].map((s) => DropdownMenuItem(value: s, child: Text('$s 秒'))).toList(),
                  onChanged: (v) {
                    if (v != null) player.setImageDuration(v);
                  },
                ),
              ),
              ListTile(
                leading: const Icon(Icons.animation),
                title: const Text('过渡效果'),
                trailing: DropdownButton<TransitionEffect>(
                  value: player.transitionEffect,
                  items: TransitionEffect.values.map((effect) {
                    String name;
                    switch (effect) {
                      case TransitionEffect.fade: name = '淡入淡出'; break;
                      case TransitionEffect.slide: name = '滑动'; break;
                      case TransitionEffect.scale: name = '缩放'; break;
                      case TransitionEffect.rotate: name = '旋转'; break;
                      case TransitionEffect.blur: name = '模糊'; break;
                    }
                    return DropdownMenuItem(value: effect, child: Text(name));
                  }).toList(),
                  onChanged: (v) {
                    if (v != null) player.setTransitionEffect(v);
                  },
                ),
              ),
              ListTile(
                leading: const Icon(Icons.sort),
                title: const Text('缩略图排序'),
                trailing: DropdownButton<SortType>(
                  value: player.sortType,
                  items: SortType.values.map((type) {
                    String name;
                    switch (type) {
                      case SortType.timeNewest: name = '最新优先'; break;
                      case SortType.timeOldest: name = '最旧优先'; break;
                      case SortType.folder: name = '按文件夹'; break;
                      case SortType.dateGroup: name = '按日期'; break;
                    }
                    return DropdownMenuItem(value: type, child: Text(name));
                  }).toList(),
                  onChanged: (v) {
                    if (v != null) player.setSortType(v);
                  },
                ),
              ),
              const Divider(),
              SwitchListTile(secondary: const Icon(Icons.music_note), title: const Text('背景音乐'), value: music.isMusicEnabled, onChanged: (_) => music.toggleMusic()),
              if (music.isMusicEnabled)
                ListTile(
                  leading: const Icon(Icons.library_music),
                  title: const Text('选择音乐'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    Navigator.pop(context);
                    await music.selectMusicFile();
                  },
                ),
              const Divider(),
              SwitchListTile(
                secondary: const Icon(Icons.favorite),
                title: const Text('只显示收藏'),
                subtitle: Text('共 ${favorites.favorites.length} 个收藏'),
                value: player.showOnlyFavorites,
                onChanged: (_) => player.toggleFavoritesFilter(favorites.favorites),
              ),
              const Divider(),
              ListTile(leading: const Icon(Icons.folder_open), title: const Text('选择文件夹'), trailing: const Icon(Icons.chevron_right), onTap: () {
                Navigator.pop(context);
                _selectFolder();
              }),
              ListTile(
                leading: const Icon(Icons.refresh),
                title: const Text('重新扫描设备'),
                subtitle: const Text('清除缓存并重新扫描'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  Navigator.pop(context);
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('重新扫描'),
                      content: const Text('这将清除缓存并重新扫描整个设备，确定继续吗？'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
                        ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('确定')),
                      ],
                    ),
                  );
                  if (confirm == true && mounted) await player.rescan();
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('清除缓存'),
                subtitle: const Text('删除已保存的文件列表'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  Navigator.pop(context);
                  await MediaDatabase.clearCache();
                  _showSnackBar('缓存已清除', Colors.green);
                },
              ),
              const Divider(),
              FutureBuilder<DateTime?>(
                future: MediaDatabase.getCacheTime(),
                builder: (context, snapshot) {
                  if (snapshot.hasData && snapshot.data != null) {
                    final cacheTime = snapshot.data!;
                    final formatter = DateFormat('yyyy-MM-dd HH:mm:ss');
                    return ListTile(
                      leading: const Icon(Icons.info_outline),
                      title: const Text('关于'),
                      subtitle: Text('版本 2.1.0\n共 ${player.totalCount} 个媒体文件\n收藏 ${favorites.favorites.length} 个\n缓存时间: ${formatter.format(cacheTime)}'),
                    );
                  }
                  return ListTile(
                    leading: const Icon(Icons.info_outline),
                    title: const Text('关于'),
                    subtitle: Text('版本 2.1.0\n共 ${player.totalCount} 个媒体文件\n收藏 ${favorites.favorites.length} 个'),
                  );
                },
              ),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭'))],
      ),
    );
  }
}

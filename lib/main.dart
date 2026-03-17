import 'dart:io';
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:audioplayers/audioplayers.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  
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

// ==================== 数据模型 ====================

enum MediaType { image, video }

enum TransitionEffect {
  fade,      // 淡入淡出
  slide,     // 滑动
  scale,     // 缩放
  rotate,    // 旋转
  blur,      // 模糊
}

class MediaFile {
  final File file;
  final MediaType type;
  final String name;
  final int? duration;

  MediaFile({
    required this.file,
    required this.type,
    required this.name,
    this.duration,
  });

  String get path => file.path;
  bool get isImage => type == MediaType.image;
  bool get isVideo => type == MediaType.video;
}

// ==================== 收藏管理 ====================

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

  bool isFavorite(String path) {
    return _favorites.contains(path);
  }

  Future<void> toggleFavorite(String path) async {
    if (_favorites.contains(path)) {
      _favorites.remove(path);
    } else {
      _favorites.add(path);
    }
    await _prefs?.setStringList('favorites', _favorites.toList());
    notifyListeners();
  }

  List<MediaFile> filterFavorites(List<MediaFile> allFiles) {
    return allFiles.where((file) => _favorites.contains(file.path)).toList();
  }
}

// ==================== 背景音乐管理 ====================

class MusicProvider with ChangeNotifier {
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isMusicEnabled = false;
  String? _currentMusicPath;
  List<String> _musicFiles = [];

  bool get isMusicEnabled => _isMusicEnabled;
  String? get currentMusicPath => _currentMusicPath;
  List<String> get musicFiles => _musicFiles;

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
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowMultiple: false,
      );

      if (result != null && result.files.single.path != null) {
        final musicPath = result.files.single.path!;
        _currentMusicPath = musicPath;
        if (_isMusicEnabled) {
          await playMusic(musicPath);
        }
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

// ==================== 媒体扫描 ====================

class MediaScanner {
  static const imageExts = [
    'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp',
    'heic', 'heif', 'tiff', 'tif', 'svg', 'ico',
    'jfif', 'pjpeg', 'pjp', 'avif',
  ];
  
  static const videoExts = ['mp4', 'avi', 'mov', 'mkv', '3gp', 'webm', 'flv'];
  
  int _scannedCount = 0;
  final Function(int)? onProgress;
  
  MediaScanner({this.onProgress});
  
  Future<List<MediaFile>> scanDirectory(String dirPath) async {
    final mediaFiles = <MediaFile>[];
    final directory = Directory(dirPath);
    
    if (!await directory.exists()) {
      print('目录不存在: $dirPath');
      return mediaFiles;
    }
    
    _scannedCount = 0;
    
    try {
      await _scanRecursively(directory, mediaFiles);
      print('扫描完成，共找到 ${mediaFiles.length} 个媒体文件');
    } catch (e, stackTrace) {
      print('扫描错误: $e');
      print('堆栈: $stackTrace');
    }
    
    mediaFiles.sort((a, b) => a.file.lastModifiedSync().compareTo(b.file.lastModifiedSync()));
    
    return mediaFiles;
  }
  
  Future<void> _scanRecursively(Directory folder, List<MediaFile> result) async {
    try {
      final entities = await folder.list().toList();
      
      for (var entity in entities) {
        try {
          if (entity is Directory) {
            final dirName = path.basename(entity.path);
            if (dirName.startsWith('.') || 
                dirName == 'Android' || 
                dirName == 'thumbnails') {
              continue;
            }
            await _scanRecursively(entity, result);
          } else if (entity is File) {
            _scannedCount++;
            if (_scannedCount % 50 == 0) {
              onProgress?.call(_scannedCount);
              await Future.delayed(const Duration(milliseconds: 10));
            }
            
            final mediaFile = await _processFile(entity);
            if (mediaFile != null) {
              result.add(mediaFile);
            }
          }
        } catch (e) {
          print('处理文件失败: ${entity.path}, 错误: $e');
          continue;
        }
      }
    } catch (e) {
      print('扫描目录失败: ${folder.path}, 错误: $e');
    }
  }
  
  Future<MediaFile?> _processFile(File file) async {
    try {
      final ext = path.extension(file.path).toLowerCase().replaceAll('.', '');
      final fileName = path.basename(file.path);
      
      final fileSize = await file.length();
      if (fileSize < 1024) return null;
      
      if (imageExts.contains(ext)) {
        return MediaFile(
          file: file,
          type: MediaType.image,
          name: fileName,
        );
      } else if (videoExts.contains(ext)) {
        final duration = await _getVideoDuration(file);
        if (duration != null && duration > 0 && duration <= 120) {
          return MediaFile(
            file: file,
            type: MediaType.video,
            name: fileName,
            duration: duration,
          );
        }
      }
    } catch (e) {
      print('处理文件失败: ${file.path}, 错误: $e');
    }
    return null;
  }
  
  Future<int?> _getVideoDuration(File file) async {
    VideoPlayerController? controller;
    try {
      controller = VideoPlayerController.file(file);
      await controller.initialize().timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException('视频初始化超时'),
      );
      final duration = controller.value.duration.inSeconds;
      return duration;
    } catch (e) {
      print('获取视频时长失败: ${file.path}, 错误: $e');
      return null;
    } finally {
      await controller?.dispose();
    }
  }
  
  Future<List<MediaFile>> scanAllImages() async {
    final mediaFiles = <MediaFile>[];
    
    final commonPaths = [
      '/storage/emulated/0/DCIM',
      '/storage/emulated/0/Pictures',
      '/storage/emulated/0/Download',
      '/storage/emulated/0/Screenshots',
      '/storage/emulated/0/Camera',
    ];
    
    for (var dirPath in commonPaths) {
      final dir = Directory(dirPath);
      if (await dir.exists()) {
        print('扫描目录: $dirPath');
        await _scanRecursively(dir, mediaFiles);
      }
    }
    
    final uniqueFiles = <String, MediaFile>{};
    for (var file in mediaFiles) {
      uniqueFiles[file.path] = file;
    }
    
    final result = uniqueFiles.values.toList();
    result.sort((a, b) => a.file.lastModifiedSync().compareTo(b.file.lastModifiedSync()));
    
    return result;
  }
}

// ==================== 播放器管理 ====================

class PlayerProvider with ChangeNotifier {
  List<MediaFile> _mediaFiles = [];
  int _currentIndex = 0;
  bool _isPlaying = false;
  bool _isLoading = false;
  int _imageDuration = 5;
  Timer? _timer;
  int _scannedCount = 0;
  TransitionEffect _transitionEffect = TransitionEffect.fade;
  bool _showOnlyFavorites = false;
  
  List<MediaFile> get mediaFiles => _mediaFiles;
  MediaFile? get currentMedia => _mediaFiles.isEmpty ? null : _mediaFiles[_currentIndex];
  bool get isPlaying => _isPlaying;
  bool get isLoading => _isLoading;
  int get imageDuration => _imageDuration;
  int get currentIndex => _currentIndex;
  int get totalCount => _mediaFiles.length;
  int get scannedCount => _scannedCount;
  TransitionEffect get transitionEffect => _transitionEffect;
  bool get showOnlyFavorites => _showOnlyFavorites;
  
  PlayerProvider() {
    _loadSettings();
  }
  
  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _imageDuration = prefs.getInt('image_duration') ?? 5;
    final effectIndex = prefs.getInt('transition_effect') ?? 0;
    _transitionEffect = TransitionEffect.values[effectIndex];
    notifyListeners();
  }
  
  Future<void> loadDirectory(String dirPath) async {
    _isLoading = true;
    _scannedCount = 0;
    notifyListeners();
    
    try {
      final scanner = MediaScanner(
        onProgress: (count) {
          _scannedCount = count;
          notifyListeners();
        },
      );
      
      _mediaFiles = await scanner.scanDirectory(dirPath);
      _currentIndex = 0;
      
      print('加载完成，共 ${_mediaFiles.length} 个文件');
      
      if (_mediaFiles.isNotEmpty) {
        play();
      }
    } catch (e, stackTrace) {
      print('加载失败: $e');
      print('堆栈: $stackTrace');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
  
  Future<void> loadAllImages() async {
    _isLoading = true;
    _scannedCount = 0;
    notifyListeners();
    
    try {
      final scanner = MediaScanner(
        onProgress: (count) {
          _scannedCount = count;
          notifyListeners();
        },
      );
      
      _mediaFiles = await scanner.scanAllImages();
      _currentIndex = 0;
      
      print('扫描全部图片完成，共 ${_mediaFiles.length} 个文件');
      
      if (_mediaFiles.isNotEmpty) {
        play();
      }
    } catch (e, stackTrace) {
      print('扫描全部图片失败: $e');
      print('堆栈: $stackTrace');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
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
      if (_isPlaying) {
        _scheduleNext();
      }
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

// ==================== 主界面 ====================

class HomeScreen extends StatefulWidget {
  const HomeScreen({Key? key}) : super(key: key);

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  VideoPlayerController? _videoController;
  MediaFile? _currentDisplayedMedia;
  bool _showThumbnails = false;

  Future<void> _selectFolder() async {
    try {
      String? dir = await FilePicker.platform.getDirectoryPath();
      if (dir != null && mounted) {
        await context.read<PlayerProvider>().loadDirectory(dir);
      }
    } catch (e) {
      print('选择文件夹失败: $e');
      if (mounted) {
        _showSnackBar('选择文件夹失败: $e', Colors.red);
      }
    }
  }
  
  Future<void> _scanAllImages() async {
    try {
      await context.read<PlayerProvider>().loadAllImages();
    } catch (e) {
      print('扫描全部图片失败: $e');
      if (mounted) {
        _showSnackBar('扫描失败: $e', Colors.red);
      }
    }
  }
  
  void _showSnackBar(String message, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Consumer3<PlayerProvider, FavoritesProvider, MusicProvider>(
        builder: (context, player, favorites, music, child) {
          if (player.isLoading) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const CircularProgressIndicator(color: Colors.white),
                  const SizedBox(height: 24),
                  Text(
                    '正在扫描文件...\n已扫描: ${player.scannedCount} 个',
                    style: const TextStyle(color: Colors.white, fontSize: 18),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            );
          }

          if (player.mediaFiles.isEmpty) {
            return _buildWelcomeScreen();
          }

          return Stack(
            children: [
              // 主显示区域
              Center(
                child: _buildMediaDisplay(player),
              ),
              
              // 缩略图网格（建议1）
              if (_showThumbnails)
                _buildThumbnailGrid(player, favorites),
              
              // 控制栏
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: _buildControls(player, favorites, music),
              ),
              
              // 收藏按钮（建议2）
              Positioned(
                top: 16,
                right: 16,
                child: _buildFavoriteButton(player, favorites),
              ),
              
              // 分享按钮（建议5）
              Positioned(
                top: 16,
                right: 80,
                child: _buildShareButton(player),
              ),
              
              // 缩略图切换按钮
              Positioned(
                top: 16,
                left: 16,
                child: _buildThumbnailToggle(),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildWelcomeScreen() {
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.photo_library_outlined, size: 100, color: Colors.white54),
            const SizedBox(height: 32),
            const Text(
              '欢迎使用相册播放器 Pro',
              style: TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              '功能强大的照片和视频播放器',
              style: TextStyle(color: Colors.white70, fontSize: 16),
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
            
            ElevatedButton.icon(
              onPressed: _scanAllImages,
              icon: const Icon(Icons.search, size: 32),
              label: const Text('扫描全部图片', style: TextStyle(fontSize: 20)),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 24),
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 建议3：多种过渡动画
  Widget _buildMediaDisplay(PlayerProvider player) {
    final media = player.currentMedia!;
    
    Widget mediaWidget = media.isImage
        ? _buildImageViewer(media)
        : _buildVideoPlayer(media, player);
    
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 800),
      switchInCurve: Curves.easeInOut,
      switchOutCurve: Curves.easeInOut,
      transitionBuilder: (Widget child, Animation<double> animation) {
        switch (player.transitionEffect) {
          case TransitionEffect.fade:
            return FadeTransition(opacity: animation, child: child);
          
          case TransitionEffect.slide:
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(1.0, 0.0),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            );
          
          case TransitionEffect.scale:
            return ScaleTransition(scale: animation, child: child);
          
          case TransitionEffect.rotate:
            return RotationTransition(
              turns: animation,
              child: FadeTransition(opacity: animation, child: child),
            );
          
          case TransitionEffect.blur:
            return FadeTransition(
              opacity: animation,
              child: child,
            );
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
            Text(
              '无法加载图片\n${media.name}',
              style: const TextStyle(color: Colors.white70, fontSize: 14),
              textAlign: TextAlign.center,
            ),
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
        ? AspectRatio(
            key: ValueKey(media.path),
            aspectRatio: _videoController!.value.aspectRatio,
            child: VideoPlayer(_videoController!),
          )
        : const Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: Colors.white),
              SizedBox(height: 16),
              Text('加载视频中...', style: TextStyle(color: Colors.white)),
            ],
          );
  }
  
  Future<void> _initializeVideo(MediaFile media, PlayerProvider player) async {
    try {
      await _videoController?.dispose();
      
      _videoController = VideoPlayerController.file(media.file);
      await _videoController!.initialize();
      
      if (mounted) {
        setState(() {});
        if (player.isPlaying) {
          await _videoController!.play();
        }
      }
      
      _videoController!.addListener(() {
        if (_videoController!.value.position >= _videoController!.value.duration) {
          player.onVideoEnded();
        }
      });
    } catch (e) {
      print('视频初始化失败: ${media.path}, 错误: $e');
    }
  }

  // 建议1：缩略图网格
  Widget _buildThumbnailGrid(PlayerProvider player, FavoritesProvider favorites) {
    return Container(
      color: Colors.black.withOpacity(0.9),
      child: Column(
        children: [
          // 标题栏
          Container(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const Text(
                  '缩略图预览',
                  style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () {
                    setState(() {
                      _showThumbnails = false;
                    });
                  },
                ),
              ],
            ),
          ),
          
          // 网格
          Expanded(
            child: GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
                childAspectRatio: 1.0,
              ),
              itemCount: player.mediaFiles.length,
              itemBuilder: (context, index) {
                final media = player.mediaFiles[index];
                final isCurrent = index == player.currentIndex;
                final isFavorite = favorites.isFavorite(media.path);
                
                return GestureDetector(
                  onTap: () {
                    player.jumpToIndex(index);
                    setState(() {
                      _showThumbnails = false;
                    });
                  },
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // 缩略图
                      Container(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: isCurrent ? Colors.blue : Colors.transparent,
                            width: 3,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: media.isImage
                              ? Image.file(
                                  media.file,
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, error, stackTrace) {
                                    return const Icon(Icons.broken_image, color: Colors.grey);
                                  },
                                )
                              : Container(
                                  color: Colors.grey[800],
                                  child: const Icon(Icons.play_circle_outline, color: Colors.white, size: 40),
                                ),
                        ),
                      ),
                      
                      // 收藏标记
                      if (isFavorite)
                        Positioned(
                          top: 4,
                          right: 4,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.6),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.favorite, color: Colors.red, size: 16),
                          ),
                        ),
                      
                      // 当前播放标记
                      if (isCurrent)
                        Positioned(
                          bottom: 4,
                          left: 4,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.blue,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Text(
                              '播放中',
                              style: TextStyle(color: Colors.white, fontSize: 10),
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // 建议2：收藏按钮
  Widget _buildFavoriteButton(PlayerProvider player, FavoritesProvider favorites) {
    if (player.currentMedia == null) return const SizedBox.shrink();
    
    final isFavorite = favorites.isFavorite(player.currentMedia!.path);
    
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.6),
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: Icon(
          isFavorite ? Icons.favorite : Icons.favorite_border,
          color: isFavorite ? Colors.red : Colors.white,
          size: 32,
        ),
        onPressed: () async {
          await favorites.toggleFavorite(player.currentMedia!.path);
          _showSnackBar(
            isFavorite ? '已取消收藏' : '已添加到收藏',
            isFavorite ? Colors.grey : Colors.red,
          );
        },
      ),
    );
  }

  // 建议5：分享按钮
  Widget _buildShareButton(PlayerProvider player) {
    if (player.currentMedia == null) return const SizedBox.shrink();
    
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.6),
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: const Icon(Icons.share, color: Colors.white, size: 32),
        onPressed: () async {
          try {
            final media = player.currentMedia!;
            await Share.shareXFiles(
              [XFile(media.path)],
              text: '分享图片: ${media.name}',
            );
          } catch (e) {
            print('分享失败: $e');
            _showSnackBar('分享失败: $e', Colors.red);
          }
        },
      ),
    );
  }

  Widget _buildThumbnailToggle() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.6),
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: Icon(
          _showThumbnails ? Icons.grid_off : Icons.grid_on,
          color: Colors.white,
          size: 32,
        ),
        onPressed: () {
          setState(() {
            _showThumbnails = !_showThumbnails;
          });
        },
      ),
    );
  }

  Widget _buildControls(PlayerProvider player, FavoritesProvider favorites, MusicProvider music) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black.withOpacity(0.8), Colors.transparent],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 主控制按钮
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.skip_previous, size: 36),
                color: Colors.white,
                onPressed: player.playPrevious,
              ),
              const SizedBox(width: 24),
              Container(
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  shape: BoxShape.circle,
                ),
                child: IconButton(
                  icon: Icon(
                    player.isPlaying ? Icons.pause : Icons.play_arrow,
                    size: 48,
                  ),
                  color: Colors.white,
                  onPressed: () => player.isPlaying ? player.pause() : player.play(),
                ),
              ),
              const SizedBox(width: 24),
              IconButton(
                icon: const Icon(Icons.skip_next, size: 36),
                color: Colors.white,
                onPressed: player.playNext,
              ),
              const Spacer(),
              
              // 音乐控制（建议4）
              IconButton(
                icon: Icon(
                  music.isMusicEnabled ? Icons.music_note : Icons.music_off,
                  color: music.isMusicEnabled ? Colors.green : Colors.white,
                  size: 28,
                ),
                onPressed: () => music.toggleMusic(),
              ),
              
              // 进度显示
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  '${player.currentIndex + 1} / ${player.totalCount}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              IconButton(
                icon: const Icon(Icons.settings, size: 28),
                color: Colors.white,
                onPressed: () => _showSettings(player, favorites, music),
              ),
            ],
          ),
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
              // 图片时长
              ListTile(
                leading: const Icon(Icons.timer),
                title: const Text('图片显示时长'),
                trailing: DropdownButton<int>(
                  value: player.imageDuration,
                  items: [3, 5, 10, 15, 30, 60].map((s) {
                    return DropdownMenuItem(value: s, child: Text('$s 秒'));
                  }).toList(),
                  onChanged: (v) {
                    if (v != null) {
                      player.setImageDuration(v);
                    }
                  },
                ),
              ),
              
              // 过渡效果（建议3）
              ListTile(
                leading: const Icon(Icons.animation),
                title: const Text('过渡效果'),
                trailing: DropdownButton<TransitionEffect>(
                  value: player.transitionEffect,
                  items: TransitionEffect.values.map((effect) {
                    String name;
                    switch (effect) {
                      case TransitionEffect.fade:
                        name = '淡入淡出';
                        break;
                      case TransitionEffect.slide:
                        name = '滑动';
                        break;
                      case TransitionEffect.scale:
                        name = '缩放';
                        break;
                      case TransitionEffect.rotate:
                        name = '旋转';
                        break;
                      case TransitionEffect.blur:
                        name = '模糊';
                        break;
                    }
                    return DropdownMenuItem(value: effect, child: Text(name));
                  }).toList(),
                  onChanged: (v) {
                    if (v != null) {
                      player.setTransitionEffect(v);
                    }
                  },
                ),
              ),
              
              const Divider(),
              
              // 背景音乐（建议4）
              SwitchListTile(
                secondary: const Icon(Icons.music_note),
                title: const Text('背景音乐'),
                value: music.isMusicEnabled,
                onChanged: (_) => music.toggleMusic(),
              ),
              
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
              
              // 只显示收藏
              SwitchListTile(
                secondary: const Icon(Icons.favorite),
                title: const Text('只显示收藏'),
                subtitle: Text('共 ${favorites.favorites.length} 个收藏'),
                value: player.showOnlyFavorites,
                onChanged: (_) => player.toggleFavoritesFilter(favorites.favorites),
              ),
              
              const Divider(),
              
              // 其他选项
              ListTile(
                leading: const Icon(Icons.folder_open),
                title: const Text('选择文件夹'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.pop(context);
                  _selectFolder();
                },
              ),
              
              ListTile(
                leading: const Icon(Icons.search),
                title: const Text('扫描全部图片'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.pop(context);
                  _scanAllImages();
                },
              ),
              
              const Divider(),
              
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('关于'),
                subtitle: Text(
                  '版本 2.0.0\n共 ${player.totalCount} 个媒体文件\n收藏 ${favorites.favorites.length} 个',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _videoController?.dispose();
    super.dispose();
  }
}

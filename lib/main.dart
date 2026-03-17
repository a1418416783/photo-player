import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:video_player/video_player.dart';
import 'package:path/path.dart' as path;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 捕获全局错误
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
    return ChangeNotifierProvider(
      create: (_) => PlayerProvider(),
      child: MaterialApp(
        title: '相册播放器',
        theme: ThemeData(
          primarySwatch: Colors.blue,
          brightness: Brightness.dark,
        ),
        home: const HomeScreen(),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}

enum MediaType { image, video }

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

class MediaScanner {
  // 支持所有常见图片格式
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
    
    // 按修改时间排序
    mediaFiles.sort((a, b) => a.file.lastModifiedSync().compareTo(b.file.lastModifiedSync()));
    
    return mediaFiles;
  }
  
  Future<void> _scanRecursively(Directory folder, List<MediaFile> result) async {
    try {
      final entities = await folder.list().toList();
      
      for (var entity in entities) {
        try {
          if (entity is Directory) {
            // 跳过隐藏文件夹和系统文件夹
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
              // 每扫描50个文件暂停一下，避免阻塞UI
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
      
      // 跳过太小的文件（可能是缩略图）
      final fileSize = await file.length();
      if (fileSize < 1024) return null; // 小于1KB
      
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
  
  // 扫描整个设备的图片（优化3）
  Future<List<MediaFile>> scanAllImages() async {
    final mediaFiles = <MediaFile>[];
    
    // Android常见的图片存储位置
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
    
    // 去重
    final uniqueFiles = <String, MediaFile>{};
    for (var file in mediaFiles) {
      uniqueFiles[file.path] = file;
    }
    
    final result = uniqueFiles.values.toList();
    result.sort((a, b) => a.file.lastModifiedSync().compareTo(b.file.lastModifiedSync()));
    
    return result;
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
  
  List<MediaFile> get mediaFiles => _mediaFiles;
  MediaFile? get currentMedia => _mediaFiles.isEmpty ? null : _mediaFiles[_currentIndex];
  bool get isPlaying => _isPlaying;
  bool get isLoading => _isLoading;
  int get imageDuration => _imageDuration;
  int get currentIndex => _currentIndex;
  int get totalCount => _mediaFiles.length;
  int get scannedCount => _scannedCount;
  
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
      } else {
        print('未找到媒体文件');
      }
    } catch (e, stackTrace) {
      print('加载失败: $e');
      print('堆栈: $stackTrace');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
  
  // 优化3：扫描全部图片
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
  
  void setImageDuration(int seconds) {
    _imageDuration = seconds;
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

  Future<void> _selectFolder() async {
    try {
      String? dir = await FilePicker.platform.getDirectoryPath();
      if (dir != null && mounted) {
        await context.read<PlayerProvider>().loadDirectory(dir);
      }
    } catch (e) {
      print('选择文件夹失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('选择文件夹失败: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }
  
  // 优化3：扫描全部图片
  Future<void> _scanAllImages() async {
    try {
      await context.read<PlayerProvider>().loadAllImages();
    } catch (e) {
      print('扫描全部图片失败: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('扫描失败: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Consumer<PlayerProvider>(
        builder: (context, player, child) {
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
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.photo_library_outlined, size: 80, color: Colors.white54),
                  const SizedBox(height: 24),
                  const Text('欢迎使用相册播放器', 
                    style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),
                  const Text('选择一个选项开始',
                    style: TextStyle(color: Colors.white70, fontSize: 16)),
                  const SizedBox(height: 32),
                  
                  // 选择文件夹按钮
                  ElevatedButton.icon(
                    onPressed: _selectFolder,
                    icon: const Icon(Icons.folder_open, size: 28),
                    label: const Text('选择文件夹', style: TextStyle(fontSize: 18)),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                    ),
                  ),
                  
                  const SizedBox(height: 16),
                  
                  // 扫描全部图片按钮（优化3）
                  ElevatedButton.icon(
                    onPressed: _scanAllImages,
                    icon: const Icon(Icons.search, size: 28),
                    label: const Text('扫描全部图片', style: TextStyle(fontSize: 18)),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                    ),
                  ),
                ],
              ),
            );
          }

          final media = player.currentMedia!;
          
          return Stack(
            children: [
              // 优化4：添加淡入淡出效果
              Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 800),
                  switchInCurve: Curves.easeIn,
                  switchOutCurve: Curves.easeOut,
                  transitionBuilder: (Widget child, Animation<double> animation) {
                    return FadeTransition(
                      opacity: animation,
                      child: child,
                    );
                  },
                  child: media.isImage
                      ? _buildImageViewer(media)
                      : _buildVideoPlayer(media, player),
                ),
              ),
              
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: _buildControls(player),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildImageViewer(MediaFile media) {
    return Image.file(
      media.file,
      key: ValueKey(media.path),
      fit: BoxFit.contain,
      errorBuilder: (context, error, stackTrace) {
        print('图片加载失败: ${media.path}, 错误: $error');
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

  Widget _buildControls(PlayerProvider player) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black.withOpacity(0.8), Colors.transparent],
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.skip_previous, size: 32),
            color: Colors.white,
            onPressed: player.playPrevious,
          ),
          const SizedBox(width: 24),
          IconButton(
            icon: Icon(player.isPlaying ? Icons.pause : Icons.play_arrow, size: 48),
            color: Colors.white,
            onPressed: () => player.isPlaying ? player.pause() : player.play(),
          ),
          const SizedBox(width: 24),
          IconButton(
            icon: const Icon(Icons.skip_next, size: 32),
            color: Colors.white,
            onPressed: player.playNext,
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.5),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(
              '${player.currentIndex + 1} / ${player.totalCount}',
              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(width: 16),
          IconButton(
            icon: const Icon(Icons.settings, size: 28),
            color: Colors.white,
            onPressed: () => _showSettings(player),
          ),
        ],
      ),
    );
  }

  void _showSettings(PlayerProvider player) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('设置'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
                    Navigator.pop(context);
                  }
                },
              ),
            ),
            const Divider(),
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
              subtitle: Text('共 ${player.totalCount} 个媒体文件'),
            ),
          ],
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

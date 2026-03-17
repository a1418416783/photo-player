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
  static const imageExts = [
  'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp',  // 常见格式
  'heic', 'heif',  // iOS格式
  'tiff', 'tif',   // TIFF格式
  'svg',           // 矢量图
  'ico',           // 图标
  'jfif',          // JPEG变体
  'pjpeg', 'pjp',  // 渐进式JPEG
  'avif',          // 新格式
];
  static const videoExts = ['mp4', 'avi', 'mov', 'mkv', '3gp'];
  
  Future<List<MediaFile>> scanDirectory(String dirPath) async {
    final mediaFiles = <MediaFile>[];
    final directory = Directory(dirPath);
    
    if (!await directory.exists()) return mediaFiles;
    
    try {
      await for (var entity in directory.list(recursive: true)) {
        if (entity is File) {
          final ext = path.extension(entity.path).toLowerCase().replaceAll('.', '');
          final name = path.basename(entity.path);
          
          if (imageExts.contains(ext)) {
            mediaFiles.add(MediaFile(
              file: entity,
              type: MediaType.image,
              name: name,
            ));
          } else if (videoExts.contains(ext)) {
            final duration = await _getVideoDuration(entity);
            if (duration != null && duration > 0 && duration <= 120) {
              mediaFiles.add(MediaFile(
                file: entity,
                type: MediaType.video,
                name: name,
                duration: duration,
              ));
            }
          }
        }
      }
    } catch (e) {
      print('扫描错误: $e');
    }
    
    return mediaFiles;
  }
  
  Future<int?> _getVideoDuration(File file) async {
    try {
      final controller = VideoPlayerController.file(file);
      await controller.initialize();
      final duration = controller.value.duration.inSeconds;
      await controller.dispose();
      return duration;
    } catch (e) {
      return null;
    }
  }
}

class PlayerProvider with ChangeNotifier {
  List<MediaFile> _mediaFiles = [];
  int _currentIndex = 0;
  bool _isPlaying = false;
  bool _isLoading = false;
  int _imageDuration = 5;
  Timer? _timer;
  
  List<MediaFile> get mediaFiles => _mediaFiles;
  MediaFile? get currentMedia => _mediaFiles.isEmpty ? null : _mediaFiles[_currentIndex];
  bool get isPlaying => _isPlaying;
  bool get isLoading => _isLoading;
  int get imageDuration => _imageDuration;
  int get currentIndex => _currentIndex;
  int get totalCount => _mediaFiles.length;
  
  Future<void> loadDirectory(String dirPath) async {
    _isLoading = true;
    notifyListeners();
    
    try {
      final scanner = MediaScanner();
      _mediaFiles = await scanner.scanDirectory(dirPath);
      _currentIndex = 0;
      
      if (_mediaFiles.isNotEmpty) {
        play();
      }
    } catch (e) {
      print('加载失败: $e');
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Consumer<PlayerProvider>(
        builder: (context, player, child) {
          if (player.isLoading) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: Colors.white),
                  SizedBox(height: 24),
                  Text('正在扫描文件...', style: TextStyle(color: Colors.white, fontSize: 18)),
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
                  const Text('点击下方按钮选择相册文件夹',
                    style: TextStyle(color: Colors.white70, fontSize: 16)),
                  const SizedBox(height: 32),
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
                ],
              ),
            );
          }

          final media = player.currentMedia!;
          
          return Stack(
            children: [
              Center(
                child: media.isImage
                    ? Image.file(media.file, fit: BoxFit.contain)
                    : _buildVideoPlayer(media, player),
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

  Widget _buildVideoPlayer(MediaFile media, PlayerProvider player) {
    if (_videoController?.dataSource != media.path) {
      _videoController?.dispose();
      _videoController = VideoPlayerController.file(media.file)
        ..initialize().then((_) {
          if (mounted) {
            setState(() {});
            if (player.isPlaying) {
              _videoController!.play();
            }
          }
          _videoController!.addListener(() {
            if (_videoController!.value.position >= _videoController!.value.duration) {
              player.onVideoEnded();
            }
          });
        });
    }
    
    return _videoController != null && _videoController!.value.isInitialized
        ? AspectRatio(
            aspectRatio: _videoController!.value.aspectRatio,
            child: VideoPlayer(_videoController!),
          )
        : const CircularProgressIndicator(color: Colors.white);
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
                items: [3, 5, 10, 15, 30].map((s) {
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
              title: const Text('更换文件夹'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.pop(context);
                _selectFolder();
              },
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

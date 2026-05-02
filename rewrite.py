import re

with open('lib/src/independent/minis_video_preview_page.dart', 'r', encoding='utf-8') as f:
    code = f.read()

# 1. Add import
code = code.replace(
    "import 'package:video_player/video_player.dart';",
    "import 'package:video_player/video_player.dart';\nimport 'package:loopit_minis/src/independent/minis_preview_player.dart';"
)

# 2. Add nativeController state
code = code.replace(
    '  VideoPlayerController? _controller;',
    '  VideoPlayerController? _controller;\n  MinisPreviewPlayerController? _nativeController;\n  bool get _isMultiClip => _paths.length > 1;'
)

# 3. Update initState
init_state_old = '''    // Asynchronously probe duration in case VideoPlayer fails to read it.
    minisFinalizeClipDurationMs(1, _path, fromGalleryFile: true).then((ms) {
      if (mounted) setState(() => _probedDurationMs = ms);
    });
    
    unawaited(_initPlaybackAsync());'''

init_state_new = '''    // Asynchronously probe duration in case VideoPlayer fails to read it.
    minisFinalizeClipDurationMs(1, _path, fromGalleryFile: true).then((ms) {
      if (mounted) setState(() => _probedDurationMs = ms);
    });
    
    if (_isMultiClip) {
      _nativeController = MinisPreviewPlayerController(_paths);
      _nativeController!.addListener(() {
        if (mounted) setState(() {});
      });
      // Start fake player initialization
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // Wait briefly for native creation
      });
    } else {
      unawaited(_initPlaybackAsync());
    }'''
code = code.replace(init_state_old, init_state_new)

# 4. Update dispose
dispose_old = '''    _controller?.removeListener(_onVideoTick);
    _controller?.dispose();'''
dispose_new = '''    _controller?.removeListener(_onVideoTick);
    _controller?.dispose();
    _nativeController?.dispose();'''
code = code.replace(dispose_old, dispose_new)

# 5. Fix UI getter logic
code = code.replace(
    '''  Widget build(BuildContext context) {
    final c = _controller;''',
    '''  Widget build(BuildContext context) {
    final c = _controller;
    final nc = _nativeController;
    
    final bool isReady = _isMultiClip ? (nc?.isInitialized == true) : (c?.value.isInitialized == true);
    final bool isPlaying = _isMultiClip ? (nc?.isPlaying == true) : (c?.value.isPlaying == true);
    final Duration currentPos = _isMultiClip ? (nc?.position ?? Duration.zero) : (c?.value.position ?? Duration.zero);
    final int currentDurMs = _isMultiClip ? (nc?.duration.inMilliseconds ?? 0) : (c?.value.duration.inMilliseconds ?? 0);
    final int totalDurMs = currentDurMs > 0 ? currentDurMs : (_probedDurationMs ?? 0);
    final double ar = _isMultiClip ? ((nc?.videoSize?.width ?? 1) / (nc?.videoSize?.height ?? 1)) : (c?.value.aspectRatio ?? 1);
'''
)

# 6. Replace c.value.isInitialized logic
code = re.sub(r'c == null \|\| !c\.value\.isInitialized', r'!isReady', code)
code = re.sub(r'c != null && c\.value\.isInitialized', r'isReady', code)
code = re.sub(r'c != null &&\s*c\.value\.isInitialized', r'isReady', code)

# 7. Replace playing logic
code = code.replace('c.value.isPlaying', 'isPlaying')
code = code.replace('''if (isPlaying) {
                                                    c.pause();
                                                  } else {
                                                    c.play();
                                                  }''', 
                                                  '''if (isPlaying) {
                                                    _isMultiClip ? nc?.pause() : c?.pause();
                                                  } else {
                                                    _isMultiClip ? nc?.play() : c?.play();
                                                  }''')

# 8. Replace position/duration format
code = code.replace('_formatDuration(c.value.position)', '_formatDuration(currentPos)')
code = code.replace('c.value.duration.inMilliseconds', 'currentDurMs')
code = code.replace('c.value.position.inMilliseconds', 'currentPos.inMilliseconds')
code = code.replace('c.value.aspectRatio', 'ar')

# 9. Replace VideoPlayer(c) widget
code = code.replace('''Positioned.fill(
                                              child: VideoPlayer(c),
                                            ),''', 
                                            '''Positioned.fill(
                                              child: _isMultiClip ? MinisPreviewPlayerWidget(controller: nc!) : VideoPlayer(c!),
                                            ),''')

# 10. Replace seek logic
code = code.replace('''c.seekTo(
                                              Duration(milliseconds: v.round()),
                                            );''',
                                            '''final seekDur = Duration(milliseconds: v.round());
                                            _isMultiClip ? nc?.seekTo(seekDur) : c?.seekTo(seekDur);''')


# Remove playlist swapping from old _onVideoTick
code = re.sub(r'''if \(_paths\.length > 1 && c\.value\.position >= c\.value\.duration && c\.value\.duration > Duration\.zero\) \{
        // Auto-advance to next clip in playlist
        _isSwitchingVideo = true;
        _currentIndex = \(_currentIndex \+ 1\) % _paths\.length;
        _path = _paths\[_currentIndex\];
        unawaited\(_initPlaybackAsync\(\)\);
        return;
      \}''', '', code)


with open('lib/src/independent/minis_video_preview_page.dart', 'w', encoding='utf-8') as f:
    f.write(code)

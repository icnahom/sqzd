// ignore_for_file: deprecated_member_use

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

final FlutterLocalNotificationsPlugin localNotifications =
    FlutterLocalNotificationsPlugin();

late BackgroundAudioHandler audioHandler;

final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

void main() async {
  // 1. Ensure Flutter bindings are initialized
  WidgetsFlutterBinding.ensureInitialized();

  // 2. Initialize independent services
  await _initNotifications();
  await _initAudioSession();

  // 3. Load async data needed by AppState synchronously
  final sharedPrefs = await SharedPreferences.getInstance();
  const secureStorage = FlutterSecureStorage();
  final geminiApiKey = await secureStorage.read(key: 'gemini_api_key');

  // 4. Initialize Audio engine safely
  try {
    await SoLoud.instance.init();
  } catch (e) {
    debugPrint("SoLoud Init Error: $e");
  }

  // 5. Run the app, injecting the resolved dependencies
  runApp(
    ChangeNotifierProvider(
      create: (_) => AppState(
        sharedPrefs: sharedPrefs,
        secureStorage: secureStorage,
        initialApiKey: geminiApiKey,
      ),
      child: const MyApp(),
    ),
  );
}

Future<void> _initNotifications() async {
  const AndroidInitializationSettings initSettingsAndroid =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  const DarwinInitializationSettings initSettingsIOS =
      DarwinInitializationSettings();
  const InitializationSettings initSettings = InitializationSettings(
    android: initSettingsAndroid,
    iOS: initSettingsIOS,
  );
  await localNotifications.initialize(settings: initSettings);

  localNotifications
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.requestNotificationsPermission();
}

Future<void> _initAudioSession() async {
  final session = await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration.music());

  audioHandler = await AudioService.init(
    builder: BackgroundAudioHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.example.sqzd',
      androidNotificationChannelName: 'sqzd Playback',
      androidNotificationOngoing: true,
      androidShowNotificationBadge: true,
      androidNotificationIcon: 'drawable/ic_notification',
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'sqzd',
      scaffoldMessengerKey: scaffoldMessengerKey,
      theme: ThemeData.dark().copyWith(
        colorScheme: const ColorScheme.dark(primary: Colors.greenAccent),
        scaffoldBackgroundColor: Colors.black,
      ),
      home: const YouTubeBrowserScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class BackgroundAudioHandler extends BaseAudioHandler {
  Function()? onPlayAction;
  Function()? onPauseAction;
  Function()? onSkipNextAction;
  Function()? onSkipPrevAction;
  Function(Duration)? onSeekAction;

  @override
  Future<void> play() async => onPlayAction?.call();

  @override
  Future<void> pause() async => onPauseAction?.call();

  @override
  Future<void> skipToNext() async => onSkipNextAction?.call();

  @override
  Future<void> skipToPrevious() async => onSkipPrevAction?.call();

  @override
  Future<void> seek(Duration position) async => onSeekAction?.call(position);
}

class Highlight {
  final String title;
  final double start;
  final double end;

  Highlight({
    required this.title,
    required this.start,
    required this.end,
  });

  Highlight copyWith({
    String? title,
    double? start,
    double? end,
  }) {
    return Highlight(
      title: title ?? this.title,
      start: start ?? this.start,
      end: end ?? this.end,
    );
  }

  factory Highlight.fromJson(Map<String, dynamic> json) {
    return Highlight(
      title: json['title'] as String? ?? '',
      start: (json['start'] as num?)?.toDouble() ?? 0.0,
      end: (json['end'] as num?)?.toDouble() ?? 0.0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'start': start,
      'end': end,
    };
  }
}

class AppState extends ChangeNotifier {
  static const String _geminiBaseUrl =
      'https://generativelanguage.googleapis.com/v1beta';

  final SharedPreferences sharedPrefs;
  final FlutterSecureStorage _secureStorage;

  String? geminiApiKey;

  List<String> availableModels = [];
  String? selectedModel;
  String? selectedTtsModel;

  List<String> get textModels => availableModels
      .where(
        (m) =>
            m.toLowerCase().contains('gemini') &&
            !m.toLowerCase().contains('tts'),
      )
      .toList();
  List<String> get ttsModels =>
      availableModels.where((m) => m.toLowerCase().contains('tts')).toList();

  // 1 = Short, 2 = Medium, 3 = Detailed
  int highlightDensity = 2;

  bool isProcessing = false;

  bool isAppInBackground = false;

  String? currentVideoId;
  List<Highlight> extractedHighlights = [];
  int currentHighlightIndex = 0;

  double totalOriginalDuration = 0;
  double currentVideoTime = 0.0;

  bool isVideoPlaying = false;
  bool _isHandlingSkip = false;

  // Hardcoded flag controlling whether highlight TTS audio is played
  bool isTtsEnabled = true;

  InAppWebViewController? webViewController;

  final SoLoud soLoud = SoLoud.instance;
  final DefaultCacheManager cacheManager = DefaultCacheManager();

  SoundHandle? _activeTtsHandle;
  bool _isTtsPlaying = false;
  bool get isTtsPlaying => _isTtsPlaying;
  bool isTtsLoading = false;

  int _highlightSessionId = 0;

  AppState({
    required this.sharedPrefs,
    required FlutterSecureStorage secureStorage,
    String? initialApiKey,
  }) : _secureStorage = secureStorage,
       geminiApiKey = initialApiKey {
    _loadCachedPreferences();
    _setupAudioHandler();
  }

  void _loadCachedPreferences() {
    selectedModel = sharedPrefs.getString('selected_gemini_model');
    selectedTtsModel = sharedPrefs.getString('selected_tts_model');

    if (sharedPrefs.getStringList('all_models_list')
        case final List<String> cachedModels) {
      availableModels = cachedModels;
    }
  }

  void _setupAudioHandler() {
    audioHandler.onPlayAction = () => _resumeWebviewAndExecute(_playVideo);
    audioHandler.onPauseAction = () => _resumeWebviewAndExecute(() {
      stopTtsAudio();
      executeVideoJavascript("v.pause();");
    });
    audioHandler.onSkipNextAction = () => _resumeWebviewAndExecute(() {
      if (extractedHighlights.isNotEmpty &&
          currentHighlightIndex < extractedHighlights.length - 1) {
        seekToHighlight(currentHighlightIndex + 1);
      }
    });
    audioHandler.onSkipPrevAction = () => _resumeWebviewAndExecute(() {
      if (extractedHighlights.isNotEmpty && currentHighlightIndex > 0) {
        seekToHighlight(currentHighlightIndex - 1);
      }
    });
    audioHandler.onSeekAction = (position) {
      if (extractedHighlights.isNotEmpty) {
        if (_isTtsPlaying) {
          stopTtsAudio();
          _playVideo();
        }

        final highlight = extractedHighlights[currentHighlightIndex];
        final targetVideoTime =
            highlight.start + (position.inMilliseconds / 1000.0);

        _resumeWebviewAndExecute(() {
          executeVideoJavascript("v.currentTime = $targetVideoTime;");
          currentVideoTime = targetVideoTime;
          notifyListeners();
          _updateAudioPlaybackState();
        });
      }
    };
  }

  void _resumeWebviewAndExecute(VoidCallback action) {
    webViewController?.resume();
    action();
  }

  Future<dynamic> executeVideoJavascript(
    String command, {
    bool? setIntent,
  }) async {
    final intentStr = setIntent != null
        ? "window.__sqzdUserIntent = $setIntent;"
        : "";
    return webViewController?.evaluateJavascript(
      source:
          "$intentStr var v = document.getElementsByTagName('video')[0]; if(v) { $command }",
    );
  }

  void _updateAudioPlaybackState() {
    if (extractedHighlights.isEmpty) {
      audioHandler.playbackState.add(
        PlaybackState(
          processingState: AudioProcessingState.idle,
          playing: false,
        ),
      );
      return;
    }

    final isPlaying = isVideoPlaying || _isTtsPlaying;

    var position = Duration.zero;
    if (extractedHighlights.isNotEmpty) {
      final highlight = extractedHighlights[currentHighlightIndex];
      final posSec = math.max(0.0, currentVideoTime - highlight.start);
      position = Duration(milliseconds: (posSec * 1000).toInt());
    }

    audioHandler.playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          if (isPlaying) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: isTtsLoading
            ? AudioProcessingState.buffering
            : AudioProcessingState.ready,
        playing: isPlaying,
        updatePosition: position,
      ),
    );
  }

  void _updateAudioMediaItem() {
    if (extractedHighlights.isEmpty) return;

    final highlight = extractedHighlights[currentHighlightIndex];
    final duration = Duration(
      milliseconds: ((highlight.end - highlight.start) * 1000).toInt(),
    );

    audioHandler.mediaItem.add(
      MediaItem(
        id: currentVideoId ?? 'sqzd',
        title: highlight.title.isNotEmpty ? highlight.title : 'Highlight ${currentHighlightIndex + 1}',
        artist:
            'Highlight ${currentHighlightIndex + 1} of ${extractedHighlights.length}',
        duration: duration,
      ),
    );
  }

  Future<void> saveApiKey(String key) async {
    geminiApiKey = key;
    await _secureStorage.write(key: 'gemini_api_key', value: key);
    notifyListeners();
    await fetchGeminiModels();
  }

  String? selectCheapAndLatest(List<String> models) {
    final geminiFlashRegex = RegExp(
      r'^gemini-\d+(?:\.\d+)?-flash(\b|-[a-z0-9-]+)$',
    );
    final matched =
        models.where((m) => geminiFlashRegex.hasMatch(m.toLowerCase())).toList()
          ..sort();
    return matched.isNotEmpty ? matched.last : models.firstOrNull;
  }

  Future<void> fetchGeminiModels() async {
    if (geminiApiKey == null || geminiApiKey!.isEmpty) return;

    try {
      final res = await http.get(
        Uri.parse('$_geminiBaseUrl/models?key=$geminiApiKey'),
      );
      final jsonResponse = jsonDecode(res.body);

      if (res.statusCode == 200) {
        if (jsonResponse case {'models': List models}) {
          availableModels = [
            for (final m in models)
              if (m case {
                'name': String name,
                'supportedGenerationMethods': List methods,
                'thinking': bool thinking,
              } when methods.contains('generateContent') && thinking)
                name.replaceFirst('models/', ''),
          ];
        }

        await sharedPrefs.setStringList('all_models_list', availableModels);

        if (selectedModel == null || !textModels.contains(selectedModel)) {
          selectedModel = selectCheapAndLatest(textModels);
        }
        if (selectedTtsModel == null || !ttsModels.contains(selectedTtsModel)) {
          selectedTtsModel = selectCheapAndLatest(ttsModels);
        }

        if (selectedModel != null) {
          await sharedPrefs.setString('selected_gemini_model', selectedModel!);
        }
        if (selectedTtsModel != null) {
          await sharedPrefs.setString('selected_tts_model', selectedTtsModel!);
        }
      } else {
        debugPrint(switch (jsonResponse) {
          {'error': {'message': String msg}} => msg,
          _ => "Error fetching models (${res.statusCode}).",
        });
      }
    } catch (e) {
      debugPrint("Error fetching models: $e");
    }

    notifyListeners();
  }

  void selectModel(String model, bool isTts) {
    if (isTts) {
      selectedTtsModel = model;
      sharedPrefs.setString('selected_tts_model', model);
    } else {
      selectedModel = model;
      sharedPrefs.setString('selected_gemini_model', model);
    }
    notifyListeners();
  }

  void setSummaryLength(int value) {
    highlightDensity = value;
    notifyListeners();
  }

  void handleSharedUrl(String url) {
    executeVideoJavascript("v.pause();", setIntent: false);
    webViewController?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  void setPlayState(bool playing) {
    if (playing && _isTtsPlaying) {
      stopTtsAudio();
    }
    if (isVideoPlaying != playing) {
      isVideoPlaying = playing;
      notifyListeners();
      _updateAudioPlaybackState();
    }
  }

  void updatePlaybackProgress(double time) {
    if (currentVideoTime != time) {
      final oldTime = currentVideoTime;
      currentVideoTime = time;
      notifyListeners();

      if ((time - oldTime).abs() > 2.0 && isVideoPlaying) {
        _updateAudioPlaybackState();
      }

      if (extractedHighlights.isNotEmpty && !_isHandlingSkip) {
        final highlight = extractedHighlights[currentHighlightIndex];
        final triggerTime = (highlight.end - 0.2) <= highlight.start
            ? highlight.end
            : highlight.end - 0.2;

        if (time >= triggerTime && time > highlight.start) {
          handleHighlightEnded(currentHighlightIndex);
        }
      }
    }
  }

  void togglePlayPause() {
    if (_isTtsPlaying) {
      stopTtsAudio();
      _playVideo();
    } else if (extractedHighlights.isNotEmpty &&
        currentHighlightIndex >= extractedHighlights.length - 1 &&
        !isVideoPlaying) {
      seekToHighlight(currentHighlightIndex);
    } else {
      _resumeWebviewAndExecute(() {
        executeVideoJavascript(
          "v.paused ? v.play() : v.pause();",
          setIntent: true,
        );
      });
    }
  }

  void _playVideo() {
    executeVideoJavascript("""
        v.volume = 1.0;
        v.play().catch(e => {
          let b = document.querySelector('.ytp-play-button') || document.querySelector('.icon-button[aria-label="Play video"]');
          if(b) b.click();
        });
    """, setIntent: true);
  }

  Future<void> seekToHighlight(int index, {bool highlightEnded = false}) async {
    _highlightSessionId++;
    final currentSession = _highlightSessionId;
    _isHandlingSkip = false;

    currentHighlightIndex = index;
    final highlight = extractedHighlights[index];
    currentVideoTime = highlight.start;
    notifyListeners();

    _updateAudioMediaItem();

    stopTtsAudio();

    executeVideoJavascript("""
        v.pause(); 
        v.currentTime = ${highlight.start}; 
        v.volume = 1.0; 
    """, setIntent: true);

    if (highlightEnded) {
      await _playTransitionSfx();
    }

    final ttsText = highlight.title.isNotEmpty
        ? highlight.title
        : 'Highlight ${index + 1} of ${extractedHighlights.length}.';

    if (isTtsEnabled && highlightEnded) {
      _isTtsPlaying = true;
      await _playTtsAudio(ttsText);

      if (currentSession == _highlightSessionId && _isTtsPlaying) {
        _isTtsPlaying = false;
        _playVideo();
      }
    } else {
      if (currentSession == _highlightSessionId) {
        _playVideo();
      }
    }
  }

  void updateHighlightIndex(int index) {
    if (currentHighlightIndex != index) {
      currentHighlightIndex = index;
      notifyListeners();
    }
  }

  void clearHighlights() {
    stopTtsAudio();
    extractedHighlights = [];
    currentHighlightIndex = 0;
    currentVideoTime = 0.0;
    totalOriginalDuration = 0;

    audioHandler.playbackState.add(
      PlaybackState(processingState: AudioProcessingState.idle, playing: false),
    );

    notifyListeners();
  }

  String _getCacheKey(String videoId) => "yt_highlights_v1_$videoId";

  bool loadCachedHighlights(
    String videoId, {
    bool checkScale = false,
    VoidCallback? onSuccess,
  }) {
    if (sharedPrefs.getString(_getCacheKey(videoId))
        case final String cachedStr) {
      if (jsonDecode(cachedStr)
          case {
            'timestamp': int timestamp,
            'scale': int cachedScale,
            'duration': num duration,
            'highlights': List highlights,
          }
          when DateTime.now().millisecondsSinceEpoch - timestamp <
              7 * 24 * 60 * 60 * 1000) {
        if (checkScale && cachedScale != highlightDensity) return false;

        highlightDensity = cachedScale;
        totalOriginalDuration = duration.toDouble();
        
        final parsed = (highlights)
            .map((h) => Highlight.fromJson(Map<String, dynamic>.from(h)))
            .toList();

        _applyHighlights(
          parsed,
          autoplay: false,
          onSuccess: onSuccess,
        );
        return true;
      }
    }
    return false;
  }

  void _setTtsLoading(bool loading, int mySessionId) {
    if (isTtsLoading != loading && mySessionId == _highlightSessionId) {
      isTtsLoading = loading;
      notifyListeners();
    }
  }

  void stopTtsAudio() {
    _isTtsPlaying = false;
    _setTtsLoading(false, _highlightSessionId);
    if (_activeTtsHandle != null) {
      soLoud.stop(_activeTtsHandle!);
      _activeTtsHandle = null;
    }
    _updateAudioPlaybackState();
  }

  Stream<Uint8List> _streamSpeech(String text) async* {
    if (geminiApiKey == null) return;

    const voices = [
      'Aoede',
      'Charon',
      'Fenrir',
      'Kore',
      'Puck',
      'Zephyr',
      'Leda',
      'Orus',
      'Callirrhoe',
      'Autonoe',
      'Enceladus',
      'Iapetus',
      'Umbriel',
      'Algieba',
      'Despina',
      'Erinome',
      'Algenib',
      'Rasalgethi',
      'Laomedeia',
      'Achernar',
      'Alnilam',
      'Schedar',
      'Gacrux',
      'Pulcherrima',
      'Achird',
      'Zubenelgenubi',
      'Vindemiatrix',
      'Sadachbia',
      'Sadaltager',
      'Sulafat',
    ];
    final selectedVoiceName = voices[math.Random().nextInt(voices.length)];
    final ttsModel = selectedTtsModel ?? 'gemini-2.5-flash-preview-tts';

    final client = http.Client();
    final request = http.Request(
      'POST',
      Uri.parse(
        '$_geminiBaseUrl/models/$ttsModel:streamGenerateContent?key=$geminiApiKey&alt=sse',
      ),
    );
    request.headers['Content-Type'] = 'application/json';
    request.body = jsonEncode({
      'contents': [
        {
          'parts': [
            {'text': "Read this in a fast, engaging tone: '$text'"},
          ],
        },
      ],
      'generationConfig': {
        'responseModalities': ['AUDIO'],
        'speechConfig': {
          'voiceConfig': {
            'prebuiltVoiceConfig': {'voiceName': selectedVoiceName},
          },
        },
      },
    });

    try {
      final streamedResponse = await client.send(request);
      if (streamedResponse.statusCode != 200) {
        throw Exception("TTS Streaming Error: ${streamedResponse.statusCode}");
      }

      await for (final line
          in streamedResponse.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        const ssePrefix = 'data: ';
        if (line.startsWith(ssePrefix)) {
          final jsonString = line.substring(ssePrefix.length);
          if (jsonString.trim().isEmpty) continue;

          final body = jsonDecode(jsonString);

          if (body case {'error': {'message': String msg}}) {
            throw Exception(msg);
          }

          if (body case {
            'candidates': [
              {'content': {'parts': [{'inlineData': {'data': String data}}]}},
              ...,
            ],
          }) {
            yield base64Decode(data);
          }
        }
      }
    } finally {
      client.close();
    }
  }

  Future<void> _playTtsAudio(String text) async {
    final mySessionId = _highlightSessionId;
    try {
      _setTtsLoading(true, mySessionId);
      _updateAudioPlaybackState();

      final cacheKey = "tts_${sha256.convert(utf8.encode(text)).toString()}";
      final fileInfo = await cacheManager.getFileFromCache(cacheKey);

      var audioSource = soLoud.setBufferStream(
        bufferingType: BufferingType.preserved,
        channels: Channels.mono,
        sampleRate: 24000,
        format: BufferType.s16le,
      );

      if (fileInfo != null) {
        _setTtsLoading(false, mySessionId);
        final bytes = await fileInfo.file.readAsBytes();
        soLoud.addAudioDataStream(audioSource, bytes);
        soLoud.setDataIsEnded(audioSource);

        if (mySessionId != _highlightSessionId) return;
        _activeTtsHandle = await soLoud.play(audioSource);
      } else {
        if (mySessionId != _highlightSessionId) return;
        _activeTtsHandle = await soLoud.play(audioSource);

        final audioChunks = BytesBuilder();
        var isSourceEnded = false;
        var hasError = false;

        try {
          await for (final chunk in _streamSpeech(text)) {
            _setTtsLoading(false, mySessionId);
            audioChunks.add(chunk);
            final isActive =
                _isTtsPlaying && (mySessionId == _highlightSessionId);

            if (isActive && !isSourceEnded) {
              soLoud.addAudioDataStream(audioSource, chunk);
            } else if (!isSourceEnded) {
              soLoud.setDataIsEnded(audioSource);
              isSourceEnded = true;
            }
          }
        } catch (e) {
          debugPrint("Speech Streaming Error: $e");
          hasError = true;
        } finally {
          _setTtsLoading(false, mySessionId);
          if (!isSourceEnded) {
            try {
              soLoud.setDataIsEnded(audioSource);
            } catch (_) {}
          }
          if (audioChunks.isNotEmpty && !hasError) {
            await cacheManager.putFile(
              cacheKey,
              audioChunks.toBytes(),
              fileExtension: 'pcm',
            );
          }
        }
      }

      while (_isTtsPlaying &&
          mySessionId == _highlightSessionId &&
          _activeTtsHandle != null &&
          soLoud.getIsValidVoiceHandle(_activeTtsHandle!)) {
        await Future.delayed(const Duration(milliseconds: 100));
      }

      try {
        soLoud.disposeSource(audioSource);
      } catch (_) {}
      if (mySessionId == _highlightSessionId) _activeTtsHandle = null;
    } catch (e) {
      debugPrint("TTS Audio Setup Error: $e");
      _setTtsLoading(false, mySessionId);
      if (_isTtsPlaying && mySessionId == _highlightSessionId) {
        await Future.delayed(const Duration(seconds: 2));
      }
    }
  }

  Future<void> handleHighlightEnded(int currentIndex) async {
    if (_isHandlingSkip) return;
    _isHandlingSkip = true;

    if (currentIndex >= extractedHighlights.length - 1) {
      executeVideoJavascript("v.pause();");
      setPlayState(false);
      _showSavedTimeSnackbar();
      await _playSuccessSfx();
    } else {
      await seekToHighlight(currentIndex + 1, highlightEnded: true);
    }

    _isHandlingSkip = false;
  }

  void _showSavedTimeSnackbar() {
    if (totalOriginalDuration <= 0) return;

    double totalHighlightDuration = 0;
    for (final h in extractedHighlights) {
      totalHighlightDuration += (h.end - h.start);
    }

    final savedSeconds = totalOriginalDuration - totalHighlightDuration;
    if (savedSeconds <= 0) return;

    final savedMinutes = (savedSeconds / 60).round();
    final savedText = savedMinutes > 0
        ? "$savedMinutes minute${savedMinutes > 1 ? 's' : ''}"
        : "${savedSeconds.round()} seconds";

    scaffoldMessengerKey.currentState?.clearSnackBars();
    scaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text("🎉 You've saved $savedText!"),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  AudioSource? _transitionSfxSource;
  Future<void> _playTransitionSfx() async {
    try {
      _transitionSfxSource ??= await soLoud.loadAsset(
        'assets/sfx/kauasilbershlachparodes-shutter-click-3-494029.mp3',
      );
      await soLoud.play(_transitionSfxSource!, volume: 0.35);
    } catch (e) {
      debugPrint("Transition SFX Error: $e");
    }
  }

  AudioSource? _successSfxSource;
  Future<void> _playSuccessSfx() async {
    try {
      _successSfxSource ??= await soLoud.loadAsset('assets/sfx/36505577-smooth-completed-notify-274735.mp3');
      await soLoud.play(_successSfxSource!, volume: 0.5);
    } catch (e) {
      debugPrint("Success SFX Error: $e");
    }
  }

  Future<void> _fetchTotalOriginalDuration() async {
    final durationJS = await webViewController?.evaluateJavascript(
      source:
          "document.getElementsByTagName('video')[0] ? document.getElementsByTagName('video')[0].duration : 0",
    );
    totalOriginalDuration = (durationJS is num) ? durationJS.toDouble() : 0.0;
  }

  Future<void> generateHighlights(
    String videoUrl, {
    bool forceRegenerate = false,
    required void Function(String) onError,
    VoidCallback? onSuccess,
  }) async {
    if (geminiApiKey == null || selectedModel == null) {
      onError("Error: Please set Gemini API Key and Model.");
      return;
    }

    final regExp = RegExp(
      r'(?:youtu\.be\/|youtube\.com\/(?:embed\/|v\/|watch\?v=|watch\?.+&v=))([\w-]{11})',
    );
    final videoId = regExp.firstMatch(videoUrl)?.group(1);

    if (videoId == null) {
      onError("Error: Invalid YouTube URL. Could not extract video ID.");
      return;
    }

    currentVideoId = videoId;

    clearHighlights();

    isProcessing = true;
    notifyListeners();

    try {
      await _fetchTotalOriginalDuration();

      if (!forceRegenerate &&
          loadCachedHighlights(
            videoId,
            checkScale: true,
            onSuccess: onSuccess,
          )) {
        isProcessing = false;
        notifyListeners();
        return;
      }
      final scale = switch (highlightDensity) {
        1 => '3-5',
        2 => '7-10',
        _ => 'all',
      };

      final scaleText =
          "Extract $scale key moments as distinct clips from the very first minute to the very last second, naturally omitting filler in between.";

      final prompt =
          """
You are a master video editor curating a highlight reel. 

Your goal is to extract the exact moments of peak value from this video. Do not create a continuous table of contents. Instead, pinpoint specific, isolated clips where the most important points are made. 

Review the video in its entirety before making your cuts. It is crucial that your final reel captures the full arc of the content. Ensure your selections are drawn from the start, middle, and end of the timeline.

Start each clip right as the core insight begins, and cut it the exact moment the point is concluded. Skip all intros, sponsor reads, rambling, and conversational filler.

Important: $scaleText

For each curated clip, output a structured JSON array of objects with:
title: A punchy 3-5 word title
start: Exact beginning time in seconds
end: Exact concluding time in seconds
""";
      notifyListeners();

      localNotifications.show(
        id: 888,
        title: 'Generating Highlights',
        body: 'This may take a while depending on the video length.',
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'sqzd_gen',
            'Highlight Generation',
            channelDescription: 'Ongoing background generation',
            importance: Importance.low,
            priority: Priority.low,
            ongoing: true,
            autoCancel: false,
          ),
        ),
      );

      final response = await http.post(
        Uri.parse(
          '$_geminiBaseUrl/models/$selectedModel:generateContent?key=$geminiApiKey',
        ),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          "contents": [
            {
              "role": "user",
              "parts": [
                {"text": prompt},
                {
                  "fileData": {
                    "mimeType": "video/webm",
                    "fileUri": 'https://www.youtube.com/watch?v=$videoId',
                  },
                },
              ],
            },
          ],
          "generationConfig": {
            "responseMimeType": "application/json",
            "responseSchema": {
              "type": "OBJECT",
              "properties": {
                "highlights": {
                  "type": "ARRAY",
                  "items": {
                    "type": "OBJECT",
                    "properties": {
                      "title": {"type": "STRING"},
                      "start": {"type": "INTEGER"},
                      "end": {"type": "INTEGER"},
                    },
                    "required": ["title", "start", "end"],
                  },
                },
              },
              "required": ["highlights"],
            },
          },
        }),
      );

      final resData = jsonDecode(response.body);

      if (resData case {'error': {'message': String msg}}) {
        throw Exception(msg);
      } else if (response.statusCode != 200) {
        throw Exception("API Error: ${response.statusCode}");
      }

      String? highlightsJson;

      if (resData case {
        'candidates': [
          {'content': {'parts': [{'text': String text}, ...]}},
          ...,
        ],
      }) {
        highlightsJson = text;
      }

      if (highlightsJson == null) {
        throw Exception(
          "Could not find generated highlights text in the API response.",
        );
      }

      final parsedHighlights = (jsonDecode(highlightsJson)['highlights'] as List)
          .map((h) => Highlight.fromJson(Map<String, dynamic>.from(h)))
          .toList();

      parsedHighlights.sort((a, b) => a.start.compareTo(b.start));

      for (var i = 1; i < parsedHighlights.length; i++) {
        final curr = parsedHighlights[i];
        final prev = parsedHighlights[i - 1];

        if (curr.start <= prev.end) {
          var newStart = prev.end + 1.0;
          var newEnd = curr.end;
          if (newEnd <= newStart) {
            newEnd = newStart + 15.0;
          }
          parsedHighlights[i] = curr.copyWith(start: newStart, end: newEnd);
        }
      }

      sharedPrefs.setString(
        _getCacheKey(videoId),
        jsonEncode({
          "timestamp": DateTime.now().millisecondsSinceEpoch,
          "duration": totalOriginalDuration,
          "scale": highlightDensity,
          "highlights": parsedHighlights.map((h) => h.toJson()).toList(),
        }),
      );

      localNotifications.cancel(id: 888);

      if (isAppInBackground) {
        localNotifications.show(
          id: 889,
          title: 'Highlights Ready!',
          body: 'Your video highlights have been generated.',
          notificationDetails: const NotificationDetails(
            android: AndroidNotificationDetails(
              'sqzd_gen_done',
              'Highlight Generation Done',
              importance: Importance.high,
              priority: Priority.high,
              playSound: true,
            ),
            iOS: DarwinNotificationDetails(
              presentSound: true,
              presentAlert: true,
            ),
          ),
        );
      }

      _applyHighlights(
        parsedHighlights,
        autoplay: !isAppInBackground,
        onSuccess: onSuccess,
      );
    } catch (e) {
      localNotifications.cancel(id: 888);
      onError("Error generating highlights: $e");
    }
    isProcessing = false;
    notifyListeners();
  }

  void _applyHighlights(
    List<Highlight> highlights, {
    bool autoplay = true,
    VoidCallback? onSuccess,
  }) {
    extractedHighlights = highlights;
    currentHighlightIndex = 0;
    currentVideoTime = highlights.isNotEmpty
        ? highlights.first.start
        : 0.0;

    isProcessing = false;
    notifyListeners();

    _updateAudioMediaItem();
    _updateAudioPlaybackState();

    if (onSuccess != null) onSuccess();
    _tryInjectJS(autoplay: autoplay);
  }

  Future<void> _tryInjectJS({bool autoplay = true}) async {
    for (var i = 0; i < 15; i++) {
      if (extractedHighlights.isEmpty) return;
      final hasVideo = await webViewController?.evaluateJavascript(
        source:
            "document.getElementsByTagName('video').length > 0 && document.getElementsByTagName('video')[0].readyState > 0",
      );

      if (hasVideo == true) {
        if (totalOriginalDuration <= 0) {
          await _fetchTotalOriginalDuration();
          notifyListeners();
        }
        await _injectJS(autoplay: autoplay);
        return;
      }
      await Future.delayed(const Duration(milliseconds: 1000));
    }
  }

  Future<void> _injectJS({bool autoplay = true}) async {
    if (autoplay) {
      seekToHighlight(0);
    } else {
      final startRaw = extractedHighlights[0].start;
      executeVideoJavascript(
        "v.pause(); v.currentTime = $startRaw; v.volume = 1.0;",
      );
    }
  }
}

class HighlightsTimelinePainter extends CustomPainter {
  final double totalDuration;
  final List<Highlight> highlights;
  final int currentIndex;
  final double currentProgress;
  final Color primaryColor;
  final Color dimColor;
  final Color backgroundColor;

  HighlightsTimelinePainter({
    required this.totalDuration,
    required this.highlights,
    required this.currentIndex,
    required this.currentProgress,
    required this.primaryColor,
    required this.dimColor,
    required this.backgroundColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (highlights.isEmpty) return;

    final lineY = size.height / 2;
    const pillThickness = 6.0;

    Paint createPaint(Color color) {
      return Paint()
        ..color = color
        ..strokeWidth = pillThickness
        ..strokeCap = StrokeCap.round;
    }

    final bgPaint = createPaint(backgroundColor);
    canvas.drawLine(Offset(0, lineY), Offset(size.width, lineY), bgPaint);

    final activeHighlight = highlights[currentIndex];
    final activeStart = activeHighlight.start;
    final activeEnd = activeHighlight.end;
    var activeDur = activeEnd - activeStart;
    if (activeDur <= 0) activeDur = 1.0;

    var effectiveTotalDur = totalDuration;
    final lastEndRaw = highlights.last.end;
    if (lastEndRaw > effectiveTotalDur) {
      effectiveTotalDur = lastEndRaw;
    }
    if (effectiveTotalDur <= 0) effectiveTotalDur = 1.0;

    final minActiveWidth = math.min(80.0, size.width * 0.4);
    final rawActiveWidth = (activeDur / effectiveTotalDur) * size.width;
    final actualActiveWidth = math.max(rawActiveWidth, minActiveWidth);

    final remainingPixels = math.max(0.0, size.width - actualActiveWidth);
    final remainingDuration = math.max(0.001, effectiveTotalDur - activeDur);

    double timeToX(double t) {
      if (t <= activeStart) {
        return (t / remainingDuration) * remainingPixels;
      } else if (t <= activeEnd) {
        final startX = (activeStart / remainingDuration) * remainingPixels;
        final p = (t - activeStart) / activeDur;
        return startX + p * actualActiveWidth;
      } else {
        final startX = (activeStart / remainingDuration) * remainingPixels;
        final endX = startX + actualActiveWidth;
        final timeAfter = t - activeEnd;
        return endX + (timeAfter / remainingDuration) * remainingPixels;
      }
    }

    for (var i = 0; i < highlights.length; i++) {
      final h = highlights[i];
      final startX = timeToX(h.start);
      final endX = timeToX(h.end);

      final pad = pillThickness / 2;
      final drawStartX = startX + pad;
      var drawEndX = endX - pad;
      if (drawEndX - drawStartX < 0.1) {
        drawEndX = drawStartX + 0.1;
      }

      final isCurrent = i == currentIndex;

      if (isCurrent) {
        final activeBgPaint = createPaint(primaryColor.withOpacity(0.3));
        canvas.drawLine(
          Offset(drawStartX, lineY),
          Offset(drawEndX, lineY),
          activeBgPaint,
        );

        final progX = drawStartX + (drawEndX - drawStartX) * currentProgress;
        if (progX > drawStartX) {
          final progPaint = createPaint(primaryColor);
          canvas.drawLine(
            Offset(drawStartX, lineY),
            Offset(progX, lineY),
            progPaint,
          );
        }
      } else {
        final chapPaint = createPaint(dimColor);
        canvas.drawLine(
          Offset(drawStartX, lineY),
          Offset(drawEndX, lineY),
          chapPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant HighlightsTimelinePainter oldDelegate) {
    return oldDelegate.totalDuration != totalDuration ||
        oldDelegate.highlights != highlights ||
        oldDelegate.currentIndex != currentIndex ||
        oldDelegate.currentProgress != currentProgress;
  }
}

class LoadingIndicator extends StatelessWidget {
  const LoadingIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return LinearProgressIndicator(
      backgroundColor: colors.onSurface.withOpacity(0.2),
      color: colors.primary,
    );
  }
}

class PlaybackControlsRow extends StatelessWidget {
  final List<Widget> children;

  const PlaybackControlsRow({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
        child: Row(children: children),
      ),
    );
  }
}

class ModelListTab extends StatefulWidget {
  final List<String> models;
  final String? selectedModel;
  final bool isTts;
  final ColorScheme colors;
  final Function(String, bool) onSelect;

  const ModelListTab({
    super.key,
    required this.models,
    required this.selectedModel,
    required this.isTts,
    required this.colors,
    required this.onSelect,
  });

  @override
  State<ModelListTab> createState() => _ModelListTabState();
}

class _ModelListTabState extends State<ModelListTab> {
  late ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    final index = widget.models.indexOf(widget.selectedModel ?? '');
    _scrollController = ScrollController(
      initialScrollOffset: index > 0 ? index * 56.0 : 0.0,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.models.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              "No models found.",
              style: TextStyle(
                color: widget.colors.onSurface.withOpacity(0.7),
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 12),
            GestureDetector(
              onTap: () => context.read<AppState>().fetchGeminiModels(),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.refresh, color: widget.colors.primary, size: 18),
                  const SizedBox(width: 6),
                  Text(
                    "Tap to try again",
                    style: TextStyle(
                      color: widget.colors.primary,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      color: widget.colors.primary,
      onRefresh: () async {
        await context.read<AppState>().fetchGeminiModels();
      },
      child: ListView.builder(
        controller: _scrollController,
        itemExtent: 56.0,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
        itemCount: widget.models.length,
        itemBuilder: (context, idx) {
          final m = widget.models[idx];
          final isSelected = widget.selectedModel == m;
          return ListTile(
            title: Text(
              m,
              style: TextStyle(
                color: isSelected
                    ? widget.colors.primary
                    : widget.colors.onSurface,
              ),
            ),
            trailing: isSelected
                ? Icon(Icons.check, color: widget.colors.primary)
                : null,
            onTap: () {
              widget.onSelect(m, widget.isTts);
            },
          );
        },
      ),
    );
  }
}

class YouTubeBrowserScreen extends StatefulWidget {
  const YouTubeBrowserScreen({super.key});
  @override
  State<YouTubeBrowserScreen> createState() => _YouTubeBrowserScreenState();
}

class _YouTubeBrowserScreenState extends State<YouTubeBrowserScreen>
    with WidgetsBindingObserver {
  String currentUrl = "https://m.youtube.com";
  String? _pendingSharedUrl;

  late StreamSubscription _intentSub;
  late PullToRefreshController pullToRefreshController;

  late PageController _pageController;
  bool _isPageAnimating = false;

  DateTime? _lastPressedAt;

  final String _initScript = """
    (function() {
      if (window.__scriptInitDone) return;
      window.__scriptInitDone = true;
      window.__sqzdUserIntent = false;

      // Block Page Visibility API
      Object.defineProperty(document, 'hidden', { value: false, writable: false });
      Object.defineProperty(document, 'visibilityState', { value: 'visible', writable: false });
      Object.defineProperty(document, 'webkitHidden', { value: false, writable: false });
      document.hasFocus = function() { return true; }; 

      const stopProp = (e) => { e.stopImmediatePropagation(); e.stopPropagation(); };
      document.addEventListener('visibilitychange', stopProp, true);
      document.addEventListener('webkitvisibilitychange', stopProp, true);
      window.addEventListener('pagehide', stopProp, true);
      window.addEventListener('blur', stopProp, true);

      const originalPlay = HTMLVideoElement.prototype.play;
      HTMLVideoElement.prototype.play = function() {
        if (window.__sqzdUserIntent) {
          return originalPlay.apply(this, arguments);
        } else {
          return Promise.reject(new DOMException("Autoplay blocked by sqzd", "NotAllowedError"));
        }
      };

      const allowPlay = () => { window.__sqzdUserIntent = true; };
      document.addEventListener('touchstart', allowPlay, {capture: true, passive: true});
      document.addEventListener('click', allowPlay, {capture: true, passive: true});

      document.addEventListener('play', (e) => {
        if (e.target && e.target.tagName === 'VIDEO') {
          window.flutter_inappwebview.callHandler('playState', true);
        }
      }, true);

      document.addEventListener('pause', (e) => {
        if (e.target && e.target.tagName === 'VIDEO') {
          window.flutter_inappwebview.callHandler('playState', false);
        }
      }, true);

      document.addEventListener('timeupdate', (e) => {
        if (e.target && e.target.tagName === 'VIDEO') {
          let now = Date.now();
          if (!window.lastProgTime || now - window.lastProgTime > 250) {
            window.lastProgTime = now;
            window.flutter_inappwebview.callHandler('progressChange', e.target.currentTime);
          }
        }
      }, true);
    })();
  """;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _pageController = PageController();

    pullToRefreshController = PullToRefreshController(
      settings: PullToRefreshSettings(color: Colors.greenAccent),
      onRefresh: () async {
        context.read<AppState>().webViewController?.reload();
      },
    );

    _intentSub = ReceiveSharingIntent.instance.getMediaStream().listen((
      List<SharedMediaFile> value,
    ) {
      _processSharedIntent(value);
    });

    ReceiveSharingIntent.instance.getInitialMedia().then((
      List<SharedMediaFile> value,
    ) {
      _processSharedIntent(value);
      ReceiveSharingIntent.instance.reset();
    });
  }

  void _processSharedIntent(List<SharedMediaFile> value) {
    if (value.isEmpty) return;

    final sharedText = value.first.path;

    if (sharedText.contains("youtu")) {
      final urlRegex = RegExp(
        r'https?:\/\/(?:m\.)?(?:www\.)?(?:youtube\.com|youtu\.be)\/[^\s]+',
      );
      final match = urlRegex.firstMatch(sharedText);

      if (match != null) {
        final url = match.group(0)!;
        final appState = context.read<AppState>();

        if (appState.webViewController != null) {
          appState.handleSharedUrl(url);
        } else {
          _pendingSharedUrl = url;
          setState(() => currentUrl = url);
        }
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    _intentSub.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final appState = context.read<AppState>();

    if (state == AppLifecycleState.resumed) {
      appState.isAppInBackground = false;
      appState.webViewController?.resume();
    } else if (state
        case AppLifecycleState.paused ||
            AppLifecycleState.inactive ||
            AppLifecycleState.hidden) {
      appState.isAppInBackground = true;
      if (appState.isVideoPlaying || appState.isTtsPlaying) {
        Future.delayed(const Duration(milliseconds: 200), () {
          appState.webViewController?.resume();
          appState.executeVideoJavascript(
            "if(v.paused) { v.play().catch(e => console.log(e)); }",
            setIntent: true,
          );
        });
      }
    }
  }

  void _injectInit(InAppWebViewController controller) {
    controller.evaluateJavascript(source: _initScript);
  }

  String _formatDuration(num seconds) {
    final secs = seconds.toInt();
    return "${(secs ~/ 60).toString().padLeft(2, '0')}:${(secs % 60).toString().padLeft(2, '0')}";
  }

  void _showCustomBottomSheet(BuildContext context, WidgetBuilder builder) {
    final theme = Theme.of(context);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: builder,
    );
  }

  void _showApiKeySheet(
    BuildContext context,
    AppState state, {
    VoidCallback? onSuccess,
  }) {
    final keyCtrl = TextEditingController(text: state.geminiApiKey ?? '');

    _showCustomBottomSheet(context, (ctx) {
      final theme = Theme.of(ctx);
      final colors = theme.colorScheme;
      return Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Gemini API Key",
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: colors.onSurface,
                ),
              ),
              const SizedBox(height: 15),
              TextField(
                controller: keyCtrl,
                obscureText: true,
                style: TextStyle(color: colors.onSurface),
                decoration: InputDecoration(
                  labelText: "Enter Key",
                  labelStyle: TextStyle(
                    color: colors.onSurface.withOpacity(0.7),
                  ),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(
                      color: colors.onSurface.withOpacity(0.5),
                    ),
                  ),
                  focusedBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: colors.primary),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              InkWell(
                onTap: () async {
                  try {
                    await launchUrl(
                      Uri.parse('https://aistudio.google.com/app/apikey'),
                      mode: LaunchMode.externalApplication,
                    );
                  } catch (e) {
                    debugPrint("Could not launch URL: $e");
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4.0),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        "Get your key from Google AI Studio",
                        style: TextStyle(color: colors.primary, fontSize: 14),
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.open_in_new, size: 14, color: colors.primary),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(
                      "Cancel",
                      style: TextStyle(color: colors.onSurface),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: colors.primary,
                      foregroundColor: theme.scaffoldBackgroundColor,
                    ),
                    onPressed: () {
                      state.saveApiKey(keyCtrl.text);
                      Navigator.pop(ctx);
                      onSuccess?.call();
                    },
                    child: const Text(
                      "Save",
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    });
  }

  void _showModelSelectionSheet(BuildContext context, AppState rootState) {
    _showCustomBottomSheet(context, (ctx) {
      final theme = Theme.of(ctx);
      final colors = theme.colorScheme;
      return DefaultTabController(
        length: 2,
        child: Consumer<AppState>(
          builder: (context, state, child) {
            return SafeArea(
              child: FractionallySizedBox(
                heightFactor: 0.5,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(
                        left: 24.0,
                        right: 16.0,
                        top: 20.0,
                        bottom: 0,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            "Models",
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: colors.onSurface,
                            ),
                          ),
                          IconButton(
                            icon: Icon(Icons.vpn_key, color: colors.outline),
                            tooltip: "Edit API Key",
                            onPressed: () {
                              Navigator.pop(ctx);
                              _showApiKeySheet(context, state);
                            },
                          ),
                        ],
                      ),
                    ),
                    TabBar(
                      labelColor: colors.primary,
                      unselectedLabelColor: colors.onSurface.withOpacity(0.6),
                      indicatorColor: colors.primary,
                      dividerColor: colors.onSurface.withOpacity(0.1),
                      tabs: const [
                        Tab(text: "Text"),
                        Tab(text: "Voice"),
                      ],
                    ),
                    Expanded(
                      child: TabBarView(
                        children: [
                          ModelListTab(
                            models: state.textModels,
                            selectedModel: state.selectedModel,
                            isTts: false,
                            colors: colors,
                            onSelect: state.selectModel,
                          ),
                          ModelListTab(
                            models: state.ttsModels,
                            selectedModel: state.selectedTtsModel,
                            isTts: true,
                            colors: colors,
                            onSelect: state.selectModel,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );
    });
  }

  Widget _buildScaleOption(
    BuildContext context,
    AppState state,
    int value,
    String label,
    ColorScheme colors,
  ) {
    final isSelected = state.highlightDensity == value;
    final theme = Theme.of(context);
    final textColor = isSelected
        ? theme.scaffoldBackgroundColor
        : colors.onSurface;

    final Widget dots = Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(
        value,
        (index) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 1),
          child: Icon(Icons.circle, size: 8, color: textColor),
        ),
      ),
    );

    return GestureDetector(
      onTap: () => state.setSummaryLength(value),
      child: Container(
        height: 80,
        width: double.infinity,
        decoration: BoxDecoration(
          color: isSelected
              ? colors.primary
              : colors.onSurface.withOpacity(0.08),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            dots,
            const SizedBox(height: 10),
            Text(
              label,
              style: TextStyle(
                color: textColor,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showGenerateSheet(
    BuildContext context, {
    bool forceRegenerate = false,
  }) {
    final state = context.read<AppState>();

    if (state.geminiApiKey == null || state.geminiApiKey!.isEmpty) {
      _showApiKeySheet(
        context,
        state,
        onSuccess: () {
          Future.delayed(const Duration(milliseconds: 300), () {
            if (context.mounted) {
              _showGenerateSheet(context, forceRegenerate: forceRegenerate);
            }
          });
        },
      );
      return;
    }

    _showCustomBottomSheet(context, (ctx) {
      final theme = Theme.of(ctx);
      final colors = theme.colorScheme;
      return Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Consumer<AppState>(
          builder: (context, state, child) {
            return Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        "Generate Highlights",
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: colors.onSurface,
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.close, color: colors.onSurface),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 15),
                  Row(
                    children: [
                      Expanded(
                        child: _buildScaleOption(
                          context,
                          state,
                          1,
                          "Short",
                          colors,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildScaleOption(
                          context,
                          state,
                          2,
                          "Medium",
                          colors,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildScaleOption(
                          context,
                          state,
                          3,
                          "Detailed",
                          colors,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  GestureDetector(
                    onTap: () {
                      _showModelSelectionSheet(context, state);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 15,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: colors.onSurface.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            state.selectedModel == null
                                ? "Select Model"
                                : "Models",
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: colors.onSurface,
                              fontSize: 16,
                            ),
                          ),
                          Icon(Icons.arrow_drop_down, color: colors.onSurface),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 15),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: colors.primary,
                      ),
                      onPressed: () async {
                        final navigator = Navigator.of(ctx);
                        final url = await state.webViewController?.getUrl();
                        if (url != null) {
                          navigator.pop();
                          state.generateHighlights(
                            url.toString(),
                            forceRegenerate: forceRegenerate,
                            onError: _showErrorSnackbar,
                          );
                        } else {
                          _showErrorSnackbar(
                            "Error: Could not retrieve current URL.",
                          );
                        }
                      },
                      child: Text(
                        "Generate Highlights",
                        style: TextStyle(
                          color: theme.scaffoldBackgroundColor,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      );
    });
  }

  void _showHighlightsSheet(BuildContext context, AppState rootState) {
    final ScrollController scrollController = ScrollController();
    var lastScrolledIndex = -1;

    _showCustomBottomSheet(context, (ctx) {
      final theme = Theme.of(ctx);
      final colors = theme.colorScheme;
      return Consumer<AppState>(
        builder: (context, state, child) {
          if (lastScrolledIndex != state.currentHighlightIndex &&
              state.extractedHighlights.isNotEmpty) {
            lastScrolledIndex = state.currentHighlightIndex;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (scrollController.hasClients) {
                const itemWidth = 180.0;
                final screenWidth = MediaQuery.of(ctx).size.width;
                var offset =
                    (lastScrolledIndex * itemWidth) -
                    (screenWidth / 2) +
                    (itemWidth / 2);
                final maxScroll = scrollController.position.maxScrollExtent;
                if (offset > maxScroll) offset = maxScroll;
                if (offset < 0) offset = 0.0;

                if (maxScroll > 0 || offset == 0) {
                  scrollController.animateTo(
                    offset,
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOut,
                  );
                }
              }
            });
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          "Highlights",
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: colors.onSurface,
                          ),
                        ),
                        IconButton(
                          icon: Icon(Icons.autorenew, color: colors.onSurface),
                          tooltip: "Regenerate",
                          onPressed: () {
                            Navigator.pop(ctx);
                            _showGenerateSheet(context, forceRegenerate: true);
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 120,
                    child: ListView.builder(
                      controller: scrollController,
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      itemCount: state.extractedHighlights.length,
                      itemBuilder: (context, i) {
                        final isActive = state.currentHighlightIndex == i;

                        final highlight = state.extractedHighlights[i];
                        final startStr = _formatDuration(highlight.start);
                        final endStr = _formatDuration(highlight.end);
                        final title = highlight.title;

                        return GestureDetector(
                          onTap: () {
                            state.seekToHighlight(i);
                            Navigator.pop(ctx);
                          },
                          child: Container(
                            width: 160,
                            margin: const EdgeInsets.symmetric(horizontal: 10),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: isActive
                                  ? colors.onSurface
                                  : colors.onSurface.withOpacity(0.08),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: isActive
                                        ? theme.scaffoldBackgroundColor
                                        : colors.onSurface,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  "$startStr - $endStr",
                                  style: TextStyle(
                                    color: isActive
                                        ? theme.scaffoldBackgroundColor
                                              .withOpacity(0.7)
                                        : colors.onSurface.withOpacity(0.5),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    });
  }

  void _showErrorSnackbar(String message) {
    final theme = Theme.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: TextStyle(color: theme.colorScheme.onError),
        ),
        backgroundColor: theme.colorScheme.error,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  Future<void> _onWillPop(AppState state) async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final canGoBack = await state.webViewController?.canGoBack() ?? false;
    if (canGoBack) {
      state.webViewController?.goBack();
      return;
    }

    final now = DateTime.now();
    final isDuplicatePress =
        _lastPressedAt != null &&
        now.difference(_lastPressedAt!) < const Duration(seconds: 2);

    if (isDuplicatePress) {
      SystemNavigator.pop();
    } else {
      _lastPressedAt = now;
      scaffoldMessenger.showSnackBar(
        const SnackBar(
          content: Text("Tap again to exit"),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    if (state.extractedHighlights.isNotEmpty && _pageController.hasClients) {
      final targetPage = state.currentHighlightIndex;
      final currentPage = _pageController.page?.round() ?? 0;

      if (currentPage != targetPage && !_isPageAnimating) {
        _isPageAnimating = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_pageController.hasClients) {
            _pageController
                .animateToPage(
                  targetPage,
                  duration: const Duration(milliseconds: 350),
                  curve: Curves.easeOutCubic,
                )
                .then((_) {
                  _isPageAnimating = false;
                });
          } else {
            _isPageAnimating = false;
          }
        });
      }
    }

    final highlightStart = state.extractedHighlights.isNotEmpty
        ? state.extractedHighlights[state.currentHighlightIndex].start
        : 0.0;
    final highlightEnd = state.extractedHighlights.isNotEmpty
        ? state.extractedHighlights[state.currentHighlightIndex].end
        : 1.0;

    var highlightProgress = (highlightEnd - highlightStart) > 0
        ? (state.currentVideoTime - highlightStart) /
              (highlightEnd - highlightStart)
        : 0.0;
    highlightProgress = highlightProgress.clamp(0.0, 1.0);

    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        await _onWillPop(state);
      },
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    InAppWebView(
                      initialUrlRequest: URLRequest(url: WebUri(currentUrl)),
                      initialSettings: InAppWebViewSettings(
                        mediaPlaybackRequiresUserGesture: false,
                        allowsInlineMediaPlayback: true,
                        allowBackgroundAudioPlaying: true,
                      ),
                      initialUserScripts: UnmodifiableListView<UserScript>([
                        UserScript(
                          source: _initScript,
                          injectionTime:
                              UserScriptInjectionTime.AT_DOCUMENT_START,
                        ),
                      ]),
                      pullToRefreshController: pullToRefreshController,
                      onWebViewCreated: (controller) {
                        state.webViewController = controller;

                        controller.addJavaScriptHandler(
                          handlerName: 'playState',
                          callback: (args) => state.setPlayState(args[0]),
                        );
                        controller.addJavaScriptHandler(
                          handlerName: 'progressChange',
                          callback: (args) {
                            if (args.isNotEmpty && args[0] != null) {
                              final rawTime = args[0];
                              if (rawTime is num) {
                                state.updatePlaybackProgress(
                                  rawTime.toDouble(),
                                );
                              }
                            }
                          },
                        );

                        _injectInit(controller);

                        if (_pendingSharedUrl != null) {
                          state.handleSharedUrl(_pendingSharedUrl!);
                          _pendingSharedUrl = null;
                        }
                      },
                      onLoadStart: (controller, url) async {
                        _injectInit(controller);
                      },
                      onLoadStop: (controller, url) async {
                        pullToRefreshController.endRefreshing();
                        _injectInit(controller);
                      },
                      onReceivedError: (controller, request, error) async {
                        pullToRefreshController.endRefreshing();
                      },
                      onReceivedHttpError:
                          (controller, request, errorResponse) async {
                            pullToRefreshController.endRefreshing();
                          },
                      onProgressChanged: (controller, progress) async {
                        if (progress == 100) {
                          pullToRefreshController.endRefreshing();
                        }
                      },
                      onUpdateVisitedHistory: (controller, url, isReload) async {
                        state.executeVideoJavascript(
                          "v.pause();",
                          setIntent: false,
                        );

                        if (url != null) {
                          final urlStr = url.toString();
                          final regExp = RegExp(
                            r'(?:youtu\.be\/|youtube\.com\/(?:embed\/|v\/|watch\?v=|watch\?.+&v=))([\w-]{11})',
                          );
                          final newVideoId = regExp
                              .firstMatch(urlStr)
                              ?.group(1);

                          if (newVideoId != null &&
                              newVideoId != state.currentVideoId) {
                            state.currentVideoId = newVideoId;
                            state.clearHighlights();
                            state.loadCachedHighlights(newVideoId);
                          } else if (newVideoId == null &&
                              state.currentVideoId != null) {
                            state.currentVideoId = null;
                            state.clearHighlights();
                          }
                        }
                      },
                    ),
                    if (state.currentVideoId != null &&
                        state.extractedHighlights.isEmpty &&
                        !state.isProcessing)
                      Positioned(
                        bottom: 16 + MediaQuery.of(context).padding.bottom,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: colors.primary,
                              foregroundColor: theme.scaffoldBackgroundColor,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(24),
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 12,
                              ),
                              elevation: 4,
                            ),
                            icon: const Icon(Icons.auto_awesome),
                            label: const Text(
                              "Generate Highlights",
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                            onPressed: () => _showGenerateSheet(context),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic,
                child: state.isProcessing
                    ? Container(
                        color: colors.surface,
                        width: double.infinity,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const LoadingIndicator(),
                            PlaybackControlsRow(
                              children: [
                                IconButton.filled(
                                  icon: const Icon(Icons.auto_awesome),
                                  padding: EdgeInsets.zero,
                                  onPressed: () {},
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: SizedBox(
                                    height: 52,
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          "Generating Highlights...",
                                          style: TextStyle(
                                            color: colors.onSurface,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 16,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          "Come back in a few minutes",
                                          style: TextStyle(
                                            color: colors.onSurface.withOpacity(
                                              0.6,
                                            ),
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      )
                    : state.extractedHighlights.isNotEmpty
                    ? Container(
                        color: colors.surface,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 4.0),
                              child: SizedBox(
                                height: 6,
                                width: double.infinity,
                                child: state.isTtsLoading
                                    ? const LoadingIndicator()
                                    : Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8.0,
                                        ),
                                        child: CustomPaint(
                                          painter: HighlightsTimelinePainter(
                                            totalDuration:
                                                state.totalOriginalDuration,
                                            highlights:
                                                state.extractedHighlights,
                                            currentIndex:
                                                state.currentHighlightIndex,
                                            currentProgress: highlightProgress,
                                            primaryColor: colors.primary,
                                            dimColor: colors.onSurface
                                                .withOpacity(0.3),
                                            backgroundColor: colors.onSurface
                                                .withOpacity(0.1),
                                          ),
                                        ),
                                      ),
                              ),
                            ),
                            PlaybackControlsRow(
                              children: [
                                IconButton.filled(
                                  icon: Icon(switch ((
                                    state.isTtsPlaying,
                                    state.isVideoPlaying,
                                  )) {
                                    (true, _) => Icons.skip_next,
                                    (_, true) => Icons.pause,
                                    _ => Icons.play_arrow,
                                  }),
                                  padding: EdgeInsets.zero,
                                  onPressed: state.togglePlayPause,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: SizedBox(
                                    height: 52,
                                    child: PageView.builder(
                                      controller: _pageController,
                                      physics: const PageScrollPhysics(
                                        parent: BouncingScrollPhysics(),
                                      ),
                                      dragStartBehavior: DragStartBehavior.down,
                                      onPageChanged: (index) {
                                        if (!_isPageAnimating &&
                                            state.currentHighlightIndex !=
                                                index) {
                                          state.seekToHighlight(index);
                                        }
                                      },
                                      itemCount:
                                          state.extractedHighlights.length,
                                      itemBuilder: (context, index) {
                                        return GestureDetector(
                                          behavior: HitTestBehavior.opaque,
                                          onTap: () => _showHighlightsSheet(
                                            context,
                                            state,
                                          ),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              Text(
                                                state
                                                    .extractedHighlights[index].title,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 16,
                                                ),
                                              ),
                                              const SizedBox(height: 2),
                                              Text(
                                                "Highlight ${index + 1} of ${state.extractedHighlights.length}",
                                                style: TextStyle(
                                                  color: colors.onSurface
                                                      .withOpacity(0.6),
                                                  fontSize: 12,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                            ],
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      )
                    : const SizedBox(width: double.infinity, height: 0),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
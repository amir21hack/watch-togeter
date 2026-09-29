import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_vlc_player/flutter_vlc_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/socket_service.dart';
import '../models/chat_message.dart';

class PlayerScreen extends StatefulWidget {
  final String roomId;
  final String username;
  final String videoPathOrUrl;
  final bool isNetworkUrl;
  final String? subtitlePath;

  const PlayerScreen({
    Key? key,
    required this.roomId,
    required this.username,
    required this.videoPathOrUrl,
    required this.isNetworkUrl,
    this.subtitlePath,
  }) : super(key: key);

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late VlcPlayerController _vlcController;
  final SocketService _socket = SocketService();
  final TextEditingController _chatController = TextEditingController();

  bool _isControlsVisible = true;
  bool _isChatOpen = false;
  Timer? _controlsTimer;
  Timer? _progressReportTimer;

  // Remote Sync state
  String _partnerName = 'در انتظار دوست...';
  double _partnerTime = 0;
  bool _partnerPlaying = false;
  int? _countdownSec;
  bool _isSyncingFromRemote = false;

  final List<ChatMessage> _messages = [];

  @override
  void initState() {
    super.initState();

    // Hide status bar & landscape orientation for cinema experience
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    // Keep screen awake
    WakelockPlus.enable();

    // Initialize VLC Controller
    if (widget.isNetworkUrl) {
      _vlcController = VlcPlayerController.network(
        widget.videoPathOrUrl,
        hwAcc: HwAcc.auto,
        autoPlay: false,
        options: VlcPlayerOptions(
          advanced: VlcAdvancedOptions([
            VlcAdvancedOptions.networkCaching(2000),
          ]),
        ),
      );
    } else {
      _vlcController = VlcPlayerController.file(
        File(widget.videoPathOrUrl),
        hwAcc: HwAcc.auto,
        autoPlay: false,
      );
    }

    _setupSocketListeners();
    _startProgressReporter();
  }

  void _setupSocketListeners() {
    _socket.connect(
      serverUrl: 'https://watch.manageyar.ir',
      roomId: widget.roomId,
      username: widget.username,
    );

    _socket.onRemotePlay = (targetTime) async {
      _isSyncingFromRemote = true;
      if (targetTime != null) {
        final diff = (_vlcController.value.position.inSeconds - targetTime).abs();
        if (diff > 2) {
          _vlcController.setTime((targetTime * 1000).toInt());
        }
      }
      _vlcController.play();
      Future.delayed(const Duration(milliseconds: 500), () => _isSyncingFromRemote = false);
    };

    _socket.onRemotePause = (targetTime) async {
      _isSyncingFromRemote = true;
      if (targetTime != null) {
        final diff = (_vlcController.value.position.inSeconds - targetTime).abs();
        if (diff > 2) {
          _vlcController.setTime((targetTime * 1000).toInt());
        }
      }
      _vlcController.pause();
      Future.delayed(const Duration(milliseconds: 500), () => _isSyncingFromRemote = false);
    };

    _socket.onRemoteSeek = (targetTime) async {
      _isSyncingFromRemote = true;
      if (targetTime != null) {
        _vlcController.setTime((targetTime * 1000).toInt());
      }
      Future.delayed(const Duration(milliseconds: 500), () => _isSyncingFromRemote = false);
    };

    _socket.onCountdown = (seconds) {
      setState(() {
        _countdownSec = seconds;
      });
      Timer.periodic(const Duration(seconds: 1), (timer) {
        if (_countdownSec == null || _countdownSec! <= 1) {
          timer.cancel();
          setState(() {
            _countdownSec = null;
          });
          _vlcController.play();
        } else {
          setState(() {
            _countdownSec = _countdownSec! - 1;
          });
        }
      });
    };

    _socket.onUserProgress = (data) {
      setState(() {
        _partnerName = data['username'] ?? 'دوست شما';
        _partnerTime = (data['currentTime'] as num?)?.toDouble() ?? 0;
        _partnerPlaying = data['isPlaying'] == true;
      });
    };

    _socket.onChatMessage = (msg) {
      setState(() {
        _messages.add(msg);
      });
    };
  }

  void _startProgressReporter() {
    _progressReportTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_vlcController.value.isInitialized) {
        final positionSec = _vlcController.value.position.inSeconds.toDouble();
        final isPlaying = _vlcController.value.isPlaying;
        _socket.sendProgress(positionSec, isPlaying);
      }
    });
  }

  void _togglePlayPause() async {
    if (!_vlcController.value.isInitialized) return;

    final isPlaying = _vlcController.value.isPlaying;
    final posSec = _vlcController.value.position.inSeconds.toDouble();

    if (isPlaying) {
      _vlcController.pause();
      _socket.sendPause(posSec);
    } else {
      _vlcController.play();
      _socket.sendPlay(posSec);
    }
    _resetControlsTimer();
  }

  void _seekRelative(int seconds) {
    if (!_vlcController.value.isInitialized) return;
    final currentMs = _vlcController.value.position.inMilliseconds;
    final targetMs = (currentMs + (seconds * 1000)).clamp(0, _vlcController.value.duration.inMilliseconds);
    _vlcController.setTime(targetMs);
    _socket.sendSeek(targetMs / 1000.0);
    _resetControlsTimer();
  }

  void _syncToPartner() {
    _vlcController.setTime((_partnerTime * 1000).toInt());
    if (_partnerPlaying) {
      _vlcController.play();
      _socket.sendPlay(_partnerTime);
    } else {
      _vlcController.pause();
      _socket.sendPause(_partnerTime);
    }
  }

  void _triggerCountdown() {
    _socket.triggerCountdown(seconds: 3);
  }

  void _resetControlsTimer() {
    _controlsTimer?.cancel();
    setState(() {
      _isControlsVisible = true;
    });
    _controlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _vlcController.value.isInitialized && _vlcController.value.isPlaying) {
        setState(() {
          _isControlsVisible = false;
        });
      }
    });
  }

  void _sendChatMessage() {
    final text = _chatController.text.trim();
    if (text.isEmpty) return;
    _socket.sendChatMessage(text);
    _chatController.clear();
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final hours = twoDigits(duration.inHours);
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    if (duration.inHours > 0) {
      return '$hours:$minutes:$seconds';
    }
    return '$minutes:$seconds';
  }

  @override
  void dispose() {
    _controlsTimer?.cancel();
    _progressReportTimer?.cancel();
    _vlcController.stopRendererScanning();
    _vlcController.dispose();
    _socket.disconnect();
    WakelockPlus.disable();

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Directionality(
        textDirection: TextDirection.rtl,
        child: GestureDetector(
          onTap: () {
            setState(() {
              _isControlsVisible = !_isControlsVisible;
            });
            if (_isControlsVisible) {
              _resetControlsTimer();
            }
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 1. VLC Native Video View
              Center(
                child: VlcPlayer(
                  controller: _vlcController,
                  aspectRatio: 16 / 9,
                  placeholder: const Center(
                    child: CircularProgressIndicator(color: Color(0xFF6366F1)),
                  ),
                ),
              ),

              // 1.5. Intercept taps over the native video view
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    setState(() {
                      _isControlsVisible = !_isControlsVisible;
                    });
                    if (_isControlsVisible) {
                      _resetControlsTimer();
                    }
                  },
                  child: const SizedBox.expand(),
                ),
              ),

              // 2. Countdown Banner if active
              if (_countdownSec != null)
                Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
                    decoration: BoxDecoration(
                      color: const Color(0xFF6366F1).withOpacity(0.9),
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF6366F1).withOpacity(0.5),
                          blurRadius: 24,
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'شمارش معکوس هماهنگی',
                          style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '$_countdownSec',
                          style: const TextStyle(color: Colors.white, fontSize: 48, fontWeight: FontWeight.w900, fontFamily: 'monospace'),
                        ),
                      ],
                    ),
                  ),
                ),

              // 3. Top Status Bar: Partner Time & Sync Status
              if (_isControlsVisible)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: GestureDetector(
                    onTap: () {},
                    child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.black.withOpacity(0.85), Colors.transparent],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                          onPressed: () => Navigator.pop(context),
                        ),
                        // Room & Partner Chip
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E293B).withOpacity(0.85),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: const Color(0xFF334155)),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                _partnerPlaying ? Icons.play_arrow_rounded : Icons.pause_rounded,
                                color: _partnerPlaying ? const Color(0xFF10B981) : Colors.amber,
                                size: 16,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '$_partnerName: ${_formatDuration(Duration(seconds: _partnerTime.toInt()))}',
                                style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(width: 8),
                              GestureDetector(
                                onTap: _syncToPartner,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF6366F1),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Text('یکی شدن', style: TextStyle(color: Colors.white, fontSize: 10)),
                                ),
                              ),
                            ],
                          ),
                        ),
                        // Chat Toggle Button
                        IconButton(
                          icon: Icon(
                            _isChatOpen ? Icons.chat_bubble_rounded : Icons.chat_bubble_outline_rounded,
                            color: const Color(0xFF818CF8),
                          ),
                          onPressed: () {
                            setState(() {
                              _isChatOpen = !_isChatOpen;
                            });
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                ),

              // 4. Bottom Controls: Play/Pause, Seek, Progress Slider
              if (_isControlsVisible)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: GestureDetector(
                    onTap: () {},
                    child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [Colors.transparent, Colors.black.withOpacity(0.9)],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Progress Slider
                        ValueListenableBuilder<VlcPlayerValue>(
                          valueListenable: _vlcController,
                          builder: (context, value, child) {
                            final duration = value.duration.inMilliseconds.toDouble();
                            final position = value.position.inMilliseconds.toDouble();

                            return Row(
                              children: [
                                Text(
                                  _formatDuration(value.position),
                                  style: const TextStyle(color: Colors.white, fontSize: 11, fontFamily: 'monospace'),
                                ),
                                Expanded(
                                  child: Slider(
                                    value: position.clamp(0.0, duration > 0 ? duration : 1.0),
                                    max: duration > 0 ? duration : 1.0,
                                    activeColor: const Color(0xFF6366F1),
                                    inactiveColor: const Color(0xFF334155),
                                    onChanged: (val) {
                                      _vlcController.setTime(val.toInt());
                                      _socket.sendSeek(val / 1000.0);
                                    },
                                  ),
                                ),
                                Text(
                                  _formatDuration(value.duration),
                                  style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11, fontFamily: 'monospace'),
                                ),
                              ],
                            );
                          },
                        ),
                        // Action Buttons
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.replay_10_rounded, color: Colors.white, size: 28),
                              onPressed: () => _seekRelative(-10),
                            ),
                            const SizedBox(width: 16),
                            ValueListenableBuilder<VlcPlayerValue>(
                              valueListenable: _vlcController,
                              builder: (context, value, child) {
                                return FloatingActionButton(
                                  backgroundColor: const Color(0xFF6366F1),
                                  mini: true,
                                  onPressed: _togglePlayPause,
                                  child: Icon(
                                    value.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                    color: Colors.white,
                                    size: 26,
                                  ),
                                );
                              },
                            ),
                            const SizedBox(width: 16),
                            IconButton(
                              icon: const Icon(Icons.forward_10_rounded, color: Colors.white, size: 28),
                              onPressed: () => _seekRelative(10),
                            ),
                            const SizedBox(width: 24),
                            // Countdown Button
                            ElevatedButton.icon(
                              onPressed: _triggerCountdown,
                              icon: const Icon(Icons.timer_rounded, size: 16, color: Colors.white),
                              label: const Text('شروع هم‌زمان (۳ ثانیه)', style: TextStyle(fontSize: 11)),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF334155),
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                ),

              // 5. Floating Transparent Chat Drawer
              if (_isChatOpen)
                Positioned(
                  top: 60,
                  bottom: 70,
                  left: 16,
                  width: 280,
                  child: GestureDetector(
                    onTap: () {},
                    child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A).withOpacity(0.85),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: const Color(0xFF334155)),
                    ),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('چت زنده', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                            IconButton(
                              icon: const Icon(Icons.close_rounded, color: Colors.white54, size: 18),
                              onPressed: () => setState(() => _isChatOpen = false),
                            ),
                          ],
                        ),
                        Expanded(
                          child: ListView.builder(
                            itemCount: _messages.length,
                            itemBuilder: (context, index) {
                              final msg = _messages[index];
                              final isMe = msg.sender == widget.username;
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 6.0),
                                child: Column(
                                  crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                                  children: [
                                    Text(msg.sender, style: const TextStyle(color: Color(0xFF818CF8), fontSize: 9)),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                      decoration: BoxDecoration(
                                        color: isMe ? const Color(0xFF6366F1) : const Color(0xFF1E293B),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Text(msg.text, style: const TextStyle(color: Colors.white, fontSize: 11)),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: _chatController,
                                style: const TextStyle(color: Colors.white, fontSize: 11),
                                decoration: InputDecoration(
                                  hintText: 'پیام...',
                                  hintStyle: const TextStyle(color: Colors.white38, fontSize: 11),
                                  filled: true,
                                  fillColor: const Color(0xFF1E293B),
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(12),
                                    borderSide: BorderSide.none,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            IconButton(
                              icon: const Icon(Icons.send_rounded, color: Color(0xFF6366F1), size: 20),
                              onPressed: _sendChatMessage,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

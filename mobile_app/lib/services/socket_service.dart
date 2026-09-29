import 'package:socket_io_client/socket_io_client.dart' as IO;
import '../models/chat_message.dart';

class SocketService {
  static final SocketService _instance = SocketService._internal();
  factory SocketService() => _instance;
  SocketService._internal();

  IO.Socket? socket;
  String currentRoomId = '';
  String currentUsername = '';

  // Callbacks
  Function(double time)? onRemotePlay;
  Function(double time)? onRemotePause;
  Function(double time)? onRemoteSeek;
  Function(int seconds)? onCountdown;
  Function(ChatMessage message)? onChatMessage;
  Function(Map<String, dynamic> userProgress)? onUserProgress;
  Function(bool isConnected)? onConnectionChanged;

  void connect({
    required String serverUrl,
    required String roomId,
    required String username,
  }) {
    currentRoomId = roomId;
    currentUsername = username;

    socket?.disconnect();
    socket?.dispose();

    socket = IO.io(
      serverUrl,
      IO.OptionBuilder()
          .setTransports(['websocket', 'polling'])
          .enableAutoConnect()
          .enableReconnection()
          .build(),
    );

    socket!.onConnect((_) {
      print('[Socket] Connected to server');
      onConnectionChanged?.call(true);

      socket!.emit('join-room', {
        'roomId': roomId,
        'username': username,
        'isMuted': true,
        'isVideoOff': true,
      });
    });

    socket!.onDisconnect((_) {
      print('[Socket] Disconnected');
      onConnectionChanged?.call(false);
    });

    // Remote Playback Sync Events
    socket!.on('player-play', (data) {
      if (data != null && data['currentTime'] != null) {
        final time = (data['currentTime'] as num).toDouble();
        onRemotePlay?.call(time);
      }
    });

    socket!.on('player-pause', (data) {
      if (data != null && data['currentTime'] != null) {
        final time = (data['currentTime'] as num).toDouble();
        onRemotePause?.call(time);
      }
    });

    socket!.on('player-seek', (data) {
      if (data != null && data['currentTime'] != null) {
        final time = (data['currentTime'] as num).toDouble();
        onRemoteSeek?.call(time);
      }
    });

    // Countdown 3, 2, 1
    socket!.on('sync-countdown', (data) {
      if (data != null && data['seconds'] != null) {
        final sec = (data['seconds'] as num).toInt();
        onCountdown?.call(sec);
      }
    });

    // Progress updates from other peers
    socket!.on('user-progress-updated', (data) {
      if (data != null && data is Map) {
        onUserProgress?.call(Map<String, dynamic>.from(data));
      }
    });

    // Chat Message
    socket!.on('chat-message', (data) {
      if (data != null && data is Map) {
        final msg = ChatMessage.fromJson(Map<String, dynamic>.from(data));
        onChatMessage?.call(msg);
      }
    });
  }

  void sendPlay(double currentTime) {
    socket?.emit('player-play', {'currentTime': currentTime});
    sendProgress(currentTime, true);
  }

  void sendPause(double currentTime) {
    socket?.emit('player-pause', {'currentTime': currentTime});
    sendProgress(currentTime, false);
  }

  void sendSeek(double currentTime) {
    socket?.emit('player-seek', {'currentTime': currentTime});
    sendProgress(currentTime, false);
  }

  void sendProgress(double currentTime, bool isPlaying) {
    socket?.emit('user-progress', {
      'currentTime': currentTime,
      'isPlaying': isPlaying,
    });
  }

  void triggerCountdown({int seconds = 3}) {
    socket?.emit('trigger-countdown', {'seconds': seconds});
  }

  void sendChatMessage(String text) {
    if (text.trim().isEmpty) return;
    socket?.emit('send-message', {'text': text.trim()});
  }

  void disconnect() {
    socket?.disconnect();
    socket?.dispose();
    socket = null;
  }
}

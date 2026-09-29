class ChatMessage {
  final String id;
  final String sender;
  final String text;
  final int timestamp;
  final bool isSystem;

  ChatMessage({
    required this.id,
    required this.sender,
    required this.text,
    required this.timestamp,
    this.isSystem = false,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: json['id']?.toString() ?? DateTime.now().millisecondsSinceEpoch.toString(),
      sender: json['sender']?.toString() ?? 'کاربر',
      text: json['text']?.toString() ?? '',
      timestamp: json['timestamp'] is int ? json['timestamp'] : DateTime.now().millisecondsSinceEpoch,
      isSystem: json['isSystem'] == true,
    );
  }
}

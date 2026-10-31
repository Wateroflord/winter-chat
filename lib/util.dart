/// Даты и файлы.

DateTime? parseDate(String s) {
  if (s.isEmpty) return null;
  return DateTime.tryParse(s.replaceFirst(' ', 'T'))?.toLocal();
}

String two(int v) => v.toString().padLeft(2, '0');

String hhmm(DateTime d) => '${two(d.hour)}:${two(d.minute)}';

const _months = ['января', 'февраля', 'марта', 'апреля', 'мая', 'июня', 'июля', 'августа', 'сентября', 'октября', 'ноября', 'декабря'];

bool sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

/// Для списка чатов: время сегодня, иначе дата.
String shortTime(DateTime d) {
  final now = DateTime.now();
  if (sameDay(d, now)) return hhmm(d);
  if (sameDay(d, now.subtract(const Duration(days: 1)))) return 'вчера';
  if (d.year == now.year) return '${d.day} ${_months[d.month - 1].substring(0, 3)}';
  return '${two(d.day)}.${two(d.month)}.${d.year % 100}';
}

/// Заголовок дня в переписке.
String dayLabel(DateTime d) {
  final now = DateTime.now();
  if (sameDay(d, now)) return 'Сегодня';
  if (sameDay(d, now.subtract(const Duration(days: 1)))) return 'Вчера';
  if (d.year == now.year) return '${d.day} ${_months[d.month - 1]}';
  return '${d.day} ${_months[d.month - 1]} ${d.year}';
}

enum FileKind { image, video, audio, other }

FileKind fileKind(String name) {
  final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
  const img = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'};
  const vid = {'mp4', 'mov', 'webm', 'mkv', 'avi', 'm4v', '3gp'};
  const aud = {'mp3', 'ogg', 'wav', 'm4a', 'flac', 'opus', 'aac'};
  if (img.contains(ext)) return FileKind.image;
  if (vid.contains(ext)) return FileKind.video;
  if (aud.contains(ext)) return FileKind.audio;
  return FileKind.other;
}

/// PocketBase добавляет к имени файла случайный хвост: photo_ab12cd34ef.jpg → photo.jpg
String prettyFileName(String stored) {
  final m = RegExp(r'^(.*)_[a-zA-Z0-9]{10}(\.[^.]+)?$').firstMatch(stored);
  if (m == null) return stored;
  return '${m.group(1)}${m.group(2) ?? ''}';
}

String humanSize(int bytes) {
  if (bytes < 1024) return '$bytes Б';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} КБ';
  if (bytes < 1024 * 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(1)} МБ';
  return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} ГБ';
}

final urlRegex = RegExp(r'(https?://[^\s<>"]+)', caseSensitive: false);

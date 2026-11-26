/// API Configuration
/// Có thể truyền URL Backend local khi chạy dev để phản hồi tức thì (<5ms) thay vì chờ Render Cloud:
///   Android Emulator: flutter run --dart-define=API_BASE_URL=http://10.0.2.2:3000
///   Windows / Web / iOS Simulator: flutter run --dart-define=API_BASE_URL=http://localhost:3000
class ApiConfig {
  static const String baseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://onecoin-backend.onrender.com',
  );

  // Auth endpoints
  static const String login = '$baseUrl/auth/login';
  static const String register = '$baseUrl/auth/register';
  static const String profile = '$baseUrl/auth/profile';
  static const String changePassword = '$baseUrl/auth/change-password';
  static const String refreshToken = '$baseUrl/auth/refresh';
  static const String logout = '$baseUrl/auth/logout';

  // Data endpoints
  static const String wallets = '$baseUrl/wallets';
  static const String groups = '$baseUrl/groups';
  static const String groupsInit = '$baseUrl/groups/init';
  static const String transactions = '$baseUrl/transactions';
  static const String transactionsSync = '$baseUrl/transactions/sync';
  static const String budgets = '$baseUrl/budgets';
  static const String loans = '$baseUrl/loans';
  static const String loanPayments = '$baseUrl/loans/payments';
  static const String reminders = '$baseUrl/reminders';

  // Sync & AI endpoints
  static const String syncUpload = '$baseUrl/sync/upload';
  static const String syncDownload = '$baseUrl/sync/download';
  static const String aiParseTransaction = '$baseUrl/ai/parse-transaction';
  static const String aiScanReceipt = '$baseUrl/ai/scan-receipt';

  // Health check
  static const String health = '$baseUrl/health';
}

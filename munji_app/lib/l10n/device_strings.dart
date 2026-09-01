/// Strings for the device screen, Arabic and English.
///
/// Copy is lifted from the v64 prototype so nothing reads differently from
/// what was signed off. Kept in its own class to avoid touching `S` — fold it
/// into `S` later if you prefer one file.
class DS {
  DS(this.isArabic);
  final bool isArabic;

  String _(String ar, String en) => isArabic ? ar : en;

  // titles
  String get connectDevice => _('وصّل جهازك', 'Connect Your Device');
  String get device => _('الجهاز', 'Device');
  String get munjiDevice => _('جهاز منجي', 'Munji Device');

  // setup steps — lead line
  String get turnOnBluetooth => _('شغّل البلوتوث', 'Turn on Bluetooth');
  String get searching =>
      _('جارٍ البحث عن جهاز منجي', 'Searching for your Munji device');
  String get deviceFound => _('تم العثور على جهاز منجي', 'Munji device found');
  String get connecting => _('جارٍ الاتصال', 'Connecting');
  String get connected => _('متصل', 'Connected');

  // setup steps — sub line
  String get turnOnBluetoothSub =>
      _('ليتمكن منجي من العثور على جهازك.', 'So Munji can find your device.');
  String get searchingSub => _('تأكد أن جهازك يعمل وقريب منك.',
      'Make sure your device is powered on and nearby.');
  String get foundSub => _('جهاز منجي · إشارة قوية', 'Munji Device · strong signal');
  String get connectingSub =>
      _('جارٍ التخاطب مع جهاز منجي.', 'Talking to your Munji device.');
  String connectedSub(int battery) => _(
      'البطارية $battery٪ · المراقبة تعمل الآن.',
      'Battery $battery% · monitoring live.');

  // buttons
  String get continueLabel => _('متابعة', 'Continue');
  String get connect => _('اتصال', 'Connect');
  String get connectingBtn => _('جارٍ الاتصال…', 'Connecting…');
  String get startUsing => _('ابدأ استخدام منجي', 'Start using Munji');
  String get done => _('تم', 'Done');
  String get tryAgain => _('إعادة المحاولة', 'Try again');
  String get openSettings => _('فتح الإعدادات', 'Open settings');

  // steady state — the page you reach from Profile → Devices
  String get monitoringLive =>
      _('المراقبة تعمل الآن', 'Monitoring is live');
  String get streamingNow =>
      _('جهاز منجي يرسل البيانات مباشرة.', 'Your Munji device is streaming live.');
  String get battery => _('البطارية', 'Battery');
  String get signal => _('الإشارة', 'Signal');
  String get lastUpdate => _('آخر تحديث', 'Last update');
  String get strong => _('قوية', 'Strong');
  String get fair => _('متوسطة', 'Fair');
  String get weak => _('ضعيفة', 'Weak');
  String get none => _('لا توجد', 'None');
  String get justNow => _('الآن', 'just now');
  String secondsAgo(int s) => _('قبل $s ثانية', '${s}s ago');
  String minutesAgo(int m) => _('قبل $m دقيقة', '${m}m ago');
  String hoursAgo(int h) => _('قبل $h ساعة', '${h}h ago');

  // recovery states
  String get reconnecting => _('جارٍ إعادة الاتصال', 'Reconnecting');
  String get reconnectingSub => _(
      'ابقَ قريبًا من جهازك. سيعود منجي من تلقاء نفسه.',
      'Stay near your device. Munji will reconnect on its own.');

  String get deviceOffline => _('الجهاز غير متصل', 'Device is offline');
  String get batteryEmptySub => _(
      'انتهت بطارية الجهاز. اشحنه وسيعود الاتصال تلقائيًا.',
      'The device battery is empty. Charge it and it will reconnect on its own.');
  String get deviceOfflineSub => _(
      'تأكد أن الجهاز يعمل وقريب منك.',
      'Check the device is switched on and near you.');

  String get bluetoothOff => _('البلوتوث مغلق', 'Bluetooth is off');
  String get bluetoothOffSub => _(
      'شغّل البلوتوث من إعدادات هاتفك ليتابع منجي قلبك.',
      'Turn Bluetooth on in your phone settings so Munji can watch your heart.');

  /// The one line that matters when monitoring has stopped. Plain language —
  /// no "connection lost", no "BLE".
  String get notWatching => _(
      'منجي لا يراقب قلبك الآن.',
      'Munji is not watching your heart right now.');

  // pairing help
  String get howToPair => _('كيف أقترن بالجهاز؟', 'How to pair?');
  String get howToPairBody => _(
      'اضغط مطوّلًا على زر جهاز منجي حتى يومض الضوء.',
      'Press and hold the button on your Munji device until the light flashes.');

  String get pairingRequired => _('الاقتران مطلوب', 'Pairing is required');
  String get pairingRequiredSub => _(
      'لا يستطيع منجي مراقبة قلبك قبل توصيل الجهاز.',
      'Munji cannot monitor your heart until the device is connected.');

  String get setupComplete => _(
      'اكتمل الإعداد — المراقبة تعمل الآن',
      'Setup complete — monitoring is live');
  String get deviceConnectedToast =>
      _('تم توصيل جهاز منجي', 'Munji device connected');

  String get forgetDevice => _('نسيان الجهاز', 'Forget this device');
  String get forgetConfirm => _(
      'ستتوقف المراقبة حتى توصّل جهازًا مرة أخرى.',
      'Monitoring stops until you connect a device again.');
  String get cancel => _('إلغاء', 'Cancel');
  String get forget => _('نسيان', 'Forget');

  String stepOf(int n) => _('الخطوة $n من 3', 'Step $n of 3');
}

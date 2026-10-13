# أي ملف يخص أي صفحة

عشان الدمج مع شغل فرات بدون ما يضيع شي.

## الصفحة 1: تسجيل ECG لمدة 30 ثانية
- `munji_app/lib/screens/capture_screen.dart`
- `munji_app/lib/services/ecg_capture.dart`
- `munji_app/lib/services/recording_service.dart`
- `munji_app/lib/widgets/live_ecg_strip.dart`
- `munji_app/test/ecg_capture_test.dart`

## الصفحة 2: السجل
غير موجودة في هذا الملف (شغل فرات).

## الصفحة 3: الوصول للبيانات (الفلتر والرسوم)
- `munji_app/lib/screens/reports_screen.dart`
- `munji_app/lib/services/report_data.dart`
- `munji_app/lib/widgets/trend_chart.dart`
- `munji_app/lib/services/hourly_recorder.dart` (يكتب الملخص كل ساعة، بدونه ما فيه بيانات)
- `munji_app/test/reports_test.dart`

## الصفحة 4: توليد التقارير PDF
- `munji_app/lib/services/report_pdf.dart`
- `munji_app/assets/fonts/` (خط Tajawal، يحتاجه الـ PDF للعربي)

## ملفات مشتركة تعدلت
- `munji_app/lib/screens/patient_shell.dart` (تبويب التقارير والقياس)
- `munji_app/lib/services/device_service.dart` و `device_registry.dart` (تشغيل HourlyRecorder)
- `munji_app/lib/screens/auth_gate.dart` و `lib/main.dart`
- `munji_app/pubspec.yaml` (مكتبات: cloud_functions، firebase_storage، pdf، printing + الخط)

## الباك اند
كامل في `munji-backend2/`. الجديد هالمرة:
- `seed/seed.js`: أسبوعين بيانات تجريبية للتقارير

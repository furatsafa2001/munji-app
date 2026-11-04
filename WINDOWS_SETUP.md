# تشغيل منجي على ويندوز لأول مرة

الدليل يفترض Windows 10 أو 11 وجوال **أندرويد**.
(الآيفون ما يشتغل من ويندوز، يحتاج ماك.)

كل الأوامر تنكتب في **PowerShell**.

---

## الجزء 1: تثبيت البرامج (مرة وحدة)

### 1. Git
حمّله من https://git-scm.com/download/win وثبته بالإعدادات الافتراضية.

### 2. Node.js 22 (LTS)
حمّل نسخة **22 LTS** من https://nodejs.org وثبتها.
الـ Cloud Functions مكتوبة على Node 22، فلا تثبت نسخة أقدم.

### 3. Java 21
محاكي Firebase يحتاج Java 21. حمّل **Temurin 21 (LTS)** من https://adoptium.net
وأثناء التثبيت فعّل خيار **Set JAVA_HOME variable**.

### 4. Flutter
1. حمّل Flutter SDK لويندوز من https://docs.flutter.dev/get-started/install/windows
2. فك الملف في `C:\src\flutter` (لا تحطه في Program Files)
3. أضف `C:\src\flutter\bin` لمتغير **Path**:
   ابحث في ويندوز عن **Edit the system environment variables** ← Environment Variables ← اختر Path تحت User variables ← Edit ← New ← اكتب `C:\src\flutter\bin`

### 5. Android Studio
1. حمّله من https://developer.android.com/studio وثبته
2. افتحه مرة وخله يكمل تحميل الـ SDK
3. من **More Actions ← SDK Manager ← SDK Tools** فعّل:
   - Android SDK Command-line Tools
   - Android SDK Platform-Tools
4. اضغط Apply

### 6. Firebase CLI
```powershell
npm install -g firebase-tools
```

### 7. تأكد إن كل شي تمام
**سكّر PowerShell وافتحه من جديد** (عشان يقرأ الـ Path الجديد)، وبعدين:
```powershell
git --version
node --version
java -version
flutter --version
firebase --version
flutter doctor --android-licenses
flutter doctor
```
- وافق على كل التراخيص بـ `y`
- في `flutter doctor` المهم يطلع ✓ جنب **Flutter** و**Android toolchain**. علامات Visual Studio و Chrome ما تهمنا.

---

## الجزء 2: تجهيز المشروع (مرة وحدة)

### 8. جيب المشروع
**الطريقة الأولى (مفضلة): من GitHub**
```powershell
cd $HOME\Documents
git clone https://github.com/furatsafa2001/munji-app.git munji
cd munji
git checkout month2
```
لو طلب تسجيل دخول، بيفتح المتصفح، سجل بحساب عنده صلاحية على الـ repo.

**الطريقة الثانية: من الـ zip**
فك الملف في `C:\Users\اسمك\Documents\munji` وادخل المجلد.

### 9. ثبّت مكتبات الباك اند
```powershell
cd munji-backend2
npm install
npm --prefix functions install
```

### 10. سجل دخول Firebase
```powershell
firebase login
```
سجل بحساب `technical@munji.co`.

### 11. ثبّت مكتبات التطبيق
```powershell
cd ..\munji_app
flutter pub get
```
لو طلع خطأ في نسخة أي مكتبة من الجديدة، اكتب:
```powershell
flutter pub add cloud_functions firebase_storage pdf printing
```
وهو يختار النسخ المتوافقة.

### 12. اسمح لجدار الحماية
افتح **PowerShell كمسؤول** (كليك يمين ← Run as administrator) واكتب:
```powershell
New-NetFirewallRule -DisplayName "Munji Firebase emulators" -Direction Inbound -Protocol TCP -LocalPort 4000,5001,8080,9099,9199 -Action Allow -Profile Private
```
وتأكد إن شبكة الواي فاي عندك **Private** مو Public:
الإعدادات ← الشبكة والإنترنت ← Wi-Fi ← اسم الشبكة ← Network profile type ← **Private**

بدون هالخطوة الجوال ما يقدر يوصل للمحاكي اللي على جهازك.

### 13. السماح بتشغيل السكربتات
```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

### 14. جهز جوال الأندرويد
1. **الإعدادات ← حول الهاتف ← معلومات البرنامج** واضغط **رقم الإصدار** 7 مرات
2. ارجع للإعدادات ← **خيارات المطور** ← فعّل **USB debugging**
3. وصل الجوال بالكيبل، ووافق على رسالة **Allow USB debugging**
4. تأكد:
```powershell
flutter devices
```
المفروض يطلع جوالك.

---

## الجزء 3: التشغيل (كل مرة)

تحتاج **3 نوافذ PowerShell**.

### النافذة 1: المحاكي
```powershell
cd $HOME\Documents\munji\munji-backend2
npm run emu
```
انتظر لين يطلع `All emulators ready`. **خلها مفتوحة.**
لوحة المحاكي: http://localhost:4000

### النافذة 2: البيانات التجريبية (مرة بعد كل تشغيل للمحاكي)
```powershell
cd $HOME\Documents\munji\munji-backend2
npm run seed
```

### النافذة 3: التطبيق
```powershell
cd $HOME\Documents\munji\munji_app
.\scripts\run_emulator.ps1
```
المفروض يطلع `Emulator host: 192.168.x.x` وبعدها يثبت التطبيق على الجوال.
**الجوال والكمبيوتر لازم يكونون على نفس الواي فاي.**

### الحسابات التجريبية (كلمة السر `Test1234!`)
| الإيميل | النوع |
|---|---|
| safa.khan@email.com | مريضة، مرتبطة بنورة |
| ahmed.khan@email.com | مريض، مرتبط بنورة |
| nora.khan@email.com | مرافقة للاثنين |

---

## الجزء 4: تجربة الربط بين المريض والمرافق

الربط يشتغل على المحاكي، وعلى المشروع الحقيقي بعد نشر الـ Functions (`npm run deploy:functions`).

**أسهل طريقة بجوال واحد:**
1. سجل دخول بـ `safa.khan@email.com`
2. **حسابي ← المرافقون ← إضافة مرافق**، وسجل الرمز اللي يطلع (صالح 10 دقائق)
3. سجل خروج، وسو **حساب جديد** نوعه **مرافق**
4. الإيميل التجريبي ما يوصل فعليًا، رابط التأكيد يطلع في **النافذة 1**، انسخه وافتحه في المتصفح
5. **إدخال الرمز** ← اكتب الرمز ← **ربط**
6. المفروض تطلع صفاء في قائمة "من أرعاهم" مع نبضها

**بجهازين:** شغل التطبيق على جوالين (أو جوال + Android Emulator من Android Studio)، واحد مريض وواحد مرافق، وبتشوف شاشة المريض تتحول لـ "تم ربط..." لحالها لما المرافق يدخل الرمز.

---

## الجزء 5: الاختبارات

```powershell
cd $HOME\Documents\munji\munji-backend2
npm run test:functions   # بدون محاكي
npm run test:rules       # يشغل المحاكي لحاله
npm run test:links       # يشغل المحاكي لحاله

cd ..\munji_app
flutter analyze
flutter test             # اختبارات ملف التسجيل والتقارير
```
**قبلها سكّر النافذة 1** لأن الاختبارات تشغل محاكي خاص فيها على نفس المنافذ.

---

## الجزء 6: تجربة تسجيل ECG

يحتاج اللاصقة متصلة، والمحاكي شغال (النافذة 1).

1. سجل دخول كمريض ووصّل اللاصقة
2. تبويب **القياس** ← **ابدأ التسجيل**، واثبت 30 ثانية
3. المفروض يطلع **تم حفظ التسجيل** مع متوسط النبض
4. تأكد من لوحة المحاكي http://localhost:4000:
   - **Storage**: ملف في `patients/{uid}/recordings/`
   - **Firestore**: مستند في `users/{uid}/recordings/` (هذا ينشئه الخادم بعد ما يتحقق من الملف)

جرب كمان الحالات الصعبة: افصل قطب أثناء التسجيل، أو ابعد الجوال عن اللاصقة، والمفروض يوقف التسجيل ويقول السبب.

---

## الجزء 7: تجربة التقارير

البيانات التجريبية فيها أسبوعين لصفاء (يومين منهم فاضيين عمدًا).

1. سجل دخول بـ `safa.khan@email.com`
2. تبويب **التقارير** ← جرب: 3 أيام، أسبوع، شهر، مخصص
3. 3 أيام تعرض **بالساعة**، والباقي **باليوم**
4. الأيام الفاضية لازم تطلع **فراغ** في الرسم، مو خط واصل
5. اضغط **تصدير تقرير PDF** ← يفتح قائمة المشاركة (واتساب، إيميل، حفظ)

**ملاحظة:** البيانات الحقيقية تنكتب كل ساعة من جوال المريض وهو متصل باللاصقة، يعني بعد ساعة من التوصيل يبدأ يطلع شي في التقارير.

---

## مشاكل شائعة

| المشكلة | الحل |
|---|---|
| `flutter` أو `firebase` is not recognized | سكّر PowerShell وافتحه من جديد، ولو استمرت تأكد من الـ Path |
| `Could not start Firestore Emulator, port taken` | فيه محاكي ثاني شغال، سكّر كل نوافذ PowerShell وأعد |
| `Java version ... is not supported` | ثبت Java 21 وأعد فتح PowerShell |
| التطبيق يعلق على التحميل أو `unavailable` | الجوال ما يوصل للكمبيوتر: تأكد من الخطوة 12 ومن نفس الواي فاي |
| `running scripts is disabled on this system` | الخطوة 13 |
| `flutter devices` ما يشوف الجوال | غير الكيبل، ووافق على رسالة USB debugging في الجوال، وجرب `adb devices` |
| `INVALID_REFRESH_TOKEN` | الجوال فيه حساب قديم من Firebase الحقيقي: `adb shell pm clear co.munji.munji_app` |

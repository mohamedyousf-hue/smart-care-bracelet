import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
 
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
 
// ---------- إعدادات ----------
const String baseUrl = 'http://127.0.0.1:8000';
const Duration staleAfter = Duration(seconds: 30); // مع السوار الحقيقي: حوالي 3 دقايق
const Color bgColor = Color(0xFFF2F5F7);
 
// ---------- مستويات الحالة ----------
// الحدود أولية من سلايد 16 (للعرض فقط لحد المراجعة الطبية).
// الفجوات بين النطاقات (مثل نبض 40-49 و121-130) بتتعامل كـ "تحذير" مؤقتًا.
enum Level { normal, warning, emergency }
 
Level heartLevel(double v) {
  if (v < 40 || v > 130) return Level.emergency;
  if (v >= 60 && v <= 100) return Level.normal;
  return Level.warning;
}
 
Level spo2Level(double v) {
  if (v >= 95) return Level.normal;
  if (v <= 90) return Level.emergency;
  return Level.warning;
}
 
Level tempLevel(double v) {
  if (v >= 39) return Level.emergency;
  if (v >= 36.1 && v <= 37.5) return Level.normal;
  return Level.warning;
}
 
Level worst(List<Level> l) => l.reduce((a, b) => a.index >= b.index ? a : b);
 
const Color cNormal = Color(0xFF2E7D32);
const Color cWarning = Color(0xFFEF6C00);
const Color cEmergency = Color(0xFFC62828);
const Color cStale = Color(0xFF607D8B);
 
// null = مفيش بيانات حديثة
Color levelColor(Level? l) {
  if (l == Level.normal) return cNormal;
  if (l == Level.warning) return cWarning;
  if (l == Level.emergency) return cEmergency;
  return cStale;
}
 
String levelTitle(Level? l) {
  if (l == Level.normal) return 'الحالة مستقرة';
  if (l == Level.warning) return 'تحذير: تحتاج متابعة';
  if (l == Level.emergency) return 'طوارئ: قراءات خطيرة';
  return 'لا توجد بيانات حديثة';
}
 
IconData levelIcon(Level? l) {
  if (l == Level.normal) return Icons.check_circle_rounded;
  if (l == Level.warning) return Icons.warning_amber_rounded;
  if (l == Level.emergency) return Icons.error_rounded;
  return Icons.wifi_off_rounded;
}
 
String ageText(Duration d) {
  if (d.isNegative) d = Duration.zero;
  if (d.inSeconds < 60) return 'منذ ${d.inSeconds} ثانية';
  if (d.inMinutes < 60) return 'منذ ${d.inMinutes} دقيقة';
  return 'منذ ${d.inHours} ساعة';
}
 
// رسالة الخطأ اللي السيرفر بعتها (مهم: نفك الترميز UTF-8 بإيدينا عشان العربي)
String serverDetail(http.Response res) {
  try {
    final d = jsonDecode(utf8.decode(res.bodyBytes));
    if (d is Map && d['detail'] is String) return d['detail'] as String;
  } catch (_) {}
  return 'خطأ من السيرفر (${res.statusCode})';
}
 
// ---------- النماذج ----------
class Session {
  final String token;
  final String role; // patient أو caregiver
  final String name;
  final String? patientName;
  final String? deviceId;
 
  Session({
    required this.token,
    required this.role,
    required this.name,
    this.patientName,
    this.deviceId,
  });
 
  bool get isPatient => role == 'patient';
}
 
class Reading {
  final DateTime measuredAt; // UTC
  final double heartRate;
  final double spo2;
  final double temperature;
  final String source;
 
  Reading({
    required this.measuredAt,
    required this.heartRate,
    required this.spo2,
    required this.temperature,
    required this.source,
  });
 
  factory Reading.fromJson(Map<String, dynamic> j) {
    final s = j['measured_at'] as String;
    return Reading(
      measuredAt: DateTime.parse(s.endsWith('Z') ? s : '${s}Z'),
      heartRate: (j['heart_rate'] as num).toDouble(),
      spo2: (j['spo2'] as num).toDouble(),
      temperature: (j['temperature'] as num).toDouble(),
      source: (j['source'] ?? '') as String,
    );
  }
}
 
void main() => runApp(const SmartCareApp());
 
class SmartCareApp extends StatelessWidget {
  const SmartCareApp({super.key});
 
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Smart Care',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      home: const RootApp(),
    );
  }
}
 
// ---------- الجذر: يختار بين تسجيل الدخول والشاشة الرئيسية ----------
class RootApp extends StatefulWidget {
  const RootApp({super.key});
 
  @override
  State<RootApp> createState() => _RootAppState();
}
 
class _RootAppState extends State<RootApp> {
  Session? session; // محفوظة في الذاكرة بس، بتضيع لو عملت Refresh للصفحة
  String? message;
 
  @override
  Widget build(BuildContext context) {
    final s = session;
    if (s == null) {
      return LoginScreen(
        message: message,
        onLoggedIn: (newSession) => setState(() {
          session = newSession;
          message = null;
        }),
      );
    }
    return HomeScreen(
      key: ValueKey(s.token),
      session: s,
      onLogout: ([String? msg]) => setState(() {
        session = null;
        message = msg;
      }),
    );
  }
}
 
// ---------- شاشة تسجيل الدخول ----------
class LoginScreen extends StatefulWidget {
  final void Function(Session) onLoggedIn;
  final String? message;
 
  const LoginScreen({super.key, required this.onLoggedIn, this.message});
 
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}
 
class _LoginScreenState extends State<LoginScreen> {
  final userCtrl = TextEditingController();
  final passCtrl = TextEditingController();
  bool loading = false;
  String? error;
 
  @override
  void dispose() {
    userCtrl.dispose();
    passCtrl.dispose();
    super.dispose();
  }
 
  Future<void> doLogin() async {
    final u = userCtrl.text.trim();
    final p = passCtrl.text;
    if (u.isEmpty || p.isEmpty) {
      setState(() => error = 'اكتب اسم المستخدم وكلمة السر');
      return;
    }
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final res = await http.post(
        Uri.parse('$baseUrl/auth/login'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'username': u, 'password': p}),
      );
      if (res.statusCode != 200) {
        if (mounted) setState(() => error = serverDetail(res));
        return;
      }
      final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
      final token = data['access_token'] as String;
 
      final meRes = await http.get(
        Uri.parse('$baseUrl/me'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (meRes.statusCode != 200) {
        if (mounted) setState(() => error = serverDetail(meRes));
        return;
      }
      final me = jsonDecode(utf8.decode(meRes.bodyBytes)) as Map<String, dynamic>;
      widget.onLoggedIn(Session(
        token: token,
        role: me['role'] as String,
        name: me['name'] as String,
        patientName: me['patient_name'] as String?,
        deviceId: me['device_id'] as String?,
      ));
    } catch (_) {
      if (mounted) setState(() => error = 'تعذّر الاتصال بالسيرفر');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }
 
  @override
  Widget build(BuildContext context) {
    final msg = error ?? widget.message;
    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.health_and_safety,
                      size: 72, color: Color(0xFF00695C)),
                  const SizedBox(height: 12),
                  const Text('السوار الذكي للرعاية',
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  const Text('سجّل الدخول لمتابعة الحالة',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.black54)),
                  const SizedBox(height: 32),
                  TextField(
                    controller: userCtrl,
                    textDirection: TextDirection.ltr,
                    decoration: const InputDecoration(
                      labelText: 'اسم المستخدم',
                      prefixIcon: Icon(Icons.person),
                      border: OutlineInputBorder(),
                      filled: true,
                      fillColor: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: passCtrl,
                    obscureText: true,
                    textDirection: TextDirection.ltr,
                    onSubmitted: (_) => doLogin(),
                    decoration: const InputDecoration(
                      labelText: 'كلمة السر',
                      prefixIcon: Icon(Icons.lock),
                      border: OutlineInputBorder(),
                      filled: true,
                      fillColor: Colors.white,
                    ),
                  ),
                  if (msg != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(msg,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: cEmergency)),
                    ),
                  const SizedBox(height: 20),
                  SizedBox(
                    height: 50,
                    child: FilledButton(
                      onPressed: loading ? null : doLogin,
                      child: loading
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('دخول', style: TextStyle(fontSize: 18)),
                    ),
                  ),
                  const SizedBox(height: 24),
                  // للعرض التجريبي فقط: احذف الجزء ده قبل أي استخدام حقيقي
                  const Text(
                    'حسابات تجريبية\nمريض: ahmed / ahmed123\nمقدم رعاية: mohamed / mohamed123',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.black38, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
 
// ---------- الشاشة الرئيسية (مريض أو مقدم رعاية) ----------
class HomeScreen extends StatefulWidget {
  final Session session;
  final void Function([String?]) onLogout;
 
  const HomeScreen({super.key, required this.session, required this.onLogout});
 
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}
 
class _HomeScreenState extends State<HomeScreen> {
  List<Reading> history = [];
  bool loaded = false;
  String? error;
  Timer? timer;
  int tick = 0;
 
  @override
  void initState() {
    super.initState();
    fetchHistory();
    // كل ثانية نحدّث "منذ كذا ثانية"، وكل 3 ثواني نطلب بيانات جديدة
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      tick++;
      if (tick % 3 == 0) {
        fetchHistory();
      } else {
        setState(() {});
      }
    });
  }
 
  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }
 
  Future<void> fetchHistory() async {
    try {
      final res = await http.get(
        Uri.parse('$baseUrl/me/history?limit=30'),
        headers: {'Authorization': 'Bearer ${widget.session.token}'},
      );
      if (!mounted) return;
      if (res.statusCode == 200) {
        final list = (jsonDecode(utf8.decode(res.bodyBytes)) as List)
            .map((e) => Reading.fromJson(e as Map<String, dynamic>))
            .toList();
        setState(() {
          history = list;
          loaded = true;
          error = null;
        });
      } else if (res.statusCode == 401) {
        widget.onLogout('انتهت الجلسة، سجّل الدخول من جديد');
      } else {
        setState(() => error = serverDetail(res));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => error = 'تعذّر الاتصال بالسيرفر');
    }
  }
 
  BoxDecoration _cardDecoration() => BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
              color: Color(0x14000000), blurRadius: 12, offset: Offset(0, 4)),
        ],
      );
 
  Widget _demoChip(Reading? last) {
    if (last == null || last.source != 'simulator') {
      return const SizedBox.shrink();
    }
    return const Chip(
      label: Text('بيانات تجريبية'),
      avatar: Icon(Icons.science, size: 18),
    );
  }
 
  Widget _caregiverHeader(Reading? last) {
    final s = widget.session;
    return Row(
      children: [
        const CircleAvatar(
          radius: 26,
          backgroundColor: Color(0xFFB2DFDB),
          child: Icon(Icons.elderly, size: 30, color: Color(0xFF00695C)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s.patientName ?? 'لا يوجد مريض مرتبط',
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.bold)),
              Text('السوار: ${s.deviceId ?? '-'}',
                  style: const TextStyle(color: Colors.black54)),
            ],
          ),
        ),
        _demoChip(last),
      ],
    );
  }
 
  Widget _statusCard(Level? level, Duration age) {
    final c = levelColor(level);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [c, Color.lerp(c, Colors.black, 0.25)!],
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
        ),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Row(
        children: [
          Icon(levelIcon(level), color: Colors.white, size: 56),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(levelTitle(level),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text('آخر تحديث ${ageText(age)}',
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 14)),
              ],
            ),
          ),
        ],
      ),
    );
  }
 
  // كارت صغير لمقدم الرعاية (3 جنب بعض)
  Widget _tile(
      String label, String value, String unit, IconData icon, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
        decoration: _cardDecoration(),
        child: Column(
          children: [
            Icon(icon, color: color, size: 30),
            const SizedBox(height: 8),
            Text(value,
                style: TextStyle(
                    fontSize: 28, fontWeight: FontWeight.bold, color: color)),
            Text(unit,
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(fontSize: 14)),
          ],
        ),
      ),
    );
  }
 
  // كارت كبير للمريض (خط كبير وواضح)
  Widget _bigVital(
      String label, String value, String unit, IconData icon, Color color) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(20),
      decoration: _cardDecoration(),
      child: Row(
        children: [
          Icon(icon, color: color, size: 44),
          const SizedBox(width: 16),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 22))),
          Text(value,
              style: TextStyle(
                  fontSize: 40, fontWeight: FontWeight.bold, color: color)),
          const SizedBox(width: 6),
          Text(unit,
              style: const TextStyle(fontSize: 14, color: Colors.black54)),
        ],
      ),
    );
  }
 
  Widget _chartCard(Color color) {
    final values = history.map((r) => r.heartRate).toList();
    final lo = values.reduce(math.min).toStringAsFixed(0);
    final hi = values.reduce(math.max).toStringAsFixed(0);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('نبض القلب (آخر ${values.length} قراءة)',
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          SizedBox(
            height: 140,
            width: double.infinity,
            child: CustomPaint(painter: SparkPainter(values, color)),
          ),
          const SizedBox(height: 8),
          Text('الأقل: $lo   •   الأعلى: $hi',
              style: const TextStyle(color: Colors.black54, fontSize: 13)),
        ],
      ),
    );
  }
 
  Widget _errorBox(String msg) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFEBEE),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.cloud_off, color: cEmergency),
          const SizedBox(width: 8),
          Expanded(child: Text(msg)),
        ],
      ),
    );
  }
 
  @override
  Widget build(BuildContext context) {
    final s = widget.session;
    final last = history.isEmpty ? null : history.last;
    final age = last == null
        ? Duration.zero
        : DateTime.now().toUtc().difference(last.measuredAt);
    final live = last != null && age <= staleAfter;
 
    Level? level;
    if (last != null && live) {
      level = worst([
        heartLevel(last.heartRate),
        spo2Level(last.spo2),
        tempLevel(last.temperature),
      ]);
    }
 
    Color c(Level Function(double) f, double v) =>
        live ? levelColor(f(v)) : cStale;
 
    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: bgColor,
        surfaceTintColor: Colors.transparent,
        title: Text(s.isPatient ? 'حالتي' : 'لوحة المتابعة'),
        actions: [
          IconButton(
            tooltip: 'تسجيل الخروج',
            icon: const Icon(Icons.logout),
            onPressed: () => widget.onLogout(),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (s.isPatient) ...[
                  Text('أهلاً، ${s.name}',
                      style: const TextStyle(
                          fontSize: 26, fontWeight: FontWeight.bold)),
                  Align(
                      alignment: Alignment.centerRight,
                      child: _demoChip(last)),
                ] else
                  _caregiverHeader(last),
                const SizedBox(height: 16),
                if (error != null) _errorBox(error!),
                if (!loaded && error == null)
                  const Padding(
                    padding: EdgeInsets.all(40),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                if (loaded && last == null)
                  const Padding(
                    padding: EdgeInsets.all(40),
                    child: Center(child: Text('لا توجد قراءات بعد')),
                  ),
                if (last != null) ...[
                  _statusCard(level, age),
                  const SizedBox(height: 16),
                  if (s.isPatient) ...[
                    _bigVital('نبض القلب', last.heartRate.toStringAsFixed(0),
                        'نبضة/دقيقة', Icons.favorite, c(heartLevel, last.heartRate)),
                    _bigVital('الأكسجين', last.spo2.toStringAsFixed(0), '%',
                        Icons.air, c(spo2Level, last.spo2)),
                    _bigVital('الحرارة', last.temperature.toStringAsFixed(1),
                        '°C', Icons.thermostat, c(tempLevel, last.temperature)),
                  ] else ...[
                    Row(
                      children: [
                        _tile('النبض', last.heartRate.toStringAsFixed(0),
                            'نبضة/دقيقة', Icons.favorite,
                            c(heartLevel, last.heartRate)),
                        const SizedBox(width: 12),
                        _tile('الأكسجين', last.spo2.toStringAsFixed(0), '%',
                            Icons.air, c(spo2Level, last.spo2)),
                        const SizedBox(width: 12),
                        _tile('الحرارة', last.temperature.toStringAsFixed(1),
                            '°C', Icons.thermostat,
                            c(tempLevel, last.temperature)),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _chartCard(live ? levelColor(level) : cStale),
                  ],
                ],
                const SizedBox(height: 16),
                const Text(
                  'الحدود المستخدمة أولية للعرض فقط، والنظام لا يقدّم تشخيصًا طبيًا.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.black45, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
 
// رسم منحنى النبض بدون مكتبات إضافية
class SparkPainter extends CustomPainter {
  final List<double> values;
  final Color color;
 
  SparkPainter(this.values, this.color);
 
  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final lo = values.reduce(math.min) - 5;
    final hi = values.reduce(math.max) + 5;
    final range = hi - lo;
 
    Offset pt(int i) => Offset(
          size.width * i / (values.length - 1),
          size.height - (values[i] - lo) / range * size.height,
        );
 
    final line = Path()..moveTo(pt(0).dx, pt(0).dy);
    for (var i = 1; i < values.length; i++) {
      line.lineTo(pt(i).dx, pt(i).dy);
    }
 
    final fill = Path.from(line)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
 
    canvas.drawPath(fill, Paint()..color = color.withAlpha(35));
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawCircle(pt(values.length - 1), 5, Paint()..color = color);
  }
 
  @override
  bool shouldRepaint(covariant SparkPainter old) => true;
}
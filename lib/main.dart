import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------- Helpers ----------------
const teal = Color(0xFF00796B);
const bg = Color(0xFFF2F7F6);

// Date to text, for example "2026-11-19"
String dk(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

// TimeOfDay to text, for example "08:30"
String hm(TimeOfDay t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

// "08:30" to minutes (510), so two times can be compared
int mins(String t) => int.parse(t.substring(0, 2)) * 60 + int.parse(t.substring(3, 5));

// Rounded white card used across the app
Widget box({
  required Widget child,
  Color color = Colors.white,
  Color? border,
  EdgeInsets pad = const EdgeInsets.all(14),
}) {
  return Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: pad,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: border ?? Colors.transparent),
      boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 8, offset: Offset(0, 2))],
    ),
    child: child,
  );
}

// Round medicine photo (or an icon if there is no photo)
Widget avatar(Med m, {double r = 24}) => CircleAvatar(
  radius: r,
  backgroundColor: Colors.teal.shade50,
  backgroundImage: m.photo.isEmpty ? null : FileImage(File(m.photo)),
  child: m.photo.isEmpty ? Icon(Icons.medication, color: teal, size: r) : null,
);

Widget sectionTitle(String t) => Padding(
  padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
  child: Text(t, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Color(0xFF004D40))),
);

// ---------------- Model ----------------
class Med {
  String id, name, photo;
  int stock, days;
  DateTime start;
  List<String> times; // for example "08:00"
  bool afterFood;

  Med({required this.id, required this.name, required this.photo, required this.stock,
    required this.days, required this.start, required this.times, required this.afterFood});

  Map<String, dynamic> toJson() => {
    'id': id, 'name': name, 'photo': photo, 'stock': stock, 'days': days,
    'start': start.toIso8601String(), 'times': times, 'afterFood': afterFood,
  };

  factory Med.fromJson(Map<String, dynamic> j) => Med(
    id: j['id'], name: j['name'], photo: j['photo'], stock: j['stock'], days: j['days'],
    start: DateTime.parse(j['start']), times: List<String>.from(j['times']),
    afterFood: j['afterFood'],
  );

  // Is this medicine still active on the given date?
  bool activeOn(DateTime d) {
    final day = DateTime(d.year, d.month, d.day);
    final end = DateTime(start.year, start.month, start.day + days);
    return !day.isBefore(start) && day.isBefore(end);
  }
}

// One scheduled dose of a medicine
class Dose {
  final Med med;
  final String key, time;
  final String? status; // taken, skipped, or null (still pending)
  Dose(this.med, this.key, this.time, this.status);
}

// ---------------- Storage ----------------
// logs: "medId|doseIndex|date" -> taken or skipped
// over: "medId|doseIndex|date" -> "HH:mm" (changed time for that day)
class Store {
  static Future<List<Med>> meds() async {
    final s = (await SharedPreferences.getInstance()).getString('meds');
    if (s == null) return [];
    return (jsonDecode(s) as List).map((e) => Med.fromJson(e)).toList();
  }

  static Future<void> saveMeds(List<Med> m) async => (await SharedPreferences.getInstance())
      .setString('meds', jsonEncode(m.map((e) => e.toJson()).toList()));

  static Future<Map<String, String>> map(String name) async {
    final s = (await SharedPreferences.getInstance()).getString(name);
    return s == null ? {} : Map<String, String>.from(jsonDecode(s));
  }

  static Future<void> setEntry(String name, String key, String value) async {
    final m = await map(name);
    m[key] = value;
    await (await SharedPreferences.getInstance()).setString(name, jsonEncode(m));
  }
}

// ---------------- App ----------------
void main() => runApp(const MedApp());

class MedApp extends StatelessWidget {
  const MedApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Medicine Tracker',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(useMaterial3: true, colorSchemeSeed: teal, scaffoldBackgroundColor: bg),
    home: const Shell(),
  );
}

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int tab = 0;
  List<Med> meds = [];
  Map<String, String> logs = {}, over = {};
  Timer? timer;

  @override
  void initState() {
    super.initState();
    load();
    // Refresh the screen every 30 seconds so reminder messages update on their own
    timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  // Read all saved data and refresh the screen
  Future<void> load() async {
    final m = await Store.meds();
    final l = await Store.map('logs');
    final o = await Store.map('over');
    if (mounted) setState(() { meds = m; logs = l; over = o; });
  }

  void snack(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(s)));
  }

  // Taken or Skip
  Future<void> setStatus(Dose d, String status) async {
    await Store.setEntry('logs', d.key, status);
    if (status == 'taken' && d.med.stock > 0) {
      d.med.stock--; // reduce stock by one
      await Store.saveMeds(meds);
    }
    await load();
    snack(status == 'taken' ? '${d.med.name} marked as taken' : '${d.med.name} skipped');
  }

  // Later: remind again after 10 minutes
  Future<void> later(Dose d) async {
    final t = DateTime.now().add(const Duration(minutes: 10));
    await Store.setEntry('over', d.key, hm(TimeOfDay.fromDateTime(t)));
    await load();
    snack('Reminder moved by 10 minutes');
  }

  // Change the time for today only
  Future<void> changeTime(Dose d) async {
    final t = await showTimePicker(context: context, initialTime: TimeOfDay.now());
    if (t == null) return;
    await Store.setEntry('over', d.key, hm(t));
    await load();
    snack("Today's time changed to ${hm(t)}");
  }

  Future<void> delete(Med m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove medicine?'),
        content: Text('${m.name} will be removed from the list.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Yes')),
        ],
      ),
    );
    if (ok != true) return;
    meds.removeWhere((e) => e.id == m.id);
    await Store.saveMeds(meds);
    await load();
  }

  // All doses scheduled for the given day, sorted by time
  List<Dose> todayDoses(DateTime now) {
    final list = <Dose>[];
    for (final m in meds.where((m) => m.activeOn(now))) {
      for (var i = 0; i < m.times.length; i++) {
        final key = '${m.id}|$i|${dk(now)}';
        list.add(Dose(m, key, over[key] ?? m.times[i], logs[key]));
      }
    }
    list.sort((a, b) => a.time.compareTo(b.time));
    return list;
  }

  // ---------- Tab 1: Today ----------
  Widget msg(String icon, String text, MaterialColor c) => box(
    color: c.shade50,
    border: c.shade200,
    pad: const EdgeInsets.all(12),
    child: Row(children: [
      Text(icon, style: const TextStyle(fontSize: 22)),
      const SizedBox(width: 10),
      Expanded(child: Text(text, style: TextStyle(color: c.shade900, fontWeight: FontWeight.w600))),
    ]),
  );

  Widget doseCard(Dose d, int nowMin) {
    final pending = d.status == null;
    final due = pending && mins(d.time) <= nowMin;

    return box(
      border: due ? Colors.red.shade200 : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          avatar(d.med),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(d.med.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 2),
              Text('${d.time}  •  ${d.med.afterFood ? "After food" : "Empty stomach"}',
                  style: TextStyle(color: due ? Colors.red.shade700 : Colors.black54)),
            ]),
          ),
          if (pending)
            IconButton(
              tooltip: "Change today's time",
              icon: const Icon(Icons.edit_calendar_outlined),
              onPressed: () => changeTime(d),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: d.status == 'taken' ? Colors.green.shade50 : Colors.red.shade50,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                d.status == 'taken' ? 'Taken ✅' : 'Skipped ❌',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: d.status == 'taken' ? Colors.green.shade800 : Colors.red.shade800,
                ),
              ),
            ),
        ]),
        if (pending) ...[
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: FilledButton(onPressed: () => setStatus(d, 'taken'), child: const Text('Taken ✅'))),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4)),
                onPressed: () => later(d),
                child: const Text('Later ⏰'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4)),
                onPressed: () => setStatus(d, 'skipped'),
                child: const Text('Skip ❌'),
              ),
            ),
          ]),
        ],
      ]),
    );
  }

  Widget todayTab() {
    final now = DateTime.now();
    final nowMin = now.hour * 60 + now.minute;
    final doses = todayDoses(now);
    final taken = doses.where((d) => d.status == 'taken').length;

    // In-app reminder messages (used instead of notifications)
    final msgs = <Widget>[];
    for (final d in doses.where((d) => d.status == null)) {
      final diff = mins(d.time) - nowMin;
      if (diff <= 0) {
        msgs.add(msg('💊', '${d.med.name} is due now (${d.time})', Colors.red));
      } else if (d.med.afterFood && diff <= 60) {
        msgs.add(msg('🍽️', 'Have your meal! ${d.med.name} is due in $diff minutes', Colors.orange));
      }
    }
    for (final m in meds.where((m) => m.activeOn(now) && m.stock <= 3)) {
      msgs.add(msg('⚠️', '${m.name} is running low: only ${m.stock} left', Colors.amber));
    }

    return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 100), children: [
      // Progress card
      Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [Color(0xFF00897B), Color(0xFF4DB6AC)]),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${now.day}/${now.month}/${now.year}', style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 4),
          const Text("Today's Progress",
              style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: doses.isEmpty ? 0 : taken / doses.length,
              minHeight: 10,
              backgroundColor: Colors.white24,
              valueColor: const AlwaysStoppedAnimation(Colors.white),
            ),
          ),
          const SizedBox(height: 8),
          Text('$taken / ${doses.length} doses taken', style: const TextStyle(color: Colors.white)),
        ]),
      ),
      if (msgs.isNotEmpty) ...[sectionTitle('Reminders'), ...msgs],
      sectionTitle("Today's Doses"),
      if (doses.isEmpty)
        box(
          child: const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: Text('No medicines for today.\nTap the button below to add one.', textAlign: TextAlign.center)),
          ),
        ),
      for (final d in doses) doseCard(d, nowMin),
    ]);
  }

  // ---------- Tab 2: Medicines ----------
  Widget medsTab() {
    if (meds.isEmpty) {
      return const Center(child: Text('No medicines yet.\nTap the button below to add one.', textAlign: TextAlign.center));
    }
    final today = DateTime.now();
    return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 100), children: [
      for (final m in meds)
        box(
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            avatar(m, r: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(m.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text('Stock: ${m.stock}',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: m.stock <= 3 ? Colors.red : Colors.black87,
                    )),
                Text(m.afterFood ? 'After food' : 'Empty stomach', style: const TextStyle(color: Colors.black54)),
                Text(
                  '${(DateTime(m.start.year, m.start.month, m.start.day + m.days).difference(DateTime(today.year, today.month, today.day)).inDays).clamp(0, 9999)} days left',
                  style: const TextStyle(color: Colors.black54),
                ),
                const SizedBox(height: 6),
                Wrap(spacing: 6, children: [
                  for (final t in m.times)
                    Chip(
                      label: Text(t),
                      visualDensity: VisualDensity.compact,
                      backgroundColor: Colors.teal.shade50,
                      side: BorderSide.none,
                    ),
                ]),
              ]),
            ),
            IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red), onPressed: () => delete(m)),
          ]),
        ),
    ]);
  }

  // ---------- Tab 3: History (last 14 days) ----------
  Widget historyTab() {
    final now = DateTime.now();
    final nowMin = now.hour * 60 + now.minute;
    final out = <Widget>[];

    for (var back = 0; back < 14; back++) {
      final day = DateTime(now.year, now.month, now.day - back);
      final items = <MapEntry<String, Widget>>[];

      for (final m in meds.where((m) => m.activeOn(day))) {
        for (var i = 0; i < m.times.length; i++) {
          final key = '${m.id}|$i|${dk(day)}';
          final t = over[key] ?? m.times[i];
          var s = logs[key];
          if (s == null) {
            if (back == 0 && mins(t) > nowMin) continue; // still upcoming today
            s = 'missed';
          }
          final ic = s == 'taken' ? Icons.check_circle : s == 'skipped' ? Icons.cancel : Icons.warning_amber_rounded;
          final c = s == 'taken' ? Colors.green : s == 'skipped' ? Colors.red : Colors.orange;
          final label = s == 'taken' ? 'Taken' : s == 'skipped' ? 'Skipped' : 'Missed';
          items.add(MapEntry(
            t,
            box(
              pad: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(children: [
                Icon(ic, color: c),
                const SizedBox(width: 12),
                Expanded(child: Text('$t  •  ${m.name}')),
                Text(label, style: TextStyle(color: c, fontWeight: FontWeight.bold)),
              ]),
            ),
          ));
        }
      }

      if (items.isEmpty) continue;
      items.sort((a, b) => a.key.compareTo(b.key));
      out.add(sectionTitle(back == 0 ? 'Today' : dk(day)));
      out.addAll(items.map((e) => e.value));
    }

    if (out.isEmpty) return const Center(child: Text('No history yet.'));
    return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: out);
  }

  @override
  Widget build(BuildContext context) {
    const titles = ["Today's Medicines", 'My Medicines', 'History'];
    return Scaffold(
      appBar: AppBar(
        title: Text(titles[tab], style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF004D40))),
        backgroundColor: bg,
        scrolledUnderElevation: 0,
      ),
      body: tab == 0 ? todayTab() : tab == 1 ? medsTab() : historyTab(),
      floatingActionButton: tab == 2
          ? null
          : FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Add Medicine'),
        onPressed: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => const AddPage()));
          load();
        },
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.today_outlined), selectedIcon: Icon(Icons.today), label: 'Today'),
          NavigationDestination(icon: Icon(Icons.medication_outlined), selectedIcon: Icon(Icons.medication), label: 'Medicines'),
          NavigationDestination(icon: Icon(Icons.history), label: 'History'),
        ],
      ),
    );
  }
}

// ---------------- Add Medicine ----------------
class AddPage extends StatefulWidget {
  const AddPage({super.key});
  @override
  State<AddPage> createState() => _AddPageState();
}

class _AddPageState extends State<AddPage> {
  final name = TextEditingController();
  final stock = TextEditingController();
  final days = TextEditingController(text: '7');
  final times = <String>[];
  bool afterFood = true;
  String photo = '';

  @override
  void dispose() {
    name.dispose();
    stock.dispose();
    days.dispose();
    super.dispose();
  }

  InputDecoration deco(String label, IconData icon) => InputDecoration(
    labelText: label,
    prefixIcon: Icon(icon),
    filled: true,
    fillColor: Colors.white,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
  );

  // Pick a photo and copy it into the app folder so it is not lost later
  Future<void> pick(ImageSource s) async {
    final x = await ImagePicker().pickImage(source: s, maxWidth: 800);
    if (x == null) return;
    final dir = await getApplicationDocumentsDirectory();
    final f = await File(x.path).copy('${dir.path}/${DateTime.now().millisecondsSinceEpoch}.jpg');
    setState(() => photo = f.path);
  }

  Future<void> save() async {
    if (name.text.trim().isEmpty || times.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Enter a name and at least one time')));
      return;
    }
    final meds = await Store.meds();
    final now = DateTime.now();
    meds.add(Med(
      id: (now.millisecondsSinceEpoch % 100000).toString(),
      name: name.text.trim(),
      photo: photo,
      stock: int.tryParse(stock.text) ?? 0,
      days: int.tryParse(days.text) ?? 7,
      start: DateTime(now.year, now.month, now.day),
      times: List<String>.from(times)..sort(),
      afterFood: afterFood,
    ));
    await Store.saveMeds(meds);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add Medicine', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF004D40))),
        backgroundColor: bg,
        scrolledUnderElevation: 0,
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Center(
          child: GestureDetector(
            onTap: () => showModalBottomSheet(
              context: context,
              builder: (ctx) => Column(mainAxisSize: MainAxisSize.min, children: [
                ListTile(
                  leading: const Icon(Icons.camera_alt),
                  title: const Text('Camera'),
                  onTap: () { Navigator.pop(ctx); pick(ImageSource.camera); },
                ),
                ListTile(
                  leading: const Icon(Icons.photo),
                  title: const Text('Gallery'),
                  onTap: () { Navigator.pop(ctx); pick(ImageSource.gallery); },
                ),
              ]),
            ),
            child: CircleAvatar(
              radius: 56,
              backgroundColor: Colors.teal.shade50,
              backgroundImage: photo.isEmpty ? null : FileImage(File(photo)),
              child: photo.isEmpty ? Icon(Icons.add_a_photo, size: 36, color: teal) : null,
            ),
          ),
        ),
        const SizedBox(height: 6),
        const Center(child: Text('Medicine photo', style: TextStyle(color: Colors.black54))),
        const SizedBox(height: 18),
        TextField(controller: name, decoration: deco('Medicine name', Icons.medication_outlined)),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: TextField(
              controller: stock,
              keyboardType: TextInputType.number,
              decoration: deco('Stock', Icons.inventory_2_outlined),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: days,
              keyboardType: TextInputType.number,
              decoration: deco('Days', Icons.date_range_outlined),
            ),
          ),
        ]),
        const SizedBox(height: 18),
        const Text('When to take it?', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Empty stomach')),
            ButtonSegment(value: true, label: Text('After food')),
          ],
          selected: {afterFood},
          onSelectionChanged: (s) => setState(() => afterFood = s.first),
        ),
        const SizedBox(height: 18),
        const Text('Times', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final t in times) Chip(label: Text(t), onDeleted: () => setState(() => times.remove(t))),
          ActionChip(
            avatar: const Icon(Icons.access_time, size: 18),
            label: const Text('Add time'),
            onPressed: () async {
              final t = await showTimePicker(context: context, initialTime: TimeOfDay.now());
              if (t != null && !times.contains(hm(t))) setState(() => times.add(hm(t)));
            },
          ),
        ]),
        const SizedBox(height: 28),
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          icon: const Icon(Icons.check),
          label: const Text('Save'),
          onPressed: save,
        ),
      ]),
    );
  }
}
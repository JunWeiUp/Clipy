import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'clipboard_manager.dart';
import 'sync_manager.dart';
import 'models.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SyncManager.instance.init();
  await ClipboardManager.instance.init();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Clipy Android',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  void initState() {
    super.initState();
    ClipboardManager.instance.onHistoryChanged = () {
      setState(() {});
    };
  }

  @override
  Widget build(BuildContext context) {
    final history = ClipboardManager.instance.history;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Clipy History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const SettingsPage()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => ClipboardManager.instance.clearHistory(),
          ),
        ],
      ),
      body: ListView.builder(
        itemCount: history.length,
        itemBuilder: (context, index) {
          final entry = history[index];
          return ListTile(
            title: Text(
              entry.item.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text('${entry.sourceApp ?? 'Unknown'} • ${entry.date.toString().split('.')[0]}'),
            onTap: () {
              ClipboardManager.instance.copyToClipboard(entry.item);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Copied to clipboard')),
              );
            },
          );
        },
      ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late TextEditingController _nameController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: SyncManager.instance.deviceName);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Enable LAN Sync'),
            subtitle: const Text('Sync clipboard with other devices on your local network'),
            value: SyncManager.instance.isSyncEnabled,
            onChanged: (value) {
              SyncManager.instance.setSyncEnabled(value);
              setState(() {});
            },
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Device Name',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (value) {
                SyncManager.instance.setDeviceName(value);
              },
            ),
          ),
          const ListTile(
            title: Text('About'),
            subtitle: Text('ClipyClone Android v1.0.0'),
          ),
        ],
      ),
    );
  }
}

import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.sizeBytes,
  });

  final String name;
  final String downloadUrl;
  final int sizeBytes;
}

class UpdateInfo {
  const UpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.tagName,
    required this.hasUpdate,
    required this.releaseNotes,
    required this.htmlUrl,
    required this.matchingAsset,
  });

  final String currentVersion;
  final String latestVersion;
  final String tagName;
  final bool hasUpdate;
  final String releaseNotes;
  final String htmlUrl;
  final ReleaseAsset? matchingAsset;
}

class UpdateChecker {
  static const String repoOwner = 'arunsasidharan84';
  static const String repoName = 'CCS_SleepStudio';

  /// Compares semantic versions (e.g. "1.11.1" vs "1.12.0").
  /// Returns 1 if v1 > v2, -1 if v1 < v2, 0 if equal.
  static int compareSemVer(String v1, String v2) {
    final cleanV1 = v1.replaceAll(RegExp(r'[^0-9.]'), '');
    final cleanV2 = v2.replaceAll(RegExp(r'[^0-9.]'), '');

    final parts1 = cleanV1.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final parts2 = cleanV2.split('.').map((e) => int.tryParse(e) ?? 0).toList();

    for (int i = 0; i < 3; i++) {
      final p1 = i < parts1.length ? parts1[i] : 0;
      final p2 = i < parts2.length ? parts2[i] : 0;
      if (p1 > p2) return 1;
      if (p1 < p2) return -1;
    }
    return 0;
  }

  /// Finds the best matching release asset for the current OS platform.
  static ReleaseAsset? findMatchingAsset(List<dynamic> assets) {
    for (final rawAsset in assets) {
      if (rawAsset is! Map<String, dynamic>) continue;
      final name = (rawAsset['name'] as String? ?? '').toLowerCase();
      final url = rawAsset['browser_download_url'] as String? ?? '';
      final size = (rawAsset['size'] as num?)?.toInt() ?? 0;

      if (url.isEmpty) continue;

      if (Platform.isMacOS) {
        if (name.endsWith('.zip') && (name.contains('macos') || name.contains('mac'))) {
          // Prefer full build over lite if both available
          if (!name.contains('lite')) {
            return ReleaseAsset(name: rawAsset['name'], downloadUrl: url, sizeBytes: size);
          }
        }
      } else if (Platform.isWindows) {
        if (name.endsWith('.exe') && name.contains('installer')) {
          if (!name.contains('lite')) {
            return ReleaseAsset(name: rawAsset['name'], downloadUrl: url, sizeBytes: size);
          }
        }
      } else if (Platform.isLinux) {
        if (name.endsWith('.deb') || name.endsWith('.rpm') || name.endsWith('.tar.gz')) {
          return ReleaseAsset(name: rawAsset['name'], downloadUrl: url, sizeBytes: size);
        }
      }
    }

    // Fallback: pick any matching OS keyword
    for (final rawAsset in assets) {
      if (rawAsset is! Map<String, dynamic>) continue;
      final name = (rawAsset['name'] as String? ?? '').toLowerCase();
      final url = rawAsset['browser_download_url'] as String? ?? '';
      final size = (rawAsset['size'] as num?)?.toInt() ?? 0;

      if (Platform.isMacOS && (name.endsWith('.zip') || name.endsWith('.dmg'))) {
        return ReleaseAsset(name: rawAsset['name'], downloadUrl: url, sizeBytes: size);
      }
      if (Platform.isWindows && name.endsWith('.exe')) {
        return ReleaseAsset(name: rawAsset['name'], downloadUrl: url, sizeBytes: size);
      }
      if (Platform.isLinux && (name.endsWith('.deb') || name.endsWith('.rpm'))) {
        return ReleaseAsset(name: rawAsset['name'], downloadUrl: url, sizeBytes: size);
      }
    }

    return null;
  }

  /// Checks GitHub API for the latest release.
  static Future<UpdateInfo> checkForUpdates() async {
    final packageInfo = await PackageInfo.fromPlatform();
    final currentVer = packageInfo.version;

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);

    try {
      final request = await client.getUrl(
        Uri.parse('https://api.github.com/repos/$repoOwner/$repoName/releases/latest'),
      );
      request.headers.set(HttpHeaders.userAgentHeader, 'CCS-SleepStudio-App');
      request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github.v3+json');

      final response = await request.close();
      if (response.statusCode != 200) {
        throw HttpException('GitHub release check returned HTTP ${response.statusCode}');
      }

      final responseBody = await response.transform(utf8.decoder).join();
      final json = jsonDecode(responseBody) as Map<String, dynamic>;

      final tagName = (json['tag_name'] as String? ?? '').trim();
      final latestVer = tagName.startsWith('v') ? tagName.substring(1) : tagName;
      final releaseNotes = json['body'] as String? ?? 'No release notes provided.';
      final htmlUrl = json['html_url'] as String? ?? '';
      final assets = json['assets'] as List<dynamic>? ?? [];

      final hasUpdate = compareSemVer(latestVer, currentVer) > 0;
      final matchingAsset = findMatchingAsset(assets);

      return UpdateInfo(
        currentVersion: currentVer,
        latestVersion: latestVer,
        tagName: tagName,
        hasUpdate: hasUpdate,
        releaseNotes: releaseNotes,
        htmlUrl: htmlUrl,
        matchingAsset: matchingAsset,
      );
    } finally {
      client.close();
    }
  }

  /// Downloads an update asset to a temporary directory with progress tracking.
  static Future<File> downloadAsset({
    required ReleaseAsset asset,
    required void Function(double progress, int receivedBytes, int totalBytes) onProgress,
  }) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 15);

    try {
      final request = await client.getUrl(Uri.parse(asset.downloadUrl));
      request.headers.set(HttpHeaders.userAgentHeader, 'CCS-SleepStudio-App');
      final response = await request.close();

      if (response.statusCode == 302 || response.statusCode == 301) {
        final redirectLoc = response.headers.value(HttpHeaders.locationHeader);
        if (redirectLoc != null) {
          final redirectReq = await client.getUrl(Uri.parse(redirectLoc));
          final redirectRes = await redirectReq.close();
          return await _saveDownloadStream(redirectRes, asset, onProgress);
        }
      }

      return await _saveDownloadStream(response, asset, onProgress);
    } finally {
      client.close();
    }
  }

  static Future<File> _saveDownloadStream(
    HttpClientResponse response,
    ReleaseAsset asset,
    void Function(double progress, int receivedBytes, int totalBytes) onProgress,
  ) async {
    final tempDir = Directory.systemTemp;
    final targetFile = File('${tempDir.path}${Platform.pathSeparator}${asset.name}');
    if (targetFile.existsSync()) {
      targetFile.deleteSync();
    }

    final totalBytes = response.contentLength > 0 ? response.contentLength : asset.sizeBytes;
    int receivedBytes = 0;
    final sink = targetFile.openWrite();

    await for (final chunk in response) {
      sink.add(chunk);
      receivedBytes += chunk.length;
      final progress = totalBytes > 0 ? (receivedBytes / totalBytes).clamp(0.0, 1.0) : 0.0;
      onProgress(progress, receivedBytes, totalBytes);
    }

    await sink.flush();
    await sink.close();
    return targetFile;
  }
}

/// Dialog to show update availability and perform in-app download and installation.
class AppUpdateDialog extends StatefulWidget {
  const AppUpdateDialog({
    super.key,
    required this.info,
  });

  final UpdateInfo info;

  @override
  State<AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<AppUpdateDialog> {
  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  String _statusMessage = '';
  File? _downloadedFile;

  Future<void> _startDownload() async {
    final asset = widget.info.matchingAsset;
    if (asset == null) {
      setState(() {
        _statusMessage = 'No matching installation package found for your operating system.';
      });
      return;
    }

    setState(() {
      _isDownloading = true;
      _statusMessage = 'Downloading ${asset.name}...';
      _downloadProgress = 0.0;
    });

    try {
      final file = await UpdateChecker.downloadAsset(
        asset: asset,
        onProgress: (prog, rec, tot) {
          setState(() {
            _downloadProgress = prog;
            final recMB = (rec / (1024 * 1024)).toStringAsFixed(1);
            final totMB = (tot / (1024 * 1024)).toStringAsFixed(1);
            _statusMessage = 'Downloading: $recMB MB / $totMB MB (${(prog * 100).toStringAsFixed(0)}%)';
          });
        },
      );

      setState(() {
        _isDownloading = false;
        _downloadedFile = file;
        _statusMessage = 'Download complete: ${file.path}';
      });

      _launchInstaller(file);
    } catch (e) {
      setState(() {
        _isDownloading = false;
        _statusMessage = 'Download failed: $e';
      });
    }
  }

  Future<void> _launchInstaller(File file) async {
    try {
      if (Platform.isWindows) {
        Process.start(file.path, [], mode: ProcessStartMode.detached);
        setState(() {
          _statusMessage = 'Installer launched. Please follow the setup wizard.';
        });
      } else if (Platform.isMacOS) {
        await _installMacOsUpdate(file);
      } else if (Platform.isLinux) {
        Process.run('xdg-open', [file.path]);
        setState(() {
          _statusMessage = 'Package opened with package manager.';
        });
      }
    } catch (e) {
      setState(() {
        _statusMessage = 'Error launching installer: $e';
      });
    }
  }

  String? _findCurrentMacAppBundle() {
    try {
      var dir = File(Platform.resolvedExecutable).parent;
      while (dir.path != dir.parent.path) {
        if (dir.path.endsWith('.app')) {
          return dir.path;
        }
        dir = dir.parent;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _installMacOsUpdate(File zipFile) async {
    final currentApp = _findCurrentMacAppBundle();
    if (currentApp == null) {
      // Running in development/debug mode outside an .app bundle; open Finder
      Process.run('open', ['-R', zipFile.path]);
      setState(() {
        _statusMessage = 'Downloaded archive opened in Finder (debug mode detected: replace app manually).';
      });
      return;
    }

    setState(() {
      _statusMessage = 'Extracting update package…';
    });

    final tempDir = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}ccs_update_${DateTime.now().millisecondsSinceEpoch}',
    );
    if (!tempDir.existsSync()) {
      tempDir.createSync(recursive: true);
    }

    try {
      // Extract with ditto to preserve permissions, symlinks, and code signatures
      var res = await Process.run('ditto', ['-x', '-k', zipFile.path, tempDir.path]);
      if (res.exitCode != 0) {
        // Fallback to unzip
        res = await Process.run('unzip', ['-q', '-o', zipFile.path, '-d', tempDir.path]);
      }

      // Find extracted .app bundle
      String? extractedApp;
      for (final entity in tempDir.listSync()) {
        if (entity is Directory && entity.path.endsWith('.app')) {
          extractedApp = entity.path;
          break;
        }
      }
      if (extractedApp == null) {
        for (final entity in tempDir.listSync(recursive: true)) {
          if (entity is Directory && entity.path.endsWith('.app')) {
            extractedApp = entity.path;
            break;
          }
        }
      }

      if (extractedApp == null) {
        Process.run('open', ['-R', zipFile.path]);
        setState(() {
          _statusMessage = 'Downloaded archive opened in Finder. Replace existing application to update.';
        });
        return;
      }

      setState(() {
        _statusMessage = 'Installing update and restarting application…';
      });

      // Write helper detached script to replace .app and relaunch
      final helperScript = File('${tempDir.path}${Platform.pathSeparator}update_in_place.sh');
      final scriptContent = '''#!/bin/bash
PID="\$1"
TARGET_APP="\$2"
NEW_APP="\$3"
CLEANUP_DIR="\$4"
ZIP_FILE="\$5"

# 1. Wait for current app PID to terminate
while kill -0 "\$PID" 2>/dev/null; do
  sleep 0.3
done
sleep 0.5

# 2. Clear quarantine attribute
xattr -rd com.apple.quarantine "\$NEW_APP" 2>/dev/null || true

# 3. Replace app bundle
rm -rf "\$TARGET_APP"
if cp -R "\$NEW_APP" "\$TARGET_APP"; then
  open -a "\$TARGET_APP" 2>/dev/null || open "\$TARGET_APP"
  rm -rf "\$CLEANUP_DIR"
  rm -f "\$ZIP_FILE"
else
  # Fallback to opening extracted app in Finder if permissions denied
  open -R "\$NEW_APP"
fi
''';
      await helperScript.writeAsString(scriptContent);
      await Process.run('chmod', ['+x', helperScript.path]);

      // Launch helper detached and exit cleanly
      await Process.start(
        '/bin/bash',
        [helperScript.path, pid.toString(), currentApp, extractedApp, tempDir.path, zipFile.path],
        mode: ProcessStartMode.detached,
      );

      await Future.delayed(const Duration(milliseconds: 600));
      exit(0);
    } catch (e) {
      Process.run('open', ['-R', zipFile.path]);
      setState(() {
        _statusMessage = 'Automatic update failed ($e). Archive opened in Finder.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    return AlertDialog(
      title: Row(
        children: [
          Icon(
            info.hasUpdate ? Icons.system_update : Icons.check_circle_outline,
            color: info.hasUpdate ? Colors.purple : Colors.green,
          ),
          const SizedBox(width: 8),
          Text(info.hasUpdate ? 'New Update Available!' : 'CCS Sleep Studio is Up to Date'),
        ],
      ),
      content: SizedBox(
        width: 580,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Current version: ${info.currentVersion}'),
            Text(
              'Latest release: ${info.latestVersion}',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: info.hasUpdate ? Colors.purple : Colors.black,
              ),
            ),
            const Divider(height: 24),
            if (info.hasUpdate) ...[
              const Text(
                'Release Notes:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Container(
                height: 160,
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    info.releaseNotes,
                    style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (_isDownloading) ...[
                LinearProgressIndicator(value: _downloadProgress > 0 ? _downloadProgress : null),
                const SizedBox(height: 8),
              ],
              if (_statusMessage.isNotEmpty)
                Text(
                  _statusMessage,
                  style: TextStyle(
                    fontSize: 12,
                    color: _statusMessage.contains('failed') || _statusMessage.contains('Error')
                        ? Colors.red
                        : Colors.green.shade800,
                  ),
                ),
            ] else ...[
              const Text('You are running the latest version of CCS Sleep Studio.'),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
        if (info.hasUpdate && !_isDownloading && _downloadedFile == null)
          ElevatedButton.icon(
            icon: const Icon(Icons.download),
            label: const Text('Download & Update'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.purple,
              foregroundColor: Colors.white,
            ),
            onPressed: info.matchingAsset != null ? _startDownload : null,
          ),
        if (_downloadedFile != null)
          ElevatedButton.icon(
            icon: const Icon(Icons.launch),
            label: const Text('Launch Installer Again'),
            onPressed: () => _launchInstaller(_downloadedFile!),
          ),
      ],
    );
  }
}

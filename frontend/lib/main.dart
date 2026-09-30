import 'dart:async';
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'src/app.dart';

void main() {
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      MediaKit.ensureInitialized();
      FilePicker.skipEntitlementsChecks();
      FlutterError.onError = FlutterError.presentError;
      PlatformDispatcher.instance.onError = (error, stack) {
        FlutterError.reportError(
          FlutterErrorDetails(exception: error, stack: stack),
        );
        return true;
      };
      ErrorWidget.builder = (details) => Material(
        color: const Color(0xFFF8F9FB),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 42, color: Colors.red),
                  const SizedBox(height: 16),
                  const Text(
                    'CCS Sleep Studio could not render this view',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'The application is still running. Close the current dialog '
                    'or reopen the recording. Technical details:',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                  SelectableText(
                    details.exceptionAsString(),
                    maxLines: 8,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      runApp(const CCSSleepStudioApp());
    },
    (error, stack) => FlutterError.reportError(
      FlutterErrorDetails(exception: error, stack: stack),
    ),
  );
}

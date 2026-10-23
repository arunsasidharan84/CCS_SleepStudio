import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ccs_sleep_studio/src/update_checker.dart';

void main() {
  testWidgets('ReleaseNotesMarkdownView renders headings, bullets, and math cleanly', (tester) async {
    const rawMarkdown = '''
### Key Highlights & Clinical Improvements

#### 1. Automated AASM Cardiac and Arrhythmia Event Analysis
- **AASM Scoring Manual Rules:** Direct clinical implementation of standard ECG guidelines.
- **Asystole:** Cardiac pause \$\\ge 3.0\\text{ s}\$ in adults.
- **Bradycardia:** Sustained heart rate \$< 40\\text{ bpm}\$.
''';

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ReleaseNotesMarkdownView(text: rawMarkdown),
          ),
        ),
      ),
    );

    // Verify headers rendered as Text without ### marks
    expect(find.text('Key Highlights & Clinical Improvements'), findsOneWidget);
    expect(find.text('1. Automated AASM Cardiac and Arrhythmia Event Analysis'), findsOneWidget);

    // Verify math cleaned up
    expect(find.textContaining('≥ 3.0 s'), findsOneWidget);
    expect(find.textContaining('< 40 bpm'), findsOneWidget);
  });
}

import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:mono_dash/presentation/common/components/frosted_action_button.dart';

void main() {
  testWidgets('frosted actions use premium adaptive glass', (tester) async {
    var tapped = false;

    await tester.pumpWidget(
      CupertinoApp(
        home: Center(
          child: FrostedActionButton(text: 'Save', onTap: () => tapped = true),
        ),
      ),
    );

    final glass = tester.widget<AdaptiveGlass>(find.byType(AdaptiveGlass));
    expect(glass.quality, GlassQuality.premium);

    await tester.tap(find.text('Save'));
    expect(tapped, isTrue);
  });
}

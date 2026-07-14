import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:mono_dash/core/widgets/app_toggle_switch.dart';
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

  testWidgets('app toggles use blue premium glass switches', (tester) async {
    var value = false;

    await tester.pumpWidget(
      CupertinoApp(
        home: Center(
          child: AppToggleSwitch(
            value: value,
            onChanged: (next) => value = next,
          ),
        ),
      ),
    );

    final glass = tester.widget<GlassSwitch>(find.byType(GlassSwitch));
    final context = tester.element(find.byType(GlassSwitch));
    expect(glass.activeColor, CupertinoColors.systemBlue.resolveFrom(context));
    expect(glass.useOwnLayer, isTrue);
    expect(glass.quality, GlassQuality.premium);

    await tester.tap(find.byType(GlassSwitch));
    expect(value, isTrue);
  });
}

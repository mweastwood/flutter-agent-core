@TestOn('chrome')
library;

import 'package:flutter_agent_core/flutter_agent_core_web.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';

class FakeRegistrar extends Registrar {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FlutterAgentCoreWeb Tests', () {
    test('instantiates FlutterAgentCoreWeb successfully', () {
      final instance = FlutterAgentCoreWeb();
      expect(instance, isNotNull);
      expect(instance, isA<FlutterAgentCoreWeb>());
    });

    test('registerWith completes normally with Registrar instance', () {
      final registrar = Registrar();
      expect(
        () => FlutterAgentCoreWeb.registerWith(registrar),
        returnsNormally,
      );
    });

    test('registerWith completes normally with FakeRegistrar subclass', () {
      final registrar = FakeRegistrar();
      expect(
        () => FlutterAgentCoreWeb.registerWith(registrar),
        returnsNormally,
      );
    });
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show Tooltip;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xterm/xterm.dart';

import '../../../../core/localization/l10n_x.dart';
import '../../../../core/localization/locale_controller.dart';
import '../../../../core/network/app_user_agent.dart';
import '../../../../core/network/web_socket_connector.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/storage/storage_service.dart';
import '../frosted_header.dart';
import '../frosted_overlay_menu.dart';
import '../../../features/server_detail/providers/active_server_provider.dart';

Future<void> showAppTerminal(
  BuildContext context, {
  required String containerId,
  String user = 'root',
  required String command,
  String source = 'container',
  String? databaseType,
  String? databaseName,
}) {
  final container = ProviderScope.containerOf(context);
  return Navigator.of(context).push(
    CupertinoPageRoute(
      builder: (context) => UncontrolledProviderScope(
        container: container,
        child: _AppTerminalScreen(
          containerId: containerId,
          user: user,
          command: command,
          source: source,
          databaseType: databaseType,
          databaseName: databaseName,
        ),
      ),
    ),
  );
}

class _AppTerminalScreen extends ConsumerStatefulWidget {
  const _AppTerminalScreen({
    required this.containerId,
    required this.user,
    required this.command,
    required this.source,
    this.databaseType,
    this.databaseName,
  });

  final String containerId;
  final String user;
  final String command;
  final String source;
  final String? databaseType;
  final String? databaseName;

  @override
  ConsumerState<_AppTerminalScreen> createState() => _AppTerminalScreenState();
}

class _AppTerminalScreenState extends ConsumerState<_AppTerminalScreen> {
  late final Terminal _terminal;
  final TerminalController _terminalController = TerminalController();
  final FocusNode _terminalFocusNode = FocusNode();
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  bool _isConnected = false;
  String _statusMessage = '';

  @override
  void initState() {
    super.initState();
    _terminal = Terminal(maxLines: 10000);
    _connect();
  }

  Future<void> _connect() async {
    final l10n = ref.read(appLocalizationsProvider);
    try {
      final serverId = ref.read(activeServerIdProvider);
      final storage = ref.read(storageServiceProvider);
      final server = await storage.getServer(serverId);
      final apiKey = await storage.getApiKey(serverId) ?? '';

      if (server == null) {
        if (!mounted) return;
        setState(() {
          _statusMessage = l10n.terminal_serverInfoFailed;
        });
        return;
      }

      final baseUrl = server.baseUrl.toString();
      final uri = Uri.parse(baseUrl);
      final wsScheme = uri.scheme == 'https' ? 'wss' : 'ws';

      final timestamp = (DateTime.now().millisecondsSinceEpoch ~/ 1000)
          .toString();
      final tokenRaw = '1panel$apiKey$timestamp';
      final token = md5.convert(utf8.encode(tokenRaw)).toString();
      final userAgent = await AppUserAgent.value;

      final isDatabase = widget.source == 'database';
      final isRedis =
          isDatabase && (widget.databaseType?.contains('redis') ?? false);
      final wsUrl = Uri(
        scheme: wsScheme,
        host: uri.host,
        port: uri.port,
        path: widget.source == 'host'
            ? '${uri.path}/api/v2/hosts/terminal'.replaceAll('//', '/')
            : '${uri.path}/api/v2/containers/exec'.replaceAll('//', '/'),
        queryParameters: {
          'cols': _terminal.viewWidth.toString(),
          'rows': _terminal.viewHeight.toString(),
          if (isRedis) ...{
            'source': 'redis',
            'name': widget.databaseName ?? '',
            'from': 'local',
          } else if (isDatabase) ...{
            'source': 'database',
            'databaseType': widget.databaseType ?? '',
            'database': widget.databaseName ?? '',
          } else ...{
            'source': widget.source,
            'containerid': widget.containerId,
            'user': widget.user,
            'command': widget.command,
          },
          'operateNode': 'local',
        },
      );

      _channel = connectAppWebSocket(
        wsUrl,
        headers: {
          '1Panel-Token': token,
          '1Panel-Timestamp': timestamp,
          HttpHeaders.userAgentHeader: userAgent,
        },
        allowInsecureConnections: server.allowInsecureConnections,
      );

      _subscription = _channel!.stream.listen(
        (data) {
          if (!_isConnected) {
            if (!mounted) return;
            setState(() {
              _isConnected = true;
              _statusMessage = '';
            });
          }

          try {
            final Map<String, dynamic> msg = jsonDecode(data.toString());
            final type = msg['type'];
            final payload = msg['data'];

            if (type == 'cmd' && payload is String) {
              final decoded = utf8.decode(
                base64Decode(payload),
                allowMalformed: true,
              );
              _terminal.write(decoded);
            }
          } catch (e) {
            // If not JSON or other error, fallback to raw write if it's a string
            if (data is String) {
              _terminal.write(data);
            }
          }
        },
        onError: (e) {
          _terminal.write(
            '\r\n${l10n.terminal_connectionErrorWithDetail('$e')}\r\n',
          );
          if (!mounted) return;
          setState(() {
            _isConnected = false;
            _statusMessage = l10n.terminal_connectionError;
          });
        },
        onDone: () {
          _terminal.write('\r\n${l10n.terminal_disconnectedOutput}\r\n');
          if (!mounted) return;
          setState(() {
            _isConnected = false;
            _statusMessage = l10n.terminal_disconnected;
          });
        },
      );

      _terminal.onOutput = (data) {
        if (_isConnected) {
          final payload = jsonEncode({
            'type': 'cmd',
            'data': base64Encode(utf8.encode(data)),
          });
          _channel?.sink.add(payload);
        }
      };

      _terminal.onResize = (w, h, pw, ph) {
        if (_isConnected) {
          final payload = jsonEncode({'type': 'resize', 'cols': w, 'rows': h});
          _channel?.sink.add(payload);
        }
      };
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusMessage = l10n.terminal_initializationFailed('$e');
      });
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _channel?.sink.close();
    _terminalController.dispose();
    _terminalFocusNode.dispose();
    super.dispose();
  }

  Future<void> _copySelectionOrAll() async {
    final selection = _terminalController.selection;
    final text = selection != null
        ? _terminal.buffer.getText(selection)
        : _terminal.buffer.getText();
    await Clipboard.setData(ClipboardData(text: text));
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    _terminal.paste(text);
  }

  void _sendTerminalKey(
    TerminalKey key, {
    bool ctrl = false,
    bool alt = false,
    bool shift = false,
  }) {
    _terminalFocusNode.requestFocus();
    _terminal.keyInput(key, ctrl: ctrl, alt: alt, shift: shift);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;

    // 明亮模式下终端配色
    final brightTheme = TerminalTheme(
      cursor: const Color(0xFF000000),
      selection: const Color(0x44000000),
      foreground: const Color(0xFF000000),
      background: AppColors.background(context),
      black: const Color(0xFF000000),
      red: const Color(0xFFCD3131),
      green: const Color(0xFF0DBC79),
      yellow: const Color(0xFF949400),
      blue: const Color(0xFF0451A5),
      magenta: const Color(0xFFBC05BC),
      cyan: const Color(0xFF0598BC),
      white: const Color(0xFF555555),
      brightBlack: const Color(0xFF666666),
      brightRed: const Color(0xFFCD3131),
      brightGreen: const Color(0xFF14CE14),
      brightYellow: const Color(0xFFB5BA00),
      brightBlue: const Color(0xFF0451A5),
      brightMagenta: const Color(0xFFBC05BC),
      brightCyan: const Color(0xFF0598BC),
      brightWhite: const Color(0xFFA5A5A5),
      searchHitBackground: const Color(0xFFFFFF00),
      searchHitBackgroundCurrent: const Color(0xFFFF9600),
      searchHitForeground: const Color(0xFF000000),
    );

    return CupertinoPageScaffold(
      backgroundColor: AppColors.background(context),
      child: Stack(
        children: [
          Padding(
            padding: EdgeInsets.only(
              top:
                  MediaQuery.paddingOf(context).top +
                  FrostedHeader.headerHeight,
            ),
            child: Column(
              children: [
                if (!_isConnected && _statusMessage.isNotEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    color: CupertinoColors.systemRed.withValues(alpha: 0.2),
                    child: Text(
                      _statusMessage,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: CupertinoColors.systemRed,
                        fontSize: 13,
                      ),
                    ),
                  ),
                Expanded(
                  child: SafeArea(
                    top: false,
                    bottom: false,
                    child: MediaQuery.removePadding(
                      context: context,
                      removeTop: true,
                      child: TerminalView(
                        _terminal,
                        controller: _terminalController,
                        focusNode: _terminalFocusNode,
                        textStyle: const TerminalStyle(
                          fontSize: 14,
                          fontFamily: 'Menlo',
                        ),
                        deleteDetection: true,
                        theme: isDark
                            ? TerminalThemes.defaultTheme
                            : brightTheme,
                      ),
                    ),
                  ),
                ),
                _TerminalShortcutToolbar(
                  enabled: _isConnected,
                  onKey: _sendTerminalKey,
                  onPaste: _pasteFromClipboard,
                ),
              ],
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: FrostedHeader(
              title: widget.source == 'host'
                  ? context.l10n.terminal_hostTitle
                  : widget.source == 'database'
                  ? context.l10n.terminal_databaseTitle(
                      widget.databaseName ?? '',
                    )
                  : context.l10n.terminal_containerTitle(widget.containerId),
              onBack: () => Navigator.of(context).maybePop(),
              trailingBuilder: (isDark, isOverlapping) =>
                  FrostedOverlayMenuButton(
                    label: _isConnected
                        ? context.l10n.common_menu
                        : context.l10n.terminal_connecting,
                    isDark: isDark,
                    isOverlapping: isOverlapping,
                    items: [
                      FrostedMenuItem(
                        text: context.l10n.terminal_copySelection,
                        icon: CupertinoIcons.doc_on_doc,
                        action: _copySelectionOrAll,
                      ),
                      FrostedMenuItem(
                        text: context.l10n.terminal_pasteToTerminal,
                        icon: CupertinoIcons.doc_on_clipboard,
                        action: _pasteFromClipboard,
                      ),
                    ],
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TerminalShortcutToolbar extends StatelessWidget {
  const _TerminalShortcutToolbar({
    required this.enabled,
    required this.onKey,
    required this.onPaste,
  });

  final bool enabled;
  final void Function(TerminalKey key, {bool ctrl, bool alt, bool shift}) onKey;
  final VoidCallback onPaste;

  @override
  Widget build(BuildContext context) {
    final isDark = CupertinoTheme.brightnessOf(context) == Brightness.dark;
    final borderColor = isDark
        ? CupertinoColors.white.withValues(alpha: 0.12)
        : CupertinoColors.black.withValues(alpha: 0.08);
    final backgroundColor = AppColors.secondaryBackground(
      context,
    ).withValues(alpha: isDark ? 0.78 : 0.9);

    return SafeArea(
      top: false,
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: backgroundColor,
          border: Border(top: BorderSide(color: borderColor, width: 0.5)),
        ),
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          children: [
            _TerminalShortcutButton.text(
              label: 'Esc',
              enabled: enabled,
              onPressed: () => onKey(TerminalKey.escape),
            ),
            _TerminalShortcutButton.text(
              label: 'Tab',
              enabled: enabled,
              onPressed: () => onKey(TerminalKey.tab),
            ),
            _TerminalShortcutButton.text(
              label: 'Ctrl+C',
              enabled: enabled,
              onPressed: () => onKey(TerminalKey.keyC, ctrl: true),
            ),
            _TerminalShortcutButton.text(
              label: 'Ctrl+D',
              enabled: enabled,
              onPressed: () => onKey(TerminalKey.keyD, ctrl: true),
            ),
            _TerminalShortcutButton.text(
              label: 'Ctrl+L',
              enabled: enabled,
              onPressed: () => onKey(TerminalKey.keyL, ctrl: true),
            ),
            _TerminalShortcutButton.icon(
              icon: CupertinoIcons.arrow_left,
              tooltip: 'Left',
              enabled: enabled,
              onPressed: () => onKey(TerminalKey.arrowLeft),
            ),
            _TerminalShortcutButton.icon(
              icon: CupertinoIcons.arrow_down,
              tooltip: 'Down',
              enabled: enabled,
              onPressed: () => onKey(TerminalKey.arrowDown),
            ),
            _TerminalShortcutButton.icon(
              icon: CupertinoIcons.arrow_up,
              tooltip: 'Up',
              enabled: enabled,
              onPressed: () => onKey(TerminalKey.arrowUp),
            ),
            _TerminalShortcutButton.icon(
              icon: CupertinoIcons.arrow_right,
              tooltip: 'Right',
              enabled: enabled,
              onPressed: () => onKey(TerminalKey.arrowRight),
            ),
            _TerminalShortcutButton.text(
              label: 'Home',
              enabled: enabled,
              onPressed: () => onKey(TerminalKey.home),
            ),
            _TerminalShortcutButton.text(
              label: 'End',
              enabled: enabled,
              onPressed: () => onKey(TerminalKey.end),
            ),
            _TerminalShortcutButton.text(
              label: 'Del',
              enabled: enabled,
              onPressed: () => onKey(TerminalKey.delete),
            ),
            _TerminalShortcutButton.icon(
              icon: CupertinoIcons.doc_on_clipboard,
              tooltip: context.l10n.terminal_pasteToTerminal,
              enabled: enabled,
              onPressed: onPaste,
            ),
          ],
        ),
      ),
    );
  }
}

class _TerminalShortcutButton extends StatelessWidget {
  const _TerminalShortcutButton.text({
    required String label,
    required bool enabled,
    required VoidCallback onPressed,
  }) : this._(
         label: label,
         tooltip: label,
         enabled: enabled,
         onPressed: onPressed,
       );

  const _TerminalShortcutButton.icon({
    required IconData icon,
    required String tooltip,
    required bool enabled,
    required VoidCallback onPressed,
  }) : this._(
         icon: icon,
         tooltip: tooltip,
         enabled: enabled,
         onPressed: onPressed,
       );

  const _TerminalShortcutButton._({
    this.label,
    this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onPressed,
  });

  final String? label;
  final IconData? icon;
  final String tooltip;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final foregroundColor = enabled
        ? AppColors.label(context)
        : AppColors.tertiaryLabel(context);
    final backgroundColor = AppColors.tertiaryBackground(
      context,
    ).withValues(alpha: enabled ? 0.88 : 0.45);

    final child = CupertinoButton(
      padding: EdgeInsets.zero,
      minimumSize: label == null ? const Size(36, 36) : const Size(0, 36),
      borderRadius: BorderRadius.circular(8),
      color: backgroundColor,
      disabledColor: backgroundColor,
      onPressed: enabled ? onPressed : null,
      child: SizedBox(
        height: 36,
        width: label == null ? 36 : null,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: label == null ? 0 : 12),
          child: Center(
            child: icon == null
                ? Text(
                    label!,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0,
                      color: foregroundColor,
                    ),
                  )
                : Icon(icon, size: 17, color: foregroundColor),
          ),
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Tooltip(message: tooltip, child: child),
    );
  }
}

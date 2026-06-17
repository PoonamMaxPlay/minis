import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Native emoji keyboard PlatformView host. Replaces `emoji_picker_flutter`.
///
/// The Android factory is registered for viewType `loopit/minis/emoji_picker`
/// in [LoopitMinisPlugin]. The iOS factory matches. Selection events are
/// pushed on the `loopit/minis/emoji_picker/selected` MethodChannel as
/// `emit({codePoint: int})`.
class MinisEmojiPicker extends StatefulWidget {
  const MinisEmojiPicker({super.key, required this.onSelected});

  final ValueChanged<int> onSelected;

  @override
  State<MinisEmojiPicker> createState() => _MinisEmojiPickerState();
}

class _MinisEmojiPickerState extends State<MinisEmojiPicker> {
  static const _viewType = 'loopit/minis/emoji_picker';
  static const _channel = MethodChannel('loopit/minis/emoji_picker/selected');

  @override
  void initState() {
    super.initState();
    _channel.setMethodCallHandler(_onMethod);
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    super.dispose();
  }

  Future<dynamic> _onMethod(MethodCall call) async {
    if (call.method == 'emit') {
      final args = call.arguments;
      if (args is Map) {
        final cp = (args['codePoint'] as num?)?.toInt();
        if (cp != null) widget.onSelected(cp);
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform == TargetPlatform.android) {
      return const AndroidView(viewType: _viewType);
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return const UiKitView(viewType: _viewType);
    }
    return const SizedBox.shrink();
  }
}

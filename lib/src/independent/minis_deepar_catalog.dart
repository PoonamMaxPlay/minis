/// Catalog of bundled DeepAR effects. Each entry points at a `.deepar` asset
/// (with this package as the owner). Folder names are snake_case slugs; the
/// `.deepar` filename inside each folder is preserved from the source pack and
/// is NOT always the same as the slug — keep [assetPath] authoritative.
class DeepArFilter {
  const DeepArFilter({
    required this.id,
    required this.name,
    required this.assetPath,
    this.remoteUrl,
  });

  /// Stable identifier (== folder slug).
  final String id;

  /// Human-readable name shown in the picker.
  final String name;

  /// Flutter asset key for the `.deepar` file. Already includes the package
  /// prefix so it resolves whether the caller is the example app or the
  /// host app.
  final String assetPath;

  /// Optional remote URL — kept null today; reserved for hosting effects
  /// off-device later via `DeepArControllerPlus.switchFilter(url)`.
  final String? remoteUrl;
}

const String _pkg = 'packages/loopit_minis';
const String _root = '$_pkg/lib/assets/deepar_filters';

/// All 17 free DeepAR filters bundled with this package. Order matches the
/// picker display order (alphabetical by display name).
const List<DeepArFilter> kDeepArFilters = <DeepArFilter>[
  DeepArFilter(
    id: 'burning_effect',
    name: 'Burning Effect',
    assetPath: '$_root/burning_effect/burning_effect.deepar',
  ),
  DeepArFilter(
    id: 'devil_neon_horns',
    name: 'Devil Neon Horns',
    assetPath: '$_root/devil_neon_horns/Neon_Devil_Horns.deepar',
  ),
  DeepArFilter(
    id: 'elephant_trunk',
    name: 'Elephant Trunk',
    assetPath: '$_root/elephant_trunk/Elephant_Trunk.deepar',
  ),
  DeepArFilter(
    id: 'emotion_meter',
    name: 'Emotion Meter',
    assetPath: '$_root/emotion_meter/Emotion_Meter.deepar',
  ),
  DeepArFilter(
    id: 'emotions_exaggerator',
    name: 'Emotions Exaggerator',
    assetPath: '$_root/emotions_exaggerator/Emotions_Exaggerator.deepar',
  ),
  DeepArFilter(
    id: 'fire_effect',
    name: 'Fire Effect',
    assetPath: '$_root/fire_effect/Fire_Effect.deepar',
  ),
  DeepArFilter(
    id: 'flower_face',
    name: 'Flower Face',
    assetPath: '$_root/flower_face/flower_face.deepar',
  ),
  DeepArFilter(
    id: 'galaxy_background',
    name: 'Galaxy Background',
    assetPath: '$_root/galaxy_background/galaxy_background.deepar',
  ),
  DeepArFilter(
    id: 'hope',
    name: 'Hope',
    assetPath: '$_root/hope/Hope.deepar',
  ),
  DeepArFilter(
    id: 'humanoid',
    name: 'Humanoid',
    assetPath: '$_root/humanoid/Humanoid.deepar',
  ),
  DeepArFilter(
    id: 'makeup_look_simple',
    name: 'Makeup Look',
    assetPath: '$_root/makeup_look_simple/MakeupLook.deepar',
  ),
  DeepArFilter(
    id: 'makeup_look_split_screen',
    name: 'Makeup Split Screen',
    assetPath: '$_root/makeup_look_split_screen/Split_View_Look.deepar',
  ),
  DeepArFilter(
    id: 'ping_pong_minigame',
    name: 'Ping Pong',
    assetPath: '$_root/ping_pong_minigame/Ping_Pong.deepar',
  ),
  DeepArFilter(
    id: 'pixel_heart_particles',
    name: 'Pixel Hearts',
    assetPath: '$_root/pixel_heart_particles/8bitHearts.deepar',
  ),
  DeepArFilter(
    id: 'snail',
    name: 'Snail',
    assetPath: '$_root/snail/Snail.deepar',
  ),
  DeepArFilter(
    id: 'stallone',
    name: 'Stallone',
    assetPath: '$_root/stallone/Stallone.deepar',
  ),
  DeepArFilter(
    id: 'vendetta_mask',
    name: 'Vendetta Mask',
    assetPath: '$_root/vendetta_mask/Vendetta_Mask.deepar',
  ),
  DeepArFilter(
    id: 'viking_helmet_pbr',
    name: 'Viking Helmet',
    assetPath: '$_root/viking_helmet_pbr/viking_helmet.deepar',
  ),
];

import 'dart:async';
import 'dart:math' as math;

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/slideshow_config.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/models/cast/cast_manager_state.dart';
import 'package:immich_mobile/presentation/pages/drift_slideshow.page.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/services/gcast.service.dart';

class _StubAssetService implements AssetService {
  const _StubAssetService();

  @override
  Future<BaseAsset?> getAsset(BaseAsset asset) async => asset;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubGCastService implements GCastService {
  @override
  void Function(bool)? onConnectionState;

  @override
  void Function(Duration)? onCurrentTime;

  @override
  void Function(Duration)? onDuration;

  @override
  void Function(String)? onReceiverName;

  @override
  void Function(CastState)? onCastState;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeVideoPlayerNotifier extends VideoPlayerNotifier {
  _FakeVideoPlayerNotifier(VideoPlayerState initial) {
    state = initial;
    latest = this;
  }

  // the provider is autoDispose: page churn disposes and recreates it, so the
  // override hands out a fresh notifier each time and this tracks the live one
  static _FakeVideoPlayerNotifier? latest;

  int restartCalls = 0;

  // the real restart() no-ops without a controller (seekTo early-returns); this
  // mirrors what it does with one attached: a synchronous reset then playing
  @override
  Future<void> restart() async {
    restartCalls++;
    state = state.copyWith(position: Duration.zero, status: VideoPlaybackStatus.playing);
  }

  void emit(VideoPlayerState next) => state = next;
}

class _ShuffleStubTimelineService extends TimelineService {
  _ShuffleStubTimelineService(super.query, this._randomAsset);

  BaseAsset _randomAsset;

  @override
  BaseAsset getRandomAsset() => _randomAsset;

  void shuffleTo(BaseAsset asset) => _randomAsset = asset;
}

class _SeededAssetViewerNotifier extends AssetViewerStateNotifier {
  _SeededAssetViewerNotifier(this._asset);

  final BaseAsset _asset;

  @override
  AssetViewerState build() {
    super.build();
    return AssetViewerState(currentAsset: _asset);
  }
}

class _CountingTimelineService extends TimelineService {
  _CountingTimelineService(super.query);

  int safeReads = 0;

  @override
  BaseAsset? getAssetSafe(int index) {
    safeReads++;
    return super.getAssetSafe(index);
  }
}

final _image1 = LocalAsset(
  id: 'image1',
  name: 'image1.jpg',
  type: AssetType.image,
  createdAt: DateTime(2025),
  updatedAt: DateTime(2025, 2),
  playbackStyle: AssetPlaybackStyle.image,
  isEdited: false,
);

final _video = LocalAsset(
  id: 'video1',
  name: 'video1.mp4',
  type: AssetType.video,
  createdAt: DateTime(2025, 3),
  updatedAt: DateTime(2025, 4),
  playbackStyle: AssetPlaybackStyle.video,
  durationMs: 30000,
  width: 1920,
  height: 1080,
  isEdited: false,
);

final _image2 = LocalAsset(
  id: 'image2',
  name: 'image2.jpg',
  type: AssetType.image,
  createdAt: DateTime(2025, 5),
  updatedAt: DateTime(2025, 6),
  playbackStyle: AssetPlaybackStyle.image,
  isEdited: false,
);

const _videoDuration = Duration(seconds: 30);
const _playing = VideoPlayerState(
  position: Duration.zero,
  duration: _videoDuration,
  status: VideoPlaybackStatus.playing,
);
const _buffering = VideoPlayerState(
  position: Duration.zero,
  duration: _videoDuration,
  status: VideoPlaybackStatus.buffering,
);

TimelineService _timeline(List<BaseAsset> assets) => TimelineService((
  assetSource: (index, count) async => assets.sublist(index, math.min(index + count, assets.length)),
  bucketSource: () => Stream.value([Bucket(assetCount: assets.length)]),
  origin: TimelineOrigin.main,
));

void _mockWakelock(TestDefaultBinaryMessenger messenger) {
  const codec = StandardMessageCodec();
  messenger.setMockMessageHandler(
    'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
    (message) async => codec.encodeMessage([null]),
  );
}

double? _currentPage(WidgetTester tester) => tester.widget<PageView>(find.byType(PageView)).controller?.page;

final _swallowedErrors = <Object>[];

bool _isExpectedImageError(Object error) =>
    error.toString().contains('Null check operator used on a null value') ||
    (error is PlatformException && error.toString().contains('ImageApi'));

// Image providers cannot resolve in the test environment (no platform channels,
// no HTTP). Only their known failures may be drained; anything else fails loudly.
void _drainImageErrors(WidgetTester tester) {
  for (var i = 0; i < 200; i++) {
    final error = tester.takeException();
    if (error == null) {
      return;
    }
    if (!_isExpectedImageError(error)) {
      fail('unexpected framework exception: $error');
    }
    _swallowedErrors.add(error);
  }
}

Future<void> _elapse(WidgetTester tester, Duration duration) async {
  await tester.pump(duration);
  await tester.pump();
  _drainImageErrors(tester);
}

Future<ProviderContainer> _pumpSlideshow(
  WidgetTester tester, {
  required List<BaseAsset> assets,
  VideoPlayerState? initialPlayerState,
  AppConfig config = const AppConfig(),
  TimelineService? timeline,
  BaseAsset? startAsset,
}) async {
  final effectiveTimeline = timeline ?? _timeline(assets);

  // the bucket stream delivers on the fake-async timer queue, so pump until the
  // initial asset batch has loaded before the page reads totalAssets
  var attempts = 0;
  while (effectiveTimeline.totalAssets != assets.length && attempts < 20) {
    attempts++;
    await tester.pump();
  }
  if (effectiveTimeline.totalAssets != assets.length) {
    fail('timeline did not load: totalAssets=${effectiveTimeline.totalAssets}');
  }

  final container = ProviderContainer(
    overrides: [
      appConfigProvider.overrideWithValue(config),
      assetServiceProvider.overrideWithValue(const _StubAssetService()),
      gCastServiceProvider.overrideWithValue(_StubGCastService()),
      if (startAsset != null) assetViewerProvider.overrideWith(() => _SeededAssetViewerNotifier(startAsset)),
      if (initialPlayerState != null)
        videoPlayerProvider.overrideWith((_, _) => _FakeVideoPlayerNotifier(initialPlayerState)),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));

  await tester.pumpWidget(
    EasyLocalization(
      supportedLocales: locales.values.toList(),
      path: translationsPath,
      startLocale: locales.values.first,
      fallbackLocale: locales.values.first,
      saveLocale: false,
      useFallbackTranslations: true,
      assetLoader: const CodegenLoader(),
      child: UncontrolledProviderScope(
        container: container,
        child: Builder(
          builder: (context) => MaterialApp(
            debugShowCheckedModeBanner: false,
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            home: DriftSlideshowPage(timeline: effectiveTimeline),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  _drainImageErrors(tester);
  return container;
}

Future<void> _advanceToVideoSlide(WidgetTester tester) async {
  // first slide is an image shown for the configured 5 seconds
  await _elapse(tester, const Duration(seconds: 6));
  expect(_currentPage(tester), 1.0, reason: 'the slideshow should have advanced onto the video slide');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    _mockWakelock(messenger);
    // the binding never answers SystemChrome.setEnabledSystemUIMode, without
    // this the slideshow's app bar toggle hangs and its buttons stay untappable
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    _swallowedErrors.clear();
  });

  tearDown(() {
    messenger.setMockMessageHandler('dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle', null);
  });

  testWidgets('a video that never becomes ready does not block the slideshow', (tester) async {
    // no player override: the source cannot be created in this environment, so
    // the video stays at the default (never ready) state forever
    await _pumpSlideshow(tester, assets: [_image1, _video, _image2]);
    await _advanceToVideoSlide(tester);

    await _elapse(tester, const Duration(seconds: 6));

    expect(_currentPage(tester), 2.0, reason: 'a video that never becomes ready must not block advancing');
  });

  testWidgets('a video stuck buffering at the start does not block the slideshow', (tester) async {
    await _pumpSlideshow(tester, assets: [_image1, _video, _image2], initialPlayerState: _buffering);
    await _advanceToVideoSlide(tester);

    await _elapse(tester, const Duration(seconds: 6));

    expect(_currentPage(tester), 2.0, reason: 'a video stuck buffering must not block advancing');
  });

  testWidgets('a never-ready video as the first slide advances after one slide duration', (tester) async {
    await _pumpSlideshow(tester, assets: [_video, _image1], initialPlayerState: _buffering);
    expect(_currentPage(tester), 0.0);

    await _elapse(tester, const Duration(seconds: 6));

    expect(_currentPage(tester), 1.0, reason: 'a video first slide that never becomes ready must not block advancing');
  });

  testWidgets('a slow starting video that succeeds within one duration is not skipped', (tester) async {
    await _pumpSlideshow(tester, assets: [_image1, _video, _image2], initialPlayerState: _buffering);
    await _advanceToVideoSlide(tester);

    // the video buffers for 3s of the 5s bound, then starts making progress
    await _elapse(tester, const Duration(seconds: 3));
    for (var position = 1; position <= 5; position++) {
      _FakeVideoPlayerNotifier.latest!.emit(
        VideoPlayerState(
          position: Duration(seconds: position),
          duration: _videoDuration,
          status: VideoPlaybackStatus.playing,
        ),
      );
      await _elapse(tester, const Duration(seconds: 1));
      expect(_currentPage(tester), 1.0, reason: 'a video that started playing at ${position}s must not be skipped');
    }
  });

  testWidgets('a video that stalls mid-playback does not block the slideshow', (tester) async {
    await _pumpSlideshow(
      tester,
      assets: [_image1, _video, _image2],
      initialPlayerState: const VideoPlayerState(
        position: Duration(seconds: 5),
        duration: _videoDuration,
        status: VideoPlaybackStatus.playing,
      ),
    );
    await _advanceToVideoSlide(tester);

    await _elapse(tester, const Duration(seconds: 6));

    expect(_currentPage(tester), 2.0, reason: 'a video stalled mid-playback must not block advancing');
  });

  testWidgets('the no-progress bound counts from the last progress, not from the slide start', (tester) async {
    await _pumpSlideshow(tester, assets: [_image1, _video, _image2], initialPlayerState: _playing);
    await _advanceToVideoSlide(tester);

    // progress at 2s and 4s of playback, then the position freezes for good
    for (final position in [2, 4]) {
      _FakeVideoPlayerNotifier.latest!.emit(
        VideoPlayerState(
          position: Duration(seconds: position),
          duration: _videoDuration,
          status: VideoPlaybackStatus.playing,
        ),
      );
      await _elapse(tester, const Duration(seconds: 2));
    }

    await _elapse(tester, const Duration(seconds: 4));
    expect(_currentPage(tester), 1.0, reason: 'one bound of no progress has not passed yet');

    await _elapse(tester, const Duration(seconds: 3));
    expect(_currentPage(tester), 2.0, reason: 'a full bound after the last progress must advance');
  });

  testWidgets('a video that keeps making progress is never skipped', (tester) async {
    await _pumpSlideshow(tester, assets: [_image1, _video, _image2], initialPlayerState: _playing);
    await _advanceToVideoSlide(tester);

    for (var position = 2; position <= 16; position += 2) {
      _FakeVideoPlayerNotifier.latest!.emit(
        VideoPlayerState(
          position: Duration(seconds: position),
          duration: _videoDuration,
          status: VideoPlaybackStatus.playing,
        ),
      );
      await _elapse(tester, const Duration(seconds: 2));
      expect(_currentPage(tester), 1.0, reason: 'a video at ${position}s is still playing and must not be skipped');
    }
  });

  testWidgets('a completed video advances the slideshow exactly once', (tester) async {
    await _pumpSlideshow(tester, assets: [_image1, _video, _image2], initialPlayerState: _playing);
    await _advanceToVideoSlide(tester);

    _FakeVideoPlayerNotifier.latest!.emit(
      const VideoPlayerState(position: _videoDuration, duration: _videoDuration, status: VideoPlaybackStatus.completed),
    );
    await _elapse(tester, const Duration(seconds: 2));

    expect(_currentPage(tester), 2.0, reason: 'a completed video must advance to the next slide, not past it');
  });

  testWidgets('a backgrounded app is not treated as a stall', (tester) async {
    addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));

    await _pumpSlideshow(tester, assets: [_image1, _video, _image2], initialPlayerState: _buffering);
    await _advanceToVideoSlide(tester);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await _elapse(tester, const Duration(seconds: 12));
    expect(_currentPage(tester), 1.0, reason: 'no advance while the app is backgrounded');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _elapse(tester, const Duration(seconds: 6));
    expect(_currentPage(tester), 2.0, reason: 'the bound applies again once the app is back');
  });

  testWidgets('a slide duration change re-arms the video wait', (tester) async {
    final container = await _pumpSlideshow(tester, assets: [_image1, _video, _image2], initialPlayerState: _buffering);
    await _advanceToVideoSlide(tester);

    container.updateOverrides([
      appConfigProvider.overrideWithValue(const AppConfig(slideshow: SlideshowConfig(duration: 20))),
      assetServiceProvider.overrideWithValue(const _StubAssetService()),
      gCastServiceProvider.overrideWithValue(_StubGCastService()),
      videoPlayerProvider.overrideWith((_, _) => _FakeVideoPlayerNotifier(_buffering)),
    ]);
    await _elapse(tester, const Duration(seconds: 1));

    await _elapse(tester, const Duration(seconds: 5));
    expect(_currentPage(tester), 1.0, reason: 'the old 5s bound must not fire after the re-arm');

    await _elapse(tester, const Duration(seconds: 16));
    expect(_currentPage(tester), 2.0, reason: 'the new 20s bound applies');
  });

  testWidgets('advancing onto and past the last slide does not throw', (tester) async {
    // video is the last slide; the show wraps to the first when it advances
    await _pumpSlideshow(tester, assets: [_image1, _video], initialPlayerState: _buffering);
    await _advanceToVideoSlide(tester);

    await _elapse(tester, const Duration(seconds: 6));

    expect(_currentPage(tester), 0.0, reason: 'repeat wraps the show back to the first slide');
    expect(_swallowedErrors.whereType<RangeError>(), isEmpty, reason: 'no timeline RangeError at the bounds');
  });

  testWidgets('shuffle resolving to the current slide still advances a never-ready video', (tester) async {
    final timeline = _ShuffleStubTimelineService((
      assetSource: (index, count) async => [_video, _image1].sublist(index, math.min(index + count, 2)),
      bucketSource: () => Stream.value(const [Bucket(assetCount: 2)]),
      origin: TimelineOrigin.main,
    ), _video);

    await _pumpSlideshow(
      tester,
      assets: [_video, _image1],
      initialPlayerState: _buffering,
      config: const AppConfig(slideshow: SlideshowConfig(direction: SlideshowDirection.shuffle)),
      timeline: timeline,
    );
    expect(_currentPage(tester), 0.0);

    // first bound fires with the target still on the current slide: no jump,
    // but the timer must be re-armed and the shuffle re-rolled
    timeline.shuffleTo(_image1);
    await _elapse(tester, const Duration(seconds: 6));
    expect(_currentPage(tester), 0.0, reason: 'a same-slide shuffle result must not jump');

    // second bound resolves to the other slide
    await _elapse(tester, const Duration(seconds: 6));
    expect(_currentPage(tester), 1.0, reason: 'the re-armed bound advances once the shuffle target moves on');
  });

  testWidgets('resume after background restarts a full fresh bound', (tester) async {
    addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));

    await _pumpSlideshow(tester, assets: [_video, _image1], initialPlayerState: _buffering);
    expect(_currentPage(tester), 0.0);

    await _elapse(tester, const Duration(seconds: 1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);

    // the bound fires once in the background and is re-armed without advancing
    await _elapse(tester, const Duration(seconds: 8));
    expect(_currentPage(tester), 0.0, reason: 'no advance while the app is backgrounded');

    // resume shortly before the background-armed fire: a full fresh bound applies
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _elapse(tester, const Duration(seconds: 2));
    expect(_currentPage(tester), 0.0, reason: 'the stale background bound must not skip the video right after resume');

    await _elapse(tester, const Duration(seconds: 4));
    expect(_currentPage(tester), 1.0, reason: 'the fresh bound started at resume fires after one full duration');
  });

  testWidgets('ending the show on a completed video does not rebuild forever', (tester) async {
    await _pumpSlideshow(
      tester,
      assets: [_image1, _video],
      initialPlayerState: _playing,
      config: const AppConfig(slideshow: SlideshowConfig(repeat: false)),
    );
    await _advanceToVideoSlide(tester);

    _FakeVideoPlayerNotifier.latest!.emit(
      const VideoPlayerState(position: _videoDuration, duration: _videoDuration, status: VideoPlaybackStatus.completed),
    );
    await _elapse(tester, const Duration(seconds: 2));

    expect(_currentPage(tester), 1.0, reason: 'repeat off parks the show on the last slide');

    // the deferred advance must stop re-firing once the show has paused: the
    // next frame must not rebuild the video slide at all (its build reads the provider)
    // once the show has paused, the deferred advance must stop re-firing: a
    // settled frame must not leave the page marked dirty (the rebuild loop
    // would re-dirty it every frame)
    final pageElement = tester.element(find.byType(DriftSlideshowPage));
    await tester.pump();
    _drainImageErrors(tester);
    expect(pageElement.dirty, isFalse, reason: 'a paused end of show must not keep rebuilding');
  });

  testWidgets('a timeline swap under the current slide does not park the show', (tester) async {
    final videoA = LocalAsset(
      id: 'videoA',
      name: 'videoA.mp4',
      type: AssetType.video,
      createdAt: DateTime(2025, 3),
      updatedAt: DateTime(2025, 4),
      playbackStyle: AssetPlaybackStyle.video,
      durationMs: 30000,
      width: 1920,
      height: 1080,
      isEdited: false,
    );
    final videoB = LocalAsset(
      id: 'videoB',
      name: 'videoB.mp4',
      type: AssetType.video,
      createdAt: DateTime(2025, 3),
      updatedAt: DateTime(2025, 4),
      playbackStyle: AssetPlaybackStyle.video,
      durationMs: 30000,
      width: 1920,
      height: 1080,
      isEdited: false,
    );

    final assets = [_image1, videoA, _image2];
    final bucketController = StreamController<List<Bucket>>();
    addTearDown(bucketController.close);
    final timeline = TimelineService((
      assetSource: (index, count) async => assets.sublist(index, math.min(index + count, assets.length)),
      bucketSource: () => bucketController.stream,
      origin: TimelineOrigin.main,
    ));
    bucketController.add([const Bucket(assetCount: 3)]);

    await _pumpSlideshow(tester, assets: List.of(assets), timeline: timeline, initialPlayerState: _buffering);
    await _advanceToVideoSlide(tester);

    // a sync swaps a different asset into the current index under the running show
    assets[1] = videoB;
    bucketController.add([const Bucket(assetCount: 3)]);
    await tester.pump();

    // first bound adopts the new asset and stays armed, second bound advances
    await _elapse(tester, const Duration(seconds: 6));
    await _elapse(tester, const Duration(seconds: 5));
    expect(_currentPage(tester), 2.0, reason: 'a slide identity swap must not park the show');
  });

  testWidgets('the buffer momentarily not serving the current index does not park the show', (tester) async {
    final assets = [_image1, _video];
    var serving = true;
    final bucketController = StreamController<List<Bucket>>();
    addTearDown(bucketController.close);
    final timeline = TimelineService((
      assetSource: (index, count) async => serving
          ? assets.sublist(index, math.min(index + count, assets.length))
          : assets.sublist(index, math.min(index + count, 1)),
      bucketSource: () => bucketController.stream,
      origin: TimelineOrigin.main,
    ));
    bucketController.add([const Bucket(assetCount: 2)]);

    await _pumpSlideshow(tester, assets: assets, timeline: timeline, initialPlayerState: _buffering);
    await _advanceToVideoSlide(tester);

    // a reload leaves the buffer unable to serve the current index for a while
    serving = false;
    bucketController.add([const Bucket(assetCount: 2)]);
    await tester.pump();

    // first bound finds nothing, stays armed; the buffer recovers, next bound advances
    await _elapse(tester, const Duration(seconds: 6));
    serving = true;
    bucketController.add([const Bucket(assetCount: 2)]);
    await tester.pump();

    await _elapse(tester, const Duration(seconds: 4));
    expect(_currentPage(tester), 0.0, reason: 'a temporarily unservable index must not park the show');
  });

  testWidgets('shuffle resolving to a completed video advances instead of looping', (tester) async {
    final timeline = _ShuffleStubTimelineService((
      assetSource: (index, count) async => [_video, _image1].sublist(index, math.min(index + count, 2)),
      bucketSource: () => Stream.value(const [Bucket(assetCount: 2)]),
      origin: TimelineOrigin.main,
    ), _video);

    await _pumpSlideshow(
      tester,
      assets: [_video, _image1],
      initialPlayerState: _playing,
      config: const AppConfig(slideshow: SlideshowConfig(direction: SlideshowDirection.shuffle)),
      timeline: timeline,
    );
    expect(_currentPage(tester), 0.0);

    // the video completes with the shuffle target still on itself
    _FakeVideoPlayerNotifier.latest!.emit(
      const VideoPlayerState(position: _videoDuration, duration: _videoDuration, status: VideoPlaybackStatus.completed),
    );
    timeline.shuffleTo(_image1);

    await _elapse(tester, const Duration(seconds: 2));
    expect(
      _currentPage(tester),
      1.0,
      reason: 'a completed video must consume the re-rolled target, not loop on the timer',
    );
  });

  testWidgets('a single slide wrapping to itself does not park the show', (tester) async {
    final timeline = _CountingTimelineService((
      assetSource: (index, count) async => [_video].sublist(index, math.min(index + count, 1)),
      bucketSource: () => Stream.value(const [Bucket(assetCount: 1)]),
      origin: TimelineOrigin.main,
    ));

    await _pumpSlideshow(tester, assets: [_video], timeline: timeline, initialPlayerState: _buffering);
    expect(_currentPage(tester), 0.0);

    await _elapse(tester, const Duration(seconds: 6));
    final readsAfterFirstBound = timeline.safeReads;

    await _elapse(tester, const Duration(seconds: 6));
    expect(
      timeline.safeReads,
      greaterThan(readsAfterFirstBound),
      reason: 'a wrap to the same page must keep the timer armed',
    );
  });

  testWidgets('pause holds the show and play re-arms it', (tester) async {
    await _pumpSlideshow(
      tester,
      assets: [_image1, _video, _image2],
      initialPlayerState: const VideoPlayerState(
        position: Duration(seconds: 5),
        duration: _videoDuration,
        status: VideoPlaybackStatus.paused,
      ),
    );
    await _advanceToVideoSlide(tester);

    await tester.tap(find.byType(DriftSlideshowPage));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byIcon(Icons.pause));
    await tester.pump();

    await _elapse(tester, const Duration(seconds: 12));
    expect(_currentPage(tester), 1.0, reason: 'a paused slideshow must not advance');

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();
    await _elapse(tester, const Duration(seconds: 6));
    expect(_currentPage(tester), 2.0, reason: 'resuming must re-arm the video wait');
  });

  testWidgets('two advances crossing a preload do not skip a slide', (tester) async {
    final assets = [
      for (var i = 0; i < 1030; i++)
        i == 1023
            ? _video
            : LocalAsset(
                id: 'img$i',
                name: 'img$i.jpg',
                type: AssetType.image,
                createdAt: DateTime(2025),
                updatedAt: DateTime(2025, 2),
                playbackStyle: AssetPlaybackStyle.image,
                isEdited: false,
              ),
    ];

    final preloadGate = Completer<void>();
    final timeline = TimelineService((
      assetSource: (index, count) async {
        if (index + count > 1024) {
          await preloadGate.future;
        }
        return assets.sublist(index, math.min(index + count, assets.length));
      },
      bucketSource: () => Stream.value([Bucket(assetCount: assets.length)]),
      origin: TimelineOrigin.main,
    ));

    await _pumpSlideshow(tester, assets: assets, timeline: timeline, initialPlayerState: _playing, startAsset: _video);
    expect(_currentPage(tester), 1023.0);

    // two completion callbacks queue behind the gated preload of index 1024
    _FakeVideoPlayerNotifier.latest!.emit(
      const VideoPlayerState(position: _videoDuration, duration: _videoDuration, status: VideoPlaybackStatus.completed),
    );
    await tester.pump();
    _FakeVideoPlayerNotifier.latest!.emit(
      const VideoPlayerState(
        position: Duration(seconds: 29),
        duration: _videoDuration,
        status: VideoPlaybackStatus.completed,
      ),
    );
    await tester.pump();

    preloadGate.complete();
    await tester.pump();
    await tester.pump();

    expect(_currentPage(tester), 1024.0, reason: 'the second advance must not consume the target the first one rolled');
  });

  testWidgets('an emptied timeline stops the show without throwing', (tester) async {
    final assets = [_video];
    final bucketController = StreamController<List<Bucket>>();
    addTearDown(bucketController.close);
    final timeline = TimelineService((
      assetSource: (index, count) async => assets.sublist(index, math.min(index + count, assets.length)),
      bucketSource: () => bucketController.stream,
      origin: TimelineOrigin.main,
    ));
    bucketController.add([const Bucket(assetCount: 1)]);

    await _pumpSlideshow(tester, assets: List.of(assets), timeline: timeline, initialPlayerState: _buffering);
    expect(_currentPage(tester), 0.0);

    // the only asset is removed on another client
    assets.removeLast();
    bucketController.add([const Bucket(assetCount: 0)]);
    await tester.pump();

    await _elapse(tester, const Duration(seconds: 12));
    expect(
      find.byIcon(Icons.play_arrow).evaluate(),
      isNotEmpty,
      reason: 'an emptied timeline must stop the show, not crash it',
    );
    expect(_swallowedErrors.whereType<RangeError>(), isEmpty, reason: 'no range error from an empty timeline');
  });

  testWidgets('a completed single-asset video restarts on repeat instead of parking', (tester) async {
    final timeline = _CountingTimelineService((
      assetSource: (index, count) async => [_video].sublist(index, math.min(index + count, 1)),
      bucketSource: () => Stream.value(const [Bucket(assetCount: 1)]),
      origin: TimelineOrigin.main,
    ));

    await _pumpSlideshow(
      tester,
      assets: [_video],
      timeline: timeline,
      initialPlayerState: const VideoPlayerState(
        position: _videoDuration,
        duration: _videoDuration,
        status: VideoPlaybackStatus.completed,
      ),
    );
    expect(_currentPage(tester), 0.0);

    await _elapse(tester, const Duration(seconds: 6));
    expect(
      _FakeVideoPlayerNotifier.latest!.restartCalls,
      greaterThan(0),
      reason: 'repeat must restart a completed single video',
    );
    expect(_FakeVideoPlayerNotifier.latest!.state.position, Duration.zero, reason: 'the restart resets playback');

    await _elapse(tester, const Duration(seconds: 6));
    expect(timeline.safeReads, greaterThan(0), reason: 'the show stays alive after the restart');
  });

  testWidgets('a completed video staying on itself with repeat off stops the show', (tester) async {
    final timeline = _ShuffleStubTimelineService((
      assetSource: (index, count) async => [_video, _image1].sublist(index, math.min(index + count, 2)),
      bucketSource: () => Stream.value(const [Bucket(assetCount: 2)]),
      origin: TimelineOrigin.main,
    ), _video);

    await _pumpSlideshow(
      tester,
      assets: [_video, _image1],
      timeline: timeline,
      initialPlayerState: const VideoPlayerState(
        position: _videoDuration,
        duration: _videoDuration,
        status: VideoPlaybackStatus.completed,
      ),
      config: const AppConfig(slideshow: SlideshowConfig(direction: SlideshowDirection.shuffle, repeat: false)),
    );
    expect(_currentPage(tester), 0.0);

    // the shuffle keeps resolving to the completed video itself
    await _elapse(tester, const Duration(seconds: 2));
    expect(find.byIcon(Icons.play_arrow).evaluate(), isNotEmpty, reason: 'repeat off with nowhere to go must stop');
  });
}

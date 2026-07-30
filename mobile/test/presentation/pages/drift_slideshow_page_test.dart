import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/slideshow_config.dart';
import 'package:immich_mobile/presentation/pages/drift_slideshow.page.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/services/gcast.service.dart';

import 'slideshow_test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    mockSlideshowChannels(messenger);
    swallowedErrors.clear();
  });

  testWidgets('a video that never becomes ready advances after one slide duration', (tester) async {
    // no player override: the source cannot be created in this environment, so
    // the video stays at the default (never ready) state forever
    await pumpSlideshow(tester, assets: [kImage1, kVideo, kImage2]);
    await advanceToVideoSlide(tester);

    await elapse(tester, const Duration(seconds: 6));

    expect(currentPage(tester), 2.0, reason: 'a video that never becomes ready must not block advancing');
  });

  testWidgets('a video stuck buffering at the start advances', (tester) async {
    await pumpSlideshow(tester, assets: [kImage1, kVideo, kImage2], initialPlayerState: kBuffering);
    await advanceToVideoSlide(tester);

    await elapse(tester, const Duration(seconds: 6));

    expect(currentPage(tester), 2.0, reason: 'a video stuck buffering must not block advancing');
  });

  testWidgets('a never-ready video as the first slide advances', (tester) async {
    await pumpSlideshow(tester, assets: [kVideo, kImage1], initialPlayerState: kBuffering);
    expect(currentPage(tester), 0.0);

    await elapse(tester, const Duration(seconds: 6));

    expect(currentPage(tester), 1.0, reason: 'a video first slide that never becomes ready must not block advancing');
  });

  testWidgets('a video making progress within the bound is not skipped', (tester) async {
    await pumpSlideshow(tester, assets: [kImage1, kVideo, kImage2], initialPlayerState: kBuffering);
    await advanceToVideoSlide(tester);

    // buffers for 3s of the 5s bound, then starts playing and keeps moving
    await elapse(tester, const Duration(seconds: 3));
    for (var position = 1; position <= 8; position++) {
      FakeVideoPlayerNotifier.latest!.emit(
        VideoPlayerState(
          position: Duration(seconds: position),
          duration: kVideoDuration,
          status: VideoPlaybackStatus.playing,
        ),
      );
      await elapse(tester, const Duration(seconds: 1));
      expect(currentPage(tester), 1.0, reason: 'a video still making progress at ${position}s must not be skipped');
    }
  });

  testWidgets('a video that stalls mid-playback advances', (tester) async {
    await pumpSlideshow(
      tester,
      assets: [kImage1, kVideo, kImage2],
      initialPlayerState: const VideoPlayerState(
        position: Duration(seconds: 5),
        duration: kVideoDuration,
        status: VideoPlaybackStatus.playing,
      ),
    );
    await advanceToVideoSlide(tester);

    await elapse(tester, const Duration(seconds: 6));

    expect(currentPage(tester), 2.0, reason: 'a video stalled mid-playback must not block advancing');
  });

  testWidgets('the no-progress bound counts from the last progress, not from the slide start', (tester) async {
    await pumpSlideshow(tester, assets: [kImage1, kVideo, kImage2], initialPlayerState: kPlaying);
    await advanceToVideoSlide(tester);

    // progress at 2s and 4s of playback, then the position freezes for good
    for (final position in [2, 4]) {
      FakeVideoPlayerNotifier.latest!.emit(
        VideoPlayerState(
          position: Duration(seconds: position),
          duration: kVideoDuration,
          status: VideoPlaybackStatus.playing,
        ),
      );
      await elapse(tester, const Duration(seconds: 2));
    }

    await elapse(tester, const Duration(seconds: 4));
    expect(currentPage(tester), 1.0, reason: 'one bound of no progress has not passed yet');

    await elapse(tester, const Duration(seconds: 3));
    expect(currentPage(tester), 2.0, reason: 'a full bound after the last progress must advance');
  });

  testWidgets('a completed video advances exactly once', (tester) async {
    await pumpSlideshow(tester, assets: [kImage1, kVideo, kImage2], initialPlayerState: kPlaying);
    await advanceToVideoSlide(tester);

    FakeVideoPlayerNotifier.latest!.emit(kCompleted);
    await elapse(tester, const Duration(seconds: 2));

    expect(currentPage(tester), 2.0, reason: 'a completed video must advance to the next slide, not past it');
  });

  testWidgets('backgrounding is not a stall and resume restarts a full bound', (tester) async {
    addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));

    await pumpSlideshow(tester, assets: [kVideo, kImage1], initialPlayerState: kBuffering);
    expect(currentPage(tester), 0.0);

    await elapse(tester, const Duration(seconds: 1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);

    // the bound fires in the background and is re-armed without advancing
    await elapse(tester, const Duration(seconds: 8));
    expect(currentPage(tester), 0.0, reason: 'no advance while the app is backgrounded');

    // resume shortly before the background-armed fire: a full fresh bound applies
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await elapse(tester, const Duration(seconds: 2));
    expect(currentPage(tester), 0.0, reason: 'the stale background bound must not skip the video right after resume');

    await elapse(tester, const Duration(seconds: 4));
    expect(currentPage(tester), 1.0, reason: 'the fresh bound started at resume fires after one full duration');
  });

  testWidgets('a slide duration change re-arms the video wait', (tester) async {
    final container = await pumpSlideshow(tester, assets: [kImage1, kVideo, kImage2], initialPlayerState: kBuffering);
    await advanceToVideoSlide(tester);

    container.updateOverrides([
      appConfigProvider.overrideWithValue(const AppConfig(slideshow: SlideshowConfig(duration: 20))),
      assetServiceProvider.overrideWithValue(const StubAssetService()),
      gCastServiceProvider.overrideWithValue(StubGCastService()),
      videoPlayerProvider.overrideWith((_, _) => FakeVideoPlayerNotifier(kBuffering)),
    ]);
    await elapse(tester, const Duration(seconds: 1));

    await elapse(tester, const Duration(seconds: 5));
    expect(currentPage(tester), 1.0, reason: 'the old 5s bound must not fire after the re-arm');

    await elapse(tester, const Duration(seconds: 16));
    expect(currentPage(tester), 2.0, reason: 'the new 20s bound applies');
  });

  testWidgets('ending the show on a completed video does not rebuild forever', (tester) async {
    await pumpSlideshow(
      tester,
      assets: [kImage1, kVideo],
      initialPlayerState: kPlaying,
      config: const AppConfig(slideshow: SlideshowConfig(repeat: false)),
    );
    await advanceToVideoSlide(tester);

    FakeVideoPlayerNotifier.latest!.emit(kCompleted);
    await elapse(tester, const Duration(seconds: 2));

    expect(currentPage(tester), 1.0, reason: 'repeat off parks the show on the last slide');

    // a settled frame must not leave the page marked dirty; the rebuild loop
    // would re-dirty it every frame
    final pageElement = tester.element(find.byType(DriftSlideshowPage));
    await tester.pump();
    drainImageErrors(tester);
    expect(pageElement.dirty, isFalse, reason: 'a paused end of show must not keep rebuilding');
  });

  testWidgets('pause holds the show and play re-arms it', (tester) async {
    await pumpSlideshow(
      tester,
      assets: [kImage1, kVideo, kImage2],
      initialPlayerState: const VideoPlayerState(
        position: Duration(seconds: 5),
        duration: kVideoDuration,
        status: VideoPlaybackStatus.paused,
      ),
    );
    await advanceToVideoSlide(tester);

    await tester.tap(find.byType(DriftSlideshowPage));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byIcon(Icons.pause));
    await tester.pump();

    await elapse(tester, const Duration(seconds: 12));
    expect(currentPage(tester), 1.0, reason: 'a paused slideshow must not advance');

    await tester.tap(find.byIcon(Icons.play_arrow));
    await tester.pump();
    await elapse(tester, const Duration(seconds: 6));
    expect(currentPage(tester), 2.0, reason: 'resuming must re-arm the video wait');
  });

  testWidgets('a plain backward step moves to the previous slide', (tester) async {
    await pumpSlideshow(
      tester,
      assets: [kImage1, kImage2, imageAsset('img3')],
      startAsset: kImage2,
      config: const AppConfig(slideshow: SlideshowConfig(direction: SlideshowDirection.backward)),
    );
    expect(currentPage(tester), 1.0);

    await elapse(tester, const Duration(seconds: 6));
    expect(currentPage(tester), 0.0, reason: 'backward steps to the previous slide');
  });

  testWidgets('backward wraps from the first slide to the last and keeps advancing', (tester) async {
    await pumpSlideshow(
      tester,
      assets: [kImage1, kImage2, imageAsset('img3')],
      config: const AppConfig(slideshow: SlideshowConfig(direction: SlideshowDirection.backward)),
    );
    expect(currentPage(tester), 0.0);

    // the bound fires with the target at -1: repeat must wrap to the last slide
    await elapse(tester, const Duration(seconds: 6));
    expect(currentPage(tester), 2.0, reason: 'backward from the first slide must wrap to the last');

    await elapse(tester, const Duration(seconds: 6));
    expect(currentPage(tester), 1.0, reason: 'the show keeps stepping backward after the wrap');
  });
}

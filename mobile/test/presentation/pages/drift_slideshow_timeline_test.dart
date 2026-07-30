import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/config/slideshow_config.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';

import 'slideshow_test_utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    mockSlideshowChannels(messenger);
    swallowedErrors.clear();
  });

  testWidgets('advancing onto and past the last slide does not throw', (tester) async {
    // video is the last slide; the show wraps to the first when it advances
    await pumpSlideshow(tester, assets: [kImage1, kVideo], initialPlayerState: kBuffering);
    await advanceToVideoSlide(tester);

    await elapse(tester, const Duration(seconds: 6));

    expect(currentPage(tester), 0.0, reason: 'repeat wraps the show back to the first slide');
    expect(swallowedErrors.whereType<RangeError>(), isEmpty, reason: 'no timeline RangeError at the bounds');
  });

  testWidgets('shuffle resolving to the current slide still advances a never-ready video', (tester) async {
    final timeline = ShuffleStubTimelineService((
      assetSource: (index, count) async => [kVideo, kImage1].sublist(index, math.min(index + count, 2)),
      bucketSource: () => Stream.value(const [Bucket(assetCount: 2)]),
      origin: TimelineOrigin.main,
    ), kVideo);

    await pumpSlideshow(
      tester,
      assets: [kVideo, kImage1],
      initialPlayerState: kBuffering,
      config: const AppConfig(slideshow: SlideshowConfig(direction: SlideshowDirection.shuffle)),
      timeline: timeline,
    );
    expect(currentPage(tester), 0.0);

    // first bound fires with the target still on the current slide: no jump,
    // but the wait must be re-armed and the shuffle re-rolled
    timeline.shuffleTo(kImage1);
    await elapse(tester, const Duration(seconds: 6));
    expect(currentPage(tester), 0.0, reason: 'a same-slide shuffle result must not jump');

    // second bound resolves to the other slide
    await elapse(tester, const Duration(seconds: 6));
    expect(currentPage(tester), 1.0, reason: 'the re-armed bound advances once the shuffle target moves on');
  });

  testWidgets('timeline changes under the show do not park it', (tester) async {
    // stage 1: a sync swaps a different video into the current index
    final assets = [kImage1, videoAsset('videoA'), kImage2];
    final bucketController = StreamController<List<Bucket>>();
    addTearDown(bucketController.close);
    final timeline = TimelineService((
      assetSource: (index, count) async => assets.sublist(index, math.min(index + count, assets.length)),
      bucketSource: () => bucketController.stream,
      origin: TimelineOrigin.main,
    ));
    bucketController.add([const Bucket(assetCount: 3)]);

    await pumpSlideshow(tester, assets: List.of(assets), timeline: timeline, initialPlayerState: kBuffering);
    await advanceToVideoSlide(tester);

    assets[1] = videoAsset('videoB');
    bucketController.add([const Bucket(assetCount: 3)]);
    await tester.pump();

    // the swap must re-arm the wait: nothing may fire on the stale schedule
    await elapse(tester, const Duration(seconds: 4));
    expect(currentPage(tester), 1.0, reason: 'a swapped slide must not advance on the stale wait');

    // the re-armed wait advances the new never-ready video instead
    await elapse(tester, const Duration(seconds: 2));
    expect(currentPage(tester), 2.0, reason: 'an identity swap must not park the show');

    // unmount so the second show starts with a fresh state
    await tester.pumpWidget(const SizedBox.shrink());

    // stage 2, fresh show: a reload leaves the buffer unable to serve the index
    final assets2 = [kImage1, kVideo];
    var serving = true;
    final bucketController2 = StreamController<List<Bucket>>();
    addTearDown(bucketController2.close);
    final timeline2 = TimelineService((
      assetSource: (index, count) async => serving
          ? assets2.sublist(index, math.min(index + count, assets2.length))
          : assets2.sublist(index, math.min(index + count, 1)),
      bucketSource: () => bucketController2.stream,
      origin: TimelineOrigin.main,
    ));
    bucketController2.add([const Bucket(assetCount: 2)]);

    await pumpSlideshow(tester, assets: assets2, timeline: timeline2, initialPlayerState: kBuffering);
    await advanceToVideoSlide(tester);

    serving = false;
    bucketController2.add([const Bucket(assetCount: 2)]);
    await tester.pump();

    // the buffer recovers before the wait fires; the show still advances on time
    await elapse(tester, const Duration(seconds: 2));
    serving = true;
    bucketController2.add([const Bucket(assetCount: 2)]);
    await tester.pump();

    await elapse(tester, const Duration(seconds: 6));
    expect(currentPage(tester), 0.0, reason: 'a temporarily unservable index must not park the show');
  });

  testWidgets('an unrelated reload does not reset a running wait', (tester) async {
    final assets = [kImage1, kImage2];
    final bucketController = StreamController<List<Bucket>>();
    addTearDown(bucketController.close);
    final timeline = TimelineService((
      assetSource: (index, count) async => assets.sublist(index, math.min(index + count, assets.length)),
      bucketSource: () => bucketController.stream,
      origin: TimelineOrigin.main,
    ));
    bucketController.add([const Bucket(assetCount: 2)]);

    await pumpSlideshow(tester, assets: assets, timeline: timeline);
    expect(currentPage(tester), 0.0);

    // four seconds into the image's five second wait, an unrelated sync lands
    await elapse(tester, const Duration(seconds: 4));
    bucketController.add([const Bucket(assetCount: 2)]);
    await tester.pump();

    // the wait must keep its original schedule and fire one second later
    await elapse(tester, const Duration(seconds: 2));
    expect(currentPage(tester), 1.0, reason: 'an unrelated reload must not reset the running wait');
  });

  testWidgets('shuffle resolving to a completed video advances instead of looping', (tester) async {
    final timeline = ShuffleStubTimelineService((
      assetSource: (index, count) async => [kVideo, kImage1].sublist(index, math.min(index + count, 2)),
      bucketSource: () => Stream.value(const [Bucket(assetCount: 2)]),
      origin: TimelineOrigin.main,
    ), kVideo);

    await pumpSlideshow(
      tester,
      assets: [kVideo, kImage1],
      initialPlayerState: kPlaying,
      config: const AppConfig(slideshow: SlideshowConfig(direction: SlideshowDirection.shuffle)),
      timeline: timeline,
    );
    expect(currentPage(tester), 0.0);

    // the video completes with the shuffle target still on itself
    FakeVideoPlayerNotifier.latest!.emit(kCompleted);
    timeline.shuffleTo(kImage1);

    await elapse(tester, const Duration(seconds: 2));
    expect(currentPage(tester), 1.0, reason: 'a completed video must consume the re-rolled target, not loop');
  });

  testWidgets('a single slide wrapping to itself does not park the show', (tester) async {
    final timeline = CountingTimelineService((
      assetSource: (index, count) async => [kVideo].sublist(index, math.min(index + count, 1)),
      bucketSource: () => Stream.value(const [Bucket(assetCount: 1)]),
      origin: TimelineOrigin.main,
    ));

    await pumpSlideshow(tester, assets: [kVideo], timeline: timeline, initialPlayerState: kBuffering);
    expect(currentPage(tester), 0.0);

    await elapse(tester, const Duration(seconds: 6));
    final readsAfterFirstBound = timeline.safeReads;

    await elapse(tester, const Duration(seconds: 6));
    expect(
      timeline.safeReads,
      greaterThan(readsAfterFirstBound),
      reason: 'a wrap to the same page must keep the timer armed',
    );
  });

  testWidgets('two advances crossing a preload do not skip a slide', (tester) async {
    final assets = [for (var i = 0; i < 1030; i++) i == 1023 ? kVideo : imageAsset('img$i')];

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

    await pumpSlideshow(tester, assets: assets, timeline: timeline, initialPlayerState: kPlaying, startAsset: kVideo);
    expect(currentPage(tester), 1023.0);

    // two completion callbacks queue behind the gated preload of index 1024
    FakeVideoPlayerNotifier.latest!.emit(kCompleted);
    await tester.pump();
    FakeVideoPlayerNotifier.latest!.emit(kCompleted.copyWith(position: const Duration(seconds: 29)));
    await tester.pump();

    preloadGate.complete();
    await tester.pump();
    await tester.pump();

    expect(currentPage(tester), 1024.0, reason: 'the second advance must not consume the target the first one rolled');
  });

  testWidgets('an advance stale after a mid-preload swipe does not fire', (tester) async {
    final assets = [for (var i = 0; i < 1030; i++) imageAsset('img$i')];

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

    await pumpSlideshow(tester, assets: assets, timeline: timeline, startAsset: imageAsset('img1023'));
    expect(currentPage(tester), 1023.0);

    // the bound fires: the advance to the unloaded slide parks behind the gated preload
    await elapse(tester, const Duration(seconds: 6));
    expect(currentPage(tester), 1023.0);

    // a swipe settles the show on the first slide while the preload is still pending
    tester.widget<PageView>(find.byType(PageView)).controller!.jumpToPage(0);
    await tester.pump();
    expect(currentPage(tester), 0.0);

    preloadGate.complete();
    await tester.pump();
    await tester.pump();
    expect(currentPage(tester), 0.0, reason: 'the stale advance must not clobber the slide the swipe settled on');

    await elapse(tester, const Duration(seconds: 6));
    expect(currentPage(tester), 1.0, reason: 'the show keeps running from the settled slide');
  });

  testWidgets('an emptied timeline stops the show without throwing', (tester) async {
    final assets = [kVideo];
    final bucketController = StreamController<List<Bucket>>();
    addTearDown(bucketController.close);
    final timeline = TimelineService((
      assetSource: (index, count) async => assets.sublist(index, math.min(index + count, assets.length)),
      bucketSource: () => bucketController.stream,
      origin: TimelineOrigin.main,
    ));
    bucketController.add([const Bucket(assetCount: 1)]);

    await pumpSlideshow(tester, assets: List.of(assets), timeline: timeline, initialPlayerState: kBuffering);
    expect(currentPage(tester), 0.0);

    // the only asset is removed on another client
    assets.removeLast();
    bucketController.add([const Bucket(assetCount: 0)]);
    await tester.pump();

    await elapse(tester, const Duration(seconds: 12));
    expect(find.byIcon(Icons.play_arrow).evaluate(), isNotEmpty, reason: 'an emptied timeline must stop, not crash');
    expect(swallowedErrors.whereType<RangeError>(), isEmpty, reason: 'no range error from an empty timeline');
  });

  testWidgets('a completed single-asset video restarts on repeat', (tester) async {
    final timeline = CountingTimelineService((
      assetSource: (index, count) async => [kVideo].sublist(index, math.min(index + count, 1)),
      bucketSource: () => Stream.value(const [Bucket(assetCount: 1)]),
      origin: TimelineOrigin.main,
    ));

    await pumpSlideshow(tester, assets: [kVideo], timeline: timeline, initialPlayerState: kCompleted);
    expect(currentPage(tester), 0.0);

    await elapse(tester, const Duration(seconds: 6));
    expect(
      FakeVideoPlayerNotifier.latest!.restartCalls,
      greaterThan(0),
      reason: 'repeat must restart a completed video',
    );
    expect(FakeVideoPlayerNotifier.latest!.state.position, Duration.zero, reason: 'the restart resets playback');

    await elapse(tester, const Duration(seconds: 6));
    expect(timeline.safeReads, greaterThan(0), reason: 'the show stays alive after the restart');
  });

  testWidgets('a completed video staying on itself with repeat off stops the show', (tester) async {
    final timeline = ShuffleStubTimelineService((
      assetSource: (index, count) async => [kVideo, kImage1].sublist(index, math.min(index + count, 2)),
      bucketSource: () => Stream.value(const [Bucket(assetCount: 2)]),
      origin: TimelineOrigin.main,
    ), kVideo);

    await pumpSlideshow(
      tester,
      assets: [kVideo, kImage1],
      timeline: timeline,
      initialPlayerState: kCompleted,
      config: const AppConfig(slideshow: SlideshowConfig(direction: SlideshowDirection.shuffle, repeat: false)),
    );
    expect(currentPage(tester), 0.0);

    // the shuffle keeps resolving to the completed video itself
    await elapse(tester, const Duration(seconds: 2));
    expect(find.byIcon(Icons.play_arrow).evaluate(), isNotEmpty, reason: 'repeat off with nowhere to go must stop');
  });
}

import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/config/slideshow_config.dart';
import 'package:immich_mobile/domain/models/events.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/domain/utils/event_stream.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/scroll_extensions.dart';
import 'package:immich_mobile/extensions/translate_extensions.dart';
import 'package:immich_mobile/pages/common/settings.page.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/video_viewer.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/image_provider.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/system_ui.utils.dart';
import 'package:immich_mobile/widgets/common/immich_loading_indicator.dart';
import 'package:immich_mobile/widgets/photo_view/photo_view.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

@RoutePage()
class DriftSlideshowPage extends ConsumerStatefulWidget {
  final TimelineService timeline;

  const DriftSlideshowPage({super.key, required this.timeline});

  @override
  ConsumerState<DriftSlideshowPage> createState() => _DriftSlideshowPageState();
}

class _DriftSlideshowPageState extends ConsumerState<DriftSlideshowPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const double _kenBurnsZoom = 0.1;

  late SlideshowConfig _config;
  late final PageController _pageController;
  late final Stopwatch _stopwatch;
  Timer? _timer;
  late int _index;
  late int _nextIndex;
  bool _paused = false;
  bool _showAppBar = false;
  StreamSubscription<TimelineReloadEvent>? _reloadSubscription;
  Duration _lastVideoPosition = Duration.zero;
  String? _armedHeroTag;

  late final AnimationController _crossfadeController;
  late final Animation<double> _crossfadeOpacity;
  int? _crossfadeFromIndex;
  int? _crossfadeToIndex;
  int _zoomCycle = 0;
  bool _disableAnimations = false;

  @override
  initState() {
    super.initState();
    _config = ref.read(appConfigProvider.select((s) => s.slideshow));
    final asset = ref.read(assetViewerProvider).currentAsset;
    _index = asset == null ? 0 : widget.timeline.getIndex(asset.heroTag) ?? 0;
    _pageController = PageController(initialPage: _index);
    _crossfadeController = AnimationController(vsync: this, duration: Durations.extralong2);
    _crossfadeOpacity = Tween<double>(begin: 1.0, end: 0.0).animate(_crossfadeController);
    _stopwatch = Stopwatch();
    _startTimer(widget.timeline.getAssetSafe(_index));
    _updateNextIndex();
    ref.listenManual(appConfigProvider.select((s) => s.slideshow), _onConfigChanged);
    _reloadSubscription = EventStream.shared.listen<TimelineReloadEvent>((_) => _onTimelineReload());
    WidgetsBinding.instance.addObserver(this);

    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
    unawaited(WakelockPlus.enable());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _disableAnimations = MediaQuery.disableAnimationsOf(context);
  }

  @override
  dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _reloadSubscription?.cancel();
    _timer?.cancel();
    _stopwatch.stop();
    _pageController.dispose();
    _crossfadeController.dispose();
    unawaited(WakelockPlus.disable());
    unawaited(restoreEdgeToEdge());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || _paused) {
      return;
    }

    final asset = widget.timeline.getAssetSafe(_index);
    if (asset != null && !asset.isImage) {
      _startTimer(asset);
    }
  }

  void _play() {
    final asset = widget.timeline.getAssetSafe(_index)!;

    if (asset.isImage) {
      _startTimer(asset);
    } else if (ref.read(videoPlayerProvider(asset.heroTag)).status == VideoPlaybackStatus.paused) {
      ref.read(videoPlayerProvider(asset.heroTag).notifier).play();
      _startTimer(asset);
    } else {
      _nextPage();
    }

    _updateNextIndex();

    setState(() {
      _paused = false;
    });
  }

  void _pause() {
    _timer?.cancel();
    _stopwatch.stop();

    final asset = widget.timeline.getAssetSafe(_index)!;

    if (!asset.isImage) {
      ref.read(videoPlayerProvider(asset.heroTag).notifier).pause();
    }

    setState(() {
      _paused = true;
    });
  }

  void _onConfigChanged(SlideshowConfig? previous, SlideshowConfig next) {
    if (_config == next) {
      return;
    }

    final durationChanged = _config.duration != next.duration;
    _config = next;
    _updateNextIndex();

    final asset = widget.timeline.getAssetSafe(_index);
    if (durationChanged && !_paused && asset != null) {
      _startTimer(asset);
    }

    setState(() {});
  }

  void _updateNextIndex() {
    _nextIndex = switch (_config.direction) {
      SlideshowDirection.forward => _index + 1,
      SlideshowDirection.backward => _index - 1,
      SlideshowDirection.shuffle => widget.timeline.getIndex(widget.timeline.getRandomAsset().heroTag)!,
    };

    if (_nextIndex >= 0 && _nextIndex < widget.timeline.totalAssets && !widget.timeline.hasRange(_nextIndex, 1)) {
      widget.timeline.preloadAssets(_nextIndex);
    }
  }

  void _nextPage() async {
    // captured: the preload await must not re-read a re-rolled target
    final target = _nextIndex;
    // a swipe during the await settles the show elsewhere; the stale advance must not fire
    final expectedIndex = _index;
    if (target < 0 || target >= widget.timeline.totalAssets) {
      // nowhere to go: an emptied timeline or the no-repeat end stops the show
      if (widget.timeline.totalAssets == 0 || !_config.repeat) {
        setState(() {
          _paused = true;
        });
        return;
      }

      final wrapped = _config.direction == SlideshowDirection.forward ? 0 : widget.timeline.totalAssets - 1;
      if (wrapped != _index) {
        await widget.timeline.preloadAssets(wrapped);
      }
      if (_index != expectedIndex) {
        return;
      }
      _crossFadeToPage(wrapped);
      return;
    }

    if (!widget.timeline.hasRange(target, 1)) {
      await widget.timeline.preloadAssets(target);
    }

    if (_index != expectedIndex) {
      return;
    }

    _crossFadeToPage(target);
  }

  void _crossFadeToPage(int page) {
    if (!mounted) {
      return;
    }

    // the PageView emits no event for a same-page jump; settle it like any other
    if (page == _index) {
      _pageChanged(page);
      return;
    }

    if (_disableAnimations) {
      _pageController.jumpToPage(page);
      return;
    }

    final previousIndex = _index;
    _pageController.jumpToPage(page);
    setState(() {
      _crossfadeFromIndex = previousIndex;
      _crossfadeToIndex = page;
    });
    _crossfadeController.forward(from: 0.0).whenComplete(() {
      if (mounted) {
        setState(() {
          _crossfadeFromIndex = null;
          _crossfadeToIndex = null;
        });
      }
    });
  }

  Widget _getCrossfadeLayer(BuildContext context, int index, {required bool isIncoming}) {
    final asset = widget.timeline.getAssetSafe(index);

    final Widget child;
    if (isIncoming && asset?.isImage == true) {
      child = _getPhotoView(context, index);
    } else {
      final zoomOut = isIncoming ? _zoomCycle.isOdd : _zoomCycle.isEven;
      final zoom = isIncoming ? (zoomOut ? 1.0 : 0.0) : (zoomOut ? 0.0 : 1.0);
      child = _getCrossfadeChild(context, index, zoom);
    }

    return Stack(
      fit: StackFit.expand,
      children: [if (_config.look == SlideshowLook.blurredBackground) _getBlur(context, index), child],
    );
  }

  Widget _getCrossfadeChild(BuildContext context, int index, double zoom) {
    final asset = widget.timeline.getAssetSafe(index);

    if (asset == null) {
      return const SizedBox.shrink();
    }

    final scale = _config.look == SlideshowLook.cover
        ? PhotoViewComputedScale.covered
        : PhotoViewComputedScale.contained;

    return PhotoView(
      imageProvider: getFullImageProvider(asset, size: context.sizeData),
      index: index,
      disableScaleGestures: true,
      gaplessPlayback: true,
      filterQuality: FilterQuality.high,
      initialScale: scale * (1.0 + zoom * _kenBurnsZoom),
      controller: PhotoViewController(),
    );
  }

  void _startTimer(BaseAsset? asset) {
    _timer?.cancel();
    _armedHeroTag = asset?.heroTag;

    if (asset == null || asset.isImage) {
      _timer = Timer(Duration(milliseconds: _config.duration * 1000 - _stopwatch.elapsedMilliseconds), _onTimer);
      _stopwatch.start();
    } else {
      // stall baseline for the next check
      _lastVideoPosition = ref.read(videoPlayerProvider(asset.heroTag)).position;
      _timer = Timer(Duration(seconds: _config.duration), _onTimer);
    }
  }

  void _onTimer() {
    if (!mounted || _paused) {
      return;
    }

    final asset = widget.timeline.getAssetSafe(_index);

    if (asset == null || asset.isImage) {
      _stopwatch.stop();
      _stopwatch.reset();
      _nextPage();
      return;
    }

    final playerState = ref.read(videoPlayerProvider(asset.heroTag));
    final completed = playerState.status == VideoPlaybackStatus.completed && playerState.position > Duration.zero;
    final stalled = playerState.position == _lastVideoPosition;
    // the viewer pauses playback while the app is backgrounded and resumes on return
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final backgrounded =
        lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.hidden ||
        lifecycle == AppLifecycleState.detached;

    // advance past a video that made no playback progress within one slide duration
    if (!completed && stalled && !backgrounded) {
      _nextPage();
      return;
    }

    _startTimer(asset);
  }

  // the timeline changed under us; re-arm for whatever is on the slide now,
  // but an unrelated sync must not reset a running wait
  void _onTimelineReload() {
    if (!mounted || _paused) {
      return;
    }

    final asset = widget.timeline.getAssetSafe(_index);
    if (_index < widget.timeline.totalAssets && asset?.heroTag == _armedHeroTag) {
      return;
    }

    _stopwatch.stop();
    _stopwatch.reset();
    _startTimer(asset);
  }

  void _pageChanged(int page) {
    final asset = widget.timeline.getAssetSafe(page);

    setState(() {
      _index = page;
      _zoomCycle++;

      if (asset != null && !asset.isImage) {
        _paused = false;
      }
    });

    _timer?.cancel();
    _stopwatch.stop();
    _stopwatch.reset();
    _updateNextIndex();

    if (_paused) {
      return;
    }

    // a completed video with no different slide to go to replays on repeat or stops
    if (asset != null && !asset.isImage) {
      final playerState = ref.read(videoPlayerProvider(asset.heroTag));
      final completed = playerState.status == VideoPlaybackStatus.completed && playerState.position > Duration.zero;
      final hasDifferentTarget = _nextIndex != _index && _nextIndex >= 0 && _nextIndex < widget.timeline.totalAssets;
      if (completed && !hasDifferentTarget) {
        if (_config.repeat) {
          ref.read(videoPlayerProvider(asset.heroTag).notifier).restart();
          _startTimer(asset);
        } else {
          setState(() {
            _paused = true;
          });
        }
        return;
      }
    }

    _startTimer(asset);
  }

  void _onTapUp() async {
    await (_showAppBar ? SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive) : restoreEdgeToEdge());

    WidgetsBinding.instance.addPostFrameCallback((_) {
      setState(() {
        _showAppBar = !_showAppBar;
      });
    });
  }

  Widget _getProgressBar(BuildContext context) {
    final asset = widget.timeline.getAssetSafe(_index);

    if (asset == null) {
      return Container();
    }

    if (asset.isImage) {
      return _SlideshowProgressBar(
        key: Key(_index.toString()),
        durationMs: _config.duration * 1000,
        elapsedMs: _stopwatch.elapsedMilliseconds,
        paused: _paused,
        color: context.colorScheme.primary,
      );
    } else {
      return LinearProgressIndicator(
        color: context.colorScheme.primary,
        borderRadius: const BorderRadius.all(Radius.zero),
        minHeight: 5,
        value:
            ref.watch(videoPlayerProvider(asset.heroTag).select((s) => s.position)).inMilliseconds /
            asset.duration.inMilliseconds,
      );
    }
  }

  Widget _getBlur(BuildContext context, int index) {
    final asset = widget.timeline.getAssetSafe(index);

    if (asset == null) {
      return Container();
    }

    return ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
      child: Container(
        decoration: BoxDecoration(
          image: DecorationImage(
            image: getFullImageProvider(asset, size: Size(context.width, context.height)),
            fit: BoxFit.cover,
          ),
        ),
        child: Container(color: Colors.black.withValues(alpha: 0.2)),
      ),
    );
  }

  Widget _getPhotoView(BuildContext context, int index) {
    final asset = widget.timeline.getAssetSafe(index);

    if (asset == null) {
      return const Center(child: ImmichLoadingIndicator());
    }

    final scale = _config.look == SlideshowLook.cover
        ? PhotoViewComputedScale.covered
        : PhotoViewComputedScale.contained;
    final isCurrent = _index == index;
    final imageProvider = getFullImageProvider(asset, size: context.sizeData);

    if (asset.isImage) {
      PhotoView buildPhotoView(PhotoViewComputedScale initialScale) => PhotoView(
        imageProvider: imageProvider,
        index: index,
        disableScaleGestures: true,
        gaplessPlayback: true,
        filterQuality: FilterQuality.high,
        initialScale: initialScale,
        controller: PhotoViewController(),
        onTapUp: (_, _, _) => _onTapUp(),
      );

      if (_disableAnimations) {
        return buildPhotoView(scale);
      }

      final zoomOut = _zoomCycle.isOdd;
      final elapsed = _stopwatch.elapsedMilliseconds;
      final duration = _config.duration * 1000;
      final progress = zoomOut ? 1.0 - elapsed / duration.toDouble() : elapsed / duration.toDouble();

      return TweenAnimationBuilder(
        tween: Tween<double>(
          begin: progress,
          end: _paused
              ? progress
              : zoomOut
              ? 0.0
              : 1.0,
        ),
        duration: Duration(milliseconds: _paused ? 1 : max(duration - elapsed, 1)),
        builder: (context, value, _) => buildPhotoView(scale * (1.0 + value * _kenBurnsZoom)),
      );
    } else {
      final status = ref.watch(videoPlayerProvider(asset.heroTag).select((s) => s.status));
      final position = ref.read(videoPlayerProvider(asset.heroTag)).position;

      if (status == VideoPlaybackStatus.completed && isCurrent && position.inMicroseconds > 0) {
        // advancing from inside build trips the setState-during-build assert
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_paused && _index == index) {
            _nextPage();
          }
        });
      } else if (status == VideoPlaybackStatus.playing) {
        ref.read(videoPlayerProvider(asset.heroTag).notifier).setLoop(false);
      }

      return PhotoView.customChild(
        onTapUp: (_, _, _) => _onTapUp(),
        disableScaleGestures: true,
        filterQuality: FilterQuality.high,
        initialScale: scale,
        child: NativeVideoViewer(
          asset: asset,
          isCurrent: isCurrent,
          image: Image(image: imageProvider, fit: BoxFit.contain, alignment: Alignment.center),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: PreferredSize(
        preferredSize: Size(AppBar().preferredSize.width, AppBar().preferredSize.height + 5),
        child: IgnorePointer(
          ignoring: !_showAppBar,
          child: AnimatedOpacity(
            opacity: _showAppBar ? 1.0 : 0.0,
            duration: Durations.short2,
            child: Column(
              children: [
                AppBar(
                  backgroundColor: context.scaffoldBackgroundColor,
                  title: Text("slideshow".t(context: context)),
                  actions: [
                    IconButton(
                      onPressed: _paused ? _play : _pause,
                      icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
                    ),
                    IconButton(
                      onPressed: () {
                        _pause();
                        context.pushRoute(SettingsSubRoute(section: SettingSection.assetViewer));
                      },
                      icon: const Icon(Icons.settings),
                    ),
                  ],
                ),
                _getProgressBar(context),
              ],
            ),
          ),
        ),
      ),
      extendBody: true,
      extendBodyBehindAppBar: true,
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PhotoViewGestureDetectorScope(
            axis: Axis.horizontal,
            child: PageView.builder(
              controller: _pageController,
              physics: const FastClampingScrollPhysics(),
              itemCount: widget.timeline.totalAssets,
              onPageChanged: _pageChanged,
              itemBuilder: (context, index) => Stack(
                children: [
                  if (_config.look == SlideshowLook.blurredBackground) _getBlur(context, index),
                  _getPhotoView(context, index),
                ],
              ),
            ),
          ),
          if (_crossfadeFromIndex != null && _crossfadeToIndex != null)
            Positioned.fill(
              child: IgnorePointer(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const ColoredBox(color: Colors.black),
                    FadeTransition(
                      opacity: _crossfadeController,
                      child: _getCrossfadeLayer(context, _crossfadeToIndex!, isIncoming: true),
                    ),
                    FadeTransition(
                      opacity: _crossfadeOpacity,
                      child: _getCrossfadeLayer(context, _crossfadeFromIndex!, isIncoming: false),
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

/// Progress bar for image slides, driven by an explicit [AnimationController].
///
/// [TweenAnimationBuilder] creates its controller internally with the default
/// [AnimationBehavior.normal], which makes it run ~20x too fast while the system
/// "reduce motion" setting is on (flutter/flutter#164287). This owns its
/// controller so it can use [AnimationBehavior.preserve] and animate at the real
/// slide duration regardless of that setting.
class _SlideshowProgressBar extends StatefulWidget {
  final int durationMs;
  final int elapsedMs;
  final bool paused;
  final Color color;

  const _SlideshowProgressBar({
    super.key,
    required this.durationMs,
    required this.elapsedMs,
    required this.paused,
    required this.color,
  });

  @override
  State<_SlideshowProgressBar> createState() => _SlideshowProgressBarState();
}

class _SlideshowProgressBarState extends State<_SlideshowProgressBar> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: widget.durationMs),
      animationBehavior: AnimationBehavior.preserve,
    )..value = (widget.elapsedMs / widget.durationMs).clamp(0.0, 1.0);
    if (!widget.paused) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(_SlideshowProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.durationMs != oldWidget.durationMs) {
      _controller.duration = Duration(milliseconds: widget.durationMs);
    }
    if (widget.paused != oldWidget.paused) {
      widget.paused ? _controller.stop() : _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => LinearProgressIndicator(
        color: widget.color,
        borderRadius: const BorderRadius.all(Radius.zero),
        minHeight: 5,
        value: _controller.value,
      ),
    );
  }
}

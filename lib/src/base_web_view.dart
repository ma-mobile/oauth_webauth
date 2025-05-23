import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:oauth_webauth/oauth_webauth.dart';
import 'package:oauth_webauth/src/utils/custom_pop_scope.dart';

/// This allows a value of type T or T?
/// to be treated as a value of type T?.
///
/// We use this so that APIs that have become
/// non-nullable can still be used with `!` and `?`
/// to support older versions of the API as well.
T? _ambiguate<T>(T? value) => value;

class BaseWebView extends StatefulWidget {
  final BaseConfiguration _configuration;

  const BaseWebView({
    super.key,
    required BaseConfiguration configuration,
  }) : _configuration = configuration;

  @override
  State createState() => BaseWebViewState<BaseWebView>();
}

class BaseWebViewState<S extends BaseWebView> extends State<S>
    with WidgetsBindingObserver, BaseFlowMixin {
  bool ready = false;
  bool showToolbar = false;
  bool isLoading = true;
  bool allowGoBack = false;
  bool allowGoForward = false;
  bool tooltipsAlreadyInitialized = false;
  InAppWebViewController? inAppWebViewController;
  @override
  late BuildContext context;

  late String backButtonTooltip;
  late String forwardButtonTooltip;
  late String reloadButtonTooltip;
  late String clearCacheButtonTooltip;
  late String closeButtonTooltip;
  late String clearCacheWarningMessage;

  late Timer toolbarTimerShow;
  late Widget webView;
  StreamSubscription? urlStreamSubscription;

  bool clearCacheSwitch = true;
  bool clearCookiesSwitch = true;
  ThemeData theme = ThemeData();

  BaseConfiguration get configuration => widget._configuration;

  bool get toolbarVisible =>
      configuration.goBackBtnVisible ||
      configuration.goForwardBtnVisible ||
      configuration.refreshBtnVisible ||
      configuration.clearCacheBtnVisible ||
      configuration.closeBtnVisible;

  @override
  void initState() {
    super.initState();
    initBase();
    webView = initWebView();
    if (kIsWeb) onNavigateTo(OAuthWebAuth.instance.appBaseUrl);
  }

  void initBase() {
    init(
      initialUri: Uri.parse(configuration.initialUrl),
      redirectUrls: configuration.redirectUrls,
      onSuccessRedirect: configuration.onSuccessRedirect,
      onError: configuration.onError,
      onCancel: configuration.onCancel,
    );
    toolbarTimerShow = Timer(const Duration(seconds: 5), () {
      setState(() {
        showToolbar = true;
      });
    });
    _ambiguate(WidgetsBinding.instance)?.addObserver(this);
    urlStreamSubscription = configuration.urlStream?.listen(controllerGo);
  }

  void initTooltips() {
    if (tooltipsAlreadyInitialized) return;
    backButtonTooltip = configuration.backButtonTooltip ?? 'Go back';
    forwardButtonTooltip = configuration.forwardButtonTooltip ?? 'Go forward';
    reloadButtonTooltip = configuration.reloadButtonTooltip ?? 'Reload';
    clearCacheButtonTooltip =
        configuration.clearCacheButtonTooltip ?? 'Clear cache';
    closeButtonTooltip = configuration.closeButtonTooltip ??
        MaterialLocalizations.of(context).closeButtonTooltip;
    clearCacheWarningMessage = configuration.clearCacheWarningMessage ??
        'Are you sure you want to clear cache?';
    tooltipsAlreadyInitialized = true;
  }

  Widget initWebView() {
    final Widget content;

    if (kIsWeb) {
      content = const SizedBox();
    } else {
      /// InAppWebView is a better choice for Android and iOS than official plugin for WebViews
      /// due to the possibility to manage ServerTrustAuthRequest, which is crucial in Android because Android
      /// native WebView does not allow to access an URL with a certificate not authorized by
      /// known certification authority.
      content = InAppWebView(
        // windowId: 12345,
        initialSettings: InAppWebViewSettings(
          useShouldOverrideUrlLoading: true,
          supportZoom: false,
          transparentBackground: true,
          userAgent: configuration.userAgent,
          useHybridComposition: configuration.useHybridComposition,
        ),
        initialUrlRequest:
            URLRequest(url: WebUri(initialUri.toString()), headers: {
          ...configuration.headers,
          if (configuration.contentLocale != null)
            'Accept-Language': configuration.contentLocale!.toLanguageTag()
        }),
        onReceivedServerTrustAuthRequest: (controller, challenge) async {
          return ServerTrustAuthResponse(
              action: ServerTrustAuthResponseAction.PROCEED);
        },
        onWebViewCreated: (controller) {
          inAppWebViewController = controller;
        },
        shouldOverrideUrlLoading: (controller, navigationAction) async {
          final url = navigationAction.request.url?.toString() ?? '';
          return onNavigateTo(url)
              ? NavigationActionPolicy.ALLOW
              : NavigationActionPolicy.CANCEL;
        },
        onLoadStart: (controller, url) async {
          if (url == initialUri) {
            // showLoading();
            final certificate =
                (await controller.getCertificate())?.x509Certificate;
            if (certificate != null && !onCertificateValidate(certificate)) {
              onError(const CertificateException('Invalid certificate'));
            }
          } else {
            hideLoading();
          }
        },
        onLoadStop: (controller, url) async {
          hideLoading();
        },
        onProgressChanged: (controller, progress) {
          if (progress > 1) {
            // showLoading();
          } else if (progress > 99) {
            hideLoading();
          }
        },
        onReceivedError: (controller, request, error) => hideLoading(),
      );
    }

    return GestureDetector(
      onLongPressDown: (details) {},

      /// To avoid long press for text selection or open link on new tab
      child: content,
    );
  }

  @override
  void setState(VoidCallback fn) {
    if (!mounted) return;
    super.setState(fn);
  }

  @override
  void showLoading() {
    if (!isLoading && mounted) {
      setState(() {
        isLoading = true;
      });
    }
  }

  @override
  Future<void> hideLoading() async {
    if (isLoading && mounted) {
      ready = true;
      showToolbar = true;
      toolbarTimerShow.cancel();
      isLoading = false;
      allowGoBack = await controllerCanGoBack();
      allowGoForward = await controllerCanGoForward();
      setState(() {});
    }
  }

  bool onCertificateValidate(X509Certificate certificate) {
    return configuration.onCertificateValidate?.call(certificate) ?? true;
  }

  Widget iconButton({
    required IconData iconData,
    String? tooltip,
    VoidCallback? onPressed,
    bool respectLoading = true,
  }) =>
      IconButton(
        iconSize: 30,
        tooltip: tooltip,
        icon: Icon(iconData),
        color: theme.colorScheme.secondary,
        onPressed: respectLoading && isLoading ? null : onPressed,
      );

  @override
  Widget build(BuildContext context) {
    theme = configuration.themeData ?? Theme.of(context);
    final content = Builder(
      builder: (context) {
        this.context = context;
        initTooltips();
        return SafeArea(
          child: Scaffold(
            body: Stack(
              children: [
                CustomPopScope(
                  canGoBack: onBackPressed,
                  child: webView,
                ),
                Positioned.fill(
                  child: Hero(
                    tag: BaseConfiguration.firstLoadHeroTag,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: !ready && isLoading
                          ? const CircularProgressIndicator()
                          : const SizedBox(),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: Hero(
                    tag: BaseConfiguration.firstLoadHeroTag,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 200),
                      child: ready && isLoading
                          ? const CircularProgressIndicator()
                          : const SizedBox(),
                    ),
                  ),
                ),
                Positioned(
                  top: MediaQuery.of(context).size.height * 0.01,
                  left: MediaQuery.of(context).size.width * 0.02,
                  child: configuration.backButton ??
                      IconButton(
                        icon: Icon(
                          Icons.arrow_back_ios,
                          color: configuration.backButtonColor,
                        ),
                        onPressed: () {
                          Navigator.pop(context);
                        },
                      ),
                ),
              ],
            ),
            bottomNavigationBar: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              height: toolbarVisible && showToolbar ? null : 0,
              child: BottomAppBar(
                elevation: 8,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    if (configuration.goBackBtnVisible)
                      iconButton(
                        iconData: Icons.arrow_back_ios_rounded,
                        tooltip: backButtonTooltip,
                        onPressed:
                            !allowGoBack ? null : () => controllerGoBack(),
                      ),
                    if (configuration.goForwardBtnVisible)
                      iconButton(
                        iconData: Icons.arrow_forward_ios_rounded,
                        tooltip: forwardButtonTooltip,
                        onPressed: !allowGoForward
                            ? null
                            : () => controllerGoForward(),
                      ),
                    if (configuration.refreshBtnVisible)
                      iconButton(
                        iconData: Icons.refresh_rounded,
                        tooltip: reloadButtonTooltip,
                        onPressed: () => controllerReload(),
                      ),
                    if (configuration.clearCacheBtnVisible)
                      iconButton(
                        iconData: Icons.cleaning_services_rounded,
                        tooltip: clearCacheButtonTooltip,
                        onPressed: () {
                          clearCacheSwitch = clearCookiesSwitch = true;
                          showDialog(
                              context: context,
                              builder: (context) => StatefulBuilder(
                                  builder: (stateContext, setState) =>
                                      AlertDialog(
                                        title: Text(clearCacheButtonTooltip),
                                        content: SingleChildScrollView(
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(clearCacheWarningMessage),
                                              SwitchListTile(
                                                  value: clearCacheSwitch,
                                                  title: const Text('Cache'),
                                                  onChanged: (value) =>
                                                      setState(() =>
                                                          clearCacheSwitch =
                                                              value)),
                                              SwitchListTile(
                                                  value: clearCookiesSwitch,
                                                  title:
                                                      const Text('Cookies'),
                                                  onChanged: (value) =>
                                                      setState(() =>
                                                          clearCookiesSwitch =
                                                              value)),
                                            ],
                                          ),
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(context),
                                            child: Text(
                                                MaterialLocalizations.of(
                                                        context)
                                                    .cancelButtonLabel),
                                          ),
                                          TextButton(
                                            onPressed: !clearCacheSwitch &&
                                                    !clearCookiesSwitch
                                                ? null
                                                : () {
                                                    Navigator.pop(context);
                                                    if (clearCacheSwitch &&
                                                        clearCookiesSwitch) {
                                                      controllerClearAll();
                                                    } else if (clearCacheSwitch) {
                                                      controllerClearCache();
                                                    } else {
                                                      controllerClearCookies();
                                                    }
                                                  },
                                            child: Text(
                                                MaterialLocalizations.of(
                                                        context)
                                                    .okButtonLabel),
                                          ),
                                        ],
                                      )));
                        },
                      ),
                    if (configuration.closeBtnVisible)
                      iconButton(
                        iconData: Icons.close,
                        tooltip: closeButtonTooltip,
                        respectLoading: false,
                        onPressed: () => onCancel(),
                      ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
    return configuration.themeData != null
        ? Theme(
            data: configuration.themeData!,
            child: content,
          )
        : content;
  }

  Future<void> controllerGo(String url) async {
    // showLoading();
    inAppWebViewController?.loadUrl(
        urlRequest: URLRequest(url: WebUri(url), headers: {
      ...configuration.headers,
      if (configuration.contentLocale != null)
        'Accept-Language': configuration.contentLocale!.toLanguageTag()
    }));
  }

  Future<void> controllerGoBack() async {
    // showLoading();
    inAppWebViewController?.goBack();
  }

  Future<void> controllerGoForward() async {
    // showLoading();
    inAppWebViewController?.goForward();
  }

  Future<void> controllerReload() async {
    // showLoading();
    inAppWebViewController?.reload();
  }

  Future<void> controllerClearCache() async {
    // showLoading();
    await OAuthWebAuth.instance.clearCache();
    hideLoading();
    controllerReload();
  }

  Future<void> controllerClearCookies() async {
    // showLoading();
    await OAuthWebAuth.instance.clearCookies();
    hideLoading();
    controllerReload();
  }

  Future<void> controllerClearAll() async {
    // showLoading();
    await OAuthWebAuth.instance.clearAll();
    hideLoading();
    controllerReload();
  }

  Future<bool> controllerCanGoForward() async {
    bool? inAppWebViewCanGoForward;
    try {
      inAppWebViewCanGoForward = await inAppWebViewController?.canGoForward();
    } catch (e) {
      if (kDebugMode) print(e);
    }
    return inAppWebViewCanGoForward ?? false;
  }

  Future<bool> controllerCanGoBack() async {
    bool? inAppWebViewCanGoBack;
    try {
      inAppWebViewCanGoBack = await inAppWebViewController?.canGoBack();
    } catch (e) {
      if (kDebugMode) print(e);
    }
    return inAppWebViewCanGoBack ?? false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        hideLoading();
        break;
      default:
        break;
    }
  }

  Future<bool> onBackPressed({dynamic result}) async {
    if (await controllerCanGoBack()) {
      controllerGoBack();
      return false;
    }
    return true;
  }

  @override
  void dispose() {
    super.dispose();
    urlStreamSubscription?.cancel();
    toolbarTimerShow.cancel();
  }
}

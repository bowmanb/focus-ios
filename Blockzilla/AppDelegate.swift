/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import UIKit
import Telemetry

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    private var splashView: UIView?
    static let prefIntroDone = "IntroDone"
    static let prefIntroVersion = 2
    private let browserViewController = BrowserViewController()
    private var queuedUrl: URL?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplicationLaunchOptionsKey: Any]?) -> Bool {
        #if BUDDYBUILD
            BuddyBuildSDK.setup()
        #endif
        
        // Set up Telemetry
        let telemetryConfig = Telemetry.default.configuration
        telemetryConfig.appName = AppInfo.isKlar ? "Klar" : "Focus"
        telemetryConfig.userDefaultsSuiteName = AppInfo.sharedContainerIdentifier
        telemetryConfig.appVersion = AppInfo.shortVersion

        // Since Focus always clears the caches directory and Telemetry files are
        // excluded from iCloud backup, we store pings in documents.
        telemetryConfig.dataDirectory = .documentDirectory
        
        let defaultSearchEngineProvider = SearchEngineManager(prefs: UserDefaults.standard).engines.first?.name ?? "unknown"
        telemetryConfig.defaultSearchEngineProvider = defaultSearchEngineProvider
        
        telemetryConfig.measureUserDefaultsSetting(forKey: SearchEngineManager.prefKeyEngine, withDefaultValue: defaultSearchEngineProvider)
        telemetryConfig.measureUserDefaultsSetting(forKey: SettingsToggle.blockAds, withDefaultValue: Settings.getToggle(.blockAds))
        telemetryConfig.measureUserDefaultsSetting(forKey: SettingsToggle.blockAnalytics, withDefaultValue: Settings.getToggle(.blockAnalytics))
        telemetryConfig.measureUserDefaultsSetting(forKey: SettingsToggle.blockSocial, withDefaultValue: Settings.getToggle(.blockSocial))
        telemetryConfig.measureUserDefaultsSetting(forKey: SettingsToggle.blockOther, withDefaultValue: Settings.getToggle(.blockOther))
        telemetryConfig.measureUserDefaultsSetting(forKey: SettingsToggle.blockFonts, withDefaultValue: Settings.getToggle(.blockFonts))
        
        #if DEBUG
            telemetryConfig.updateChannel = "debug"
            telemetryConfig.isCollectionEnabled = false
            telemetryConfig.isUploadEnabled = false
        #else
            telemetryConfig.updateChannel = "release"
            telemetryConfig.isCollectionEnabled = Settings.getToggle(.sendAnonymousUsageData)
            telemetryConfig.isUploadEnabled = Settings.getToggle(.sendAnonymousUsageData)
        #endif
        
        Telemetry.default.add(pingBuilderType: CorePingBuilder.self)
        Telemetry.default.add(pingBuilderType: FocusEventPingBuilder.self)
        
        // Start the telemetry session and record an event indicating that we have entered the
        // foreground since `applicationWillEnterForeground(_:)` does not get called at launch.
        Telemetry.default.recordSessionStart()
        Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.foreground, object: TelemetryEventObject.app)
        
        // Only include Adjust SDK in Focus and NOT in Klar builds.
        #if FOCUS
            // Always initialize Adjust, otherwise the SDK is in a bad state. We disable it
            // immediately so that no data is collected or sent.
            AdjustIntegration.applicationDidFinishLaunching()
            if !Settings.getToggle(.sendAnonymousUsageData) {
                AdjustIntegration.enabled = false
            }
        #endif

        // Disable localStorage.
        // We clear the Caches directory after each Erase, but WebKit apparently maintains
        // localStorage in-memory (bug 1319208), so we just disable it altogether.
        UserDefaults.standard.set(false, forKey: "WebKitLocalStorageEnabledPreferenceKey")

        // Set up our custom user agent.
        UserAgent.setup()

        // Re-register the blocking lists at startup in case they've changed.
        Utils.reloadSafariContentBlocker()

        // Increase the URLCache limit to (memory: 16mb, disk: 32mb) so we don't have to re-download an image to save it.
        URLCacheManeger().setCacheCapacity(memoryCapacity: 16, diskCapacity: 32)

        LocalWebServer.sharedInstance.start()

        window = UIWindow(frame: UIScreen.main.bounds)

        let rootViewController = UINavigationController(rootViewController: browserViewController)
        window?.rootViewController = rootViewController
        window?.makeKeyAndVisible()

        WebCacheUtils.reset()

        URLProtocol.registerClass(LocalContentBlocker.self)

        displaySplashAnimation()
        KeyboardHelper.defaultHelper.startObserving()

        if UserDefaults.standard.integer(forKey: AppDelegate.prefIntroDone) < AppDelegate.prefIntroVersion {

            // Show the first run UI asynchronously to avoid the "unbalanced calls to begin/end appearance transitions" warning.
            DispatchQueue.main.async {
                // Set the prefIntroVersion viewed number in the same context as the presentation.
                UserDefaults.standard.set(AppDelegate.prefIntroVersion, forKey: AppDelegate.prefIntroDone)

                let firstRunViewController = FirstRunViewController()
                rootViewController.present(firstRunViewController, animated: false, completion: nil)
            }
        }

        return true
    }

    func application(_ application: UIApplication, open url: URL, sourceApplication: String?, annotation: Any) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }

        guard let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [AnyObject],
            let urlSchemes = urlTypes.first?["CFBundleURLSchemes"] as? [String] else {
                // Something very strange has happened; org.mozilla.Blockzilla should be the zeroeth URL type.
                return false
        }

        guard let scheme = components.scheme,
            let host = url.host,
            urlSchemes.contains(scheme) else {
            return false
        }

        let query = getQuery(url: url)

        guard host == "open-url" else { return false }

        let urlString = unescape(string: query["url"]) ?? ""
        guard let url = URL(string: urlString) else { return false }

        if application.applicationState == .active {
            // If we are active then we can ask the BVC to open the new tab right away.
            // Otherwise, we remember the URL and we open it in applicationDidBecomeActive.
            browserViewController.submit(url: url)
        } else {
            queuedUrl = url
        }

        return true
    }

    public func getQuery(url: URL) -> [String: String] {
        var results = [String: String]()
        let keyValues =  url.query?.components(separatedBy: "&")

        if keyValues?.count ?? 0 > 0 {
            for pair in keyValues! {
                let kv = pair.components(separatedBy: "=")
                if kv.count > 1 {
                    results[kv[0]] = kv[1]
                }
            }
        }

        return results
    }

    public func unescape(string: String?) -> String? {
        guard let string = string else {
            return nil
        }
        return CFURLCreateStringByReplacingPercentEscapes(
            kCFAllocatorDefault,
            string as CFString,
            "[]." as CFString) as String
    }

    fileprivate func displaySplashAnimation() {
        let splashView = UIView()
        splashView.backgroundColor = UIConstants.colors.background
        window!.addSubview(splashView)

        let logoImage = UIImageView(image: AppInfo.config.wordmark)
        splashView.addSubview(logoImage)

        splashView.snp.makeConstraints { make in
            make.edges.equalTo(window!)
        }

        logoImage.snp.makeConstraints { make in
            make.center.equalTo(splashView)
        }

        let animationDuration = 0.25
        UIView.animate(withDuration: animationDuration, delay: 0.0, options: UIViewAnimationOptions(), animations: {
            logoImage.layer.transform = CATransform3DMakeScale(0.8, 0.8, 1.0)
        }, completion: { success in
            UIView.animate(withDuration: animationDuration, delay: 0.0, options: UIViewAnimationOptions(), animations: {
                splashView.alpha = 0
                logoImage.layer.transform = CATransform3DMakeScale(2.0, 2.0, 1.0)
            }, completion: { success in
                splashView.isHidden = true
                logoImage.layer.transform = CATransform3DIdentity
                self.splashView = splashView
            })
        })
    }

    func applicationWillResignActive(_ application: UIApplication) {
        splashView?.animateHidden(false, duration: 0)
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        splashView?.animateHidden(true, duration: 0.25)
        if let url = queuedUrl {

            Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.openedFromExtension, object: TelemetryEventObject.app)

            browserViewController.ensureBrowsingMode()
            browserViewController.submit(url: url)
            queuedUrl = nil
        }
    }
    
    func applicationWillEnterForeground(_ application: UIApplication) {
        // Start a new telemetry session and record an event indicating that we have entered the
        // foreground. This only gets called for subsequent foregrounds after the initial launch.
        Telemetry.default.recordSessionStart()
        Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.foreground, object: TelemetryEventObject.app)
    }
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        // Record an event indicating that we have entered the background and end our telemetry
        // session. This gets called every time the app goes to background but should not get
        // called for *temporary* interruptions such as an incoming phone call until the user
        // takes action and we are officially backgrounded.
        let orientation = UIDevice.current.orientation.isPortrait ? "Portrait" : "Landscape"
        Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.background, object:
            TelemetryEventObject.app, value: nil, extras: ["orientation": orientation])
        Telemetry.default.recordSessionEnd()
        
        // Add the CorePing and FocusEventPing to the queue and schedule them for upload in the
        // background at iOS's discretion (usually happens immediately).
        Telemetry.default.queue(pingType: CorePingBuilder.PingType)
        Telemetry.default.queue(pingType: FocusEventPingBuilder.PingType)
        Telemetry.default.scheduleUpload(pingType: CorePingBuilder.PingType)
        Telemetry.default.scheduleUpload(pingType: FocusEventPingBuilder.PingType)
    }
}

extension UINavigationController {
    override open var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }
}

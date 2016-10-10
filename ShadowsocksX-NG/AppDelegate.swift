//
//  AppDelegate.swift
//  ShadowsocksX-NG
//
//  Created by 邱宇舟 on 16/6/5.
//  Copyright © 2016年 qiuyuzhou. All rights reserved.
//

import Cocoa


@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, NSUserNotificationCenterDelegate {
    
    // MARK: Controllers
    var qrcodeWinCtrl: SWBQRCodeWindowController!
    var preferencesWinCtrl: PreferencesWindowController!
    var advPreferencesWinCtrl: AdvPreferencesWindowController!
    var proxyPreferencesWinCtrl: ProxyPreferencesController!
    var editUserRulesWinCtrl: UserRulesController!
    var httpPreferencesWinCtrl : HTTPPreferencesWindowController!
    
    var launchAtLoginController: LaunchAtLoginController = LaunchAtLoginController()
    
    // MARK: Outlets
    @IBOutlet weak var window: NSWindow!
    @IBOutlet weak var statusMenu: NSMenu!
    
    @IBOutlet weak var runningStatusMenuItem: NSMenuItem!
    @IBOutlet weak var toggleRunningMenuItem: NSMenuItem!
    @IBOutlet weak var proxyMenuItem: NSMenuItem!
    @IBOutlet weak var autoModeMenuItem: NSMenuItem!
    @IBOutlet weak var globalModeMenuItem: NSMenuItem!
    @IBOutlet weak var manualModeMenuItem: NSMenuItem!
    @IBOutlet weak var whiteListModeMenuItem: NSMenuItem!
    @IBOutlet weak var whiteListDomainMenuItem: NSMenuItem!
    @IBOutlet weak var whiteListIPMenuItem: NSMenuItem!
    
    @IBOutlet weak var serversMenuItem: NSMenuItem!
    @IBOutlet var pingserverMenuItem: NSMenuItem!
    @IBOutlet var showQRCodeMenuItem: NSMenuItem!
    @IBOutlet var scanQRCodeMenuItem: NSMenuItem!
    @IBOutlet var showBunchJsonExampleFileItem: NSMenuItem!
    @IBOutlet var importBunchJsonFileItem: NSMenuItem!
    @IBOutlet var exportAllServerProfileItem: NSMenuItem!
    @IBOutlet var serversPreferencesMenuItem: NSMenuItem!
    
    @IBOutlet weak var lanchAtLoginMenuItem: NSMenuItem!
    @IBOutlet weak var connectAtLaunchMenuItem: NSMenuItem!
    @IBOutlet weak var ShowNetworkSpeedItem: NSMenuItem!
    
    // MARK: Variables
    var statusItemView:StatusItemView!
    var statusItem: NSStatusItem?
    var speedMonitor:NetWorkMonitor?

    // MARK: Application function

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        // Insert code here to initialize your application
//        PingServers.instance.ping()
//        let newInstance = PingTest.init(hostName: "www.baidu.com")
//        newInstance.start()
        
//        let SerMgr = ServerProfileManager.instance
//        let pingServerQueue : DispatchQueue = DispatchQueue.global(priority: DispatchQueue.GlobalQueuePriority.high)
//        
//        for profile in SerMgr.profiles {
//            let host = profile.serverHost
//            
//            pingServerQueue.async(execute: {
//                print(profile.serverHost)
//                SimplePingClient().pingHostname(host) { latency in
//                    print("-----------\(host) latency is \(latency ?? "fail")")}
////                let pingInstance = PingTest.init(hostName: host)
////                pingInstance.start()
//            })}
        NSUserNotificationCenter.default.delegate = self
        
        // Prepare ss-local
        InstallSSLocal()
        InstallPrivoxy()
        // Prepare defaults
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            "ShadowsocksOn": true,
            "ShadowsocksRunningMode": "auto",
            "LocalSocks5.ListenPort": NSNumber(value: 1086 as UInt16),
            "LocalSocks5.ListenAddress": "127.0.0.1",
            "PacServer.ListenAddress": "127.0.0.1",
            "PacServer.ListenPort":NSNumber(value: 8090 as UInt16),
            "LocalSocks5.Timeout": NSNumber(value: 60 as UInt),
            "LocalSocks5.EnableUDPRelay": NSNumber(value: false as Bool),
            "LocalSocks5.EnableVerboseMode": NSNumber(value: false as Bool),
            "GFWListURL": "https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt",
            "WhiteListURL": "https://raw.githubusercontent.com/breakwa11/gfw_whitelist/master/whitelist.pac",
            "WhiteListIPURL": "https://raw.githubusercontent.com/breakwa11/gfw_whitelist/master/whiteiplist.pac",
            "AutoConfigureNetworkServices": NSNumber(value: true as Bool),
            "LocalHTTP.ListenAddress": "127.0.0.1",
            "LocalHTTP.ListenPort": NSNumber(value: 1087 as UInt16),
            "LocalHTTPOn": true,
            "LocalHTTP.FollowGlobel": true
        ])

        setUpMenu(defaults.bool(forKey: "enable_showSpeed"))
        
//        statusItem = NSStatusBar.system().statusItem(withLength: 20)
//        let image = NSImage(named: "menu_icon")
//        image?.isTemplate = true
//        statusItem.image = image
//        statusItem.menu = statusMenu

        let notifyCenter = NotificationCenter.default
        notifyCenter.addObserver(forName: NSNotification.Name(rawValue: NOTIFY_ADV_PROXY_CONF_CHANGED), object: nil, queue: nil
            , using: {
            (note) in
                self.applyConfig()
            }
        )
        notifyCenter.addObserver(forName: NSNotification.Name(rawValue: NOTIFY_SERVER_PROFILES_CHANGED), object: nil, queue: nil
            , using: {
            (note) in
                let profileMgr = ServerProfileManager.instance
                if profileMgr.activeProfileId == nil &&
                    profileMgr.profiles.count > 0{
                    if profileMgr.profiles[0].isValid(){
                        profileMgr.setActiveProfiledId(profileMgr.profiles[0].uuid)
                    }
                }
                self.updateServersMenu()
                self.updateMainMenu()
                SyncSSLocal()
            }
        )
        notifyCenter.addObserver(forName: NSNotification.Name(rawValue: NOTIFY_ADV_CONF_CHANGED), object: nil, queue: nil
            , using: {
            (note) in
                SyncSSLocal()
                self.applyConfig()
            }
        )
        notifyCenter.addObserver(forName: NSNotification.Name(rawValue: NOTIFY_HTTP_CONF_CHANGED), object: nil, queue: nil
            , using: {
                (note) in
                SyncPrivoxy()
                self.applyConfig()
            }
        )
        notifyCenter.addObserver(forName: NSNotification.Name(rawValue: "NOTIFY_FOUND_SS_URL"), object: nil, queue: nil) {
            (note: Notification) in
            if let userInfo = (note as NSNotification).userInfo {
                let urls: [URL] = userInfo["urls"] as! [URL]
                
                let mgr = ServerProfileManager.instance
                var isChanged = false
                
                for url in urls {
                    let profielDict = ParseSSURL(url)
                    if let profielDict = profielDict {
                        let profile = ServerProfile.fromDictionary(profielDict as [String : AnyObject])
                        mgr.profiles.append(profile)
                        isChanged = true
                        
                        let userNote = NSUserNotification()
                        userNote.title = "Add Shadowsocks Server Profile".localized
                        if userInfo["source"] as! String == "qrcode" {
                            userNote.subtitle = "By scan QR Code".localized
                        } else if userInfo["source"] as! String == "url" {
                            userNote.subtitle = "By Handle SS URL".localized
                        }
                        userNote.informativeText = "Host: \(profile.serverHost)\n Port: \(profile.serverPort)\n Encription Method: \(profile.method)".localized
                        userNote.soundName = NSUserNotificationDefaultSoundName
                        
                        NSUserNotificationCenter.default
                            .deliver(userNote);
                    }else{
                        let userNote = NSUserNotification()
                        userNote.title = "Failed to Add Server Profile".localized
                        userNote.subtitle = "Address can't not be recognized".localized
                        NSUserNotificationCenter.default
                            .deliver(userNote);
                    }
                }
                
                if isChanged {
                    mgr.save()
                    self.updateServersMenu()
                }
            }
        }
        
        // Handle ss url scheme
        NSAppleEventManager.shared().setEventHandler(self
            , andSelector: #selector(self.handleURLEvent)
            , forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        
        updateMainMenu()
        updateServersMenu()
        updateRunningModeMenu()
        updateLaunchAtLoginMenu()
        
        ProxyConfHelper.install()
        applyConfig()
        SyncSSLocal()

        if defaults.bool(forKey: "ConnectAtLaunch") {
            toggleRunning(toggleRunningMenuItem)
        }
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
        StopSSLocal()
        StopPrivoxy()
        ProxyConfHelper.disableProxy("hi")
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "ShadowsocksOn")
        ProxyConfHelper.stopPACServer()
    }
    
    func applyConfig() {
        let profileMgr = ServerProfileManager.instance
        if profileMgr.profiles.count == 0{
            let notice = NSUserNotification()
            notice.title = "还没有服务器设定！"
            notice.subtitle = "去设置里面填一下吧，填完记得选择呦~"
            NSUserNotificationCenter.default.deliver(notice)
        }
        let defaults = UserDefaults.standard
        let isOn = defaults.bool(forKey: "ShadowsocksOn")
        let mode = defaults.string(forKey: "ShadowsocksRunningMode")
        
        if isOn {
            StartSSLocal()
            StartPrivoxy()
            if mode == "auto" {
                ProxyConfHelper.disableProxy("hi")
                ProxyConfHelper.enablePACProxy("hi")
            } else if mode == "global" {
                ProxyConfHelper.disableProxy("hi")
                ProxyConfHelper.enableGlobalProxy()
            } else if mode == "manual" {
                ProxyConfHelper.disableProxy("hi")
                ProxyConfHelper.disableProxy("hi")
            } else if mode == "whiteListDomain" {
                ProxyConfHelper.disableProxy("hi")
                ProxyConfHelper.enableWhiteDomainListProxy()
            } else if mode == "whiteListIP" {
                ProxyConfHelper.disableProxy("hi")
                ProxyConfHelper.enableWhiteIPListProxy()
            }
        } else {
            StopSSLocal()
            StopPrivoxy()
            ProxyConfHelper.disableProxy("hi")
        }

    }
    
    // MARK: Mainmenu functions
    
    @IBAction func toggleRunning(_ sender: NSMenuItem) {
        let defaults = UserDefaults.standard
        var isOn = defaults.bool(forKey: "ShadowsocksOn")
        isOn = !isOn
        defaults.set(isOn, forKey: "ShadowsocksOn")
        
        updateMainMenu()
        
        applyConfig()
    }

    @IBAction func updateGFWList(_ sender: NSMenuItem) {
        UpdatePACFromGFWList()
    }
    
    @IBAction func updateWhiteList(_ sender: NSMenuItem) {
        UpdatePACFromWhiteList()
    }
    
    @IBAction func editUserRulesForPAC(_ sender: NSMenuItem) {
        if editUserRulesWinCtrl != nil {
            editUserRulesWinCtrl.close()
        }
        let ctrl = UserRulesController(windowNibName: "UserRulesController")
        editUserRulesWinCtrl = ctrl

        ctrl.showWindow(self)
        NSApp.activate(ignoringOtherApps: true)
        ctrl.window?.makeKeyAndOrderFront(self)
    }
    
    @IBAction func toggleLaunghAtLogin(_ sender: NSMenuItem) {
        launchAtLoginController.launchAtLogin = !launchAtLoginController.launchAtLogin;
        updateLaunchAtLoginMenu()
    }
    
    @IBAction func toggleConnectAtLaunch(_ sender: NSMenuItem) {
        let defaults = UserDefaults.standard
        defaults.set(!defaults.bool(forKey: "ConnectAtLaunch"), forKey: "ConnectAtLaunch")
        updateMainMenu()
    }
    
    // MARK: Server submenu function

    @IBAction func showQRCodeForCurrentServer(_ sender: NSMenuItem) {
        var errMsg: String?
        if let profile = ServerProfileManager.instance.getActiveProfile() {
            if profile.isValid() {
                // Show window
                if qrcodeWinCtrl != nil{
                    qrcodeWinCtrl.close()
                }
                qrcodeWinCtrl = SWBQRCodeWindowController(windowNibName: "SWBQRCodeWindowController")
                qrcodeWinCtrl.qrCode = profile.URL()!.absoluteString
                qrcodeWinCtrl.showWindow(self)
                NSApp.activate(ignoringOtherApps: true)
                qrcodeWinCtrl.window?.makeKeyAndOrderFront(nil)
                
                return
            } else {
                errMsg = "Current server profile is not valid.".localized
            }
        } else {
            errMsg = "No current server profile.".localized
        }
        let userNote = NSUserNotification()
        userNote.title = errMsg
        userNote.soundName = NSUserNotificationDefaultSoundName
        
        NSUserNotificationCenter.default
            .deliver(userNote);
    }
    
    @IBAction func scanQRCodeFromScreen(_ sender: NSMenuItem) {
        ScanQRCodeOnScreen()
    }
    
    @IBAction func showBunchJsonExampleFile(_ sender: NSMenuItem) {
        ServerProfileManager.showExampleConfigFile()
    }
    
    @IBAction func importBunchJsonFile(_ sender: NSMenuItem) {
        ServerProfileManager.instance.importConfigFile()
        //updateServersMenu()//not working
    }
    
    @IBAction func exportAllServerProfile(_ sender: NSMenuItem) {
        ServerProfileManager.instance.exportConfigFile()
    }
    
    @IBAction func selectPACMode(_ sender: NSMenuItem) {
        let defaults = UserDefaults.standard
        defaults.setValue("auto", forKey: "ShadowsocksRunningMode")
        updateRunningModeMenu()
        applyConfig()
    }
    
    @IBAction func selectGlobalMode(_ sender: NSMenuItem) {
        let defaults = UserDefaults.standard
        defaults.setValue("global", forKey: "ShadowsocksRunningMode")
        updateRunningModeMenu()
        applyConfig()
    }
    
    @IBAction func selectManualMode(_ sender: NSMenuItem) {
        let defaults = UserDefaults.standard
        defaults.setValue("manual", forKey: "ShadowsocksRunningMode")
        updateRunningModeMenu()
        applyConfig()
    }
    
    @IBAction func selectWhiteDomainListMode(_ sender: NSMenuItem) {
        let defaults = UserDefaults.standard
        defaults.setValue("whiteListDomain", forKey: "ShadowsocksRunningMode")
        updateRunningModeMenu()
        applyConfig()
    }
    
    @IBAction func selectWhiteIPListMode(_ sender: NSMenuItem) {
        let defaults = UserDefaults.standard
        defaults.setValue("whiteListIP", forKey: "ShadowsocksRunningMode")
        updateRunningModeMenu()
        applyConfig()
    }

    @IBAction func editServerPreferences(_ sender: NSMenuItem) {
        if preferencesWinCtrl != nil {
            preferencesWinCtrl.close()
        }
        let ctrl = PreferencesWindowController(windowNibName: "PreferencesWindowController")
        preferencesWinCtrl = ctrl
        
        ctrl.showWindow(self)
        NSApp.activate(ignoringOtherApps: true)
        ctrl.window?.makeKeyAndOrderFront(self)
    }
    
    @IBAction func editAdvPreferences(_ sender: NSMenuItem) {
        if advPreferencesWinCtrl != nil {
            advPreferencesWinCtrl.close()
        }
        let ctrl = AdvPreferencesWindowController(windowNibName: "AdvPreferencesWindowController")
        advPreferencesWinCtrl = ctrl
        
        ctrl.showWindow(self)
        NSApp.activate(ignoringOtherApps: true)
        ctrl.window?.makeKeyAndOrderFront(self)
    }
    
    @IBAction func editHTTPPreferences(_ sender: NSMenuItem) {
        if httpPreferencesWinCtrl != nil {
            httpPreferencesWinCtrl.close()
        }
        let ctrl = HTTPPreferencesWindowController(windowNibName: "HTTPPreferencesWindowController")
        httpPreferencesWinCtrl = ctrl
        
        ctrl.showWindow(self)
        NSApp.activate(ignoringOtherApps: true)
        ctrl.window?.makeKeyAndOrderFront(self)
    }
    
    @IBAction func editProxyPreferences(_ sender: NSObject) {
        if proxyPreferencesWinCtrl != nil {
            proxyPreferencesWinCtrl.close()
        }
        proxyPreferencesWinCtrl = ProxyPreferencesController(windowNibName: "ProxyPreferencesController")
        proxyPreferencesWinCtrl.showWindow(self)
        NSApp.activate(ignoringOtherApps: true)
        proxyPreferencesWinCtrl.window?.makeKeyAndOrderFront(self)
    }
    
    @IBAction func selectServer(_ sender: NSMenuItem) {
        let index = sender.tag
        let spMgr = ServerProfileManager.instance
        let newProfile = spMgr.profiles[index]
        if newProfile.uuid != spMgr.activeProfileId {
            spMgr.setActiveProfiledId(newProfile.uuid)
            updateServersMenu()
            SyncSSLocal()
        }
        updateRunningModeMenu()
    }

    @IBAction func doPingTest(_ sender: AnyObject) {
        PingServers.instance.ping()
    }
    
    @IBAction func showSpeedTap(_ sender: NSMenuItem) {
        let defaults = UserDefaults.standard
        var enable = defaults.bool(forKey: "enable_showSpeed")
        enable = !enable
        setUpMenu(enable)
        defaults.set(enable, forKey: "enable_showSpeed")
        updateMainMenu()
    }

    @IBAction func showLogs(_ sender: NSMenuItem) {
        let ws = NSWorkspace.shared()
        if let appUrl = ws.urlForApplication(withBundleIdentifier: "com.apple.Console") {
            try! ws.launchApplication(at: appUrl
                ,options: .default
                ,configuration: [NSWorkspaceLaunchConfigurationArguments: "~/Library/Logs/ss-local.log"])
        }
    }
    
    @IBAction func feedback(_ sender: NSMenuItem) {
        NSWorkspace.shared().open(URL(string: "https://github.com/qinyuhang/ShadowsocksX-NG/issues")!)
    }
    
    @IBAction func showAbout(_ sender: NSMenuItem) {
        NSApp.orderFrontStandardAboutPanel(sender);
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func updateLaunchAtLoginMenu() {
        if launchAtLoginController.launchAtLogin {
            lanchAtLoginMenuItem.state = 1
        } else {
            lanchAtLoginMenuItem.state = 0
        }
    }
    
    // MARK: this function is use to update menu bar

    func updateRunningModeMenu() {
        let defaults = UserDefaults.standard
        let mode = defaults.string(forKey: "ShadowsocksRunningMode")
//<<<<<<< HEAD
        var serverMenuText = "Servers".localized
        
        let mgr = ServerProfileManager.instance
        for p in mgr.profiles {
            if mgr.activeProfileId == p.uuid {
                if !p.remark.isEmpty {
                    serverMenuText = p.remark
                } else {
                    serverMenuText = p.serverHost
                }
                if let latency = p.latency{
                    serverMenuText += "  - \(latency)ms"
                }
//=======
//
//        var serverMenuText = "Servers".localized
//        for v in defaults.array(forKey: "ServerProfiles")! {
//            let profile = v as! [String:Any]
//            if profile["Id"] as! String == defaults.string(forKey: "ActiveServerProfileId")! {
//                var profileName :String
//                if profile["Remark"] as! String != "" {
//                    profileName = profile["Remark"] as! String
//                } else {
//                    profileName = profile["ServerHost"] as! String
//>>>>>>> shadowsocks/develop
//                }
//                serverMenuText = "\(serverMenuText) - \(profileName)"
            }
        }

        serversMenuItem.title = serverMenuText

        if mode == "auto" {
            proxyMenuItem.title = "Proxy - Auto By PAC".localized
            autoModeMenuItem.state = 1
            globalModeMenuItem.state = 0
            manualModeMenuItem.state = 0
            whiteListModeMenuItem.state = 0
            whiteListDomainMenuItem.state = 0
            whiteListIPMenuItem.state = 0
        } else if mode == "global" {
            proxyMenuItem.title = "Proxy - Global".localized
            autoModeMenuItem.state = 0
            globalModeMenuItem.state = 1
            manualModeMenuItem.state = 0
            whiteListModeMenuItem.state = 0
            whiteListDomainMenuItem.state = 0
            whiteListIPMenuItem.state = 0
        } else if mode == "manual" {
            proxyMenuItem.title = "Proxy - Manual".localized
            autoModeMenuItem.state = 0
            globalModeMenuItem.state = 0
            manualModeMenuItem.state = 1
            whiteListModeMenuItem.state = 0
            whiteListDomainMenuItem.state = 0
            whiteListIPMenuItem.state = 0
        } else if mode == "whiteListDomain" {
            proxyMenuItem.title = "Proxy - White List Domain".localized
            autoModeMenuItem.state = 0
            globalModeMenuItem.state = 0
            manualModeMenuItem.state = 0
            whiteListModeMenuItem.state = 1
            whiteListDomainMenuItem.state = 1
            whiteListIPMenuItem.state = 0
        } else if mode == "whiteListIP" {
            proxyMenuItem.title = "Proxy - White List IP".localized
            autoModeMenuItem.state = 0
            globalModeMenuItem.state = 0
            manualModeMenuItem.state = 0
            whiteListModeMenuItem.state = 1
            whiteListDomainMenuItem.state = 0
            whiteListIPMenuItem.state = 1
        }
        updateStatusItemUI()
    }
    
    func updateStatusItemUI() {
        let defaults = UserDefaults.standard
        let mode = defaults.string(forKey: "ShadowsocksRunningMode")
        if mode == "auto" {
            statusItem?.title = "Auto".localized
        } else if mode == "global" {
            statusItem?.title = "Global".localized
        } else if mode == "manual" {
            statusItem?.title = "Manual".localized
        }
        let titleWidth:CGFloat = 0//statusItem?.title!.size(withAttributes: [NSFontAttributeName: statusItem?.button!.font!]).width//这里不包含IP白名单模式等等，需要重新调整//PS还是给上游加上白名单模式？
        let imageWidth:CGFloat = 22
        statusItem?.length = titleWidth + imageWidth
    }
    
    func updateMainMenu() {
        let defaults = UserDefaults.standard
        let isOn = defaults.bool(forKey: "ShadowsocksOn")
        if isOn {
            runningStatusMenuItem.title = "Shadowsocks: On".localized
            toggleRunningMenuItem.title = "Turn Shadowsocks Off".localized
            var image = NSImage(named: "menu_icon")
            if SystemThemeChangeHelper.isCurrentDark() {
                image = NSImage(named: "menu_icon_dark_mode")
            }
            
            statusItemView.setIcon(image!)
//            statusItem!.image = image
        } else {
            runningStatusMenuItem.title = "Shadowsocks: Off".localized
            toggleRunningMenuItem.title = "Turn Shadowsocks On".localized
            var image = NSImage(named: "menu_icon_disabled")
            if SystemThemeChangeHelper.isCurrentDark() {
                image = NSImage(named: "menu_icon_disabled_dark_mode")
            }
//            statusItem.image = image
            statusItemView.setIcon(image!)
        }
        
        if defaults.bool(forKey: "enable_showSpeed") {
            ShowNetworkSpeedItem.state = 1
        }else{
            ShowNetworkSpeedItem.state = 0
        }
        
        if defaults.bool(forKey: "ConnectAtLaunch") {
            connectAtLaunchMenuItem.state = 1
        } else {
            connectAtLaunchMenuItem.state = 0
        }
    }
    
    func updateServersMenu() {
        let mgr = ServerProfileManager.instance
        serversMenuItem.submenu?.removeAllItems()
        let showQRItem = showQRCodeMenuItem
        let scanQRItem = scanQRCodeMenuItem
        let preferencesItem = serversPreferencesMenuItem
        let showBunch = showBunchJsonExampleFileItem
        let importBuntch = importBunchJsonFileItem
        let exportAllServer = exportAllServerProfileItem
//        let pingItem = pingserverMenuItem

        var i = 0
        for p in mgr.profiles {
            let item = NSMenuItem()
            item.tag = i
            if p.remark.isEmpty {
                item.title = "\(p.serverHost):\(p.serverPort)"
            } else {
                item.title = "\(p.remark) (\(p.serverHost):\(p.serverPort))"
            }

            if let latency = p.latency{
                item.title += "  - \(latency)ms"
            }

            if mgr.activeProfileId == p.uuid {
                item.state = 1
            }
            if !p.isValid() {
                item.isEnabled = false
            }
            item.action = #selector(AppDelegate.selectServer)
            
            serversMenuItem.submenu?.addItem(item)
            i += 1
        }
        if !mgr.profiles.isEmpty {
            serversMenuItem.submenu?.addItem(NSMenuItem.separator())
        }
        serversMenuItem.submenu?.addItem(showQRItem!)
        serversMenuItem.submenu?.addItem(scanQRItem!)
        serversMenuItem.submenu?.addItem(showBunch!)
        serversMenuItem.submenu?.addItem(importBuntch!)
        serversMenuItem.submenu?.addItem(exportAllServer!)
        serversMenuItem.submenu?.addItem(NSMenuItem.separator())
        serversMenuItem.submenu?.addItem(preferencesItem!)
//        serversMenuItem.submenu?.addItem(pingItem)

    }
    
    func setUpMenu(_ showSpeed:Bool){
        if statusItem == nil{
            statusItem = NSStatusBar.system().statusItem(withLength: 85)
            let image = NSImage(named: "menu_icon")
            image?.isTemplate = true
            statusItem!.image = image
            statusItemView = StatusItemView(statusItem: statusItem!, menu: statusMenu)
            statusItem!.view = statusItemView
        }
        if showSpeed{
            if speedMonitor == nil{
                speedMonitor = NetWorkMonitor(statusItemView: statusItemView)
            }
            statusItem?.length = 85
            speedMonitor?.start()
        }else{
            speedMonitor?.stop()
            speedMonitor = nil
            statusItem?.length = 20
        }
    }
    
    // MARK: 

    func handleURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        if let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue {
            if let url = URL(string: urlString) {
                NotificationCenter.default.post(
                    name: Notification.Name(rawValue: "NOTIFY_FOUND_SS_URL"), object: nil
                    , userInfo: [
                        "ruls": [url],
                        "source": "url",
                    ])
            }
        }
    }
    
    //------------------------------------------------------------
    // MARK: NSUserNotificationCenterDelegate
    
    func userNotificationCenter(_ center: NSUserNotificationCenter
        , shouldPresent notification: NSUserNotification) -> Bool {
        return true
    }
}


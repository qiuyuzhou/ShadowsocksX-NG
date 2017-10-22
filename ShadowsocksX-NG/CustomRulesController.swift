import Cocoa


class CustomRulesController: NSWindowController {

    @IBOutlet weak var proxyListTableView: NSTableView!
    @IBOutlet weak var bypassListTableView: NSTableView!

    @IBOutlet var proxyListController: NSArrayController!
    @IBOutlet var bypassListController: NSArrayController!

    @IBOutlet weak var proxyListActionButtons: NSSegmentedControl!
    @IBOutlet weak var bypassListActionButtons: NSSegmentedControl!

    dynamic var proxyList = [ACLEntry]()
    dynamic var bypassList = [ACLEntry]()

    override var windowNibName: String? {
        return "CustomRulesController"
    }

    override func windowDidLoad() {
        super.windowDidLoad()

        if let window = window {
            window.center()
            window.makeKeyAndOrderFront(nil)
        } else {
            NSLog("CustomRulesController window not exist yet")
        }

        proxyListController.addObserver(self, forKeyPath: "selection", context: nil)
        bypassListController.addObserver(self, forKeyPath: "selection", context: nil)

        parseFromACL(acl: .custom)
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                      change: [NSKeyValueChangeKey : Any]?,
                      context: UnsafeMutableRawPointer?) {
        guard let object = object, let controller = object as? NSArrayController else {
            return
        }

        let enable = !controller.selectedObjects.isEmpty

        switch controller {
        case proxyListController:
            proxyListActionButtons.setEnabled(enable, forSegment: 1)

        case bypassListController:
            bypassListActionButtons.setEnabled(enable, forSegment: 1)

        default:
            return
        }
    }

    @IBAction func performListAction(_ sender: NSSegmentedControl) {
        let target: NSArrayController
        let tableView: NSTableView
        switch sender {
        case proxyListActionButtons:
            target = proxyListController
            tableView = proxyListTableView

        case bypassListActionButtons:
            target = bypassListController
            tableView = bypassListTableView

        default:
            return
        }

        switch sender.selectedSegment {
        case 0: // add
            target.addObject(target.newObject())  // Don't use add() because it defers adding
            tableView.editColumn(0, row: target.selectionIndex, with: nil, select: true)

        case 1: // remove
            target.remove(atArrangedObjectIndex: target.selectionIndex)

        default:
            return
        }
    }

    @IBAction func saveAndClose(_ sender: Any) {
        guard let window = self.window else {
            return
        }

        if writeToACL(acl: .custom) {
            window.performClose(sender)
            SyncSSLocal()
        } else {
            let alert = NSAlert()
            alert.messageText = "Failed to write custom ACL rules.".localized
            alert.beginSheetModal(for: window)
        }
    }

    @IBAction func discardAndClose(_ sender: Any) {
        self.window?.performClose(sender)
    }

    func parseFromACL(acl: ACLRule) {
        bypassList.removeAll()
        proxyList.removeAll()

        let parsed = ACLRule.parse(content: acl.load())
        bypassList = parsed.bypassList.map { ACLEntry(stringValue: $0) }
        proxyList = parsed.proxyList.map { ACLEntry(stringValue: $0) }
    }

    func writeToACL(acl: ACLRule) -> Bool {
        let rawProxyList = proxyList.map { $0.stringValue }
        let rawBypassList = bypassList.map { $0.stringValue }

        let content = ACLRule.compose(proxyList: rawProxyList,
                                      bypassList: rawBypassList)

        return acl.save(content: content)
    }
}

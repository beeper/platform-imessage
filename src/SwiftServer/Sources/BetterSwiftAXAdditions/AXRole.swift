import ApplicationServices

// https://developer.apple.com/documentation/applicationservices/carbon_accessibility/roles
public enum AXRole {
    public static let searchField = "AXSearchField"
    public static let application = kAXApplicationRole
    public static let systemWide = kAXSystemWideRole
    public static let window = kAXWindowRole
    public static let sheet = kAXSheetRole
    public static let drawer = kAXDrawerRole
    public static let growArea = kAXGrowAreaRole
    public static let image = kAXImageRole
    public static let unknown = kAXUnknownRole
    public static let button = kAXButtonRole
    public static let radioButton = kAXRadioButtonRole
    public static let checkBox = kAXCheckBoxRole
    public static let popUpButton = kAXPopUpButtonRole
    public static let menuButton = kAXMenuButtonRole
    public static let tabGroup = kAXTabGroupRole
    public static let table = kAXTableRole
    public static let column = kAXColumnRole
    public static let row = kAXRowRole
    public static let outline = kAXOutlineRole
    public static let browser = kAXBrowserRole
    public static let scrollArea = kAXScrollAreaRole
    public static let scrollBar = kAXScrollBarRole
    public static let radioGroup = kAXRadioGroupRole
    public static let list = kAXListRole
    public static let group = kAXGroupRole
    public static let valueIndicator = kAXValueIndicatorRole
    public static let comboBox = kAXComboBoxRole
    public static let slider = kAXSliderRole
    public static let incrementor = kAXIncrementorRole
    public static let busyIndicator = kAXBusyIndicatorRole
    public static let progressIndicator = kAXProgressIndicatorRole
    public static let relevanceIndicator = kAXRelevanceIndicatorRole
    public static let toolbar = kAXToolbarRole
    public static let disclosureTriangle = kAXDisclosureTriangleRole
    public static let textField = kAXTextFieldRole
    public static let textArea = kAXTextAreaRole
    public static let staticText = kAXStaticTextRole
    public static let menuBar = kAXMenuBarRole
    public static let menuBarItem = kAXMenuBarItemRole
    public static let menu = kAXMenuRole
    public static let menuItem = kAXMenuItemRole
    public static let splitGroup = kAXSplitGroupRole
    public static let splitter = kAXSplitterRole
    public static let colorWell = kAXColorWellRole
    public static let timeField = kAXTimeFieldRole
    public static let dateField = kAXDateFieldRole
    public static let helpTag = kAXHelpTagRole
    public static let matte = kAXMatteRole
    public static let dockItem = kAXDockItemRole
    public static let cell = kAXCellRole
}

public enum AXSubrole {
    public static let `switch` = kAXSwitchSubrole
    public static let closeButton = kAXCloseButtonSubrole
    public static let minimizeButton = kAXMinimizeButtonSubrole
    public static let zoomButton = kAXZoomButtonSubrole
    public static let toolbarButton = kAXToolbarButtonSubrole
    public static let secureTextField = kAXSecureTextFieldSubrole
    public static let tableRow = kAXTableRowSubrole
    public static let outlineRow = kAXOutlineRowSubrole
    public static let unknown = kAXUnknownSubrole
    public static let standardWindow = kAXStandardWindowSubrole
    public static let dialog = kAXDialogSubrole
    public static let systemDialog = kAXSystemDialogSubrole
    public static let floatingWindow = kAXFloatingWindowSubrole
    public static let systemFloatingWindow = kAXSystemFloatingWindowSubrole
    public static let incrementArrow = kAXIncrementArrowSubrole
    public static let decrementArrow = kAXDecrementArrowSubrole
    public static let incrementPage = kAXIncrementPageSubrole
    public static let decrementPage = kAXDecrementPageSubrole
    public static let sortButton = kAXSortButtonSubrole
    public static let searchField = kAXSearchFieldSubrole
    public static let applicationDockItem = kAXApplicationDockItemSubrole
    public static let documentDockItem = kAXDocumentDockItemSubrole
    public static let folderDockItem = kAXFolderDockItemSubrole
    public static let minimizedWindowDockItem = kAXMinimizedWindowDockItemSubrole
    public static let urlDockItem = kAXURLDockItemSubrole
    public static let dockExtraDockItem = kAXDockExtraDockItemSubrole
    public static let trashDockItem = kAXTrashDockItemSubrole
    public static let processSwitcherList = kAXProcessSwitcherListSubrole
}

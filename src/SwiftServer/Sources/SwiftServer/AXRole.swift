import ApplicationServices

// https://developer.apple.com/documentation/applicationservices/carbon_accessibility/roles
enum AXRole {
    static let searchField = "AXSearchField"
    static let application = kAXApplicationRole
    static let systemWide = kAXSystemWideRole
    static let window = kAXWindowRole
    static let sheet = kAXSheetRole
    static let drawer = kAXDrawerRole
    static let growArea = kAXGrowAreaRole
    static let image = kAXImageRole
    static let unknown = kAXUnknownRole
    static let button = kAXButtonRole
    static let radioButton = kAXRadioButtonRole
    static let checkBox = kAXCheckBoxRole
    static let popUpButton = kAXPopUpButtonRole
    static let menuButton = kAXMenuButtonRole
    static let tabGroup = kAXTabGroupRole
    static let table = kAXTableRole
    static let column = kAXColumnRole
    static let row = kAXRowRole
    static let outline = kAXOutlineRole
    static let browser = kAXBrowserRole
    static let scrollArea = kAXScrollAreaRole
    static let scrollBar = kAXScrollBarRole
    static let radioGroup = kAXRadioGroupRole
    static let list = kAXListRole
    static let group = kAXGroupRole
    static let valueIndicator = kAXValueIndicatorRole
    static let comboBox = kAXComboBoxRole
    static let slider = kAXSliderRole
    static let incrementor = kAXIncrementorRole
    static let busyIndicator = kAXBusyIndicatorRole
    static let progressIndicator = kAXProgressIndicatorRole
    static let relevanceIndicator = kAXRelevanceIndicatorRole
    static let toolbar = kAXToolbarRole
    static let disclosureTriangle = kAXDisclosureTriangleRole
    static let textField = kAXTextFieldRole
    static let textArea = kAXTextAreaRole
    static let staticText = kAXStaticTextRole
    static let menuBar = kAXMenuBarRole
    static let menuBarItem = kAXMenuBarItemRole
    static let menu = kAXMenuRole
    static let menuItem = kAXMenuItemRole
    static let splitGroup = kAXSplitGroupRole
    static let splitter = kAXSplitterRole
    static let colorWell = kAXColorWellRole
    static let timeField = kAXTimeFieldRole
    static let dateField = kAXDateFieldRole
    static let helpTag = kAXHelpTagRole
    static let matte = kAXMatteRole
    static let dockItem = kAXDockItemRole
}

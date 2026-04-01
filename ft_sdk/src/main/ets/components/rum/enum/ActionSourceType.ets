/**
 * Action source type
 * Aligned with Android SDK: ActionSourceType
 */
export enum ActionSourceType {
  CLICK_VIEW = "CLICK_VIEW",             // Normal View click
  CLICK_LIST_ITEM = "CLICK_LIST_ITEM",        // ListView、GridView item
  CLICK_EXPAND_LIST_ITEM = "CLICK_EXPAND_LIST_ITEM", // ExpandListView item
  CLICK_EXPAND_GROUP_ITEM = "CLICK_EXPAND_GROUP_ITEM", // ExpandListView group
  CLICK_RADIO_BUTTON = "CLICK_RADIO_BUTTON", // Radio button
  CLICK_TAB = "CLICK_TAB",              // Tab item
  CLICK_DIALOG_BUTTON = "CLICK_DIALOG_BUTTON",    // DialogInterface button
  CLICK_MENU_ITEM = "CLICK_MENU_ITEM",        // MenuItem
  CLICK_BACK = "CLICK_BACK",
  CLICK_MENU = "CLICK_MENU",
  CLICK_PAD_CENTER = "CLICK_PAD_CENTER",
  LAUNCH_HOT = "LAUNCH_HOT",             // launch hot
  LAUNCH_COLD = "LAUNCH_COLD"             // launch cold
}


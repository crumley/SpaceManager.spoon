// SpaceManager Inbox: every new tab in the Inbox window goes into the group
// for the day it was opened, "📅 Sat, Oct 4". The Inbox is the window holding
// this extension's inbox.html tab; SpaceManager opens it there by name.
const INBOX_PAGE = chrome.runtime.getURL("inbox.html");
// One color per weekday, so neighbouring days never share one.
const COLORS = ["purple", "blue", "cyan", "green", "yellow", "orange", "red"];

function todayTitle(now = new Date()) {
  const day = now.toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric" });
  return "📅 " + day;
}

async function isInbox(windowId) {
  const tabs = await chrome.tabs.query({ windowId });
  return tabs.some((t) => (t.url || t.pendingUrl || "").startsWith(INBOX_PAGE));
}

async function groupIntoToday(tabId) {
  // Chrome puts a tab opened from a grouped page into that page's group just
  // after creating it; leave those where Chrome put them.
  await new Promise((resolve) => setTimeout(resolve, 150));
  let tab;
  try {
    tab = await chrome.tabs.get(tabId);
  } catch {
    return; // closed already
  }
  if (tab.pinned || tab.groupId !== chrome.tabGroups.TAB_GROUP_ID_NONE) return;
  if ((tab.url || tab.pendingUrl || "").startsWith(INBOX_PAGE)) return;
  if (!(await isInbox(tab.windowId))) return;

  const title = todayTitle();
  const [group] = await chrome.tabGroups.query({ windowId: tab.windowId, title });
  if (group) {
    await chrome.tabs.group({ groupId: group.id, tabIds: [tabId] });
    return;
  }
  const groupId = await chrome.tabs.group({ createProperties: { windowId: tab.windowId }, tabIds: [tabId] });
  await chrome.tabGroups.update(groupId, { title, color: COLORS[new Date().getDay()] });
}

// One at a time: two tabs opened together must not each start today's group.
let queue = Promise.resolve();
chrome.tabs.onCreated.addListener((tab) => {
  queue = queue.then(() => groupIntoToday(tab.id)).catch((e) => console.warn("Inbox grouping failed", e));
});

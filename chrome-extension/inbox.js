// The marker tab pins itself, so it stays out of the way at the left.
chrome.tabs.getCurrent((tab) => {
  if (tab && !tab.pinned) chrome.tabs.update(tab.id, { pinned: true });
});

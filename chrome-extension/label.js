// The extension's marker pages pin themselves, so they stay out of the way at
// the left, and draw their own tab icon: pinned tabs show only the icon.
//   label.html?name=🟥 01 - Today&n=01&bg=ff3380&fg=000000 -- SpaceManager
//     keeps one in every window named after a space; the icon is the space's
//     number on its color.
//   inbox.html -- the Inbox's marker; its icon is data-icon on <body>.
chrome.tabs.getCurrent((tab) => {
  if (tab && !tab.pinned) chrome.tabs.update(tab.id, { pinned: true });
});

const params = new URLSearchParams(location.search);
const name = params.get("name");
if (name) {
  document.title = name;
  document.getElementById("name").textContent = name;
}

function drawIcon(text, bg, fg) {
  const size = 64;
  const canvas = document.createElement("canvas");
  canvas.width = canvas.height = size;
  const ctx = canvas.getContext("2d");
  if (bg) {
    ctx.fillStyle = bg;
    ctx.beginPath();
    ctx.roundRect(0, 0, size, size, 14);
    ctx.fill();
  }
  ctx.fillStyle = fg || "#000";
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.font = bg ? "bold 40px Menlo, monospace" : "52px sans-serif";
  ctx.fillText(text, size / 2, size / 2 + 3);
  const link = document.createElement("link");
  link.rel = "icon";
  link.href = canvas.toDataURL();
  document.head.appendChild(link);
}

const hex = (v) => (v && /^[0-9a-f]{6}$/i.test(v) ? "#" + v : null);
if (params.get("n")) {
  drawIcon(params.get("n"), hex(params.get("bg")) || "#888", hex(params.get("fg")));
} else if (document.body.dataset.icon) {
  drawIcon(document.body.dataset.icon);
}
